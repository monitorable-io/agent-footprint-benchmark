# Linux monitoring agent footprint benchmark (2026): 4 agents, one VPS type, 24 hours

| Agent | Version | Memory (PSS), idle median | Memory peak (cgroup), whole cycle | CPU, idle (% of one vCPU) | CPU, under load (% of one vCPU) | Disk written per 24 h | Network per 24 h (out for push agents, in+out for polled) | Install wall time | On-disk footprint after the cycle |
|---|---|---|---|---|---|---|---|---|---|
| Beszel agent | beszel-agent 0.21.1 | 17.9 | 118.2 | 0.2 | 0.2 | 0.0 | 3.8 | 3.4 | 10.8 |
| Monitorable agent (us) | monitorable-agent version v1.7.0 | 46.0 | 18.2 | 0.1 | 0.1 | 0.0 | 8.1 | 10.8 | 57.3 |
| Netdata (self-hosted) † | v2.12.3 | 357.1 | 308.0 | 3.8 | 2.9 | 138.7 | 0.0 | 26.4 | 794.5 |
| Netdata (claimed to Netdata Cloud) † | v2.12.3 | 360.9 | 296.0 | 3.9 | 3.2 | 148.5 | 0.6 | 30.2 | 798.1 |
| No agent (harness only) † | none | 13.2 | 17.1 | 0.1 | 0.1 | 18.6 | 0.0 | n/a | 0.1 |

Cycles: 3. Hetzner Cloud Helsinki (HEL1) CX23: 2 vCPU AMD EPYC (shared), 4 GB RAM, 40 GB NVMe, Ubuntu 26.04 LTS, kernel 7.0.0-15/-30-generic (differs by box, see kernels), harness e73e37f.

Each figure is the median of the per-run values; `results.json` has every run's value.

## Method notes

- Ubuntu's apt-daily and apt-daily-upgrade timers were masked on every box at provisioning (the pilot's unattended-upgrades restarted dynamically linked agents mid-cycle).
- Network bytes count only the box's physical interfaces; Docker bridge traffic is excluded.
- Processes are counted in the agent's cgroup and its child cgroups.
- Disk written excludes the filesystem-metadata writeback the kernel charged to the unit's cgroup: ext4 writes metadata through the block device's inode and the kernel charges one inode's writeback to a single cgroup, whichever owns it. The charge as the kernel reported it is published next to it.
- This is the instrumented retest slot of 2026-11-12/13: nine role-runs measured at the same time (slots/slot-0.plan, docs/RUN-2026-slot5.md). Its eight agent runs are also filed in data/2026/cycle-N/, where they replace the runs they stand for; the control run is published here only. The agent runs' files here are as collected; the footnotes added by hand are on their copies in data/2026/.

## Row notes (†)

**Netdata (self-hosted)**

- ML anomaly detection stays at its default (on).
- kickstart's default channel is nightly; installed with --stable-channel so the version is a release readers can reproduce.
- Anonymous telemetry and the daily updater timer stay at their defaults. The updater's unit is matched with the agent's; a unit that lives for less than the 10-second sampling interval is counted only as far as the samples catch it.
- Run 1 (box-0): 109.2 MB per 24 h of filesystem-metadata writeback were charged to this unit's cgroup and are not counted as its disk writes (247.9 MB per 24 h charged in all).
- Run 2 (box-3): 124.0 MB per 24 h of filesystem-metadata writeback were charged to this unit's cgroup and are not counted as its disk writes (260.2 MB per 24 h charged in all).
- Run 3 (box-5): 102.2 MB per 24 h of filesystem-metadata writeback were charged to this unit's cgroup and are not counted as its disk writes (242.0 MB per 24 h charged in all).

**Netdata (claimed to Netdata Cloud)**

- Same binary as the self-hosted row, claimed to Netdata Cloud. ML anomaly detection stays at its default (on).
- kickstart's default channel is nightly; installed with --stable-channel so the version is a release readers can reproduce.
- Anonymous telemetry and the daily updater timer stay at their defaults. The updater's unit is matched with the agent's; a unit that lives for less than the 10-second sampling interval is counted only as far as the samples catch it.
- Run 1 (box-2): 100.3 MB per 24 h of filesystem-metadata writeback were charged to this unit's cgroup and are not counted as its disk writes (247.7 MB per 24 h charged in all).
- Run 2 (box-4): 38.8 MB per 24 h of filesystem-metadata writeback were charged to this unit's cgroup and are not counted as its disk writes (188.0 MB per 24 h charged in all).
- Run 3 (box-7): 75.2 MB per 24 h of filesystem-metadata writeback were charged to this unit's cgroup and are not counted as its disk writes (223.7 MB per 24 h charged in all).

**No agent (harness only)**

- Control row: no agent; the collector measures its own cgroup.
- This control ran with the collector that also records the metadata writeback. The record's side file (`blockdev.csv`, about 95 appended lines per hour) is written by the collector itself, which is why this control wrote 18.6 MB per 24 h against 10.5 MB in the three control runs of the re-run. Those writes are in the collector's cgroup and in no agent's row.
