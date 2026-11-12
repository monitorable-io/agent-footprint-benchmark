"""Unit tests for collector/bench_collector.py against a fake /sys/fs/cgroup + /proc tree."""
import os
import tempfile
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "collector"))
import bench_collector as bc  # noqa: E402

FIX = ROOT / "tests" / "fixtures" / "cgroup"
CG = FIX / "sys" / "fs" / "cgroup"
PROC = FIX / "proc"


class DiscoverTest(unittest.TestCase):
    def test_discover_matches_globs(self):
        found = bc.discover(CG, ["system.slice/netdata.service"])
        self.assertEqual(list(found), ["system.slice/netdata.service"])
        self.assertEqual(found["system.slice/netdata.service"], os.stat(CG / "system.slice/netdata.service").st_ino)
        both = bc.discover(CG, ["system.slice/*.service"])
        self.assertEqual(sorted(both), ["system.slice/docker.service", "system.slice/netdata.service"])

    def test_restart_detected_on_new_inode(self):
        before = {"system.slice/x.service": 1001}
        after = {"system.slice/x.service": 1002}
        self.assertEqual(bc.diff_discovery(before, after), [("restart", "system.slice/x.service")])
        self.assertEqual(bc.diff_discovery({}, after), [("cgroup_appeared", "system.slice/x.service")])
        self.assertEqual(bc.diff_discovery(after, {}), [("cgroup_gone", "system.slice/x.service")])
        self.assertEqual(bc.diff_discovery(after, after), [])

    def test_restart_detected_on_counter_going_backwards(self):
        # cgroupfs reuses inode numbers, so a recreated cgroup may keep its inode: a CPU counter
        # that moves backwards is the second signal.
        prev = {"system.slice/x.service": 500000}
        self.assertEqual(bc.counter_resets(prev, {"system.slice/x.service": 600000}), [])
        self.assertEqual(bc.counter_resets(prev, {"system.slice/x.service": 1200}), ["system.slice/x.service"])
        self.assertEqual(bc.counter_resets({}, {"system.slice/x.service": 1200}), [])


class SafetyTest(unittest.TestCase):
    def test_discover_skips_paths_outside_the_safe_charset(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "system.slice" / "ok-1.service").mkdir(parents=True)
            (root / "system.slice" / 'bad",x.service').mkdir()
            found = bc.discover(root, ["system.slice/*.service"])
            self.assertEqual(list(found), ["system.slice/ok-1.service"])

    def test_sample_structured_carries_cpu_without_reparsing(self):
        structured, rows = bc.sample_structured(CG, PROC, {"system.slice/netdata.service": 1}, ts=1, net=lambda cg: (0, 0))
        self.assertEqual(structured["system.slice/netdata.service"]["cpu_usage_usec"], 123456)
        self.assertEqual(len(rows), 2)


class NetPortsTest(unittest.TestCase):
    def test_net_ports_mode_arms_port_rules_once_and_reads_counters_once_per_tick(self):
        import types

        fake = types.ModuleType("netcounters")
        calls = []
        fake.ensure_table = lambda: calls.append("table")
        fake.ensure_port_rules = lambda ports, key: calls.append(("ports", tuple(ports), key))
        fake.ensure_rules = lambda path, key: calls.append(("cgroup", path, key))
        fake.key_for = lambda p: "k"
        fake.read_all = lambda: (calls.append("read"), {"out_ports": 11, "in_ports": 22})[1]
        fake.read = lambda k, snapshot=None: ((snapshot or {}).get("out_" + k, 0), (snapshot or {}).get("in_" + k, 0))
        with tempfile.TemporaryDirectory() as d:
            out, ev = Path(d) / "s.csv", Path(d) / "e.csv"
            saved = sys.modules.get("netcounters")
            sys.modules["netcounters"] = fake
            try:
                bc.main(["--root", str(CG), "--proc", str(PROC), "--globs", "system.slice/*.service",
                         "--out", str(out), "--events", str(ev), "--netcounters", "--net-ports", "9100", "--once"])
            finally:
                if saved is not None:
                    sys.modules["netcounters"] = saved
                else:
                    sys.modules.pop("netcounters", None)
            rows = out.read_text().splitlines()
        self.assertIn(("ports", (9100,), "ports"), calls)
        self.assertFalse(any(c[0] == "cgroup" for c in calls if isinstance(c, tuple)))
        self.assertEqual(calls.count("read"), 1)  # two cgroups matched, one nft read
        unit_rows = [r for r in rows[1:] if ",box," not in r]
        self.assertEqual(len(unit_rows), 2)
        # port counters are attributed to the first cgroup only, so a multi-cgroup row is not double counted
        self.assertEqual(unit_rows[0].split(",")[14:16], ["11", "22"])
        self.assertEqual(unit_rows[1].split(",")[14:16], ["0", "0"])


class NetFailureTest(unittest.TestCase):
    def test_collector_survives_nft_failure(self):
        import subprocess
        import types

        fake = types.ModuleType("netcounters")
        fake.ensure_table = lambda: None
        fake.key_for = lambda p: "k"
        fake.read = lambda k, snapshot=None: (0, 0)
        fake.read_all = lambda: {}

        def boom(path, key):
            raise subprocess.CalledProcessError(1, ["nft"], stderr="Error: syntax error")

        fake.ensure_rules = boom
        with tempfile.TemporaryDirectory() as d:
            out, ev = Path(d) / "s.csv", Path(d) / "e.csv"
            saved = sys.modules.get("netcounters")
            sys.modules["netcounters"] = fake
            try:
                bc.main(["--root", str(CG), "--proc", str(PROC), "--globs", "system.slice/netdata.service",
                         "--out", str(out), "--events", str(ev), "--netcounters", "--once"])
            finally:
                if saved is not None:
                    sys.modules["netcounters"] = saved
                else:
                    sys.modules.pop("netcounters", None)
            self.assertIn("netcounter_error", ev.read_text())
            self.assertEqual(len(out.read_text().splitlines()), 3)  # header + unit row + box row


class ReadTest(unittest.TestCase):
    def test_read_cgroup_parses_cpu_memory_io_pids(self):
        s = bc.read_cgroup(CG, "system.slice/netdata.service")
        self.assertEqual(s["cpu_usage_usec"], 123456)
        self.assertEqual(s["memory_current"], 104857600)
        self.assertEqual(s["memory_peak"], 157286400)
        self.assertEqual(s["anon"], 73400320)
        self.assertEqual(s["file"], 20971520)
        self.assertEqual(s["io_rbytes"], 1024)
        self.assertEqual(s["io_wbytes"], 2048)
        self.assertEqual(s["pids"], 2)  # processes = cgroup.procs; pids.current counts threads too
        self.assertEqual(s["procs"], [4242, 4243])

    def test_read_pss_rss_sums_over_pids_and_counts_threads(self):
        pss_kb, rss_kb, threads = bc.read_pss_rss(PROC, [4242, 4243, 99999])  # 99999 vanished
        self.assertEqual(pss_kb, 40960 + 8192)
        self.assertEqual(rss_kb, 51200 + 10240)
        self.assertEqual(threads, 15)

    def test_box_stats_reads_loadavg_meminfo_steal(self):
        b = bc.box_stats(PROC)
        self.assertEqual(b["box_load1"], 0.42)
        self.assertEqual(b["box_memavail_kb"], 1500000)
        self.assertEqual(b["box_steal_ticks"], 77)


class CsvTest(unittest.TestCase):
    def test_csv_header_exact(self):
        self.assertEqual(
            bc.HEADER,
            "ts,cgroup,cgroup_ino,cpu_usage_usec,memory_current,memory_peak,anon,file,pss,rss,io_rbytes,io_wbytes,pids,threads,net_out,net_in,box_load1,box_memavail_kb,box_steal_ticks,"
            "io_wbytes_blockdev,box_wbytes_blockdev",
        )

    def test_sample_rows_for_unit_and_box(self):
        rows = bc.sample(CG, PROC, {"system.slice/netdata.service": 1}, ts=1700000000, net=lambda cg: (10, 20))
        self.assertEqual(len(rows), 2)
        unit = rows[0].split(",")
        self.assertEqual(unit[:3], ["1700000000", "system.slice/netdata.service", "1"])
        self.assertEqual(unit[8:10], [str((40960 + 8192) * 1024), str((51200 + 10240) * 1024)])
        self.assertEqual(unit[14:16], ["10", "20"])
        box = rows[1].split(",")
        self.assertEqual(box[1], "box")
        self.assertEqual(box[16:19], ["0.42", "1500000", "77"])
        self.assertEqual((unit[19:], box[19:]), (["", ""], ["", ""]))  # no tracer: the two columns stay empty


class ChildCgroupTest(unittest.TestCase):
    """HetrixTools runs as a minutely transient unit inside its slice: the pilot read only the
    slice's own cgroup.procs and saw no process in 27,006 samples."""

    def _slice(self, root):
        sl = root / "system.slice" / "system-x.slice"
        for name, pid in (("x-1.service", 101), ("x-2.service", 102)):
            (sl / name).mkdir(parents=True)
            (sl / name / "cgroup.procs").write_text(f"{pid}\n")
        (sl / "cgroup.procs").write_text("")
        return sl

    def test_read_cgroup_sums_child_cgroup_procs(self):
        with tempfile.TemporaryDirectory() as d:
            self._slice(Path(d))
            s = bc.read_cgroup(d, "system.slice/system-x.slice")
            self.assertEqual(s["pids"], 2)
            self.assertEqual(sorted(s["procs"]), [101, 102])

    def test_read_cgroup_tolerates_vanishing_child(self):
        # A transient unit that exits between listing and reading: its cgroup.procs is gone.
        with tempfile.TemporaryDirectory() as d:
            sl = self._slice(Path(d))
            gone = sl / "x-3.service"
            gone.mkdir()
            os.symlink(gone / "no-such-file", gone / "cgroup.procs")  # read -> FileNotFoundError
            s = bc.read_cgroup(d, "system.slice/system-x.slice")
            self.assertEqual(sorted(s["procs"]), [101, 102])


class SamplerRestartTest(unittest.TestCase):
    def _run(self, d, extra=(), clock=None):
        out, ev = Path(d) / "samples.csv", Path(d) / "events.csv"
        args = ["--root", str(CG), "--proc", str(PROC), "--globs", "system.slice/netdata.service",
                "--out", str(out), "--events", str(ev), *extra]
        if clock is None:
            bc.main(args + ["--once"])
        else:
            from unittest import mock
            now = [clock]

            def sleep(s):
                now[0] += s

            with mock.patch.object(bc.time, "time", lambda: now[0]), mock.patch.object(bc.time, "sleep", sleep):
                bc.main(args)
        return out, ev

    def test_restart_detected_across_sampler_restart(self):
        # The agent was restarted while the sampler was down (or in the sampler's own restart tick):
        # the persisted inode map is what tells.
        import json
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "samples.inodes.json").write_text(json.dumps({"system.slice/netdata.service": 100}))
            out, ev = self._run(d)
            events = [line.split(",")[1:3] for line in ev.read_text().splitlines()[1:]]
            self.assertIn(["restart", "system.slice/netdata.service"], events)
            saved = json.loads((Path(d) / "samples.inodes.json").read_text())
            self.assertEqual(saved, {"system.slice/netdata.service": os.stat(CG / "system.slice/netdata.service").st_ino})

    def test_no_restart_when_inode_unchanged(self):
        import json
        with tempfile.TemporaryDirectory() as d:
            ino = os.stat(CG / "system.slice/netdata.service").st_ino
            (Path(d) / "samples.inodes.json").write_text(json.dumps({"system.slice/netdata.service": ino}))
            out, ev = self._run(d)
            self.assertNotIn(",restart,", ev.read_text())
            self.assertIn(",cgroup_appeared,system.slice/netdata.service,", ev.read_text())

    def test_inode_state_saved_only_when_it_changes(self):
        # Review of PR #8: a save every tick is ~35 MB/day of writes charged to bench-collector.service,
        # which is the published control row.
        from unittest import mock
        calls = []
        real = bc.save_inode_state
        with tempfile.TemporaryDirectory() as d, \
                mock.patch.object(bc, "save_inode_state", lambda p, c: (calls.append(dict(c)), real(p, c))):
            self._run(d, extra=["--ticks", "5"], clock=2000.0)
            self.assertTrue((Path(d) / "samples.inodes.json").exists())
        self.assertEqual(len(calls), 1)  # the first tick only; the map never changed

    def test_inode_state_write_failure_does_not_stop_sampling(self):
        from unittest import mock

        def boom(path, cgroups):
            raise OSError(28, "No space left on device")

        with tempfile.TemporaryDirectory() as d, mock.patch.object(bc, "save_inode_state", boom):
            out, ev = self._run(d, extra=["--ticks", "2"], clock=3000.0)
            self.assertEqual(len(out.read_text().splitlines()), 1 + 2 * 2)  # header + 2 ticks x (unit + box)
            self.assertIn(",state_error,", ev.read_text())

    def test_load_inode_state_tolerates_missing_or_broken_file(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(bc.load_inode_state(Path(d) / "none.json"), {})
            (Path(d) / "bad.json").write_text("{not json")
            self.assertEqual(bc.load_inode_state(Path(d) / "bad.json"), {})

    def test_last_written_ts(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "s.csv"
            self.assertIsNone(bc.last_written_ts(p))
            p.write_text(bc.HEADER + "\n")
            self.assertIsNone(bc.last_written_ts(p))
            p.write_text(bc.HEADER + "\n990,a,1\n1000,a,1\n1000,box,\n")
            self.assertEqual(bc.last_written_ts(p), 1000)
            p.write_text(bc.HEADER + "\n1000,box,\n10")  # a torn last line is ignored
            self.assertEqual(bc.last_written_ts(p), 1000)

    def test_second_process_skips_already_written_ts(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "samples.csv"
            out.write_text(bc.HEADER + "\n1000,system.slice/netdata.service,1" + ",0" * 16 + "\n1000,box,\n")
            self._run(d, extra=["--ticks", "2"], clock=1000.2)
            ts = [line.split(",")[0] for line in out.read_text().splitlines()[1:]]
            self.assertEqual(ts, ["1000", "1000", "1010", "1010"])  # nothing new for 1000; one tick at 1010

    def test_second_process_skips_rest_of_written_window(self):
        # Review Focus 2: one row per 10-second window even when the new process starts mid-window.
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "samples.csv"
            out.write_text(bc.HEADER + "\n1000,box,\n")
            self._run(d, extra=["--ticks", "2"], clock=1003.5)
            ts = [line.split(",")[0] for line in out.read_text().splitlines()[1:]]
            self.assertEqual(ts, ["1000", "1010", "1010"])


if __name__ == "__main__":
    unittest.main()


class BlockdevColumnsTest(unittest.TestCase):
    """The two columns that say how much filesystem-metadata writeback was charged to the row and to
    the whole box (collector/blockdev_trace.py)."""

    NETDATA = "system.slice/netdata.service"
    LINE = ("   kworker/u8:3-1 [001] ..... 1.0: writeback_single_inode: bdi 8:0: ino=8388609 state=I_SYNC "
            "dirtied_when=1 age=1 index=0 to_write=1024 wrote={wrote} cgroup_ino={cg}\n")

    def _tracefs(self, d):
        ev = Path(d) / "tracefs" / "instances" / "bench" / "events" / "writeback" / "writeback_single_inode"
        ev.mkdir(parents=True)
        (ev / "enable").write_text("0\n")
        (ev / "filter").write_text("none\n")
        pipe = Path(d) / "tracefs" / "instances" / "bench" / "trace_pipe"
        pipe.write_text("")
        return Path(d) / "tracefs", pipe

    def _run(self, d, extra):
        out, ev = Path(d) / "samples.csv", Path(d) / "events.csv"
        bc.main(["--root", str(CG), "--proc", str(PROC), "--globs", self.NETDATA, "--out", str(out), "--events", str(ev),
                 "--once", *extra])
        return out, ev

    def test_rows_carry_the_ledger(self):
        import blockdev_trace as bt
        led = bt.Ledger()
        led.add({7: 8192, 9: 4096}, {self.NETDATA: {7}})
        rows = bc.sample_structured(CG, PROC, {self.NETDATA: 1}, ts=1, net=lambda cg: (0, 0), ledger=led)[1]
        self.assertEqual(rows[0].split(",")[19:], ["8192", ""])
        self.assertEqual(rows[1].split(",")[19:], ["", "12288"])

    def test_traced_writeback_is_charged_to_the_row_and_named_in_the_side_file(self):
        with tempfile.TemporaryDirectory() as d:
            tracefs, pipe = self._tracefs(d)
            ino = os.stat(CG / self.NETDATA).st_ino
            other = os.stat(CG / "system.slice/docker.service").st_ino
            pipe.write_text(self.LINE.format(wrote=5, cg=ino) + self.LINE.format(wrote=2, cg=other))
            out, ev = self._run(d, ["--blockdev-trace", "--tracefs", str(tracefs), "--blockdev-ino", "8388609",
                                    "--blockdev-out", str(Path(d) / "blockdev.csv")])
            lines = out.read_text().splitlines()
            self.assertEqual(lines[1].split(",")[19:], [str(5 * 4096), ""])
            self.assertEqual(lines[2].split(",")[19:], ["", str(7 * 4096)])
            self.assertIn(",blockdev_trace,,ino=8388609", ev.read_text())
            side = (Path(d) / "blockdev.csv").read_text().splitlines()
            self.assertEqual(side[0], "ts,cgroup_ino,cgroup,bytes")
            self.assertEqual(sorted(ln.split(",", 1)[1] for ln in side[1:]),
                             sorted([f"{ino},/system.slice/netdata.service,{5 * 4096}", f"{other},/system.slice/docker.service,{2 * 4096}"]))

    def test_a_tracer_that_cannot_be_armed_is_recorded_and_sampling_goes_on(self):
        with tempfile.TemporaryDirectory() as d:
            out, ev = self._run(d, ["--blockdev-trace", "--tracefs", str(Path(d) / "nowhere"), "--blockdev-ino", "1",
                                    "--blockdev-out", str(Path(d) / "blockdev.csv")])
            self.assertIn(",blockdev_trace_error,", ev.read_text())
            self.assertEqual(out.read_text().splitlines()[1].split(",")[19:], ["", ""])
