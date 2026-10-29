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
SAFE_PATH = re.compile(r"^[A-Za-z0-9_.@:\\/-]+$")


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
                if expr.get("counter", {}).get("name") == counter_name:
                    handles.append(rule["handle"])
    except (ValueError, KeyError, TypeError):
        pass
    return handles


def ensure_rules(path, key, run=_nft):
    """Create (or replace) the out/in rules + counters for one cgroup path."""
    if not SAFE_PATH.match(path):
        raise ValueError(f"refusing cgroup path with unsafe characters: {path!r}")
    level = str(level_for(path))
    for chain, prefix in (("out", "out_"), ("in", "in_")):
        name = prefix + key
        for handle in _rule_handles(chain, name, run):
            run(["delete", "rule", "inet", "bench", chain, "handle", str(handle)])
        run(["add", "counter", "inet", "bench", name])
        run(["add", "rule", "inet", "bench", chain, "socket", "cgroupv2", "level", level, f'"{path}"',
             "counter", "name", f'"{name}"'])


def read(key, run=_nft):
    """(out_bytes, in_bytes) for a key; (0, 0) when the counters do not exist."""
    out_b = in_b = 0
    try:
        for item in json.loads(run(["-j", "list", "counters"])).get("nftables", []):
            c = item.get("counter")
            if not c or c.get("table") != "bench":
                continue
            if c.get("name") == "out_" + key:
                out_b = int(c.get("bytes", 0))
            elif c.get("name") == "in_" + key:
                in_b = int(c.get("bytes", 0))
    except (ValueError, TypeError, subprocess.CalledProcessError):
        pass
    return out_b, in_b
