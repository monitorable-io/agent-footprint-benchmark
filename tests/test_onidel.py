"""bench quote / vm list against recorded fixtures (no network, no token)."""
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "fixtures" / "onidel"


def run_bench(env_text, *args):
    with tempfile.TemporaryDirectory() as d:
        env_file = Path(d) / "bench.env"
        env_file.write_text(env_text)
        os.chmod(env_file, stat.S_IRUSR | stat.S_IWUSR)
        env = dict(os.environ, BENCH_ENV=str(env_file))
        return subprocess.run([str(ROOT / "bench"), *args], env=env, capture_output=True, text=True)


ENV = (
    "ONIDEL_TOKEN=fixture\nONIDEL_INSTANCE_TYPE=vhp\nONIDEL_LOCATION=Amsterdam\n"
    "ONIDEL_VCPU=1\nONIDEL_RAM=2048\nONIDEL_DISK=20\nONIDEL_TEMPLATE=\"Ubuntu 26.04\"\n"
    "ONIDEL_SSH_KEY_ID=a3f2e5d8-1234-4abc-9876-543210fedcba\n"
)


class QuoteTest(unittest.TestCase):
    def test_quote_parses_fixture(self):
        r = run_bench(ENV, "quote", "--fixtures", str(FIXTURES))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("1 vCPU", r.stdout)
        self.assertIn("2 GB", r.stdout)
        self.assertIn("Ubuntu 26.04 x64 LTS (id 9)", r.stdout)
        self.assertIn("5.50 USD/month", r.stdout)
        self.assertIn("0.0082 USD/hour", r.stdout)  # 5.5 / 672
        self.assertIn("Amsterdam", r.stdout)

    def test_quote_fails_when_type_not_in_location(self):
        r = run_bench(ENV.replace("ONIDEL_LOCATION=Amsterdam", "ONIDEL_LOCATION=Singapore"), "quote", "--fixtures", str(FIXTURES))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not offered in Singapore", r.stderr)

    def test_vm_list_prints_name_status_ip(self):
        r = run_bench(ENV, "vm", "list", "--fixtures", str(FIXTURES))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("box-0", r.stdout)
        self.assertIn("active", r.stdout)
        self.assertIn("192.0.2.10", r.stdout)


if __name__ == "__main__":
    unittest.main()
