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
        lines.append(",".join(map(str, [ts, "box", "", "", "", "", "", "", "", "", "", "", "", "", "", "", 0.1, 1_500_000, 0])))
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
        self.assertEqual(set(r["run"]), {"provider", "location", "plan", "image", "kernel", "harnessCommit", "cycles"})
        self.assertEqual(len(r["run"]["cycles"]), 3)
        self.assertEqual(set(r["run"]["cycles"][0]), {"start", "end"})
        self.assertEqual(set(r["metrics"][0]), {"key", "label", "unit", "lowerIsBetter"})
        row = r["rows"][0]
        self.assertEqual(set(row), {"key", "name", "version", "licence", "sourceUrl", "installUrl", "unitNames", "reportsTo",
                                    "intervalSeconds", "us", "footnotes", "values"})
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

    def test_disk_written_scaled_to_24h(self):
        # 1000 B/s written -> 86.4 MB per 24 h
        self.assertAlmostEqual(self.row("alpha")["values"]["disk_written_mb_24h"]["median"], 86.4, places=1)
        self.assertAlmostEqual(self.row("alpha")["values"]["disk_footprint_mb"]["median"], 80.0, places=1)


if __name__ == "__main__":
    unittest.main()
