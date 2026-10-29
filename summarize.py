#!/usr/bin/env python3
"""Reduce data/<year>/cycle-*/ (raw 10-second samples) to results.json and results.md. Stdlib only.

Per agent and cycle: the idle window is hours 1-24 after the install finished (the first hour is
reported separately as a warm-up peak), the loaded window is the stress hour after it. CPU % is the
cgroup's CPU-time delta over wall time on the box's single vCPU. Counters that move backwards (a
recreated cgroup) count as a delta from zero. The headline value per metric is the median of the
three per-cycle values; samples are never pooled across cycles.
"""
import csv
import gzip
import json
import statistics
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

WARMUP_SECONDS = 3600
DAY = 86400
MB = 1_000_000

METRICS = [
    ("pss_idle_median_mb", "Memory (PSS), idle median", "MB", True),
    ("pss_idle_p95_mb", "Memory (PSS), idle p95", "MB", True),
    ("rss_idle_median_mb", "Memory (RSS), idle median", "MB", True),
    ("memory_peak_mb", "Memory peak (cgroup), whole cycle", "MB", True),
    ("first_hour_peak_mb", "Memory (PSS) peak, first hour after install", "MB", True),
    ("cpu_idle_pct", "CPU, idle (one vCPU)", "%", True),
    ("cpu_loaded_pct", "CPU, under load (one vCPU)", "%", True),
    ("disk_written_mb_24h", "Disk written per 24 h", "MB", True),
    ("journal_mb_24h", "Log volume handed to journald per 24 h", "MB", True),
    ("net_out_mb_24h", "Network out per 24 h", "MB", True),
    ("net_in_mb_24h", "Network in per 24 h", "MB", True),
    ("net_headline_mb_24h", "Network per 24 h (out for push agents, in+out for polled)", "MB", True),
    ("install_seconds", "Install wall time", "s", True),
    ("disk_footprint_mb", "On-disk footprint after the cycle", "MB", True),
    ("pids_median", "Processes, idle median", "", True),
    ("threads_median", "Threads, idle median", "", True),
]
COUNTERS = ("cpu_usage_usec", "io_rbytes", "io_wbytes", "net_out", "net_in")
GAUGES = ("memory_current", "memory_peak", "anon", "file", "pss", "rss", "pids", "threads")
DISPLAY = {
    "beszel": "Beszel agent", "netdata": "Netdata (self-hosted)", "netdata-cloud": "Netdata (claimed to Netdata Cloud)",
    "glances": "Glances", "node-exporter": "node_exporter", "telegraf": "Telegraf", "pulse": "Pulse agent",
    "datadog": "Datadog Agent", "fivenines": "Fivenines agent", "hetrixtools": "HetrixTools agent",
    "monitorable": "Monitorable agent", "control": "No agent (harness only)",
}
US = "monitorable"


def windows(schedule):
    """(idle_start, idle_end, load_start, load_end) from a box's schedule."""
    t0, load_start, stop = schedule["installFinished"], schedule["loadStart"], schedule["stop"]
    return (t0 + WARMUP_SECONDS, load_start, load_start, stop)


def load_rows(path):
    """(unit rows, box rows) of a samples CSV (plain or .gz); unit rows carry ints, box rows the load."""
    opener = gzip.open if str(path).endswith(".gz") else open
    rows, box = [], []
    with opener(path, "rt", newline="") as f:
        for r in csv.DictReader(f):
            if r["cgroup"] == "box":
                try:
                    box.append({"ts": int(r["ts"]), "box_load1": float(r["box_load1"] or 0)})
                except ValueError:
                    pass
                continue
            row = {"ts": int(r["ts"]), "cgroup": r["cgroup"]}
            for k in COUNTERS + GAUGES:
                row[k] = int(r[k] or 0)
            rows.append(row)
    return rows, box


def counter_total(rows, column):
    """Sum of deltas of a monotonic counter per cgroup; a backwards move counts as a delta from zero."""
    total = 0
    last = {}
    for r in rows:
        v, cg = r[column], r["cgroup"]
        if cg in last:
            total += v - last[cg] if v >= last[cg] else v
        last[cg] = v
    return total


def _by_ts(rows):
    """Gauge values summed across cgroups at each timestamp."""
    acc = defaultdict(lambda: defaultdict(int))
    for r in rows:
        for g in GAUGES:
            acc[r["ts"]][g] += r[g]
    return acc


def _p95(values):
    if not values:
        return 0.0
    s = sorted(values)
    return s[min(len(s) - 1, int(round(0.95 * (len(s) - 1))))]


LOAD_MIN_LOAD1 = 0.8


def cycle_metrics(rows, meta, box_rows=()):
    """One cycle's metric values for one agent."""
    sched = meta["schedule"]
    idle_start, idle_end, load_start, load_end = windows(sched)
    load_peak = max((b["box_load1"] for b in box_rows if load_start <= b["ts"] < load_end), default=None)
    if load_peak is not None and load_peak < LOAD_MIN_LOAD1:
        meta.setdefault("footnotes", []).append(
            f"The load window of the cycle starting {sched['installFinished']} shows no load (peak load1 {load_peak}); its loaded figure is suspect.")
    idle = [r for r in rows if idle_start <= r["ts"] < idle_end]
    loaded = [r for r in rows if load_start <= r["ts"] < load_end]
    warm = [r for r in rows if sched["installFinished"] <= r["ts"] < idle_start]
    if not idle:
        meta.setdefault("footnotes", []).append(
            f"No samples in the idle window (hours 1-24 after install) for the cycle starting {sched['installFinished']}; idle figures are 0.")
    idle_ts = _by_ts(idle)
    pss = [v["pss"] for v in idle_ts.values()]
    rss = [v["rss"] for v in idle_ts.values()]
    idle_wall = max(1, (idle[-1]["ts"] - idle[0]["ts"])) if len(idle) > 1 else 1
    load_wall = max(1, (loaded[-1]["ts"] - loaded[0]["ts"])) if len(loaded) > 1 else 1
    per_day = DAY / idle_wall
    out_b, in_b = counter_total(idle, "net_out") * per_day, counter_total(idle, "net_in") * per_day
    kind = meta.get("kind", "push")
    headline = out_b + in_b if kind == "polled" else out_b
    install = meta.get("install", {})
    footprint = meta.get("footprint") or {}
    disk_bytes = footprint.get("disk_bytes", install.get("disk_bytes", 0))
    journal = footprint.get("journal_bytes")
    return {
        "pss_idle_median_mb": statistics.median(pss) / MB if pss else 0.0,
        "pss_idle_p95_mb": _p95(pss) / MB,
        "rss_idle_median_mb": statistics.median(rss) / MB if rss else 0.0,
        "memory_peak_mb": max((v["memory_peak"] for v in _by_ts(rows).values()), default=0) / MB,
        "first_hour_peak_mb": max((v["pss"] for v in _by_ts(warm).values()), default=0) / MB,
        "cpu_idle_pct": counter_total(idle, "cpu_usage_usec") / (idle_wall * 1e6) * 100,
        "cpu_loaded_pct": counter_total(loaded, "cpu_usage_usec") / (load_wall * 1e6) * 100,
        "disk_written_mb_24h": counter_total(idle, "io_wbytes") * per_day / MB,
        "journal_mb_24h": (journal * DAY / max(1, idle_end - idle_start) / MB) if journal is not None else None,
        "net_out_mb_24h": out_b / MB,
        "net_in_mb_24h": in_b / MB,
        "net_headline_mb_24h": headline / MB,
        "install_seconds": float(install.get("seconds", 0)),
        "disk_footprint_mb": disk_bytes / MB,
        "pids_median": statistics.median(v["pids"] for v in idle_ts.values()) if idle_ts else 0,
        "threads_median": statistics.median(v["threads"] for v in idle_ts.values()) if idle_ts else 0,
    }


def reduce_cycles(per_cycle):
    """{metric: {median, cycles: [...]}} from a list of per-cycle metric dicts."""
    out = {}
    for key, *_ in METRICS:
        vals = [c[key] for c in per_cycle if c.get(key) is not None]
        out[key] = {"median": statistics.median(vals) if vals else None, "cycles": vals}
    return out


def _git_head(root):
    try:
        return subprocess.run(["git", "-C", str(root), "rev-parse", "--short", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def summarize(root, harness_commit=None):
    root = Path(root)
    year = root.name
    run_facts = json.loads((root / "run.json").read_text()) if (root / "run.json").exists() else {}
    cycles = sorted(p for p in root.glob("cycle-*") if p.is_dir())
    per_agent = defaultdict(list)
    metas = {}
    footnotes = defaultdict(list)
    spans = []
    kernel = run_facts.get("kernel", "")
    for cdir in cycles:
        starts, ends = [], []
        for mpath in sorted(cdir.glob("*.meta.json")):
            name = mpath.name[: -len(".meta.json")]
            meta = json.loads(mpath.read_text())
            csv_path = cdir / f"{name}.csv.gz"
            if not csv_path.exists():
                csv_path = cdir / f"{name}.csv"
            if not csv_path.exists():
                continue
            rows, box_rows = load_rows(csv_path)
            base_notes = list(meta.get("footnotes", []))
            meta["footnotes"] = []
            if meta.get("install", {}).get("status", "ok") != "ok" or not rows:
                meta["footnotes"].append(f"Cycle {cdir.name[-1]}: install failed or no samples; not counted.")
            else:
                per_agent[name].append(cycle_metrics(rows, meta, box_rows))
            for note in base_notes:
                if note not in footnotes[name]:
                    footnotes[name].append(note)
            footnotes[name].extend(meta["footnotes"])
            metas[name] = meta
            kernel = kernel or meta.get("install", {}).get("kernel", "")
            starts.append(meta["schedule"]["installFinished"])
            ends.append(meta["schedule"]["stop"])
        if starts:
            spans.append({"start": min(starts), "end": max(ends)})

    def row_for(name):
        meta = metas[name]
        install = meta.get("install", {})
        return {
            "key": name,
            "name": DISPLAY.get(name, name),
            "version": install.get("version", ""),
            "licence": meta.get("licence", ""),
            "sourceUrl": meta.get("sourceUrl", ""),
            "installUrl": meta.get("sourceUrl", ""),
            "unitNames": install.get("units", []),
            "reportsTo": meta.get("reportsTo", ""),
            "intervalSeconds": meta.get("intervalSeconds", 0),
            "us": name == US,
            "footnotes": footnotes[name],
            "values": reduce_cycles(per_agent.get(name, [])),
        }

    rows = [row_for(n) for n in metas if n not in ("control", "none")]
    rows.sort(key=lambda r: (r["values"]["pss_idle_median_mb"]["median"] is None, r["values"]["pss_idle_median_mb"]["median"] or 0))
    control = row_for("control") if "control" in metas else None
    return {
        "slug": f"agent-footprint-{year}",
        "title": f"Linux monitoring agent footprint benchmark ({year}): {len(rows)} agents, one VPS type, 24 hours",
        "checked": __import__("datetime").date.today().isoformat(),
        "run": {
            "provider": run_facts.get("provider", ""),
            "location": run_facts.get("location", ""),
            "plan": run_facts.get("plan", ""),
            "image": run_facts.get("image", ""),
            "kernel": kernel,
            "harnessCommit": harness_commit or _git_head(root),
            "cycles": spans,
        },
        "metrics": [{"key": k, "label": label, "unit": unit, "lowerIsBetter": lower} for k, label, unit, lower in METRICS],
        "rows": rows,
        "control": control,
    }


def to_markdown(results):
    keys = ["pss_idle_median_mb", "memory_peak_mb", "cpu_idle_pct", "cpu_loaded_pct", "disk_written_mb_24h", "net_headline_mb_24h", "install_seconds", "disk_footprint_mb"]
    labels = {m["key"]: m["label"] for m in results["metrics"]}
    lines = [f"# {results['title']}", "", "| Agent | Version | " + " | ".join(labels[k] for k in keys) + " |", "|---|---|" + "---|" * len(keys)]
    rows = list(results["rows"]) + ([results["control"]] if results.get("control") else [])
    for r in rows:
        cells = []
        for k in keys:
            m = r["values"][k]["median"]
            cells.append("n/a" if m is None else f"{m:.1f}")
        lines.append(f"| {r['name']}{' (us)' if r['us'] else ''} | {r['version']} | " + " | ".join(cells) + " |")
    lines += ["", f"Cycles: {len(results['run']['cycles'])}. {results['run']['provider']} {results['run']['location']} {results['run']['plan']}, {results['run']['image']}, kernel {results['run']['kernel']}, harness {results['run']['harnessCommit']}."]
    return "\n".join(lines) + "\n"


def main(argv=None):
    import argparse

    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("root", help="data/<year>")
    ap.add_argument("--out", help="results.json path (default <root>/results.json)")
    ap.add_argument("--md", help="results.md path (default <root>/results.md)")
    args = ap.parse_args(argv)
    root = Path(args.root)
    results = summarize(root)
    out = Path(args.out) if args.out else root / "results.json"
    md = Path(args.md) if args.md else root / "results.md"
    out.write_text(json.dumps(results, indent=2) + "\n")
    md.write_text(to_markdown(results))
    print(f"{len(results['rows'])} rows, {len(results['run']['cycles'])} cycles -> {out}, {md}")


if __name__ == "__main__":
    main()
