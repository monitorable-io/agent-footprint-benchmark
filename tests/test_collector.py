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
            "ts,cgroup,cgroup_ino,cpu_usage_usec,memory_current,memory_peak,anon,file,pss,rss,io_rbytes,io_wbytes,pids,threads,net_out,net_in,box_load1,box_memavail_kb,box_steal_ticks",
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
        self.assertEqual(box[16:], ["0.42", "1500000", "77"])


if __name__ == "__main__":
    unittest.main()
