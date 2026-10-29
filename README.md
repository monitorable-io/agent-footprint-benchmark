# Agent footprint benchmark

What Linux server monitoring agents cost the server they watch: memory, CPU,
disk writes, network bytes, install time and on-disk size, measured on
identical cheap VPSes over 24 hours idle plus one loaded hour, three times,
with every 10-second sample published here.

**Status: harness built, run not started (2026-10-29).** Results land in
`data/2026/` with the run; the write-up will be at
`https://monitorable.io/benchmarks/agent-footprint-2026/`.

Run by [Monitorable](https://monitorable.io), whose agent is one of the rows.
The method is designed so the ordering is honest by construction: every agent
is installed exactly as its own documentation says, with defaults, and every
number links to the raw samples it came from.

## Agents

Beszel agent, Netdata (self-hosted and claimed to Netdata Cloud), Glances,
node_exporter, Telegraf, Pulse's unified agent, Datadog Agent, Fivenines
agent, HetrixTools agent, Monitorable agent. Each lives in `agents/<name>/`:
`install.sh` is the documented install (its first comment names the page it
was copied from and the date), `meta.json` names what to measure and where
the agent reports. A twelfth "agent", `none`, is the control box: the
harness measuring itself.

## What is measured, and how

Every agent runs as a systemd unit, so the kernel already accounts for it:
`collector/bench_collector.py` reads the unit's cgroup every 10 s (CPU time,
current and peak memory, disk bytes, pids), PSS/RSS from `smaps_rollup` over
the cgroup's processes, and bytes in/out from nftables counters matched on
the cgroup (`collector/netcounters.py`). A recreated cgroup (agent restart) is
detected by inode change or a CPU counter moving backwards and logged.

`summarize.py` turns the CSVs into `results.json`: idle window = hours 1–24
after the install finished (the first hour is reported separately as a
warm-up peak), loaded window = the stress hour after it. CPU % is CPU-time
delta over wall time on the one vCPU. Per-24 h figures are the idle window
scaled to 24 h. The headline is the median of the three per-cycle values;
samples are never pooled across cycles. Rows are sorted by idle PSS.

Rules that keep rows comparable, and the deviations, are listed in each
`meta.json`'s `footnotes` and repeated on the results page.

## The bed

13 boxes of one type (Onidel Cloud, Amsterdam, 1 vCPU / 2 GB, Ubuntu 26.04
LTS): 11 agent boxes, a control box, and a sink box running the hubs the
self-hosted agents need (Beszel hub, Prometheus, InfluxDB 1.x, Pulse server,
a Glances poller) so that polled agents do real work. Every box runs Docker
with two idle containers for the whole cycle. Agents move one box along each
cycle so box variance averages out.

## Reproduce one agent in an hour

Any Ubuntu 26.04 VM or VPS you can SSH into as root (or a local LXD VM):

```sh
cp bench.env.example bench.env && chmod 600 bench.env
# set BOX_MYBOX_IP=<ip> (or lxd:<instance> for a local LXD VM) and the agent's keys, if any
./bench provision mybox                     # docker, stress-ng, ufw, collector
./bench install netdata mybox               # the documented install, timed; collector starts
# wait 70 minutes (an hour of warm-up is excluded), then:
./bench collect 0                           # needs data/<year>/cycle-1/schedule-netdata.json; see lib/cycle.sh
python3 summarize.py data/2026
```

For the full run: `./bench quote` (prices, nothing rented), `./bench vm create
…`, `./bench sink up`, `./bench cycle start 0`, `./bench collect 0` after 25
h, repeat for cycles 1 and 2, `./bench vm destroy …`, `python3 summarize.py
data/2026`. `docs/RUN-2026.md` is the run log.

## Adding an agent

Create `agents/<name>/install.sh` (documented commands only, source URL in the
first comment, print `VERSION=` and `UNITS=` at the end) and `meta.json`
(`kind`: push | polled | none, `cgroupGlobs`, `ports`, `reportsTo`,
`intervalSeconds`, `sourceUrl`, `licence`, `diskPaths`, `user`, optional
`env`, `package`, `footnotes`), add the name to `AGENTS` in
`lib/rotation.sh`, and run `tests/run.sh`.

## Tests

`tests/run.sh`: shellcheck on every script, `docker compose config` on the
sink, and the Python unit tests (collector parsing, restart detection, nft
rule shapes, install recording and secret redaction, Onidel client on
fixtures, summarize on synthetic cycles). `tests/test_*_lxd.sh` are the
dry runs against a local LXD VM.

## Security notes

Keys live only in `bench.env` (0600, gitignored) and reach a box as a 0600
file; the operator's Onidel and SSH credentials never leave the operator
host. Install logs are redacted before they are recorded. Polled agents'
ports are reachable from the sink only; the sink's hub ports are reachable
from the agent boxes only (gated in `DOCKER-USER`, since Docker publishes
past ufw). Pulse's installer travels over plain HTTP between two benchmark
boxes and is checksum-pinned before it runs.

## Licence

Apache-2.0. Agent names and install commands belong to their vendors.
