"""collector/netcounters.py with nft mocked by recorded JSON."""
import json
import os
import sys
import tempfile
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
        nc.ensure_rules("system.slice/netdata.service", "system_slice_netdata_service", run=fake, interfaces=[])
        flat = [" ".join(c) for c in fake.calls]
        # the stale rule for this key (handle 7) is deleted, the docker one (handle 9) is kept
        self.assertTrue(any(c.startswith("delete rule inet bench out handle 7") for c in flat), flat)
        self.assertFalse(any("handle 9" in c for c in flat), flat)
        # counters are created idempotently and the rules name the cgroup path and the counter
        self.assertIn("add counter inet bench out_system_slice_netdata_service", flat)
        self.assertIn("add counter inet bench in_system_slice_netdata_service", flat)
        self.assertIn('add rule inet bench out oifname != "lo" socket cgroupv2 level 2 "system.slice/netdata.service" counter name "out_system_slice_netdata_service"', flat)
        self.assertIn('add rule inet bench in iifname != "lo" socket cgroupv2 level 2 "system.slice/netdata.service" counter name "in_system_slice_netdata_service"', flat)

    def test_port_rules_for_socket_activated_or_polled_rows(self):
        # node_exporter's listener belongs to its .socket unit's cgroup, so accepted connections never
        # match the service's cgroup: rows with ports are counted by port instead.
        fake = FakeNft({("-j", "list", "chain"): (FIX / "list_chain_out.json").read_text()})
        nc.ensure_port_rules([9100, 9101], "ports", run=fake, interfaces=[])
        flat = [" ".join(c) for c in fake.calls]
        self.assertIn('add rule inet bench out oifname != "lo" tcp sport { 9100, 9101 } counter name "out_ports"', flat)
        self.assertIn('add rule inet bench in iifname != "lo" tcp dport { 9100, 9101 } counter name "in_ports"', flat)
        with self.assertRaises(ValueError):
            nc.ensure_port_rules([0, 70000], "ports", run=fake)

    def test_read_all_returns_every_bench_counter_once(self):
        fake = FakeNft({("-j", "list", "counters"): (FIX / "list_counters.json").read_text()})
        allc = nc.read_all(run=fake)
        self.assertEqual(allc["out_system_slice_netdata_service"], 65536)
        self.assertEqual(allc["in_system_slice_netdata_service"], 4096)
        self.assertEqual(len(fake.calls), 1)

    def test_rejects_unsafe_paths(self):
        fake = FakeNft({})
        with self.assertRaises(ValueError):
            nc.ensure_rules('system.slice/x".service', "k", run=fake)
        with self.assertRaises(ValueError):
            nc.ensure_rules("system.slice/x service", "k", run=fake)
        with self.assertRaises(ValueError):
            nc.ensure_rules("system.slice/x\\", "k", run=fake)  # a trailing backslash would escape nft's closing quote
        with self.assertRaises(ValueError):
            nc.ensure_rules("/system.slice//x.service", "k", run=fake)
        self.assertEqual(fake.calls, [])

    def test_stale_rule_found_in_real_nft_json(self):
        # Recorded from nft 1.1.x on Ubuntu 26.04: the counter ref is a plain string and the cgroup
        # path has been resolved to its id. The rule must still be found and replaced after a restart.
        fake = FakeNft({("-j", "list", "chain"): (FIX / "list_chain_in_real.json").read_text()})
        nc.ensure_rules("system.slice/docker.service", "system_slice_docker_service", run=fake)
        flat = [" ".join(c) for c in fake.calls]
        self.assertTrue(any(c.startswith("delete rule inet bench in handle 8") for c in flat), flat)

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


def fake_sysfs(d):
    """/sys/class/net of a Hetzner box with Docker: two device-backed NICs, bridges, a veth, lo."""
    net = Path(d) / "class" / "net"
    devs = Path(d) / "devices"
    for name in ("ens3", "enp7s0", "docker0", "br-abc", "veth1", "lo"):
        (net / name).mkdir(parents=True)
    for name in ("ens3", "enp7s0"):
        (devs / name).mkdir(parents=True)
        os.symlink(devs / name, net / name / "device")
    return net


class PhysicalInterfaceTest(unittest.TestCase):
    """The pilot counted every interface but lo, so Netdata's polling of the Docker containers over
    the bridge read as 692 MB/day of network."""

    def test_physical_interfaces_excludes_virtual(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(nc.physical_interfaces(fake_sysfs(d)), ["enp7s0", "ens3"])

    def test_rules_match_physical_set(self):
        with tempfile.TemporaryDirectory() as d:
            ifaces = nc.physical_interfaces(fake_sysfs(d))
        fake = FakeNft({})
        nc.ensure_rules("system.slice/netdata.service", "system_slice_netdata_service", run=fake, interfaces=ifaces)
        flat = [" ".join(c) for c in fake.calls]
        self.assertIn('add rule inet bench out oifname { "enp7s0", "ens3" } socket cgroupv2 level 2 "system.slice/netdata.service" counter name "out_system_slice_netdata_service"', flat)
        self.assertIn('add rule inet bench in iifname { "enp7s0", "ens3" } socket cgroupv2 level 2 "system.slice/netdata.service" counter name "in_system_slice_netdata_service"', flat)
        fake = FakeNft({})
        nc.ensure_port_rules([9100], "ports", run=fake, interfaces=ifaces)
        flat = [" ".join(c) for c in fake.calls]
        self.assertIn('add rule inet bench out oifname { "enp7s0", "ens3" } tcp sport { 9100 } counter name "out_ports"', flat)

    def test_private_interface_without_default_route_is_counted(self):
        # Review Focus 3: every box's private network (10.0.0.0/24, Pulse's traffic) has no default
        # route; physical means device-backed, routes are never consulted.
        with tempfile.TemporaryDirectory() as d:
            net = fake_sysfs(d)
            self.assertIn("enp7s0", nc.physical_interfaces(net))
            self.assertIn("ens3", nc.physical_interfaces(net))

    def test_default_interfaces_read_from_sysfs(self):
        with tempfile.TemporaryDirectory() as d:
            net = fake_sysfs(d)
            saved = nc.SYS_CLASS_NET
            nc.SYS_CLASS_NET = str(net)
            try:
                fake = FakeNft({})
                nc.ensure_rules("system.slice/x.service", "k", run=fake)
            finally:
                nc.SYS_CLASS_NET = saved
        self.assertTrue(any('oifname { "enp7s0", "ens3" }' in " ".join(c) for c in fake.calls))

    def test_unsafe_interface_name_refused(self):
        with self.assertRaises(ValueError):
            nc.ensure_rules("system.slice/x.service", "k", run=FakeNft({}), interfaces=['eth0" }'])


if __name__ == "__main__":
    unittest.main()
