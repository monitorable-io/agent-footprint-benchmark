"""Every agents/<name>/ has a complete meta.json and a documented install.sh."""
import json
import os
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AGENTS = ROOT / "agents"
EXPECTED = ["beszel", "netdata", "netdata-cloud", "glances", "node-exporter", "telegraf", "pulse",
            "datadog", "fivenines", "hetrixtools", "monitorable"]
REQUIRED = {"name", "kind", "cgroupGlobs", "ports", "reportsTo", "intervalSeconds", "sourceUrl", "licence", "diskPaths", "user"}
KINDS = {"push", "polled", "none"}


class MetaTest(unittest.TestCase):
    def test_all_eleven_agents_present(self):
        self.assertEqual(sorted(os.listdir(AGENTS)), sorted(EXPECTED + ["none"]))

    def test_meta_json_complete(self):
        for name in EXPECTED:
            with self.subTest(agent=name):
                meta = json.loads((AGENTS / name / "meta.json").read_text())
                self.assertTrue(REQUIRED <= set(meta), REQUIRED - set(meta))
                self.assertEqual(meta["name"], name)
                self.assertIn(meta["kind"], KINDS)
                self.assertTrue(meta["sourceUrl"].startswith("https://"))
                self.assertTrue(meta["cgroupGlobs"], "cgroupGlobs empty")
                self.assertGreater(meta["intervalSeconds"], 0)
                self.assertIsInstance(meta["ports"], list)
                self.assertIsInstance(meta["diskPaths"], list)
                self.assertIsInstance(meta.get("footnotes", []), list)

    def test_install_sh_documented_and_executable(self):
        for name in EXPECTED:
            with self.subTest(agent=name):
                script = AGENTS / name / "install.sh"
                self.assertTrue(script.exists(), script)
                self.assertTrue(os.access(script, os.X_OK), f"{script} not executable")
                lines = script.read_text().splitlines()
                comments = [line for line in lines[:5] if line.startswith("#") and not line.startswith("#!")]
                self.assertTrue(comments and comments[0].startswith("# Source: https://"), lines[:3])
                text = script.read_text()
                self.assertIn("VERSION=", text)
                self.assertIn("UNITS=", text)


if __name__ == "__main__":
    unittest.main()
