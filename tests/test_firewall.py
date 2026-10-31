"""sink/firewall.sh: argument validation before any change; empty and bad saved lists fail closed."""
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "sink" / "firewall.sh"


def run_with_fake_iptables(d, args, saved=None):
    """A fake iptables/iptables-restore/ip on PATH that logs calls; returns (proc, log)."""
    fake = Path(d) / "bin"
    fake.mkdir(exist_ok=True)
    log = Path(d) / "calls.log"
    for name in ("iptables", "iptables-restore"):
        p = fake / name
        p.write_text(f'#!/bin/bash\necho "{name} $*" >> "{log}"\nif [ "{name}" = iptables-restore ]; then cat >> "{log}"; fi\n[ "$1" = -C ] && exit 1\nexit 0\n')
        os.chmod(p, stat.S_IRWXU)
    (fake / "ip").write_text('#!/bin/bash\necho "default via 192.0.2.1 dev eth0"\n')
    os.chmod(fake / "ip", stat.S_IRWXU)
    text = SCRIPT.read_text().replace("SAVED=/etc/bench-sink-allow", f"SAVED={d}/saved")
    patched = Path(d) / "firewall.sh"
    patched.write_text(text)
    if saved is not None:
        (Path(d) / "saved").write_text(saved)
    env = dict(os.environ, PATH=f"{fake}:{os.environ['PATH']}")
    proc = subprocess.run(["bash", str(patched), *args], env=env, capture_output=True, text=True)
    return proc, (log.read_text() if log.exists() else "")


class FirewallTest(unittest.TestCase):
    def test_bad_argument_changes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            proc, log = run_with_fake_iptables(d, ["192.0.2.10", "evil; rm -rf /"])
            self.assertEqual(proc.returncode, 2)
            self.assertEqual(log, "")

    def test_empty_list_still_installs_the_drop_rule_and_restores_cleanly(self):
        with tempfile.TemporaryDirectory() as d:
            proc, log = run_with_fake_iptables(d, [])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("-j DROP", log)
            self.assertNotIn("-s  -j", log)
            self.assertEqual((Path(d) / "saved").read_text(), "")
            proc2, log2 = run_with_fake_iptables(d, ["--restore"], saved="")
            self.assertEqual(proc2.returncode, 0, proc2.stderr)
            self.assertIn("-j DROP", log2)

    def test_bad_saved_entry_is_dropped_and_gate_still_goes_up(self):
        with tempfile.TemporaryDirectory() as d:
            proc, log = run_with_fake_iptables(d, ["--restore"], saved="192.0.2.10\ngarbage\n\n")
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("-s 192.0.2.10 -j RETURN", log)
            self.assertNotIn("garbage", log)
            self.assertIn("-j DROP", log)
            self.assertIn("iptables -N DOCKER-USER", log)

    def test_cidr_is_accepted_and_bad_cidr_refused(self):
        # The bed's private network (Pulse's agent refuses plain HTTP to a public address) is allowed as a subnet.
        with tempfile.TemporaryDirectory() as d:
            proc, log = run_with_fake_iptables(d, ["192.0.2.10", "10.0.0.0/24"])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("-s 10.0.0.0/24 -j RETURN", log)
            self.assertIn("10.0.0.0/24", (Path(d) / "saved").read_text())
        for bad in ("10.0.0.0/240", "10.0.0.0/8", "0.0.0.0/0", "10.0.0.0/15"):
            with tempfile.TemporaryDirectory() as d:
                proc, log = run_with_fake_iptables(d, [bad])
                self.assertEqual(proc.returncode, 2, bad)   # a typo must not open the hubs to the internet
                self.assertEqual(log, "", bad)
        with tempfile.TemporaryDirectory() as d:
            proc, log = run_with_fake_iptables(d, ["172.16.0.0/16"])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("-s 172.16.0.0/16 -j RETURN", log)


if __name__ == "__main__":
    unittest.main()
