"""summarize.py: cycles of raw CSVs -> results.json, on synthetic data with known answers."""
import gzip
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import summarize as sm  # noqa: E402

HEADER = ("ts,cgroup,cgroup_ino,cpu_usage_usec,memory_current,memory_peak,anon,file,pss,rss,"
          "io_rbytes,io_wbytes,pids,threads,net_out,net_in,box_load1,box_memavail_kb,box_steal_ticks")
T0 = 1_700_000_000
IDLE = 7200     # test cycles are short: 2 h "idle" (first hour excluded) + 10 min load
LOAD = 600
MB = 1_000_000


def rows_for(agent, t0, pss_mb, cpu_pct, reset_at=None, wbytes_per_s=1000, out_per_s=500, in_per_s=50, step=10):
    """Rows every `step` s from t0 to t0+IDLE+LOAD: constant PSS, CPU at cpu_pct (doubled in the load window)."""
    lines = [HEADER]
    cpu = 0
    for i in range(0, IDLE + LOAD, step):
        ts = t0 + i
        in_load = i >= IDLE
        if reset_at is not None and i == reset_at:
            cpu = 0  # the cgroup was recreated: counters restart from zero
        cpu += int(step * 1e6 * (cpu_pct * (2 if in_load else 1)) / 100)
        ino = 1 if reset_at is None or i < reset_at else 2
        pss = int((pss_mb + (50 if i < 3600 else 0)) * MB)  # the first hour carries a warm-up bump
        lines.append(",".join(map(str, [ts, f"system.slice/{agent}.service", ino, cpu, pss, pss + 5 * MB, pss, 0, pss, pss + MB,
                                        0, i * wbytes_per_s, 3, 9, i * out_per_s, i * in_per_s, 0.1, 1_500_000, 0])))
        lines.append(",".join(map(str, [ts, "box", "", "", "", "", "", "", "", "", "", "", "", "", "", "", (2.0 if in_load else 0.1), 1_500_000, 0])))
    return "\n".join(lines) + "\n"


def write_cycle(root, k, agents, control=True):
    d = root / f"cycle-{k + 1}"
    d.mkdir(parents=True)
    boxes = []
    for name, spec in agents.items():
        t0 = T0 + k * 100_000
        (d / f"{name}.csv.gz").write_bytes(gzip.compress(rows_for(name, t0, spec["pss"][k], spec["cpu"], spec.get("reset_at")).encode()))
        (d / f"{name}.events.csv").write_text("ts,event,cgroup,detail\n")
        meta = {"name": name, "kind": spec["kind"], "cgroupGlobs": [f"system.slice/{name}.service"], "ports": [],
                "reportsTo": "x", "intervalSeconds": 60, "sourceUrl": "https://example.test/" + name, "licence": "MIT",
                "diskPaths": [], "user": name, "footnotes": spec.get("footnotes", []),
                "install": {"status": "ok", "seconds": 12.5 + k, "version": "v1." + str(k), "units": [name + ".service"],
                            "disk_bytes": 80 * MB, "kernel": "7.0.0-27-generic"},
                "schedule": {"agent": name, "box": f"box-{k}", "installFinished": t0, "loadStart": t0 + IDLE, "stop": t0 + IDLE + LOAD}}
        (d / f"{name}.meta.json").write_text(json.dumps(meta))
        boxes.append(meta["schedule"])
    (d / "schedule.json").write_text(json.dumps({"cycle": k + 1, "boxes": boxes}))


AGENTS = {
    "alpha": {"kind": "push", "pss": [100, 110, 90], "cpu": 1.0, "footnotes": ["alpha note"]},
    "beta": {"kind": "polled", "pss": [40, 40, 40], "cpu": 0.5, "reset_at": 4000},
    "monitorable": {"kind": "push", "pss": [60, 60, 60], "cpu": 0.8},
    "control": {"kind": "none", "pss": [5, 5, 5], "cpu": 0.1},
}


class SummarizeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name) / "2026"
        for k in range(3):
            write_cycle(cls.root, k, AGENTS)
        (cls.root / "run.json").write_text(json.dumps({"provider": "Onidel Cloud", "location": "Amsterdam", "plan": "1 vCPU / 2 GB", "image": "Ubuntu 26.04 LTS"}))
        cls.results = sm.summarize(cls.root, harness_commit="abc1234")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def row(self, key):
        return next(r for r in self.results["rows"] if r["key"] == key)

    def test_windows_excludes_first_hour(self):
        sched = {"installFinished": T0, "loadStart": T0 + IDLE, "stop": T0 + IDLE + LOAD}
        self.assertEqual(sm.windows(sched), (T0 + 3600, T0 + IDLE, T0 + IDLE, T0 + IDLE + LOAD))
        # the warm-up bump (+50 MB in the first hour) must not reach the idle median
        self.assertAlmostEqual(self.row("beta")["values"]["pss_idle_median_mb"]["median"], 40.0, places=1)
        self.assertAlmostEqual(self.row("beta")["values"]["first_hour_peak_mb"]["median"], 90.0, places=1)  # PSS peak in hour 0

    def test_cpu_pct_is_delta_over_wall(self):
        v = self.row("alpha")["values"]
        self.assertAlmostEqual(v["cpu_idle_pct"]["median"], 1.0, places=2)
        self.assertAlmostEqual(v["cpu_loaded_pct"]["median"], 2.0, places=2)

    def test_counter_reset_is_delta_from_zero(self):
        # beta's cpu counter restarts at t0+4000 (inside the idle window); the total must still be ~0.5 %
        self.assertAlmostEqual(self.row("beta")["values"]["cpu_idle_pct"]["median"], 0.5, places=2)

    def test_headline_network_per_kind(self):
        alpha, beta = self.row("alpha")["values"], self.row("beta")["values"]
        # 500 B/s out, 50 B/s in, scaled to 24 h: out = 43.2 MB, in = 4.32 MB
        self.assertAlmostEqual(alpha["net_out_mb_24h"]["median"], 43.2, places=1)
        self.assertAlmostEqual(alpha["net_headline_mb_24h"]["median"], 43.2, places=1)   # push -> out
        self.assertAlmostEqual(beta["net_headline_mb_24h"]["median"], 47.52, places=1)   # polled -> in + out

    def test_median_of_three_cycles_not_pooled(self):
        v = self.row("alpha")["values"]["pss_idle_median_mb"]
        self.assertEqual([round(c, 1) for c in v["cycles"]], [100.0, 110.0, 90.0])
        self.assertAlmostEqual(v["median"], 100.0, places=1)
        self.assertEqual([round(c, 1) for c in self.row("alpha")["values"]["install_seconds"]["cycles"]], [12.5, 13.5, 14.5])

    def test_rows_sorted_by_idle_pss(self):
        self.assertEqual([r["key"] for r in self.results["rows"]], ["beta", "monitorable", "alpha"])
        self.assertEqual(self.results["control"]["key"], "control")
        self.assertTrue(self.row("monitorable")["us"])
        self.assertFalse(self.row("alpha")["us"])

    def test_results_json_has_spec_keys(self):
        r = self.results
        self.assertEqual(set(r), {"slug", "title", "checked", "run", "metrics", "rows", "control"})
        self.assertEqual(set(r["run"]), {"provider", "location", "plan", "image", "kernel", "harnessCommit", "cycles", "notes"})
        self.assertEqual(r["run"]["notes"], [])  # run.json without notes
        self.assertEqual(len(r["run"]["cycles"]), 3)
        self.assertEqual(set(r["run"]["cycles"][0]), {"start", "end"})
        self.assertEqual(set(r["metrics"][0]), {"key", "label", "unit", "lowerIsBetter"})
        row = r["rows"][0]
        self.assertEqual(set(row), {"key", "name", "version", "versions", "licence", "sourceUrl", "installUrl", "unitNames", "reportsTo",
                                    "intervalSeconds", "us", "footnotes", "values"})
        self.assertEqual(self.row("alpha")["versions"], ["v1.0", "v1.1", "v1.2"])
        self.assertIsNone(r["control"]["values"]["install_seconds"]["median"])
        self.assertEqual(set(row["values"]), {m["key"] for m in r["metrics"]})
        self.assertEqual(set(row["values"]["pss_idle_median_mb"]), {"median", "cycles"})
        self.assertEqual(r["run"]["kernel"], "7.0.0-27-generic")
        self.assertEqual(r["run"]["harnessCommit"], "abc1234")

    def test_footnotes_carried_from_meta(self):
        self.assertEqual(self.row("alpha")["footnotes"], ["alpha note"])

    def test_empty_idle_window_is_footnoted_not_silent(self):
        meta = {"name": "x", "kind": "push", "footnotes": [], "install": {"seconds": 1, "disk_bytes": 0},
                "schedule": {"installFinished": T0, "loadStart": T0 + 300, "stop": T0 + 600}}
        rows = [{"ts": T0 + i, "cgroup": "system.slice/x.service", **{k: 0 for k in sm.COUNTERS + sm.GAUGES}} for i in range(0, 600, 10)]
        m = sm.cycle_metrics(rows, meta)
        self.assertEqual(m["pss_idle_median_mb"], 0.0)
        self.assertTrue(any("idle window" in f for f in meta["footnotes"]), meta["footnotes"])

    def test_failed_cycles_keep_footnotes_and_rows_never_vanish(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "2026"
            agents = {"alpha": AGENTS["alpha"], "monitorable": AGENTS["monitorable"], "control": AGENTS["control"]}
            for k in range(3):
                write_cycle(root, k, agents)
            # cycle 1: alpha's install failed; cycles 2 and 3: alpha failed too (vendor does not support the OS)
            for k in range(3):
                mp = root / f"cycle-{k + 1}" / "alpha.meta.json"
                m = json.loads(mp.read_text())
                m["install"]["status"] = "failed"
                mp.write_text(json.dumps(m))
            res = sm.summarize(root, harness_commit="x")
            alpha = next(r for r in res["rows"] if r["key"] == "alpha")
            self.assertIsNone(alpha["values"]["pss_idle_median_mb"]["median"])
            self.assertEqual(alpha["values"]["pss_idle_median_mb"]["cycles"], [])
            self.assertEqual(sum("install failed" in f for f in alpha["footnotes"]), 3)
            self.assertEqual([r["key"] for r in res["rows"]], ["monitorable", "alpha"])  # nulls last

    def test_footprint_at_collect_time_wins_over_install_time(self):
        meta = {"name": "x", "kind": "push", "footnotes": [], "install": {"seconds": 1, "disk_bytes": 10 * MB},
                "footprint": {"disk_bytes": 95 * MB, "journal_bytes": 8_640_000},
                "schedule": {"installFinished": T0, "loadStart": T0 + IDLE, "stop": T0 + IDLE + LOAD}}
        rows = [{"ts": T0 + i, "cgroup": "system.slice/x.service", **{k: 0 for k in sm.COUNTERS + sm.GAUGES}} for i in range(0, IDLE + LOAD, 10)]
        m = sm.cycle_metrics(rows, meta)
        self.assertAlmostEqual(m["disk_footprint_mb"], 95.0)
        # 8.64 MB of journal over a 1 h idle window (IDLE - warm-up) scales to 207.36 MB per 24 h
        self.assertAlmostEqual(m["journal_mb_24h"], 8.64 * 24, places=1)

    def test_load_window_that_did_not_run_is_footnoted(self):
        meta = {"name": "x", "kind": "push", "footnotes": [], "install": {"seconds": 1, "disk_bytes": 0},
                "schedule": {"installFinished": T0, "loadStart": T0 + IDLE, "stop": T0 + IDLE + LOAD}}
        rows = [{"ts": T0 + i, "cgroup": "system.slice/x.service", **{k: 0 for k in sm.COUNTERS + sm.GAUGES}} for i in range(0, IDLE + LOAD, 10)]
        box = [{"ts": T0 + i, "box_load1": 0.1} for i in range(0, IDLE + LOAD, 10)]
        sm.cycle_metrics(rows, meta, box_rows=box)
        self.assertTrue(any("load window" in f for f in meta["footnotes"]), meta["footnotes"])
        meta2 = dict(meta, footnotes=[])
        box2 = [{"ts": T0 + i, "box_load1": (2.5 if i >= IDLE else 0.1)} for i in range(0, IDLE + LOAD, 10)]
        sm.cycle_metrics(rows, meta2, box_rows=box2)
        self.assertFalse(any("load window" in f for f in meta2["footnotes"]))

    def test_disk_written_scaled_to_24h(self):
        # 1000 B/s written -> 86.4 MB per 24 h
        self.assertAlmostEqual(self.row("alpha")["values"]["disk_written_mb_24h"]["median"], 86.4, places=1)
        self.assertAlmostEqual(self.row("alpha")["values"]["disk_footprint_mb"]["median"], 80.0, places=1)


if __name__ == "__main__":
    unittest.main()


class ReviewFixesTest(unittest.TestCase):
    """Findings of the 2026 data review: overlapping sampler rows, cgroups whose processes are never seen, the commit flag."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "2026"

    def tearDown(self):
        self.tmp.cleanup()

    def test_duplicate_sample_rows_are_not_summed(self):
        """A restarted sampler writes the same timestamp twice; the gauges must not double."""
        write_cycle(self.root, 0, {"alpha": AGENTS["alpha"]}, control=False)
        gz = self.root / "cycle-1" / "alpha.csv.gz"
        lines = gzip.decompress(gz.read_bytes()).decode().splitlines()
        dup = [ln for ln in lines[1:] if ",system.slice/alpha.service," in ln][500]
        gz.write_bytes(gzip.compress("\n".join(lines + [dup, dup]).encode() + b"\n"))
        rows, _ = sm.load_rows(gz)
        self.assertEqual(len(rows), len({(r["ts"], r["cgroup"]) for r in rows}))
        res = sm.summarize(self.root, harness_commit="x")
        peak = res["rows"][0]["values"]["memory_peak_mb"]["cycles"][0]
        self.assertAlmostEqual(peak, 100 + 50 + 5, places=1)  # warm-up bump + 5 MB, not twice that

    def test_cgroup_with_no_visible_process_is_na_and_footnoted(self):
        write_cycle(self.root, 0, {"alpha": AGENTS["alpha"], "ghost": {"kind": "push", "pss": [0, 0, 0], "cpu": 10.0}}, control=False)
        gz = self.root / "cycle-1" / "ghost.csv.gz"
        out = []
        for ln in gzip.decompress(gz.read_bytes()).decode().splitlines():
            cells = ln.split(",")
            if cells[1].startswith("system.slice/"):
                cells[8] = cells[9] = cells[12] = cells[13] = "0"  # pss, rss, pids, threads: nobody home
            out.append(",".join(cells))
        gz.write_bytes(gzip.compress("\n".join(out).encode() + b"\n"))
        res = sm.summarize(self.root, harness_commit="x")
        ghost = next(r for r in res["rows"] if r["key"] == "ghost")
        for k in ("pss_idle_median_mb", "pss_idle_p95_mb", "rss_idle_median_mb", "first_hour_peak_mb", "pids_median", "threads_median"):
            self.assertIsNone(ghost["values"][k]["median"], k)
        self.assertAlmostEqual(ghost["values"]["cpu_idle_pct"]["median"], 10.0, places=1)
        self.assertTrue(any("No process was found" in n for n in ghost["footnotes"]))
        self.assertEqual([r["key"] for r in res["rows"]], ["alpha", "ghost"])  # n/a sorts last
        self.assertIn("n/a", sm.to_markdown(res))

    def test_memory_current_idle_median(self):
        # cgroup memory.current, median over the idle window (the first hour's bump is excluded);
        # synthetic rows carry memory.current = PSS.
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "2026"
            for k in range(3):
                write_cycle(root, k, {"alpha": AGENTS["alpha"]}, control=False)
            alpha = sm.summarize(root, harness_commit="x")["rows"][0]
        m = alpha["values"]["memory_current_idle_median_mb"]
        self.assertEqual(m["cycles"], [100.0, 110.0, 90.0])
        self.assertEqual(m["median"], 100.0)
        keys = [k for k, *_ in sm.METRICS]
        self.assertEqual(keys.index("memory_current_idle_median_mb"), keys.index("rss_idle_median_mb") + 1)

    def test_memory_current_present_when_no_process_is_visible(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "2026"
            write_cycle(root, 0, {"ghost": {"kind": "push", "pss": [7, 7, 7], "cpu": 1.0}}, control=False)
            gz = root / "cycle-1" / "ghost.csv.gz"
            out = []
            for ln in gzip.decompress(gz.read_bytes()).decode().splitlines():
                cells = ln.split(",")
                if cells[1].startswith("system.slice/"):
                    cells[8] = cells[9] = cells[12] = cells[13] = "0"
                out.append(",".join(cells))
            gz.write_bytes(gzip.compress("\n".join(out).encode() + b"\n"))
            ghost = sm.summarize(root, harness_commit="x")["rows"][0]
        self.assertIsNone(ghost["values"]["pss_idle_median_mb"]["median"])
        self.assertEqual(ghost["values"]["memory_current_idle_median_mb"]["median"], 7.0)

    def test_year_is_the_directory_s_leading_year(self):
        # data/2026-pilot reproduces the pilot's published results.json (slug and title say 2026).
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "2026-pilot"
            write_cycle(root, 0, {"alpha": AGENTS["alpha"]}, control=False)
            res = sm.summarize(root, harness_commit="x")
        self.assertEqual(res["slug"], "agent-footprint-2026")
        self.assertIn("(2026)", res["title"])

    def test_run_notes_carried(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "2026"
            write_cycle(root, 0, {"alpha": AGENTS["alpha"]}, control=False)
            notes = ["Ubuntu's apt-daily timers were masked.", "Docker bridge traffic is excluded."]
            (root / "run.json").write_text(json.dumps({"provider": "P", "notes": notes}))
            self.assertEqual(sm.summarize(root, harness_commit="x")["run"]["notes"], notes)

    def test_harness_commit_flag(self):
        write_cycle(self.root, 0, {"alpha": AGENTS["alpha"]}, control=False)
        out = self.root / "r.json"
        sm.main([str(self.root), "--out", str(out), "--md", str(self.root / "r.md"), "--harness-commit", "903c57c..ea882d1"])
        self.assertEqual(json.loads(out.read_text())["run"]["harnessCommit"], "903c57c..ea882d1")
