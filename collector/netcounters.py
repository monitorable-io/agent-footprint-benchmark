#!/usr/bin/env python3
"""Per-cgroup byte counters with nftables (stdlib only).

Table `inet bench` has an output chain and an input chain; for each measured cgroup one rule per
chain matches `socket cgroupv2 level N "<path>"` and feeds a named counter (out_<key>, in_<key>).
nft resolves the cgroup path to its id when the rule is added, so a recreated cgroup (agent
restart) needs ensure_rules() again; the collector calls it on every appeared/restart event.
"""
import json
import re
import subprocess

TABLE = "inet bench"
# Only unit-name characters reach an nft rule; anything else is refused (never shell-quoted around).
SAFE_PATH = re.compile(r"[A-Za-z0-9_.@:-]+(/[A-Za-z0-9_.@:-]+)*")  # used with fullmatch; no quotes, blanks, backslashes


def _nft(args):
    return subprocess.run(["nft", *args], check=True, capture_output=True, text=True).stdout


def key_for(path):
    """Counter-name-safe key for a cgroup path."""
    return "".join(c if c.isalnum() else "_" for c in path)


def level_for(path):
    """cgroupv2 match level = number of path components."""
    return len([p for p in path.split("/") if p])


def ensure_table(run=_nft):
    run(["add", "table", "inet", "bench"])
    run(["add", "chain", "inet", "bench", "out", "{", "type", "filter", "hook", "output", "priority", "0", ";", "}"])
    run(["add", "chain", "inet", "bench", "in", "{", "type", "filter", "hook", "input", "priority", "0", ";", "}"])


def _rule_handles(chain, counter_name, run):
    """Handles of rules in `chain` that feed `counter_name`."""
    out = run(["-j", "list", "chain", "inet", "bench", chain])
    handles = []
    try:
        for item in json.loads(out).get("nftables", []):
            rule = item.get("rule")
            if not rule:
                continue
            for expr in rule.get("expr", []):
                # nft -j writes a named-counter reference as {"counter": "<name>"}; older/other
                # builds as {"counter": {"name": ...}}. Accept both.
                ref = expr.get("counter") if isinstance(expr, dict) else None
                name = ref.get("name") if isinstance(ref, dict) else ref
                if name == counter_name:
                    handles.append(rule["handle"])
    except (ValueError, KeyError, TypeError):
        pass
    return handles


def _replace_rules(key, match_out, match_in, run):
    """Replace the out/in rules feeding out_<key>/in_<key> (loopback traffic is never network)."""
    for chain, prefix, match, iface in (("out", "out_", match_out, "oifname"), ("in", "in_", match_in, "iifname")):
        name = prefix + key
        for handle in _rule_handles(chain, name, run):
            run(["delete", "rule", "inet", "bench", chain, "handle", str(handle)])
        run(["add", "counter", "inet", "bench", name])
        run(["add", "rule", "inet", "bench", chain, iface, "!=", '"lo"', *match, "counter", "name", f'"{name}"'])


def ensure_rules(path, key, run=_nft):
    """Create (or replace) the out/in rules + counters for one cgroup path."""
    if not SAFE_PATH.fullmatch(path):
        raise ValueError(f"refusing cgroup path with unsafe characters: {path!r}")
    match = ["socket", "cgroupv2", "level", str(level_for(path)), f'"{path}"']
    _replace_rules(key, match, match, run)


def ensure_port_rules(ports, key, run=_nft):
    """Counters by TCP port for rows whose sockets are not in the unit's cgroup (socket activation)
    or that are polled: bytes sent from the port (out) and received on it (in)."""
    ports = [int(p) for p in ports]
    if not ports or any(p < 1 or p > 65535 for p in ports):
        raise ValueError(f"bad port list: {ports!r}")
    set_ = "{ " + ", ".join(str(p) for p in ports) + " }"
    _replace_rules(key, ["tcp", "sport", set_], ["tcp", "dport", set_], run)


def read_all(run=_nft):
    """{counter name: bytes} for every counter in table bench, in one nft call."""
    out = {}
    try:
        for item in json.loads(run(["-j", "list", "counters"])).get("nftables", []):
            c = item.get("counter")
            if c and c.get("table") == "bench":
                out[c.get("name")] = int(c.get("bytes", 0))
    except (ValueError, TypeError, subprocess.CalledProcessError):
        pass
    return out


def read(key, run=_nft, snapshot=None):
    """(out_bytes, in_bytes) for a key from a read_all() snapshot (taken if not given); (0, 0) when absent."""
    allc = snapshot if snapshot is not None else read_all(run)
    return allc.get("out_" + key, 0), allc.get("in_" + key, 0)
