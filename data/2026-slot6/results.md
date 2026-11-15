# Linux monitoring agent footprint benchmark (2026): 1 agents, one VPS type, 24 hours

One slot, measured to replace the three Netdata Cloud runs of the 2026 run: not a comparison table. The three runs were simultaneous. The published table is data/2026/results.md.

| Agent | Version | Memory (PSS), idle median | Memory peak (cgroup), whole cycle | CPU, idle (% of one vCPU) | CPU, under load (% of one vCPU) | Disk written per 24 h | Network per 24 h (out for push agents, in+out for polled) | Install wall time | On-disk footprint after the cycle |
|---|---|---|---|---|---|---|---|---|---|
| Netdata (claimed to Netdata Cloud) † | v2.12.3 | 358.2 | 293.1 | 3.9 | 2.9 | 140.8 | 0.3 | 25.7 | 795.2 |

Cycles: 3. Hetzner Cloud Helsinki (HEL1) CX23: 2 vCPU AMD EPYC (shared), 4 GB RAM, 40 GB NVMe, Ubuntu 26.04 LTS, kernel 7.0.0-15/-30-generic (differs by box, see kernels), harness 12c959b.

Each figure is the median of the per-run values; `results.json` has every run's value.

## Method notes

- Ubuntu's apt-daily and apt-daily-upgrade timers were masked on every box at provisioning (the pilot's unattended-upgrades restarted dynamically linked agents mid-cycle).
- Network bytes count only the box's physical interfaces; Docker bridge traffic is excluded.
- Processes are counted in the agent's cgroup and its child cgroups.
- Disk written excludes the filesystem-metadata writeback the kernel charged to the unit's cgroup: ext4 writes metadata through the block device's inode and the kernel charges one inode's writeback to a single cgroup, whichever owns it. The charge as the kernel reported it is published next to it.
- This is the slot of 2026-11-13/14: the three Netdata Cloud runs measured again on the boxes of the retest slot, with nobody opening the Netdata Cloud Space the nodes are claimed to (slots/slot-0.plan, docs/RUN-2026-slot6.md). Each box's Netdata access log was read after the collect: no request over the Netdata Cloud link during the runs. The three runs are also filed in data/2026/cycle-N/, where they replace the runs of data/2026-slot5/ they stand for. The files here are as collected; the footnotes added by hand are on their copies in data/2026/. There is no control run in this slot: the collector and the bed are those of the retest slot, whose control run is data/2026-slot5/cycle-1/control.*.

## Row notes (†)

**Netdata (claimed to Netdata Cloud)**

- Same binary as the self-hosted row, claimed to Netdata Cloud. ML anomaly detection stays at its default (on).
- kickstart's default channel is nightly; installed with --stable-channel so the version is a release readers can reproduce.
- Anonymous telemetry and the daily updater timer stay at their defaults. The updater's unit is matched with the agent's; a unit that lives for less than the 10-second sampling interval is counted only as far as the samples catch it.
- Run 1 (box-2): 89.7 MB per 24 h of filesystem-metadata writeback were charged to this unit's cgroup and are not counted as its disk writes (233.3 MB per 24 h charged in all).
- Run 2 (box-4): 90.3 MB per 24 h of filesystem-metadata writeback were charged to this unit's cgroup and are not counted as its disk writes (231.0 MB per 24 h charged in all).
- Run 3 (box-7): 139.3 MB per 24 h of filesystem-metadata writeback were charged to this unit's cgroup and are not counted as its disk writes (275.7 MB per 24 h charged in all).
