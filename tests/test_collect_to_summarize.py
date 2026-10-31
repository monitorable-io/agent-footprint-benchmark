"""Integration: what collect_box writes (via merge_meta) is what summarize reads, control row included."""
import gzip
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import summarize as sm  # noqa: E402
sys.path.insert(0, str(ROOT / "tests"))
from test_summarize import rows_for, T0, IDLE, LOAD  # noqa: E402


def merge_meta(meta, install, schedule, footprint=None):
    args = [str(meta), str(install), str(schedule)] + ([str(footprint)] if footprint else [])
    script = f'cd "{ROOT}"; . lib/common.sh; . lib/rotation.sh; . lib/cycle.sh; merge_meta "$@"'
    r = subprocess.run(["bash", "-c", script, "_", *args], capture_output=True, text=True, check=True)
    return r.stdout


class CollectToSummarizeTest(unittest.TestCase):
    def test_control_row_and_failed_cycle_flow_through(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "2026"
            for k in range(2):
                cdir = root / f"cycle-{k + 1}"
                cdir.mkdir(parents=True)
                t0 = T0 + k * 100_000
                for agent_dir, outname, status, pss in (("none", "control", "ok", 5), ("telegraf", "telegraf", "ok" if k == 0 else "failed", 60)):
                    (cdir / f"{outname}.csv.gz").write_bytes(gzip.compress(rows_for(outname, t0, pss, 0.5).encode()))
                    inst = cdir / f"{outname}.install.json"
                    inst.write_text(json.dumps({"agent": agent_dir, "status": status, "exit_code": 0 if status == "ok" else 1, "seconds": 3.0,
                                                "version": "v1", "units": [f"{agent_dir}.service"], "disk_bytes": 1, "kernel": "k", "tail": []}))
                    sched = cdir / f"schedule-{outname}.json"
                    sched.write_text(json.dumps({"agent": agent_dir, "box": outname, "installFinished": t0, "loadStart": t0 + IDLE, "stop": t0 + IDLE + LOAD}))
                    fp = cdir / f"{outname}.footprint.json"
                    fp.write_text(json.dumps({"disk_bytes": 42_000_000, "journal_bytes": 1000}))
                    (cdir / f"{outname}.meta.json").write_text(merge_meta(ROOT / "agents" / agent_dir / "meta.json", inst, sched, fp))
            res = sm.summarize(root, harness_commit="t")
            self.assertEqual(res["control"]["key"], "control")
            self.assertAlmostEqual(res["control"]["values"]["pss_idle_median_mb"]["median"], 5.0, places=1)
            tg = next(r for r in res["rows"] if r["key"] == "telegraf")
            self.assertEqual(len(tg["values"]["pss_idle_median_mb"]["cycles"]), 1)   # one good cycle counted
            self.assertTrue(any("Cycle 2" in f and "failed" in f for f in tg["footnotes"]), tg["footnotes"])
            self.assertTrue(any("stock config" in f for f in tg["footnotes"]))         # meta footnote kept
            self.assertAlmostEqual(tg["values"]["disk_footprint_mb"]["median"], 42.0, places=1)
            self.assertEqual(res["run"]["kernel"], "k")


if __name__ == "__main__":
    unittest.main()
