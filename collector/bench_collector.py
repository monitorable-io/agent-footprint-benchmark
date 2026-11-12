#!/usr/bin/env python3
"""Sample a set of cgroups every N seconds into a CSV. Stdlib only.

Reads the kernel's own accounting for each matched cgroup (cpu.stat, memory.*, io.stat,
pids.current), PSS/RSS from /proc/<pid>/smaps_rollup over the processes of the cgroup and
of every cgroup below it, and bytes in/out from nftables counters (collector/netcounters.py).
With --blockdev-trace it also records how much filesystem-metadata writeback the kernel charged to
each row (io_wbytes_blockdev) and to the whole box (box_wbytes_blockdev): collector/blockdev_trace.py.
Restarts are detected by the cgroup directory's inode changing; the inode map is persisted
next to the CSV so a restart that happens while the sampler itself restarts is still logged.
"""
import argparse
import csv
import glob
import json
import os
import re
import sys
import time
from pathlib import Path

# A cgroup path we are willing to put into a CSV and an nft rule: unit-name characters only.
SAFE_PATH = re.compile(r"[A-Za-z0-9_.@:-]+(/[A-Za-z0-9_.@:-]+)*")  # used with fullmatch; no quotes, blanks, backslashes

HEADER = (
    "ts,cgroup,cgroup_ino,cpu_usage_usec,memory_current,memory_peak,anon,file,pss,rss,"
    "io_rbytes,io_wbytes,pids,threads,net_out,net_in,box_load1,box_memavail_kb,box_steal_ticks,"
    "io_wbytes_blockdev,box_wbytes_blockdev"
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
    procs = read_procs(d)
    return {
        "cpu_usage_usec": cpu.get("usage_usec", 0),
        "memory_current": _read_int(d / "memory.current"),
        "memory_peak": _read_int(d / "memory.peak"),
        "anon": mem.get("anon", 0),
        "file": mem.get("file", 0),
        "io_rbytes": rbytes,
        "io_wbytes": wbytes,
        "pids": len(procs),  # processes; pids.current would count every thread
        "procs": procs,
    }


def read_procs(d):
    """Pids in cgroup `d` and every cgroup below it. A slice's units live in child cgroups (HetrixTools'
    minutely transient unit); a child that vanishes mid-walk is skipped (os.walk ignores errors)."""
    procs = []
    for dirpath, _dirs, files in os.walk(d):
        if "cgroup.procs" in files:
            try:
                procs.extend(int(x) for x in (Path(dirpath) / "cgroup.procs").read_text().split())
            except (OSError, ValueError):
                continue
    return procs


def inode_state_path(out):
    """<samples>.inodes.json next to the CSV."""
    return Path(out).with_suffix(".inodes.json")


def load_inode_state(path):
    """The cgroup -> inode map the previous sampler process saved; {} if none or unreadable."""
    try:
        data = json.loads(Path(path).read_text())
        return {str(k): int(v) for k, v in data.items()} if isinstance(data, dict) else {}
    except (OSError, ValueError, TypeError, AttributeError):
        return {}


def save_inode_state(path, cgroups):
    tmp = Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(cgroups, sort_keys=True))
    os.replace(tmp, path)


def startup_events(saved, cur):
    """First-tick events of a new sampler process: every cgroup appears (nft rules are re-armed), except
    one whose inode differs from the saved map, which is a restart."""
    events = [("cgroup_gone", p) for p in sorted(set(saved) - set(cur))]
    for path in sorted(cur):
        events.append(("restart" if path in saved and saved[path] != cur[path] else "cgroup_appeared", path))
    return events


def last_written_ts(csv_path):
    """ts of the last complete sample row in the CSV, or None (no file, header only)."""
    try:
        with open(csv_path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 65536))
            tail = f.read().decode("utf-8", "replace")
    except OSError:
        return None
    lines = tail.split("\n")
    complete = lines[:-1]  # the part after the last newline is empty or a torn write
    for line in reversed(complete):
        first = line.split(",", 1)[0]
        if first.isdigit():
            return int(first)
    return None


def last_blockdev_values(csv_path):
    """({cgroup: io_wbytes_blockdev}, box_wbytes_blockdev) of the last tick in the CSV; ({}, 0) if none.
    A new sampler process continues these counts instead of restarting them at zero."""
    try:
        with open(csv_path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 65536))
            lines = f.read().decode("utf-8", "replace").split("\n")[:-1]
    except OSError:
        return {}, 0
    rows, total, last = {}, 0, None
    for line in reversed(lines):
        cells = line.split(",")
        if len(cells) < 21 or not cells[0].isdigit():
            continue
        if last is None:
            last = cells[0]
        if cells[0] != last:
            break
        if cells[1] == "box":
            total = int(cells[20]) if cells[20].isdigit() else 0
        elif cells[19].isdigit():
            rows[cells[1]] = int(cells[19])
    return rows, total


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


def sample_structured(cg_root, proc, cgroups, ts, net, ledger=None):
    """One tick: ({path: counters}, [csv rows]) with one row per cgroup, then one 'box' row. The last two
    columns are empty without a ledger (no --blockdev-trace, or the tracer could not be armed)."""
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
             str(s["io_wbytes"]), str(s["pids"]), str(threads), str(out_b), str(in_b)] + box_cols
            + ["" if ledger is None else str(ledger.row(path)), ""]))
    rows.append(",".join([str(ts), "box", ""] + [""] * len(UNIT_COLUMNS) + box_cols
                         + ["", "" if ledger is None else str(ledger.total)]))
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
    ap.add_argument("--net-ports", default="", help="comma-separated TCP ports: count bytes by port instead of by cgroup "
                    "(socket-activated or polled rows); attributed to the row's first cgroup")
    ap.add_argument("--blockdev-trace", action="store_true", help="record the filesystem-metadata writeback charged "
                    "to each row and to the box (collector/blockdev_trace.py)")
    ap.add_argument("--tracefs", default="/sys/kernel/tracing")
    ap.add_argument("--blockdev-ino", type=int, default=0, help="the block-device inode to watch (default: the root filesystem's)")
    ap.add_argument("--blockdev-out", default="/var/lib/bench/blockdev.csv", help="who was charged, per tick with writeback")
    ap.add_argument("--once", action="store_true", help="one tick, then exit (for tests)")
    ap.add_argument("--ticks", type=int, default=0, help="stop after this many ticks (for tests); 0 = run forever")
    args = ap.parse_args(argv)
    if args.once:
        args.ticks = 1

    net_ports = [int(p) for p in args.net_ports.split(",") if p.strip()]
    snapshot = {}
    first_path = {"value": None}
    if args.netcounters:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import netcounters  # noqa: WPS433

        netcounters.ensure_table()
        if net_ports:
            netcounters.ensure_port_rules(net_ports, "ports")

        def net(path):
            if net_ports:
                return netcounters.read("ports", snapshot=snapshot) if path == first_path["value"] else (0, 0)
            return netcounters.read(netcounters.key_for(path), snapshot=snapshot)
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

    # Filesystem-metadata writeback: which cgroup the kernel charged it to. A box where the tracepoint
    # cannot be armed is recorded and sampled without the two columns.
    tracer = ledger = side = None
    names = {}
    if args.blockdev_trace:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import blockdev_trace  # noqa: WPS433

        ino = args.blockdev_ino or blockdev_trace.blockdev_ino(os.stat("/").st_dev)
        try:
            tracer = blockdev_trace.Tracer(args.tracefs, ino=ino)
            tracer.arm()
            ledger = blockdev_trace.Ledger()
            ledger.seed(*last_blockdev_values(args.out))
            new_side = not os.path.exists(args.blockdev_out) or os.path.getsize(args.blockdev_out) == 0
            side = open(args.blockdev_out, "a", buffering=1)
            if new_side:
                side.write("ts,cgroup_ino,cgroup,bytes\n")
            ev.writerow([int(time.time()), "blockdev_trace", "", f"ino={ino}"])
        except OSError as e:
            tracer = ledger = None
            ev.writerow([int(time.time()), "blockdev_trace_error", "", str(e)[:200]])

    unparsed_seen = 0
    state_path = inode_state_path(args.out)
    saved = load_inode_state(state_path)
    # The previous process may have written this window already (a unit restart overlaps the two
    # processes for a moment): never write a second row for a window it wrote.
    last_ts = last_written_ts(args.out)
    known = None
    last_cpu = {}
    ticks = 0
    try:
        while True:
            ts = int(time.time())
            cur = discover(args.root, args.globs)
            changes = startup_events(saved, cur) if known is None else diff_discovery(known, cur)
            fresh = [path for event, path in changes if event in ("cgroup_appeared", "restart")]
            for event, path in changes:
                ev.writerow([ts, event, path, cur.get(path, "")])
            # Saved only when it changes: a write every tick would be ~35 MB/day charged to the
            # collector's own cgroup (the control row). A failed save is logged, never fatal.
            if known is None or cur != known:
                try:
                    save_inode_state(state_path, cur)
                except OSError as e:
                    ev.writerow([ts, "state_error", "", str(e)[:200]])
            known = cur
            first_path["value"] = next(iter(known), None)
            if args.netcounters:
                snapshot = netcounters.read_all()
            if tracer is not None:
                # Whatever goes wrong here is recorded and ends the tracing, never the sampling: the
                # rows of this tick and of every later one are written without the two columns.
                try:
                    charged = tracer.poll()
                    ledger.add(charged, {path: blockdev_trace.cgroup_inodes(Path(args.root) / path) for path in known})
                    if any(ino not in names for ino in charged):
                        names = blockdev_trace.cgroup_names(args.root)   # a walk only when a new owner shows up
                    for ino, nbytes in sorted(charged.items()):
                        side.write(f"{ts},{ino},{names.get(ino, '')},{nbytes}\n")
                    if tracer.unparsed > unparsed_seen:
                        unparsed_seen = tracer.unparsed
                        ev.writerow([ts, "blockdev_trace_unparsed", "", f"{unparsed_seen} line(s); last: {tracer.last_unparsed[:160]}"])
                except Exception as e:  # noqa: BLE001
                    ev.writerow([ts, "blockdev_trace_error", "", str(e)[:200]])
                    tracer.close()
                    tracer = ledger = None
            structured, rows = sample_structured(args.root, args.proc, known, ts, net, ledger)
            cpu_now = {path: s["cpu_usage_usec"] for path, s in structured.items()}
            for path in counter_resets(last_cpu, cpu_now):
                ev.writerow([ts, "restart", path, "cpu counter reset"])
                fresh.append(path)
            last_cpu = cpu_now
            if args.netcounters and not net_ports:
                for path in dict.fromkeys(fresh):
                    try:
                        netcounters.ensure_rules(path, netcounters.key_for(path))
                    except Exception as e:  # nft refused: keep sampling, record it
                        ev.writerow([ts, "netcounter_error", path, str(e)[:200]])
            if last_ts is None or ts // args.interval > last_ts // args.interval:
                for row in rows:
                    out.write(row + "\n")
            ticks += 1
            if args.ticks and ticks >= args.ticks:
                break
            time.sleep(max(0.0, args.interval - (time.time() % args.interval)))
    finally:
        ev.writerow([int(time.time()), "stop", "", ""])
        out.close()
        events.close()
        if side is not None:
            side.close()
        if tracer is not None:
            tracer.close()   # the instance stays armed: its buffer bridges a sampler restart


if __name__ == "__main__":
    main()
