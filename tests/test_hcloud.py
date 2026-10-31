"""bench vm/quote on the Hetzner Cloud client against recorded fixtures (no network, no token)."""
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "fixtures" / "hcloud"

ENV = (
    "BENCH_PROVIDER=hcloud\nHCLOUD_TOKEN=fixture\nHCLOUD_SERVER_TYPE=cx23\nHCLOUD_LOCATION=hel1\n"
    "HCLOUD_IMAGE=ubuntu-26.04\nHCLOUD_SSH_KEY=ssh@ansible\nSSH_KEY_PATH=/dev/null\n"
    "BOX_BOX_0_IP=192.0.2.10\nBOX_SINK_IP=192.0.2.19\n"
)


def run_bench(env_text, *args, extra_env=None):
    with tempfile.TemporaryDirectory() as d:
        env_file = Path(d) / "bench.env"
        env_file.write_text(env_text)
        os.chmod(env_file, stat.S_IRUSR | stat.S_IWUSR)
        env = dict(os.environ, BENCH_ENV=str(env_file), HCLOUD_POLL_SECONDS="0", **(extra_env or {}))
        return subprocess.run([str(ROOT / "bench"), *args], env=env, capture_output=True, text=True)


def lib(script):
    full = f'BENCH_ROOT="{ROOT}"; . "$BENCH_ROOT/lib/common.sh"; . "$BENCH_ROOT/lib/hcloud.sh"; {script}'
    return subprocess.run(["bash", "-c", full], capture_output=True, text=True)


class ListQuoteTest(unittest.TestCase):
    def test_vm_list_maps_boxes_by_ip(self):
        r = run_bench(ENV, "vm", "list", "--fixtures", str(FIXTURES))
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = [line for line in r.stdout.splitlines() if line.strip()]
        rows = {line.split()[0]: line for line in lines}
        self.assertIn("ubuntu-4gb-hel1-7", rows["box-0"])
        self.assertIn("192.0.2.10", rows["box-0"])
        self.assertIn("ubuntu-4gb-hel1-11", rows["sink"])
        self.assertEqual(sum(1 for line in lines if line.startswith("-")), 8)   # servers no BOX_*_IP names
        self.assertEqual(len(lines), 10)
        self.assertIn("ubuntu-26.04", rows["box-0"])
        self.assertIn("running", rows["box-0"])

    def test_quote_prints_cx23_hel1_prices(self):
        r = run_bench(ENV, "quote", "--fixtures", str(FIXTURES))
        self.assertEqual(r.returncode, 0, r.stderr)
        for needle in ("cx23", "2 vCPU", "4 GB", "40 GB", "shared", "hel1", "0.0088", "5.49", "EUR", "0.0008", "ubuntu-26.04", "10 boxes"):
            self.assertIn(needle, r.stdout, needle)
        self.assertNotIn("rented", r.stdout.lower().replace("nothing rented", ""))

    def test_provider_required(self):
        r = run_bench(ENV.replace("BENCH_PROVIDER=hcloud\n", ""), "vm", "list", "--fixtures", str(FIXTURES))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("BENCH_PROVIDER", r.stderr)


class DestroyTest(unittest.TestCase):
    def test_destroy_refused_without_flag(self):
        r = run_bench(ENV, "vm", "destroy", "box-0", "--fixtures", str(FIXTURES))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("refused", r.stderr)
        self.assertEqual(r.stdout, "")
        self.assertNotIn("DELETE", r.stderr)

    def test_destroy_with_flag_reaches_delete(self):
        r = run_bench(ENV, "vm", "destroy", "box-0", "--fixtures", str(FIXTURES), extra_env={"BENCH_ALLOW_DESTROY": "1"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no fixture for DELETE /servers/173543213", r.stderr)


class RebuildTest(unittest.TestCase):
    def test_rebuild_dies_on_failed_action(self):
        r = run_bench(ENV, "vm", "rebuild", "box-0", "--fixtures", str(FIXTURES),
                      extra_env={"HCLOUD_POST_FIXTURE": "rebuild.json", "HCLOUD_ACTIONS_FIXTURE": "actions_failed.json"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Server rebuild failed", r.stderr)
        self.assertNotIn("rebuilt box-0", r.stderr)

    def test_rebuild_reports_success(self):
        r = run_bench(ENV, "vm", "rebuild", "box-0", "--fixtures", str(FIXTURES),
                      extra_env={"HCLOUD_POST_FIXTURE": "rebuild.json", "HCLOUD_ACTIONS_FIXTURE": "actions_success.json"})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("rebuilt box-0 (192.0.2.10) from ubuntu-26.04", r.stderr)

    def test_rebuild_unknown_box_dies(self):
        r = run_bench(ENV + "BOX_BOX_5_IP=198.51.100.5\n", "vm", "rebuild", "box-5", "--fixtures", str(FIXTURES))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no Hetzner server has the address of box-5", r.stderr)

    def test_rebuild_body_and_create_body(self):
        r = lib("HCLOUD_IMAGE=ubuntu-26.04 hcloud_rebuild_body | jq -r .image")
        self.assertEqual(r.stdout.strip(), "ubuntu-26.04", r.stderr)
        r = lib("HCLOUD_IMAGE=ubuntu-26.04 HCLOUD_SERVER_TYPE=cx23 HCLOUD_LOCATION=hel1 HCLOUD_SSH_KEY=ssh@ansible "
                "hcloud_create_body box-9 | jq -r '[.name, .server_type, .image, .location, .ssh_keys[0], (.start_after_create|tostring)] | join(\" \")'")
        self.assertEqual(r.stdout.strip(), "box-9 cx23 ubuntu-26.04 hel1 ssh@ansible true", r.stderr)


class OnidelStillWorksTest(unittest.TestCase):
    def test_onidel_provider_dispatch(self):
        env = ("BENCH_PROVIDER=onidel\nONIDEL_TOKEN=fixture\nONIDEL_INSTANCE_TYPE=vhp\nONIDEL_LOCATION=Amsterdam\n"
               "ONIDEL_VCPU=1\nONIDEL_RAM=2048\nONIDEL_DISK=20\nONIDEL_TEMPLATE=\"Ubuntu 26.04\"\n")
        r = run_bench(env, "vm", "list", "--fixtures", str(ROOT / "tests" / "fixtures" / "onidel"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("box-0", r.stdout)


if __name__ == "__main__":
    unittest.main()
