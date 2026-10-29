#!/usr/bin/env python3
"""Sample a set of cgroups every N seconds into a CSV. Stdlib only.

Reads the kernel's own accounting for each matched cgroup (cpu.stat, memory.*, io.stat,
pids.current), PSS/RSS from /proc/<pid>/smaps_rollup over the cgroup's processes, and
bytes in/out from nftables counters (collector/netcounters.py). Restarts are detected by
the cgroup directory's inode changing.
"""
import argparse
import csv
import glob
import os
import re
import sys
import time
from pathlib import Path

# A cgroup path we are willing to put into a CSV and an nft rule: unit-name characters only.
SAFE_PATH = re.compile(r"[A-Za-z0-9_.@:-]+(/[A-Za-z0-9_.@:-]+)*")  # used with fullmatch; no quotes, blanks, backslashes

HEADER = (
    "ts,cgroup,cgroup_ino,cpu_usage_usec,memory_current,memory_peak,anon,file,pss,rss,"
    "io_rbytes,io_wbytes,pids,threads,net_out,net_in,box_load1,box_memavail_kb,box_steal_ticks"
)
UNIT_COLUMNS = HEADER.split(",")[3:16]


def discover(root, globs):
    """Map cgroup path (relative to root) -> directory inode, for every directory matching a glob."""
    root = Path(root)
    found = {}
    for pattern in globs:
        for p in sorted(glob.glob(str(root / pattern))):
            if os.path.isdir(p):
                rel = os.path.relpath(p, root)
                if SAFE_PATH.fullmatch(rel):
                    found[rel] = os.stat(p).st_ino
    return found


def diff_discovery(prev, cur):
    """Events between two discover() results: cgroup_appeared, cgroup_gone, restart (same path, new inode)."""
    events = []
    for path in sorted(set(prev) | set(cur)):
        if path in prev and path not in cur:
            events.append(("cgroup_gone", path))
        elif path not in prev and path in cur:
            events.append(("cgroup_appeared", path))
        elif prev[path] != cur[path]:
            events.append(("restart", path))
    return events


def counter_resets(prev_cpu, cur_cpu):
    """Paths whose cpu_usage_usec went backwards: the cgroup was recreated (inode numbers are reused)."""
    return [p for p, v in cur_cpu.items() if p in prev_cpu and v < prev_cpu[p]]


def _read_int(path, default=0):
    try:
        return int(Path(path).read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return default


def _read_kv(path):
    out = {}
    try:
        for line in Path(path).read_text().splitlines():
            parts = line.split()
            if len(parts) >= 2:
                try:
                    out[parts[0]] = int(parts[1])
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def read_cgroup(root, path):
    """The kernel counters of one cgroup."""
    d = Path(root) / path
    cpu = _read_kv(d / "cpu.stat")
    mem = _read_kv(d / "memory.stat")
    rbytes = wbytes = 0
    try:
        for line in (d / "io.stat").read_text().splitlines():
            for field in line.split()[1:]:
                k, _, v = field.partition("=")
                if k == "rbytes":
                    rbytes += int(v)
                elif k == "wbytes":
                    wbytes += int(v)
    except OSError:
        pass
    procs = []
    try:
        procs = [int(x) for x in (d / "cgroup.procs").read_text().split()]
    except OSError:
        pass
    return {
        "cpu_usage_usec": cpu.get("usage_usec", 0),
        "memory_current": _read_int(d / "memory.current"),
        "memory_peak": _read_int(d / "memory.peak"),
        "anon": mem.get("anon", 0),
        "file": mem.get("file", 0),
        "io_rbytes": rbytes,
        "io_wbytes": wbytes,
        "pids": _read_int(d / "pids.current"),
        "procs": procs,
    }


def read_pss_rss(proc, pids):
    """(pss_kb, rss_kb, threads) summed over pids; a pid that vanished mid-read is skipped."""
    pss = rss = threads = 0
    for pid in pids:
        try:
            for line in (Path(proc) / str(pid) / "smaps_rollup").read_text().splitlines():
                if line.startswith("Pss:"):
                    pss += int(line.split()[1])
                elif line.startswith("Rss:"):
                    rss += int(line.split()[1])
            for line in (Path(proc) / str(pid) / "status").read_text().splitlines():
                if line.startswith("Threads:"):
                    threads += int(line.split()[1])
        except (OSError, ValueError, IndexError):
            continue
    return pss, rss, threads


def box_stats(proc):
    proc = Path(proc)
    load1 = 0.0
    try:
        load1 = float((proc / "loadavg").read_text().split()[0])
    except (OSError, ValueError, IndexError):
        pass
    memavail = 0
    for k, v in _read_kv(proc / "meminfo").items():
        if k == "MemAvailable:":
            memavail = v
    steal = 0
    try:
        first = (proc / "stat").read_text().splitlines()[0].split()
        steal = int(first[8])  # user nice system idle iowait irq softirq steal
    except (OSError, ValueError, IndexError):
        pass
    return {"box_load1": load1, "box_memavail_kb": memavail, "box_steal_ticks": steal}


def sample_structured(cg_root, proc, cgroups, ts, net):
    """One tick: ({path: counters}, [csv rows]) with one row per cgroup, then one 'box' row."""
    box = box_stats(proc)
    box_cols = [str(box["box_load1"]), str(box["box_memavail_kb"]), str(box["box_steal_ticks"])]
    structured = {}
    rows = []
    for path, ino in cgroups.items():
        s = read_cgroup(cg_root, path)
        pss_kb, rss_kb, threads = read_pss_rss(proc, s["procs"])
        out_b, in_b = net(path)
        s.update(pss=pss_kb * 1024, rss=rss_kb * 1024, threads=threads, net_out=out_b, net_in=in_b)
        structured[path] = s
        rows.append(",".join(
            [str(ts), path, str(ino), str(s["cpu_usage_usec"]), str(s["memory_current"]), str(s["memory_peak"]),
             str(s["anon"]), str(s["file"]), str(s["pss"]), str(s["rss"]), str(s["io_rbytes"]),
             str(s["io_wbytes"]), str(s["pids"]), str(threads), str(out_b), str(in_b)] + box_cols))
    rows.append(",".join([str(ts), "box", ""] + [""] * len(UNIT_COLUMNS) + box_cols))
    return structured, rows


def sample(cg_root, proc, cgroups, ts, net):
    """CSV rows (strings) for one tick."""
    return sample_structured(cg_root, proc, cgroups, ts, net)[1]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default="/sys/fs/cgroup")
    ap.add_argument("--proc", default="/proc")
    ap.add_argument("--globs", action="append", required=True, help="cgroup path glob relative to --root; repeatable")
    ap.add_argument("--interval", type=int, default=10)
    ap.add_argument("--out", default="/var/lib/bench/samples.csv")
    ap.add_argument("--events", default="/var/lib/bench/events.csv")
    ap.add_argument("--netcounters", action="store_true", help="read nft byte counters per cgroup (collector/netcounters.py)")
    ap.add_argument("--once", action="store_true", help="one tick, then exit (for tests)")
    args = ap.parse_args(argv)

    if args.netcounters:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import netcounters  # noqa: WPS433

        netcounters.ensure_table()

        def net(path):
            return netcounters.read(netcounters.key_for(path))
    else:
        def net(path):
            return (0, 0)

    new_out = not os.path.exists(args.out) or os.path.getsize(args.out) == 0
    out = open(args.out, "a", buffering=1)
    events = open(args.events, "a", buffering=1)
    if new_out:
        out.write(HEADER + "\n")
    if os.path.getsize(args.events) == 0:
        events.write("ts,event,cgroup,detail\n")
    ev = csv.writer(events)
    ev.writerow([int(time.time()), "start", "", " ".join(args.globs)])

    known = {}
    last_cpu = {}
    try:
        while True:
            ts = int(time.time())
            cur = discover(args.root, args.globs)
            fresh = [path for event, path in diff_discovery(known, cur) if event in ("cgroup_appeared", "restart")]
            for event, path in diff_discovery(known, cur):
                ev.writerow([ts, event, path, cur.get(path, "")])
            known = cur
            structured, rows = sample_structured(args.root, args.proc, known, ts, net)
            cpu_now = {path: s["cpu_usage_usec"] for path, s in structured.items()}
            for path in counter_resets(last_cpu, cpu_now):
                ev.writerow([ts, "restart", path, "cpu counter reset"])
                fresh.append(path)
            last_cpu = cpu_now
            if args.netcounters:
                for path in dict.fromkeys(fresh):
                    try:
                        netcounters.ensure_rules(path, netcounters.key_for(path))
                    except Exception as e:  # nft refused: keep sampling, record it
                        ev.writerow([ts, "netcounter_error", path, str(e)[:200]])
            for row in rows:
                out.write(row + "\n")
            if args.once:
                break
            time.sleep(max(0.0, args.interval - (time.time() % args.interval)))
    finally:
        ev.writerow([int(time.time()), "stop", "", ""])
        out.close()
        events.close()


if __name__ == "__main__":
    main()
