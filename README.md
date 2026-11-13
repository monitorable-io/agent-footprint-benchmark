# Agent footprint benchmark

What Linux server monitoring agents cost the server they watch: memory, CPU,
disk writes, network bytes, install time and on-disk size, measured on
identical cheap VPSes over 24 hours idle plus one loaded hour, three times,
with every 10-second sample published here.

**Status: the run is complete (2026-11-07 → 2026-11-13).** 11 agents and a
control, three runs each on three different boxes, 36 role-runs, all
collected. `data/2026/results.md` is the headline table and
`data/2026/results.json` the same with every per-run value and footnote;
`docs/RUN-2026.md` is the run log with every deviation.
`python3 summarize.py data/2026 --harness-commit d879a73..e73e37f` reproduces
`results.json` (apart from its `checked` date). The files in `data/2026/` are laid out like the pilot's,
described below.

Eight of the 36 role-runs were measured twice. Checking the data showed
that the kernel can charge the box's own filesystem-metadata writeback to
the measured agent's cgroup, where it reads as the agent's disk writes
(`docs/RUN-2026-slot5.md` has the mechanism and the evidence). The collector
now records how much of it each row was charged, and the runs it had
affected or could have affected were measured again in one more slot on
2026-11-12/13 under a rule fixed beforehand: every run measured again
replaces the run it stands for, whatever it shows. They are Monitorable
run 1, Beszel run 3 and the three runs of each Netdata row; their samples
come with `<agent>.blockdev.csv`, the record of which cgroup was charged.
The replaced runs stay published in `data/2026/superseded/`, and the slot as
collected, with its own control run, in `data/2026-slot5/`.

The first run (2026-10-31 → 2026-11-04) is the **pilot**: it found four
harness defects (the collector missed processes in child cgroups and could
write a timestamp twice, network bytes counted Docker bridge traffic,
Ubuntu's unattended-upgrades restarted agents mid-cycle), so every row was
measured again with the fixed harness and the current release of every
agent (`data/2026/run.json` lists what the method changed in its `notes`).
One of the pilot's findings was about our own row: the Monitorable agent
(v1.5.0) wrote 115 MB per 24 h to its on-disk export queue. We shipped
v1.7.0, which writes a batch only if it is still undelivered after 15 s,
as a normal release and started the re-run after it, so the re-run measures
the release a reader installs today, for our agent as for every other.

The pilot stays published in `data/2026-pilot/`: `results.json` and `results.md` (the headline table),
`cycle-1…3/<agent>.csv.gz` (every 10-second sample), `<agent>.meta.json` (install
record, schedule, footnotes), `<agent>.events.csv` (collector start/stop and the
cgroup inode changes it noticed; the samples' `cgroup_ino` column is the complete
record of agent restarts), `slots/` (the slot manifests) and `run.json` (the bed,
with the kernel each box booted). `docs/RUN-2026-pilot.md` is its run log with every
deviation; `python3 summarize.py data/2026-pilot --harness-commit 903c57c..ea882d1`
reproduces its `results.json` with this checkout's summarize (which adds the
`memory_current_idle_median_mb` metric and `run.notes`). The write-up will be at
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

Disk writes need one correction. ext4 writes its metadata (inode tables,
bitmaps, directories) through the block device's own inode, and the kernel
charges all writeback of one inode to a single cgroup: whichever owns that
inode at the time, not whoever caused the writes. On the 2026 boxes that
stream is about 2.8 MB per hour of 4 KB writes where the agent writes little
and 5.6 to 6.4 MB per hour on a box running Netdata, whose own file activity
adds to it. It was seen charged to a mount unit with no process, to rsyslog,
to the root cgroup and to Netdata's unit (for 8 to 21 of the 23 idle hours
in each of its six instrumented runs); that it was charged to the measured
agent for seven to eight hours in two earlier runs is inferred from the rate
and the write sizes (`docs/RUN-2026.md`, "Deviations"). No row's disk figure
is meant to contain it: disk written counts data writes, and the metadata an
agent's own file activity causes is left out for every agent alike.
The collector therefore records how much of it the kernel charged to each
row (`collector/blockdev_trace.py`: the tracepoint
`writeback:writeback_single_inode`, filtered to that inode, in a tracefs
instance of its own; columns `io_wbytes_blockdev` and `box_wbytes_blockdev`;
`<agent>.blockdev.csv` names the charged cgroup at every sample that saw
such writeback). `summarize.py` publishes an agent's disk writes without it
(`disk_written_mb_24h`; taken out hour by hour, never more than was charged
in that hour), the whole charge
(`disk_charged_mb_24h`) and the excluded part
(`disk_metadata_charged_mb_24h`). Samples taken before the tracer existed
have no such column, and their charge is published as it is. Two limits:
the tracepoint fires for the flusher's per-inode pass only, so metadata
written by a sync of the block device or by a journal checkpoint in a
process's own context stays in the unit's figure; and it counts whole pages
per pass, so it reads above the kernel's charge: 1,552,384 bytes against
1,392,640 (11 %) over 40 minutes on a box where the charged cgroup has no
process of its own, which is the one case where the two can be compared
exactly. A unit that is charged the stream therefore has its own writes of
those hours understated by up to that excess: about 0.3 MB per hour on a
quiet box and 0.6 to 0.75 MB per hour for Netdata's unit, about a tenth of
its published figure (`docs/RUN-2026-slot5.md`, "Deviations"). That is why
the charge is published as well, as `disk_charged_mb_24h` in `results.json`
and in the row notes of `results.md`. The side file is
written by the collector, whose own cost is the control row.

`summarize.py` turns the CSVs into `results.json`: idle window = hours 1–24
after the install finished (the first hour is reported separately as a
warm-up peak), loaded window = the stress hour after it. CPU % is CPU-time
delta over wall time, as a share of one vCPU (the boxes have two; a value of
100 % means one core busy). Per-24 h figures are the idle window
scaled to 24 h. The headline is the median of the three per-cycle values;
samples are never pooled across cycles. Rows are sorted by idle PSS. A
metric's `cycles` lists the values of the runs that have one, in cycle
order; each row's `runs` gives the box and the dates behind each cycle and
says whether that run has the metadata record.

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
(`lib/rotation.sh`; `./bench cycle plan` prints the table). A slot can also
be given its roles by hand: a plan file `data/<year>/slots/slot-<s>.plan`
(one line per box, `box-J ROLE RUN`) replaces the rotation for that slot,
and `YEAR` and `BENCH_SLOT_COUNT` in `bench.env` name the data root and the
number of slots of the run the checkout is set up for (the instrumented
retest slot of 2026 is `data/2026-slot5`, one slot). A run with a plan file
has no rotation slots: a slot without a file is refused. `cycle start`
refuses while a slot of any data root is still measuring. Between slots a
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
data/2026 --harness-commit <sha>`. `BENCH_ONLY_BOXES="box-4" ./bench cycle start <s>` redoes one
box (and forgets only it on the hubs). A plain `bench install pulse box-N`
has no slot token and warns: it writes bench.env's setup-day `PULSE_TOKEN`,
which Pulse revoked with the last host that used it. `bench sink reset --all` is refused
while a slot is running. `docs/RUN-2026.md` is the run log.

The rest of a run needs no session: `./bench auto init` (markers for the
work already done by hand, a worktree of the data branch for the run log,
the cron line), then that line in the crontab of the host. Every tick
(`./bench auto tick`) reads the slot manifests and the markers in
`data/<year>/auto/`, collects a slot once its last stop has passed, starts
the next slot in the same tick, runs `cycle status` and a hub check right
after and again at +1 h, and writes each step to the run log (committed and
pushed). A collect with a failure halts the runner instead of starting the
next slot, since the start would rebuild the uncollected boxes: fix by
hand, then `./bench auto resume`. `./bench auto status` shows where it is.

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
