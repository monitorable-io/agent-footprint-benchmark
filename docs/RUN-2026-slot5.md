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
- [x] `bench.env` points at this run; plan file and `run.json` in place; `./bench cycle plan 0`: 2026-11-12 17:50Z. `bench.env`: `YEAR=2026-slot5`, `BENCH_SLOT_COUNT=1`, `RUNLOG_BRANCH=data/run-2026-slot5`, `RUNLOG_DIR` = a worktree of that branch (the re-run's run-log worktree and its data PR #9 are not touched). `./bench cycle plan 0` printed the nine lines of the table above; `./bench cycle plan 1` was refused ("slot 1 is outside this run"). To be reverted once this slot's data is handled.

## Slot 5 (s = 0 of this run)

- [x] founder's words for `./bench cycle start 0` (date, words): 2026-11-12 ~17:48Z, in chat: "The replacement rule: agree with your proposal. Netdata Cloud nodes deleted. You may start the slot"; asked who merges PR #10 first, he answered that I do (squash).
- [x] `./bench cycle start 0` at: 2026-11-12T17:51:00Z → 2026-11-12T18:14:00Z (by hand, main e73e37f). Failures log: empty. 9 boxes in the manifest, AMD EPYC-Rome Processor / 2 vCPU; every provision printed "apt-timers: … masked, unattended-upgrades stopped". Hubs reset first: Beszel forgot box-6, Pulse forgot box-3 (no Pulse row in this slot, so no token minted). Installs: netdata 26.4 s, 23.1 s, 27.5 s (v2.12.3), netdata-cloud 30.3 s, 30.2 s, 29.7 s (v2.12.3), monitorable 10.8 s (v1.7.0), beszel 3.4 s (0.21.1): the same versions as in the re-run. Collect after 2026-11-13T19:13:50Z. `cycle status 0` right after (18:14Z): 9/9 rows active, the metadata tracer counting on every box (`meta=` 0.5 to 4.5 MB), every `next=` on 2026-11-13; sink: n/a this slot (no node-exporter or glances row); hubs: beszel box-6 up; the three Netdata Cloud boxes claimed and online (`netdatacli aclk-state`). No `blockdev_trace_error` or `blockdev_trace_unparsed` event on any box.
- [x] `./bench cycle status 0` at 2026-11-12T18:55:01Z (+1 h, unattended runner): 9/9 rows active; metadata tracer: 9/9 boxes counting; sink: n/a this slot (no node-exporter/glances row); hubs: beszel box-6 up
- 2026-11-12 18:15Z, first look at who is charged (the boxes' `blockdev.csv`, minutes after the installs, so the installs' own metadata is in it): the stream has already been charged to several owners. `netdata.service` itself holds part of it on four of the six Netdata boxes (0.25 to 1.0 MB so far), `containerd.service` most of the rest, the collector's own unit 1.2 MB on box-2, the root cgroup and `sysroot.mount` on others; on box-1 and box-6 the Monitorable and Beszel units have been charged none. So the Netdata rows do hold the stream at times, which the re-run's data could not show.
- [x] `./bench collect 0` at: 2026-11-13T19:20:01Z–2026-11-13T19:22:10Z (unattended runner, main e73e37f): 9/9 rows collected, `slot-0.collect-failures.log` empty, every samples file verified, `summarize.py` ran clean (auto/summarize-0.out).
- [x] RUN COMPLETE 2026-11-13T19:22:18Z (unattended runner): every slot collected; `summarize.py` output in data/2026-slot5/auto/summarize-final.out. The boxes stay rented until the founder says otherwise.

## Data

- [x] `python3 summarize.py data/2026-slot5 --harness-commit e73e37f`: 2026-11-13. On a copy of the directory as the runner left it, the command reproduced the runner's `results.json` and `results.md` byte for byte. They were generated again after two hand edits: `run.json` gained the kernel each box booted (box-2 7.0.0-15, every other box 7.0.0-30, box-7 included, which had booted -42 and -43 in the re-run) and a note on what this directory is; the control's `meta.json` gained the footnote on its disk figure (below). The eight agent runs' files in `data/2026-slot5/` are as collected.
- [x] 2026-11-13, checks before the data PR, all from the raw files, with a script that does not import `summarize.py`: 9/9 role-runs `status: ok`; both failure logs empty; the schedule in each `meta.json`, in `schedule-<agent>.json` and in the slot manifest agree; one sampler start per run and no event other than `start`, `blockdev_trace`, `cgroup_appeared`, `stop`; no gap over 10 s between samples; 0 duplicate (ts, cgroup) rows; 0 cgroup-inode changes; a process at every idle sample; both tracer columns filled in every row and never moving backwards; each run's `blockdev.csv` sums to the box column exactly, and its lines for the unit's cgroup to the unit column exactly; every per-run figure of `results.json` for PSS, memory.current, memory peak, CPU (idle and loaded), disk charged, metadata excluded, disk written, network in and out, install time and footprint recomputed: 0 differences; peak load1 in the load windows 4.65 to 8.28. Every `bench.env` value of six or more characters searched in all files: two hits, the image name in `run.json` and the run's directory name, neither a secret. Harness tests: 126 green (129 after the second review's two additions to `summarize.py`).
- [x] What the slot measured (MB per 24 h in the idle window; "metadata" is the part of the box's metadata writeback that the kernel charged to the unit and the summary takes out):

  | run | box | charged | metadata | disk written | hours of 23 in which the unit was charged metadata |
  |---|---|---|---|---|---|
  | Monitorable run 1 | box-1 | 0.0 | 0.0 | 0.0 | 0 |
  | Beszel run 3 | box-6 | 0.0 | 0.0 | 0.0 | 0 |
  | Netdata run 1 | box-0 | 247.9 | 109.2 | 138.7 | 21 |
  | Netdata run 2 | box-3 | 260.2 | 124.0 | 136.2 | 21 |
  | Netdata run 3 | box-5 | 242.0 | 102.2 | 139.8 | 18 |
  | Netdata Cloud run 1 | box-2 | 247.7 | 100.3 | 147.4 | 16 |
  | Netdata Cloud run 2 | box-4 | 188.0 | 38.8 | 149.2 | 8 |
  | Netdata Cloud run 3 | box-7 | 223.7 | 75.2 | 148.5 | 14 |
  | control | box-8 | 18.6 | 0.0 | 18.6 | 0 |

  - Who was charged, idle window, MB per hour: on the three boxes without Netdata the stream was 2.8 to 2.9 MB per hour and all of it went to `sysroot.mount`, which has no process (box-1, box-6, box-8). On the six Netdata boxes it was 5.6 to 6.4 MB per hour, shared between `netdata.service` (1.6 to 5.2) and the root cgroup (0.6 to 4.4), with `init.scope` 0.8 on box-2; ownership moved between them in blocks of hours.
  - Monitorable and Beszel: neither unit was charged any of the stream, so this slot did not show the episode again; it shows the agents without it. Monitorable was charged nothing after its install (`io.stat` stood at 53,248 B from the first sample to the last, page cache 28,672 B throughout, footprint 57,251,083 B as in run 2; run 3's is 98,304 B larger, its queue file); Beszel was charged 4 KB in 25 hours. Every other figure of the two runs is within 3 % of the replaced run's, except install time (Monitorable 10.8 s against 6.4, Beszel 3.4 against 3.6) and CPU (Monitorable under load 0.068 % against 0.064; Beszel idle 0.189 against 0.181 and under load 0.166 against 0.159).
  - Netdata: the charge to the unit varies with how long it held the stream (188 to 260 MB per 24 h; the replaced runs 231 to 276); what is left after the metadata is taken out does not (136 to 140 self-hosted, 147 to 149 claimed to Netdata Cloud). In the hours in which a Netdata unit was charged no metadata it was charged 5.3 to 7.1 MB per hour, in the hours in which it held all of it 11.0 to 12.1.
- [x] Runs filed in `data/2026/` by the rule above, 2026-11-13, on the branch of data PR #9 (`data/run-2026-rerun`, into which `main` and this branch were merged): the eight replaced runs' files moved to `data/2026/superseded/cycle-N/` (samples, events, `meta.json`, `schedule-<agent>.json`), the slot's eight agent runs copied to `data/2026/cycle-N/` with their `blockdev.csv`, each cycle's `schedule.json` regenerated the way `collect` does. `data/2026/slots/README.md` says what the four manifests there list and that the replacing runs' `"slot": 0` is this run's. A difference from the plan as written above: the runs were copied, not moved, so `data/2026-slot5/` stays complete and its `results.json` can be reproduced from it. The copied `meta.json`s keep `"slot": 0`, this run's slot number; `run` and the cycle directory say which run they stand for. `python3 summarize.py data/2026 --harness-commit d879a73..e73e37f` → 11 rows × 3 cycles + control. Footnotes added by hand to the copies: on the Monitorable and Beszel runs what they replace and what they showed; on both Netdata rows that the three runs are simultaneous and what they replace, the tracer's over-count (below), run 1's CPU on box-0 (below) and the Netdata Cloud bursts (below); the replaced runs' footnotes now say that they are superseded and why.

## Deviations and incidents

- **The record of the metadata writeback reads above the kernel's charge on the Netdata boxes too, and there the hourly limit does not catch it. The Netdata rows' disk figures are therefore a little low; published by the rule, footnoted.** Before the slot the tracer read 11 % above the kernel's charge on box-1, where the owner has no process and the comparison is exact. The six Netdata runs give the same order of size by two routes. (1) Hourly charge against hourly record over the 138 idle hours, with each run's mean and each hour-of-run's mean removed: the charge rises by 0.88 MB for each MB recorded (standard error 0.03), so the record reads 13 % high (6 to 21 %). (2) In the 10-second samples in which the unit was charged no more than the record shows, so that nothing of its own was written, the charge is 87 to 90 % of the record (425 to 1,330 samples per run); in 28 to 34 % of the samples with metadata the two are equal to the byte. The summary never takes out more metadata than was charged in the same hour, which protects a unit that writes little; a Netdata unit is charged more than the stream in every hour (no hour of the 138 was limited), so the excess is taken out of its own writes: at 13 % about 12 to 15 MB per 24 h of each self-hosted run and 5 to 12 MB of each Netdata Cloud run, about a tenth of the self-hosted figure and a few percent of the Cloud one, in Netdata's favour; over the 6 to 21 % range, 6 to 22 and 2 to 18 MB. A cruder comparison points higher: in five of the six runs the unit was charged 6.3 to 7.1 MB per hour in the hours with no metadata and 5.4 to 5.7 MB per hour, net, in the hours in which it held all of it, which would be an over-count of 19 to 27 %; that comparison does not remove the hour of the run (the early idle hours write more in every run), which the regression does. The rule was fixed before the slot and stands. A limit per sample instead of per hour would catch most of the excess (it is 6.5 to 8.6 % of the record at 10 s), but would also misplace metadata charged just before a sample and recorded just after it; not done.
- **Netdata Cloud, all three runs: two simultaneous bursts of traffic in the idle window; cause not established; footnoted.** At 20:06:50Z and from 20:53:50Z to 20:54:50Z on 2026-11-12 all three nodes sent more than their usual 14 KB per hour, in the same 10-second samples, eight in all: 64 + 146 KB (box-2), 25 + 974 KB (box-4), 25 + 146 KB (box-7), and received 61, 290 and 59 KB. Nothing was run on the boxes then (the +1 h check was at 18:55Z, the next access was the collect). It is what a visit to the Space in Netdata Cloud's interface would look like, the second one opening box-4's node; the Space is the founder's (his own node is the only other one in it); he does not think he opened it and is not sure, so a visit by the operator cannot be ruled out, and the footnote says so. The runs' network out is 0.55, 1.38 and 0.51 MB per 24 h; without those samples each is 0.34, the replaced runs' figure (0.337 to 0.340). Because the three runs are simultaneous, one event is in all of them and the median cannot set it aside: the row's headline goes from 0.3 to 0.6 MB per 24 h. The footnote gives both.
- **Netdata run 1 (box-0): idle CPU 5.4 % against 3.8 % in runs 2 and 3; a property of the box; footnoted; the median is not affected.** The figure is flat over the 23 hours (5.2 to 5.6 % per hour) and under load the three runs agree (2.9, 2.7, 2.9 %). Box-0 and box-6 are on a different host type from the other seven boxes: their virtual CPUs report 2,495.312 MHz (bogomips 4,990.62), the others 2,445.40 MHz (4,890.80), same model name and microcode, read on 2026-11-13 (`docs/evidence/2026-slot5/host-probe-2026-11-13.txt`); that points to another host type, which is a reading, not a finding. A single-thread loop takes the same time on all nine (0.30 to 0.35 s), so the boxes are not slower at computing; but in the re-run each of the four agents measured on box-0 and on box-3 used 1.34 to 1.38 times the idle CPU time on box-0 and 1.31 to 1.46 times on box-6 (1.53 for Beszel with its retest run), and under load the ratio falls to 1.0 to 1.2 for three of them (Beszel keeps 1.5). This bears on the re-run more than on this slot: Beszel, HetrixTools, Pulse and Glances have two of three runs on those boxes, so their idle CPU medians are box-0 or box-6 figures. Each of the four rows is footnoted with its box-3 figure; see the note on CPU in `docs/RUN-2026.md`.
- **Control: 18.6 MB per 24 h of disk writes against 10.5 in the re-run's control runs; the collector's new side file; footnoted on the control.** The collector appends a line to `blockdev.csv` in each sample in which the stream was written back, about 95 times an hour, and each append is written back as a 4 KB page: at most 0.39 MB per hour on top of the 0.44 of the samples file, and the control wrote 0.75 to 0.79 in every hour. The writes are in the collector's own cgroup; no agent's row contains them.
- **Disk written counts data writes; the metadata an agent's own activity causes is in no row.** The stream through the block device's inode is the whole filesystem's metadata, the measured agent's included. In this slot it was 5.6 to 6.4 MB per hour on the six boxes running Netdata and 2.8 to 2.9 on the three others, so about 2.8 to 3.5 MB per hour, 65 to 85 MB per 24 h, appear to be caused by Netdata's file activity. The summary takes metadata out of a unit's charge wherever the record shows it and never adds it to anyone, so that amount is in no row's figure. This is the same for every agent (an agent that writes files causes metadata, and in the runs without the record it is charged to whichever cgroup owns the inode), but only for Netdata is it large against the published figure (138.7 and 148.5 MB). Footnoted on both Netdata rows; in `run.json` `notes` and the README.
- **All figures of the two Netdata rows now come from one slot and day, and some moved against Netdata.** The rule replaces runs, not single figures. Install time: 23.1 to 30.3 s in the six installs of this slot against 20.6 to 26.5 s in the replaced runs (medians 26.4 against 21.2 s self-hosted, 30.2 against 25.4 Cloud). Memory peak, self-hosted: 308 against 294 MB. Netdata Cloud CPU: idle 3.9 against 3.7 %, under load 3.2 against 2.8. Netdata Cloud network: the bursts above. The footnotes of both rows give the replaced runs' medians.
- box-2 booted kernel 7.0.0-15 again, as on every rebuild; the tracer's event format is the same there and the unit was charged metadata in 16 of 23 hours. box-7 booted 7.0.0-30 this time (7.0.0-42 and -43 in the re-run).
