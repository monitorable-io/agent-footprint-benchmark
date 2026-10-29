"""base/install-runner.sh records a failed install instead of aborting (Review Focus 2)."""
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "base" / "install-runner.sh"


def make_agent(d, name, script, meta=None):
    a = Path(d) / "agents" / name
    a.mkdir(parents=True)
    (a / "install.sh").write_text(script)
    os.chmod(a / "install.sh", stat.S_IRWXU)
    (a / "meta.json").write_text(json.dumps(meta or {"name": name, "diskPaths": [str(a)], "cgroupGlobs": ["system.slice/x.service"]}))
    return a


class RunnerTest(unittest.TestCase):
    def run_runner(self, d, name):
        env = dict(os.environ, BENCH_STATE=str(Path(d) / "state"), BENCH_AGENTS=str(Path(d) / "agents"))
        Path(d, "state").mkdir()
        return subprocess.run(["bash", str(RUNNER), name], env=env, capture_output=True, text=True)

    def test_failed_install_is_recorded(self):
        with tempfile.TemporaryDirectory() as d:
            make_agent(d, "fake", "#!/bin/bash\necho starting\necho 'E: Unable to locate package' >&2\nexit 3\n")
            r = self.run_runner(d, "fake")
            self.assertEqual(r.returncode, 0, r.stderr)
            rec = json.loads((Path(d) / "state" / "install.json").read_text())
            self.assertEqual(rec["status"], "failed")
            self.assertEqual(rec["exit_code"], 3)
            self.assertEqual(rec["agent"], "fake")
            self.assertTrue(any("Unable to locate package" in line for line in rec["tail"]), rec["tail"])
            self.assertGreaterEqual(rec["seconds"], 0)

    def test_secret_values_are_redacted_from_the_recorded_tail(self):
        with tempfile.TemporaryDirectory() as d:
            a = make_agent(d, "fake", "#!/bin/bash\ncd \"$(dirname \"$0\")\"\n. ./env\necho \"installing with key $DD_API_KEY and site $DD_SITE\"\necho VERSION=1\necho UNITS=x\n")
            (a / "env").write_text("DD_API_KEY=abcdef0123456789secret\nDD_SITE=eu1\n")
            r = self.run_runner(d, "fake")
            self.assertEqual(r.returncode, 0, r.stderr)
            rec = json.loads((Path(d) / "state" / "install.json").read_text())
            joined = "\n".join(rec["tail"])
            self.assertNotIn("abcdef0123456789secret", joined)
            self.assertIn("***", joined)
            self.assertIn("site eu1", joined)  # values under 8 chars are not worth masking and stay readable
            mode = stat.S_IMODE(os.stat(Path(d) / "state" / "install.json").st_mode)
            self.assertEqual(mode, 0o600)

    def test_ok_install_records_version_units_and_disk(self):
        with tempfile.TemporaryDirectory() as d:
            a = make_agent(d, "fake", "#!/bin/bash\necho VERSION=v1.2.3\necho UNITS=x.service,y.socket\n")
            (a / "blob").write_bytes(b"x" * 4096)
            r = self.run_runner(d, "fake")
            self.assertEqual(r.returncode, 0, r.stderr)
            rec = json.loads((Path(d) / "state" / "install.json").read_text())
            self.assertEqual(rec["status"], "ok")
            self.assertEqual(rec["version"], "v1.2.3")
            self.assertEqual(rec["units"], ["x.service", "y.socket"])
            self.assertGreaterEqual(rec["disk_bytes"], 4096)
            self.assertIsInstance(rec["listening_ports"], list)


if __name__ == "__main__":
    unittest.main()
