# Linux monitoring agent footprint benchmark (2026): 11 agents, one VPS type, 24 hours

| Agent | Version | Memory (PSS), idle median | Memory peak (cgroup), whole cycle | CPU, idle (% of one vCPU) | CPU, under load (% of one vCPU) | Disk written per 24 h | Network per 24 h (out for push agents, in+out for polled) | Install wall time | On-disk footprint after the cycle |
|---|---|---|---|---|---|---|---|---|---|
| HetrixTools agent † | 2.4.2 | 9.0 | 12.5 | 17.0 | 12.9 | 5.9 | 3.8 | 2.1 | 0.1 |
| Beszel agent † | beszel-agent 0.21.1 | 17.9 | 118.1 | 0.2 | 0.2 | 0.0 | 3.8 | 3.4 | 10.8 |
| node_exporter † | v1.12.1 | 24.5 | 10.6 | 0.0 | 0.0 | 0.0 | 19.7 | 1.8 | 23.9 |
| Monitorable agent (us) † | monitorable-agent version v1.7.0 | 45.8 | 18.2 | 0.1 | 0.1 | 0.0 | 8.1 | 6.7 | 57.3 |
| Pulse agent † | v6.6.0 | 49.5 | 17.3 | 0.1 | 0.0 | 11.8 | 16.2 | 31.3 | 42.1 |
| Fivenines agent † | fivenines-agent 1.23.1 | 49.9 | 128.7 | 0.2 | 0.2 | 0.5 | 10.0 | 4.1 | 52.1 |
| Glances † | 4.5.9 | 77.7 | 72.6 | 2.4 | 1.7 | 0.0 | 3929.7 | 33.4 | 28.8 |
| Telegraf † | Telegraf 1.40.3 (git: HEAD@41b45388) | 180.2 | 59.0 | 0.2 | 0.2 | 0.0 | 17.3 | 7.9 | 330.6 |
| Datadog Agent † | Agent 7.85.2, Agent 7.85.3 | 195.7 | 198.6 | 1.6 | 1.1 | 103.2 | 89.3 | 17.9 | 1619.3 |
| Netdata (self-hosted) † | v2.12.3 | 357.1 | 308.0 | 3.8 | 2.9 | 138.7 | 0.0 | 26.4 | 794.5 |
| Netdata (claimed to Netdata Cloud) † | v2.12.3 | 360.9 | 296.0 | 3.9 | 3.2 | 148.5 | 0.6 | 30.2 | 798.1 |
| No agent (harness only) † | none | 12.6 | 16.1 | 0.1 | 0.1 | 10.5 | 0.0 | n/a | 0.1 |

Cycles: 3. Hetzner Cloud Helsinki (HEL1) CX23: 2 vCPU AMD EPYC (shared), 4 GB RAM, 40 GB NVMe, Ubuntu 26.04 LTS, kernel 7.0.0-15/-30/-42/-43-generic (differs by box, see kernels), harness d879a73..e73e37f.

Each figure is the median of the per-run values; `results.json` has every run's value.

## Method notes

- Ubuntu's apt-daily and apt-daily-upgrade timers were masked on every box at provisioning (the pilot's unattended-upgrades restarted dynamically linked agents mid-cycle).
- Network bytes count only the box's physical interfaces; Docker bridge traffic is excluded.
- Processes are counted in the agent's cgroup and its child cgroups.
- Disk written counts data writes. Filesystem metadata is written through the block device's inode, and the kernel charges all writeback of one inode to a single cgroup, whichever owns it, so it is not counted for any row, including the metadata an agent's own file activity causes. In the eight runs whose collector recorded it (Monitorable run 1, Beszel run 3 and the three runs of each Netdata row, measured again on 2026-11-12/13; docs/RUN-2026-slot5.md) the metadata charged to the unit's cgroup is taken out and the charge as the kernel reported it is published as well (disk_charged_mb_24h). The other 28 runs have no such record and publish the kernel's charge; docs/RUN-2026-slot5.md says why they are taken not to contain that stream.
- Those eight runs replace the runs first measured in their place, under a rule fixed before the retest: every run measured again replaces the run it stands for, whatever it shows. The replaced runs are in data/2026/superseded/. A cycle therefore holds runs of different days: each row's `runs` in results.json gives the box and the dates of every run and whether it has the metadata record.
- CPU under load is lower than idle CPU in every row, the control included, and no box recorded steal time; the cause is not established.
- Idle CPU depends on the box. On box-0 and box-6 an agent used 1.3 to 1.5 times the idle CPU time it used on box-3; under load the difference is smaller for three of the four agents measured on all three. Beszel, HetrixTools, Pulse and Glances have two of their three runs on those two boxes, so their idle CPU median is one of those runs (each row's notes give its box-3 figure); every other row was measured on the other seven boxes, except Netdata's run 1. The two boxes' virtual CPUs report 2,495 MHz and the others' 2,445 MHz (read on 2026-11-13, docs/evidence/2026-slot5/), so they are probably on another host type; the cause is not established.

## Row notes (†)

**HetrixTools agent**

- This box has no cron, so the vendor installer's own systemd path runs: a minutely timer starting a transient unit per run. Those runs are placed in a persistent slice (one word added to the vendor launcher) so the kernel's accounting for them survives each run. The timer's launcher unit is matched too; a unit that lives for less than the 10-second sampling interval is counted only as far as the samples catch it.
- The CPU figure is 12.6 to 17.4 % of one vCPU in the three runs, and the box's load average agrees: its idle median is 0.22 to 0.30 on this row's boxes against 0.05 to 0.13 on every other box.
- Idle CPU: the published median (17.05 %) is a run on box-0 or box-6, which idle 1.3 to 1.5 times higher than the other boxes for every agent measured on them; this row's run on box-3 shows 12.63 % (see the method notes).

**Beszel agent**

- The memory peak (118 MB) is not only an install-time figure. The cgroup's high-water mark is already 117 MB at the first sample, seconds after the install, and its memory then returns to 101 to 118 MB for one 10-second sample every 61 minutes: 24 such samples in each of runs 1 and 3, with a PSS of 116 to 132 MB in them, and none caught in run 2, as can happen with a spike shorter than the sampling interval. Between them the cgroup holds about 8 MB, which is what the idle median shows.
- Idle CPU: the published median (0.17 %) is a run on box-0 or box-6, which idle 1.3 to 1.5 times higher than the other boxes for every agent measured on them; this row's run on box-3 shows 0.12 % (see the method notes).
- Run 3 (box-6) was measured again on 2026-11-12/13, on the same box, with a collector that records which cgroup the kernel charges for the box's filesystem-metadata writeback; it replaces the run of 2026-11-10 (`data/2026/superseded/cycle-3/`). That run was charged 16.6 MB of disk writes in its first seven hours; this one was charged 4 KB in 25 hours, while the box's metadata writeback (150 MB over the run) was charged to other cgroups throughout. `docs/RUN-2026-slot5.md` has the cause and the rule under which the run was replaced.

**node_exporter**

- Network bytes are counted by TCP port (the listening socket is not in the service's cgroup under socket activation, and polled traffic is what this row sends).

**Monitorable agent**

- Run 1 (box-1) was measured again on 2026-11-12/13, on the same box, with a collector that records which cgroup the kernel charges for the box's filesystem-metadata writeback; it replaces the run of 2026-11-08 (`data/2026/superseded/cycle-1/`). That run was charged 15.8 MB of disk writes in its first eight hours; this one was charged nothing after its install, in 25 hours, while the box's metadata writeback (163 MB over the run) was charged to other cgroups throughout. `docs/RUN-2026-slot5.md` has the cause and the rule under which the run was replaced.
- The pilot run measured v1.5.0, which wrote 115 MB per 24 h to its on-disk export queue. v1.7.0 keeps a batch in memory for up to 15 s and writes it to disk only if it is still undelivered; the re-run was scheduled after that release, so that this row, like every other, is the agent's current release.
- Run 3 (box-7): the 0.3 MB are the agent's export queue. A batch that is not delivered within 15 s is written to disk; that happened seven times between 16:24 and 21:16 UTC on 2026-11-11, while our own ingest endpoint was slow or failing. A run in which every batch is delivered in time writes nothing (runs 1 and 2).

**Pulse agent**

- Auto-update stays at its default (on).
- The agent talks to the Pulse server over the bed's private network (10.0.0.0/24) in plain HTTP: the agent refuses an http:// server URL unless the host is loopback or a private address, and the sink has no TLS hostname. The installer it fetches from the server is checksum-pinned.
- Idle CPU: the published median (0.072 %) is a run on box-0 or box-6, which idle 1.3 to 1.5 times higher than the other boxes for every agent measured on them; this row's run on box-3 shows 0.053 % (see the method notes).

**Fivenines agent**

- The memory peak (129 MB) is not only an install-time figure. The cgroup's high-water mark is already 125 MB at the first sample, seconds after the install, while it holds 34 MB; later its memory rose again, to as much as 128 MB, in single samples 16 minutes apart: 12 samples between 21.9 and 24.8 hours after the install in run 2 and 14 between 17.9 and 21.6 hours in run 3 (samples above 1.3 times the run's median), none in run 1. Otherwise it holds about 35 MB, which is what the idle median shows.

**Glances**

- Glances ships no systemd unit; the harness adds a two-line one that runs `glances -w`.
- Runs as root (pipx install as root, the documented route); port 61208 is reachable from the sink only.
- Network bytes are counted by TCP port (61208); polled traffic is what this row sends.
- The network figure is the harness's own poller fetching /api/4/all every 3 s (Glances' refresh period); each reply is about 137 KB, which is the 3.9 GB per 24 h. Scale it to your own polling interval.
- Idle CPU: the published median (2.38 %) is a run on box-0 or box-6, which idle 1.3 to 1.5 times higher than the other boxes for every agent measured on them; this row's run on box-3 shows 1.83 % (see the method notes).

**Telegraf**

- Telegraf's stock config enables no output; its [[outputs.influxdb]] block is enabled with the sink's URL (two lines). Nothing else is changed.

**Datadog Agent**

- Every datadog-agent* unit is summed (7.84+ runs a process manager).
- The memory peak is the sum of each datadog-agent* unit's own high-water mark over the cycle; those peaks did not happen at the same moment, so the figure overstates the coincident peak.
- Run 3 (box-4) installed Agent 7.85.3; runs 1 and 2 installed 7.85.2. The vendor's documented install takes the release that is current at install time.

**Netdata (self-hosted)**

- ML anomaly detection stays at its default (on).
- kickstart's default channel is nightly; installed with --stable-channel so the version is a release readers can reproduce.
- Anonymous telemetry and the daily updater timer stay at their defaults. The updater's unit is matched with the agent's; a unit that lives for less than the 10-second sampling interval is counted only as far as the samples catch it.
- The three runs of this row were measured at the same time, on 2026-11-12/13 on box-0, box-3 and box-5, with a collector that records how much of the box's filesystem-metadata writeback the kernel charged to the unit. They replace the runs of 2026-11-07 to 11-11 (`data/2026/superseded/`), which have no such record: their disk figures (254 to 270 MB per 24 h) include an unknown share of that stream. All of this row's figures, not only the disk figure, therefore come from one slot and day. Against the replaced runs' medians, the install time is 26.4 s (was 21.2) and the memory peak 308 MB (294); the other figures moved by less than 2 %. `docs/RUN-2026-slot5.md` has the cause and the rule under which the runs were replaced.
- Disk written counts data writes. Filesystem metadata is written through the block device's inode and is not counted for any row, whichever cgroup the kernel charges it to, and that includes the metadata an agent's own file activity causes. On the six boxes running Netdata the metadata stream was 5.6 to 6.4 MB per hour, on the three other boxes of the same slot 2.8 to 2.9: about 65 to 85 MB per 24 h more, which Netdata's activity appears to cause and which is in no row's figure.
- The disk figure is probably about a tenth too low. The record of the metadata writeback counts whole pages per pass and reads above what the kernel charges: by 11 % on a box where the two could be compared exactly, and by about 13 % (between 6 and 21 %) in the hours of the six Netdata runs. An hour's metadata is never taken out beyond that hour's charge, but this unit writes more than the stream in every hour, so the excess is not caught: about 12 to 15 MB per 24 h in each run at 13 %, 6 to 22 MB over that range.
- Run 1 (box-0): idle CPU is 5.4 % of one vCPU against 3.8 % in runs 2 and 3; under load the three runs agree (2.9, 2.7 and 2.9 %). Idle CPU depends on the box: each of the four rows measured on box-0, box-3 and box-6 shows 1.3 to 1.5 times the idle CPU time on box-0 and box-6 (on box-0 against box-3: HetrixTools 17.4 against 12.6 %, Glances 2.49 against 1.83, Beszel 0.17 against 0.12, Pulse 0.07 against 0.05), and this run's ratio to runs 2 and 3 is 1.42. Why the two boxes differ is not established (`docs/RUN-2026-slot5.md`, "Deviations"). The median is not affected.
- Run 1 (box-0): 109.2 MB per 24 h of filesystem-metadata writeback were charged to this unit's cgroup and are not counted as its disk writes (247.9 MB per 24 h charged in all).
- Run 2 (box-3): 124.0 MB per 24 h of filesystem-metadata writeback were charged to this unit's cgroup and are not counted as its disk writes (260.2 MB per 24 h charged in all).
- Run 3 (box-5): 102.2 MB per 24 h of filesystem-metadata writeback were charged to this unit's cgroup and are not counted as its disk writes (242.0 MB per 24 h charged in all).

**Netdata (claimed to Netdata Cloud)**

- Same binary as the self-hosted row, claimed to Netdata Cloud. ML anomaly detection stays at its default (on).
- kickstart's default channel is nightly; installed with --stable-channel so the version is a release readers can reproduce.
- Anonymous telemetry and the daily updater timer stay at their defaults. The updater's unit is matched with the agent's; a unit that lives for less than the 10-second sampling interval is counted only as far as the samples catch it.
- The three runs of this row were measured at the same time, on 2026-11-12/13 on box-2, box-4 and box-7, with a collector that records how much of the box's filesystem-metadata writeback the kernel charged to the unit. They replace the runs of 2026-11-07 to 11-11 (`data/2026/superseded/`), which have no such record: their disk figures (231 to 276 MB per 24 h) include an unknown share of that stream. All of this row's figures, not only the disk figure, therefore come from one slot and day. Against the replaced runs' medians, the install time is 30.2 s (was 25.4), idle CPU 3.9 % (3.7), CPU under load 3.2 % (2.8) and network 0.55 MB out and 0.25 in per 24 h (0.34 and 0.19; see the bursts below); the other figures moved by less than 2 %. `docs/RUN-2026-slot5.md` has the cause and the rule under which the runs were replaced.
- Disk written counts data writes. Filesystem metadata is written through the block device's inode and is not counted for any row, whichever cgroup the kernel charges it to, and that includes the metadata an agent's own file activity causes. On the six boxes running Netdata the metadata stream was 5.6 to 6.4 MB per hour, on the three other boxes of the same slot 2.8 to 2.9: about 65 to 85 MB per 24 h more, which Netdata's activity appears to cause and which is in no row's figure.
- The disk figure is probably a few percent too low. The record of the metadata writeback counts whole pages per pass and reads above what the kernel charges: by 11 % on a box where the two could be compared exactly, and by about 13 % (between 6 and 21 %) in the hours of the six Netdata runs. An hour's metadata is never taken out beyond that hour's charge, but this unit writes more than the stream in every hour, so the excess is not caught: about 5 to 12 MB per 24 h in each run at 13 %, 2 to 18 MB over that range.
- All three nodes sent more than usual at the same two moments of the idle window, 20:06:50Z and 20:53:50 to 20:54:50Z on 2026-11-12: 0.2 MB from the nodes of runs 1 and 3 and 1.0 MB from the node of run 2, eight samples in all. The cause is not established. The Netdata Cloud Space the nodes were claimed to belongs to the benchmark's operator, and the pattern is what a visit to it in Netdata Cloud's interface would look like, so a visit by the operator cannot be ruled out. Without those samples every run sent 0.34 MB per 24 h, as the replaced runs did, and the row's figure would be 0.3; with them the runs are 0.55, 1.38 and 0.51 and the published median is 0.6.
- Run 1 (box-2): 100.3 MB per 24 h of filesystem-metadata writeback were charged to this unit's cgroup and are not counted as its disk writes (247.7 MB per 24 h charged in all).
- Run 2 (box-4): 38.8 MB per 24 h of filesystem-metadata writeback were charged to this unit's cgroup and are not counted as its disk writes (188.0 MB per 24 h charged in all).
- Run 3 (box-7): 75.2 MB per 24 h of filesystem-metadata writeback were charged to this unit's cgroup and are not counted as its disk writes (223.7 MB per 24 h charged in all).

**No agent (harness only)**

- Control row: no agent; the collector measures its own cgroup.
