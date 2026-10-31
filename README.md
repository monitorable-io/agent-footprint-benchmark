# Agent footprint benchmark

What Linux server monitoring agents cost the server they watch: memory, CPU,
disk writes, network bytes, install time and on-disk size, measured on
identical cheap VPSes over 24 hours idle plus one loaded hour, three times,
with every 10-second sample published here.

**Status: harness built, bed rented, run not started (2026-10-31).** Results land in
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
delta over wall time, as a share of one vCPU (the boxes have two; a value of
100 % means one core busy). Per-24 h figures are the idle window
scaled to 24 h. The headline is the median of the three per-cycle values;
samples are never pooled across cycles. Rows are sorted by idle PSS.

Rules that keep rows comparable, and the deviations, are listed in each
`meta.json`'s `footnotes` and repeated on the results page.

## The bed

10 boxes of one type (Hetzner Cloud CX23, Helsinki `hel1`: 2 shared vCPU,
4 GB, 40 GB, Ubuntu 26.04 LTS): 9 measured boxes `box-0`…`box-8` and a sink
box running the hubs the self-hosted agents need (Beszel hub, Prometheus,
InfluxDB 1.x, Pulse server, a Glances poller) so that polled agents do real
work. Every box runs Docker with two idle containers for the whole cycle.

The account holds at most 10 servers, so the 12 roles (11 agents and the
control box, which runs only the harness) take turns: **4 slots of about
26 h**, 9 roles per slot, every role 3 times on 3 different boxes
(`lib/rotation.sh`; `./bench cycle plan` prints the table). Between slots a
box is **rebuilt in place** from the stock image (same server, same address);
no box is destroyed during the run, and `bench vm destroy` refuses unless
`BENCH_ALLOW_DESTROY=1`. The n-th run of a role is filed as `cycle-n`, so
the results read as three cycles per agent; `data/<year>/slots/` keeps the
slot manifests, and each install record carries the box's CPU model (shared
vCPU may be Intel or AMD) for the write-up to footnote.

Other providers: `BENCH_PROVIDER=onidel` selects the Onidel Cloud client
(`lib/onidel.sh`, create/destroy by API) kept from the first plan.

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

For the full run: `./bench quote` (prices from the API, nothing rented),
rent the boxes (`./bench vm create …` where the provider allows it; the 2026
bed was ordered by hand), fill `BOX_*_IP`, `./bench sink up`, then per slot
`./bench cycle start <s>` (it first makes the hubs forget exactly the boxes
it is about to rebuild — Beszel refuses a rebuilt box's new fingerprint
while the old record exists, Pulse binds a token to one Docker host — and
mints a Pulse agent token for the slot, since Pulse revokes a token with
the last host that used it; `bench sink reset --dry-run box-3` shows what
it would do), `./bench cycle status` right after and again after an hour,
`./bench collect <s>` after 26 h, for s = 0…3; `python3 summarize.py
data/2026`. `BENCH_ONLY_BOXES="box-4" ./bench cycle start <s>` redoes one
box (and forgets only it on the hubs). `bench sink reset --all` is refused
while a slot is running. `docs/RUN-2026.md` is the run log.

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
rule shapes, install recording and secret redaction, the Hetzner and Onidel
clients on recorded fixtures, the slot schedule, summarize on synthetic
cycles). `tests/test_*_lxd.sh` are the dry runs against a local LXD VM.

## Security notes

Keys live only in `bench.env` (0600, gitignored) and reach a box as a 0600
file; the operator's cloud API token and SSH credentials never leave the
operator host (the token travels in a curl config, never on a command line). Install logs are redacted before they are recorded. Polled agents'
ports are reachable from the sink only; the sink's hub ports are reachable
from the agent boxes only (gated in `DOCKER-USER`, since Docker publishes
past ufw). Pulse's installer travels over plain HTTP between two benchmark
boxes and is checksum-pinned before it runs.

## Licence

Apache-2.0. Agent names and install commands belong to their vendors.
