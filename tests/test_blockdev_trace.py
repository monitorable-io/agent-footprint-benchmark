"""Unit tests for collector/blockdev_trace.py against a fake tracefs tree.

Why the module exists (run log 2026, "Deviations"): ext4 writes its metadata through the block
device's own inode, and cgroup v2 charges an inode's writeback to ONE cgroup, whichever currently
owns it. On the 2026 bed that owner was a mount unit with no process, rsyslog, the root cgroup, and
for 7-8 hours in two runs the measured agent. The tracer records how much of that stream was charged
to each cgroup so the summary can take it out of the agent's figure.
"""
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "collector"))
import blockdev_trace as bt  # noqa: E402

LINE = ("   kworker/u8:3-27804   [001] ..... 4431.350273: writeback_single_inode: bdi 8:0: ino=8388609 "
        "state=I_SYNC|I_SYNC_QUEUED dirtied_when=4431350273 age=129 index=0 to_write=1024 wrote={wrote} cgroup_ino={cg}\n")


FORMAT = ('name: writeback_single_inode\nprint fmt: "bdi %s: ino=%lu state=%s dirtied_when=%lu age=%lu index=%lu '
          'to_write=%ld wrote=%lu cgroup_ino=%lu", REC->name\n')


def fake_tracefs(d):
    """A tracefs with the bench instance already there (the real one creates the tree on mkdir)."""
    ev = Path(d) / "instances" / "bench" / "events" / "writeback" / "writeback_single_inode"
    ev.mkdir(parents=True)
    (ev / "enable").write_text("0\n")
    (ev / "filter").write_text("none\n")
    (ev / "format").write_text(FORMAT)
    pipe = Path(d) / "instances" / "bench" / "trace_pipe"
    pipe.write_text("")
    return ev, pipe


class ParseTest(unittest.TestCase):
    def test_parse_line(self):
        self.assertEqual(bt.parse_line(LINE.format(wrote=5, cg=886)), (8388609, 5, 886))

    def test_parse_line_ignores_other_text(self):
        self.assertIsNone(bt.parse_line("# tracer: nop\n"))
        self.assertIsNone(bt.parse_line("   kworker/u8:3-1 [000] ..... 1.0: writeback_start: bdi 8:0: sb_dev 0:0\n"))

    def test_blockdev_ino_is_the_kernel_dev_t(self):
        # sda1 = 8:1 -> (8 << 20) | 1, the inode number the kernel gives the block device itself
        self.assertEqual(bt.blockdev_ino(os.makedev(8, 1)), 8388609)
        self.assertEqual(bt.blockdev_ino(os.makedev(252, 3)), (252 << 20) | 3)


class TracerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ev, self.pipe = fake_tracefs(self.tmp.name)
        self.t = bt.Tracer(self.tmp.name, ino=8388609, page_size=4096)

    def tearDown(self):
        self.t.close()
        self.tmp.cleanup()

    def test_arm_sets_the_filter_then_enables_the_event(self):
        self.t.arm()
        self.assertEqual((self.ev / "filter").read_text().strip(), "ino == 8388609")
        self.assertEqual((self.ev / "enable").read_text().strip(), "1")

    def test_poll_returns_new_bytes_per_cgroup_inode(self):
        self.t.arm()
        with open(self.pipe, "a") as f:
            f.write(LINE.format(wrote=5, cg=886) + LINE.format(wrote=3, cg=886) + LINE.format(wrote=2, cg=4760))
        self.assertEqual(self.t.poll(), {886: 8 * 4096, 4760: 2 * 4096})
        self.assertEqual(self.t.poll(), {})          # nothing new
        with open(self.pipe, "a") as f:
            f.write(LINE.format(wrote=1, cg=886))
        self.assertEqual(self.t.poll(), {886: 4096})

    def test_poll_keeps_a_torn_line_for_the_next_poll(self):
        self.t.arm()
        whole = LINE.format(wrote=7, cg=886)
        with open(self.pipe, "a") as f:
            f.write(whole[:60])
        self.assertEqual(self.t.poll(), {})
        with open(self.pipe, "a") as f:
            f.write(whole[60:])
        self.assertEqual(self.t.poll(), {886: 7 * 4096})

    def test_poll_drops_other_inodes_even_if_the_kernel_filter_was_refused(self):
        self.t.arm()
        with open(self.pipe, "a") as f:
            f.write(LINE.format(wrote=9, cg=886).replace("ino=8388609", "ino=14465"))
        self.assertEqual(self.t.poll(), {})

    def test_arm_refuses_a_kernel_whose_event_lacks_the_fields(self):
        # A tracer that arms and then parses nothing would publish the full charge with no warning.
        (self.ev / "format").write_text('print fmt: "bdi %s: ino=%lu wrote=%lu", REC->name\n')
        with self.assertRaises(OSError) as cm:
            self.t.arm()
        self.assertIn("cgroup_ino=", str(cm.exception))
        self.assertEqual((self.ev / "enable").read_text().strip(), "0")

    def test_poll_counts_lines_it_cannot_read(self):
        self.t.arm()
        with open(self.pipe, "a") as f:
            f.write("CPU:1 [LOST 12 EVENTS]\n" + LINE.format(wrote=1, cg=886) + "garbage\n")
        self.assertEqual(self.t.poll(), {886: 4096})
        self.assertEqual(self.t.unparsed, 2)
        self.assertEqual(self.t.last_unparsed, "garbage")

    def test_arm_fails_loudly_without_the_event(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(OSError):
                bt.Tracer(d, ino=1).arm()


class LedgerTest(unittest.TestCase):
    """Cumulative bytes per measured row: a row owns its cgroup's inode and every inode below it."""

    def test_bytes_are_added_to_the_row_that_owns_the_cgroup_inode(self):
        led = bt.Ledger()
        led.add({886: 4096, 500: 8192, 501: 100}, {"system.slice/a.service": {500, 501}, "system.slice/b.service": {600}})
        self.assertEqual(led.row("system.slice/a.service"), 8292)
        self.assertEqual(led.row("system.slice/b.service"), 0)
        self.assertEqual(led.total, 4096 + 8192 + 100)
        led.add({600: 5}, {"system.slice/a.service": {500, 501}, "system.slice/b.service": {600}})
        self.assertEqual(led.row("system.slice/b.service"), 5)
        self.assertEqual(led.row("system.slice/a.service"), 8292)

    def test_a_child_cgroup_that_vanished_is_still_charged_to_its_row(self):
        led = bt.Ledger()
        led.add({}, {"system.slice/s.slice": {10, 11}})          # 11 = a transient child, seen once
        led.add({11: 4096}, {"system.slice/s.slice": {10}})       # gone by the time its event is read
        self.assertEqual(led.row("system.slice/s.slice"), 4096)

    def test_seed_continues_the_previous_sampler_process(self):
        led = bt.Ledger()
        led.seed({"a": 8192}, 20480)
        led.add({10: 4096}, {"a": {10}})
        self.assertEqual((led.row("a"), led.total), (12288, 24576))

    def test_an_inode_seen_under_another_row_moves(self):
        led = bt.Ledger()
        led.add({}, {"a": {10}})
        led.add({10: 1}, {"b": {10}})                             # cgroupfs reused the number
        self.assertEqual((led.row("a"), led.row("b")), (0, 1))


if __name__ == "__main__":
    unittest.main()
