"""collector/netcounters.py with nft mocked by recorded JSON."""
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "collector"))
import netcounters as nc  # noqa: E402

FIX = ROOT / "tests" / "fixtures" / "nft"


class FakeNft:
    def __init__(self, responses):
        self.responses = responses  # first-arg-tuple -> stdout
        self.calls = []

    def __call__(self, args):
        self.calls.append(list(args))
        for prefix, out in self.responses.items():
            if tuple(args[: len(prefix)]) == prefix:
                return out
        return ""


class KeyTest(unittest.TestCase):
    def test_key_from_path(self):
        self.assertEqual(nc.key_for("system.slice/netdata.service"), "system_slice_netdata_service")
        self.assertEqual(nc.key_for("system.slice/docker-abc123.scope"), "system_slice_docker_abc123_scope")


class ReadTest(unittest.TestCase):
    def test_read_counters_from_json(self):
        fake = FakeNft({("-j", "list", "counters"): (FIX / "list_counters.json").read_text()})
        self.assertEqual(nc.read("system_slice_netdata_service", run=fake), (65536, 4096))
        self.assertEqual(nc.read("missing", run=fake), (0, 0))


class RuleTest(unittest.TestCase):
    def test_rule_json_shape(self):
        fake = FakeNft({("-j", "list", "chain"): (FIX / "list_chain_out.json").read_text()})
        nc.ensure_rules("system.slice/netdata.service", "system_slice_netdata_service", run=fake)
        flat = [" ".join(c) for c in fake.calls]
        # the stale rule for this key (handle 7) is deleted, the docker one (handle 9) is kept
        self.assertTrue(any(c.startswith("delete rule inet bench out handle 7") for c in flat), flat)
        self.assertFalse(any("handle 9" in c for c in flat), flat)
        # counters are created idempotently and the rules name the cgroup path and the counter
        self.assertIn("add counter inet bench out_system_slice_netdata_service", flat)
        self.assertIn("add counter inet bench in_system_slice_netdata_service", flat)
        self.assertIn('add rule inet bench out socket cgroupv2 level 2 "system.slice/netdata.service" counter name "out_system_slice_netdata_service"', flat)
        self.assertIn('add rule inet bench in socket cgroupv2 level 2 "system.slice/netdata.service" counter name "in_system_slice_netdata_service"', flat)

    def test_rejects_unsafe_paths(self):
        fake = FakeNft({})
        with self.assertRaises(ValueError):
            nc.ensure_rules('system.slice/x".service', "k", run=fake)
        with self.assertRaises(ValueError):
            nc.ensure_rules("system.slice/x service", "k", run=fake)
        self.assertEqual(fake.calls, [])

    def test_level_is_path_depth(self):
        self.assertEqual(nc.level_for("system.slice/netdata.service"), 2)
        self.assertEqual(nc.level_for("system.slice/hetrix.slice/x.service"), 3)

    def test_ensure_table_creates_table_and_chains(self):
        fake = FakeNft({})
        nc.ensure_table(run=fake)
        flat = [" ".join(c) for c in fake.calls]
        self.assertIn("add table inet bench", flat)
        self.assertIn("add chain inet bench out { type filter hook output priority 0 ; }", flat)
        self.assertIn("add chain inet bench in { type filter hook input priority 0 ; }", flat)


if __name__ == "__main__":
    unittest.main()
