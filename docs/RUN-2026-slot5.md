# Run log 2026, slot 5 (the instrumented retest slot)

One line per step, with its date. Nothing here is a secret; keys stay in `bench.env`.

## Why this slot exists

The re-run (2026-11-07 → 2026-11-12, `docs/RUN-2026.md`, `data/2026/`) finished with 36 of 36 role-runs
collected. Checking its data showed that two runs, Monitorable run 1 (box-1) and Beszel run 3 (box-6),
had each been charged about 16 MB of disk writes in their first 7 to 8 hours and nothing after, with no
change in the agent's page cache, on-disk footprint, CPU or network.

The cause was found on the still-running boxes on 2026-11-12 with the kernel tracepoint
`writeback:writeback_single_inode`:

- ext4 writes its metadata through the block device's own inode (inode 8388609 for `sda1`). On an idle
  box of this bed that is 2 to 2.7 MB per hour of 4 KB writes.
- cgroup v2 charges all writeback of one inode to one cgroup, whichever owns it. The owner differed by
  box: `sysroot.mount`, which has no process, on box-1; `rsyslog.service` on box-0 and box-7; the root
  cgroup on box-4.
- On box-7 rsyslog's cgroup had been charged 146 MB since boot while the rsyslog process itself had
  written 54 MB, as on every other box. `ssh.service` (box-0) and `networkd-dispatcher.service` (box-6),
  which write nothing, each carried 3.9 MB.

When the owner is the measured agent's cgroup, `io.stat` shows the box's metadata as the agent's writes.
That it happened in those two runs is inferred from the matching rate and write sizes: both boxes had
been rebuilt by the next slot. Rows that write less than the stream's rate cannot have held it, and
Datadog's two units write at identical rates in all three runs; the two Netdata rows could not be
cleared, because their own writes vary by 5 to 14 MB per hour.

Harness PR #10 makes the collector record how much of that stream the kernel charged to each row
(`collector/blockdev_trace.py`) and the summary publish disk writes without it, with the whole charge
next to it. This slot measures the affected and the unclearable rows with that collector.

## Rule, fixed before the slot (founder, 2026-11-12)

- Every run measured in this slot replaces the run it stands for, whatever it shows: Monitorable run 1,
  Beszel run 3, and all three runs of Netdata and of Netdata Cloud.
- The replaced runs stay in the repository under `data/2026/superseded/`, with their footnotes and this
  log's account of why.
- The slot's control run is published with the slot (`data/2026-slot5/`); it is not added to the
  control row of the re-run.
- Disk written is the kernel's charge to the unit's cgroup less the filesystem-metadata writeback
  charged to it, taken out hour by hour and never more than was charged in that hour. The charge and
  the excluded part are published next to it. Runs of the re-run that are not replaced have no such
  record; their charge is published as it is.

## The plan (`data/2026-slot5/slots/slot-0.plan`)

| box | role | stands for |
|---|---|---|
| box-0 | netdata | run 1 |
| box-1 | monitorable | run 1 (same box as the replaced run) |
| box-2 | netdata-cloud | run 1 |
| box-3 | netdata | run 2 |
| box-4 | netdata-cloud | run 2 |
| box-5 | netdata | run 3 |
| box-6 | beszel | run 3 (same box as the replaced run) |
| box-7 | netdata-cloud | run 3 |
| box-8 | control | the slot's own control |

The three runs of each Netdata row are measured at the same time on three boxes, not in three slots as
in the re-run.

## Setup

- [x] Harness PR #10 reviewed and merged; cron worktree fast-forwarded between two ticks: 2026-11-12. Opus review "merge after fixes" (0 Critical, 4 Important, 10 Minor; answered on the branch, reply on the PR): a plan file's last line without a newline escaped the check; a plan-driven run could fall back to a rotation slot; the start guard only read the current data root; a tracer error could stop the sampler and a tracer counting nothing was invisible. Merged on the founder's words 17:50:04Z (squash e73e37f); cron worktree fast-forwarded 17:50:17Z, between the 17:50 and 17:55 ticks. 126 tests green.
- [x] Tracer checked on the real kernel before the slot: 2026-11-12, kernels 7.0.0-30 and -43, no box rebuilt (one-off processes in a temp directory, tracing instance removed afterwards). 40 minutes on box-0, box-1 and box-7: one owner named throughout on each (`rsyslog.service`, `sysroot.mount`, `rsyslog.service`; 60 to 62 flushes each). On box-1, where the owner has no process and the comparison is exact, the tracer read 1,552,384 bytes against 1,392,640 charged (11 % high: it counts whole pages per pass), which is why the summary takes the metadata charge out hour by hour and never more than was charged in that hour. Final collector on box-7: the event-format check passes, counts continue across a sampler restart (73,728 → 155,648), no unreadable line.
- [x] Netdata Cloud Space has room for three nodes: 2026-11-12, the founder deleted the three offline nodes left by the re-run's Netdata Cloud runs (box-2, box-5, box-8); one node of his own remains, so three new ones fit the Community limit of five.
- [ ] `bench.env` points at this run; plan file and `run.json` in place; `./bench cycle plan 0`:

## Slot 5 (s = 0 of this run)

- [ ] founder's words for `./bench cycle start 0` (date, words):
- [ ] `./bench cycle start 0` at:
- [ ] `./bench collect 0` at:

## Data

- [ ] `python3 summarize.py data/2026-slot5 --harness-commit <main sha>`:
- [ ] Runs moved into `data/2026/` by the rule above; data PR:

## Deviations and incidents

(none yet)
