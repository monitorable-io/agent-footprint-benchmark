# Run log 2026, slot 6 (the Netdata Cloud runs, measured again)

One line per step, with its date. Nothing here is a secret; keys stay in `bench.env`.

## Why this slot exists

The three Netdata Cloud runs of the retest slot (`docs/RUN-2026-slot5.md`, `data/2026-slot5/`) carry two
bursts of traffic, at 20:06:50Z and from 20:53:50Z to 20:54:50Z on 2026-11-12, on all three nodes in the
same samples. They raise the row's network figure from 0.3 to 0.6 MB per 24 h. When the data was
published the cause was not established.

It is now. On 2026-11-13, before any rebuild, Netdata's own access log was read on the three boxes
(`docs/evidence/2026-slot6/netdata-cloud-access-2026-11-12.txt`). In the whole run each agent received
requests over its Netdata Cloud link in exactly those minutes and in no other: 53, 260 and 52 requests,
almost all for chart data, every one from the same signed-in user of the Space, with the role admin.
The Space is the benchmark operator's. The bursts are the operator looking at the Space's dashboard.

That is a harness incident in a competitor's row, caused by us. The founder's ruling of 2026-11-02 is
that a run which hit a problem is measured again, and he chose that here (2026-11-13) over keeping the
figure with a corrected note.

## Rule, fixed before the slot (founder, 2026-11-13)

- The rule of the retest slot stands: every run measured in this slot replaces the run it stands for,
  whatever it shows. Those are the three runs of the Netdata Cloud row, all figures of them, not only
  the network figure.
- The three runs they replace stay published as collected in `data/2026-slot5/`.
- Nobody opens the Space in Netdata Cloud between the start of the slot and its collect. After the
  collect, and before any rebuild or teardown, each box's access log is read again; the count of
  requests over the Cloud link during the run is recorded here whatever it is.
- No control run in this slot: the collector and the bed are those of the retest slot, whose control
  stands.

## The plan (`data/2026-slot6/slots/slot-0.plan`)

The same boxes as in the retest slot, so that the visit is the only thing that differs.

| box | role | stands for |
|---|---|---|
| box-2 | netdata-cloud | run 1 |
| box-4 | netdata-cloud | run 2 |
| box-7 | netdata-cloud | run 3 |

The other six measured boxes and the sink are not touched.

## Setup

- [x] The three nodes of the retest slot taken offline: 2026-11-13 22:30Z, `systemctl stop netdata` on box-2, box-4 and box-7 (the boxes are rebuilt by the start).
- [x] Netdata Cloud Space has room for three nodes (the founder deletes the three offline nodes; one node of his own remains): 2026-11-13 between 22:31Z and 22:36Z, before `cycle start` (22:36:19Z), the founder in chat: "Nodes are deleted. Netdata Cloud is closed in my browser". (This line first said "~22:45Z", which was wrong: the commit that recorded his words, `c7587bd`, is dated 22:36:03Z, and the commit before it 22:30:53Z. The Space was closed before the first of the three nodes was claimed, at 22:39Z.)
- [x] `bench.env` points at this run; plan file and `run.json` in place; `./bench cycle plan 0`: 2026-11-13 22:31Z, between two runner ticks. `bench.env`: `YEAR=2026-slot6`, `BENCH_SLOT_COUNT=1`, `RUNLOG_BRANCH=data/run-2026-slot6`, `RUNLOG_DIR` = a worktree of that branch (before: the same four lines for slot 5). `run.json`: the bed and the four method notes of the retest slot. `./bench cycle plan 0` printed the three lines of the table above and no other box; `./bench cycle plan 1` was refused ("slot 1 is outside this run"); `./bench auto status`: "next: none", so the runner starts nothing by itself.

## Slot 6 (s = 0 of this run)

- [x] founder's words for `./bench cycle start 0` (date, words): 2026-11-13 ~22:25Z, asked "Re-measuring needs three of the boxes. What should I do?" with the two ways forward set out, he chose "Re-measure, then teardown": measure the three Netdata Cloud runs again in one 26-hour slot with nobody opening the Space, replace them by the same rule, then destroy all ten boxes. The question said the three boxes would be rebuilt on that answer.
- [x] `./bench cycle start 0` at: 2026-11-13T22:36:19Z → 2026-11-13T22:44:34Z (by hand, main 12c959b). Failures log: empty. 3 boxes in the manifest (box-2, box-4, box-7), AMD EPYC-Rome Processor / 2 vCPU; no other box was rebuilt. Every provision printed "apt-timers: … masked, unattended-upgrades stopped". Installs: 31.0 s, 25.7 s, 25.2 s, all v2.12.3, the version of the replaced runs. Kernels as in the retest slot: box-2 7.0.0-15, box-4 and box-7 7.0.0-30. Collect after 2026-11-14T23:44:23Z. `cycle status 0` right after (22:44Z): 3/3 rows active, the metadata tracer counting on box-2 and box-4 (box-7 had five samples). Read on the boxes, not in Netdata Cloud (`netdatacli aclk-state`): all three claimed and online. Requests over the Cloud link in each access log at 22:45Z: 0.
- [x] `./bench cycle status 0` at 2026-11-13T23:40:01Z (+1 h, unattended runner): 3/3 rows active; metadata tracer: 3/3 boxes counting; sink: n/a this slot (no node-exporter/glances row); hubs: no beszel/pulse row in this slot
- [x] `./bench collect 0` at: 2026-11-14T23:50:01Z–2026-11-14T23:50:45Z (unattended runner, main 12c959b): 3/3 rows collected, `slot-0.collect-failures.log` empty, every samples file verified, `summarize.py` ran clean (auto/summarize-0.out).
- [x] RUN COMPLETE 2026-11-14T23:50:51Z (unattended runner): every slot collected; `summarize.py` output in data/2026-slot6/auto/summarize-final.out. The boxes stay rented until the founder says otherwise.

## Data

- [x] Access logs read after the collect (requests over the Cloud link during the run, per box): 2026-11-15 07:06Z, before any rebuild or deletion and before anything else was done with the data: **box-2 0, box-4 0, box-7 0** (`docs/evidence/2026-slot6/netdata-cloud-access-2026-11-14.txt`). Each box's `access.log` and `access.log.1` together run from the install (first lines 22:39:13Z, 22:41:49Z, 22:44:19Z on 2026-11-13) to hours after the collect; one rotation, at 00:00Z on 2026-11-15, no older file. No line has a `src_transport` field, so the logs hold no request of any kind; they hold the agent's own alert transitions sent to the Cloud (43, 52 and 44 lines) and one "ACLK CONNECTED" each. In the retest slot the same search found 53, 260 and 52 requests. All three nodes were still claimed and online (`netdatacli aclk-state`, read on the boxes).
- [x] `python3 summarize.py data/2026-slot6 --harness-commit 12c959b`: 2026-11-15. On the directory as the runner left it the command reproduced the runner's `results.json` (apart from the `checked` date) and `results.md` byte for byte. They were generated again after one hand edit: `run.json` gained the kernel each box booted (box-2 7.0.0-15, box-4 and box-7 7.0.0-30, as in the retest slot), a `notice` ("not a comparison table") and a note on what this directory is. The three runs' files in `data/2026-slot6/` are as collected.
- [x] 2026-11-15, checks before the data PR, all from the raw files, with a script that does not import `summarize.py` (the retest slot's, with the control made optional): 3/3 role-runs `status: ok`; both failure logs empty; the schedule in each `meta.json`, in `schedule-netdata-cloud.json` and in the slot manifest agree; one sampler start per run and no event other than `start`, `blockdev_trace`, `cgroup_appeared`, `stop`; 9,000 unit rows per run, no gap over 10 s between samples, the first sample 7 to 8 s after the install and the last 2 to 7 s before the stop; 0 duplicate (ts, cgroup) rows; 0 cgroup-inode changes; both tracer columns filled in every row and never moving backwards; each run's `blockdev.csv` sums to the box column exactly, and its lines for the unit's cgroup to the unit column exactly; every per-run figure of `results.json` for PSS, memory.current, memory peak, CPU (idle and loaded), disk charged, metadata excluded, disk written, network in, out and headline, install time and footprint recomputed: 0 differences; peak load1 in the load windows 5.56 to 6.28; steal ticks 0. Every `bench.env` value of six or more characters searched in all files, the samples unpacked: two hits, the image name in `run.json` and the run's directory name, neither a secret; the claim token's and rooms' variable names appear in the `env` list of the metas, their values nowhere. Harness tests: 129 green.
- [x] What the slot measured, next to the runs it replaces (MB per 24 h in the idle window unless a unit is given; each cell is run 1 / run 2 / run 3 on box-2 / box-4 / box-7):

  | figure | first runs, 2026-11-07 to 11-11 | retest slot, 2026-11-12/13 | this slot, 2026-11-13/14 |
  |---|---|---|---|
  | network out | 0.34 / 0.34 / 0.34 | 0.55 / 1.38 / 0.51 | 0.36 / 0.34 / 0.34 |
  | network in | 0.19 / 0.19 / 0.19 | 0.25 / 0.49 / 0.25 | 0.19 / 0.19 / 0.19 |
  | disk charged | 231.0 / 259.6 / 276.1 | 247.7 / 188.0 / 223.7 | 233.3 / 231.0 / 275.7 |
  | metadata taken out | no record | 100.3 / 38.8 / 75.2 | 89.7 / 90.3 / 139.3 |
  | disk written | 231.0 / 259.6 / 276.1 | 147.4 / 149.2 / 148.5 | 143.6 / 140.8 / 136.3 |
  | hours of 23 in which the unit was charged metadata | no record | 16 / 8 / 14 | 17 / 16 / 23 |
  | PSS, idle median (MB) | 355.7 / 356.9 / 356.4 | 359.7 / 360.9 / 361.0 | 358.7 / 357.2 / 358.2 |
  | memory peak (MB) | 295.6 / 292.5 / 308.2 | 296.0 / 291.9 / 311.5 | 300.1 / 290.2 / 293.1 |
  | CPU idle (% of one vCPU) | 3.72 / 3.96 / 3.70 | 4.04 / 3.91 / 3.79 | 3.90 / 3.89 / 3.76 |
  | CPU under load (%) | 2.79 / 3.19 / 2.81 | 3.35 / 2.95 / 3.22 | 3.07 / 2.90 / 2.90 |
  | install time (s) | 25.2 / 26.5 / 25.4 | 30.3 / 30.2 / 29.7 | 31.0 / 25.7 / 25.2 |
  | on-disk footprint (MB) | 795.9 / 794.7 / 794.7 | 801.9 / 796.8 / 798.1 | 795.2 / 795.2 / 796.3 |

  The first runs were on box-2, box-5 and box-8; the two later slots on box-2, box-4 and box-7.

  - Network: no minute of the three idle windows sent more than 1.8 KB (median 174 bytes), except one minute on box-2 (Deviations). The runs are 0.36, 0.34 and 0.34 MB per 24 h out, the figure of the first runs (0.337 to 0.340) and of the retest runs without their two bursts (0.34). The row's headline is 0.3 again.
  - Disk: the box's metadata stream was 5.7 to 5.8 MB per hour on the three boxes (5.6 to 6.4 on the six Netdata boxes of the retest slot). On box-7 Netdata's unit was charged all of it in all 23 hours; on box-2 and box-4 it shared it with the root cgroup (1.6 and 2.0 MB per hour; `init.scope` 0.5 on box-2). No hour was limited by the hourly cap. What is left after the metadata is taken out is 136 to 144 MB per 24 h (147 to 149 in the retest runs), lowest in the run that held the stream longest, which is the direction the tracer's over-count works in (`docs/RUN-2026-slot5.md`, "Deviations"): at 13 % the three figures are 10, 10 and 16 MB too low. In the samples in which the unit was charged no more than the record shows, the charge is 88 to 90 % of the record (948 to 1,513 samples per run), as in the six runs of the retest slot (87 to 90 %).
- [x] Runs filed in `data/2026/` by the rule above, 2026-11-15, on this branch: the three runs' samples, events, `blockdev.csv`, `meta.json` and `schedule-netdata-cloud.json` copied to `data/2026/cycle-1…3/` over the copies of the retest slot's runs (which stay in `data/2026-slot5/`, as collected), each cycle's `schedule.json` regenerated the way `collect` does (only the Netdata Cloud entry changes). `python3 summarize.py data/2026 --harness-commit d879a73..12c959b` → 11 rows × 3 cycles + control; the ten other rows and the control are unchanged to the last digit and the order of the table is the same. What changed in the Netdata Cloud row's medians: network 0.6 → 0.3 MB per 24 h (0.55 → 0.34 out, 0.25 → 0.19 in), disk written 148.5 → 140.8, install time 30.2 → 25.7 s, CPU under load 3.2 → 2.9 %, PSS 360.9 → 358.2 MB, memory peak 296.0 → 293.1, footprint 798.1 → 795.2; idle CPU stays 3.9 %. Every figure that moved, moved down. Footnotes added by hand to the three copies (the footnotes block only, as text): that this is the row's third measurement and what each earlier set was replaced for, with the medians that moved; the two notes on disk written of the retest slot, with this slot's figures; the Space note, which replaces the bursts note (cause, access-log counts of both slots); on run 1 the one sample of Deviations. `data/2026/run.json` notes, `data/2026/slots/README.md` and the README say which runs come from which slot; `data/2026-slot5/run.json` says in its `notice` that its three Netdata Cloud runs are no longer in the published table and why (its `results.*` regenerated, figures unchanged). Independent recompute of all 36 published role-runs: 0 differences. Data PR: **#11**, opened 2026-11-15, merged the same day (`d6aecec`).
- [x] 2026-11-15, **Opus review of PR #11: "merge after fixes", 0 Critical, 1 Important, 7 Minor; no published number was wrong** (653 per-run values of the 36 published role-runs recomputed by the reviewer's own script, 0 differences; the three runs' files byte-identical to the collector's, the copies' metas changed inside `footnotes` only; the ten other rows and the control unchanged; no secret in any changed file; 129 tests). Answered on the branch:
  - (Important) The Setup line dated the founder's "Netdata Cloud is closed" at ~22:45Z, after the start and after the three nodes were claimed, which would have broken the slot's own rule. It was a wrong time, not a late closing: the commit that recorded his words is dated 22:36:03Z. Corrected in place, with the reason.
  - Run 1's 21 KB sample said too little: the +1 h check fell in the idle window on box-2 only, and in no earlier run of the row; the sample also has a 2.2 MB disk write and two more threads, the pair most runs show ten minutes after the install; "no journal line" now says what the journal has; "no lone sample like it" is now "in the idle window". Deviations and the run's footnote rewritten with both readings.
  - The retest slot's bursts are seven samples on box-2 and box-7 and eight on box-4, and that slot's log gave sums that the samples do not reproduce (64 + 146, 25 + 974, 25 + 146 KB sent and 61, 290, 59 received; from the samples 62.3 + 144.5, 22.5 + 972.8, 22.8 + 144.7 and 58.9, 287.8, 57.3). Corrected in that log.
  - The retest slot's log called 148.5 MB the published Netdata Cloud figure; now marked as that day's.
  - The footnotes the three replaced runs were published with were only on their copies in `data/2026/`, which this PR overwrites. `data/2026-slot5/run.json` now says so, the retest slot's log quotes the bursts footnote as published, and commit `12c959b` has the files. Not done: adding footnotes to the three files in `data/2026-slot5/`, because the rule of this slot keeps them as collected.
  - Wording: "the signed-in owner" is now "a signed-in user with the role admin" of the operator's Space (what the log shows); "chart requests" is "requests, almost all for chart data" (349 of 365); the README no longer says the eight runs were measured "twice".
  - Left as it is: "about 65 to 85 MB per 24 h" for 64.8 to 86.4.

## Teardown

- [x] The six boxes this slot does not use deleted: 2026-11-13 22:51:01–22:51:25Z, `BENCH_ALLOW_DESTROY=1 ./bench vm destroy` for box-0, box-1, box-3, box-5, box-6, box-8 (Hetzner servers 173543213, …214, …220, …222, …217, …218), between two runner ticks. The founder's words: "Teardown the 10 Hetzner boxes please, if we don't need them any more" (2026-11-13), then, with this slot running, "Do we have some Hetzner boxes that we are not using at the moments and can delete?". Before the deletion the CPU and host details of six boxes were read once more (`docs/evidence/2026-slot6/host-probe-detail-2026-11-13.txt`): identical on all except the reported clock, so why box-0 and box-6 idle at a higher CPU cost stays not established. After it: box-2, box-4, box-7 and the sink running, `cycle status 0` 3/3 active, the runner's next tick unchanged ("slot 0 measuring"). The sink stays until the collect.
- [x] The last four boxes deleted (box-2, box-4, box-7, sink), after the collect, the access-log check and the data PR: 2026-11-15 07:45:15–07:45:18Z, `BENCH_ALLOW_DESTROY=1 ./bench vm destroy` for box-2, box-4, box-7 and the sink (Hetzner servers 173543215, …219, …216, …221), between two runner ticks, after data PR #11 was merged (`d6aecec`, 07:41Z; the founder: "So if we are ready to merge - do it"). The founder's words for the deletion: "Re-measure, then teardown" (2026-11-13) and, on 2026-11-15, "the teardown of the last four boxes and the cleanup, which I have already authorised". Copied off the boxes first, to the runner host and not into the repository: the three access logs in full and box-2's Netdata journal from the install to 00:30Z on 2026-11-14 (for the sample in Deviations). `./bench vm list` after it: no server.
- [x] Cron line removed; `bench.env` back to the 2026 run: 2026-11-15 07:46Z. The `bench auto tick` line is out of the crontab; `bench.env` has `RUNLOG_BRANCH=data/run-2026-rerun` and no `YEAR`, `BENCH_SLOT_COUNT` or `RUNLOG_DIR`, and `./bench cycle plan 0` prints the 2026 rotation again. The copy of the collected files kept aside during the PRs and the spare worktrees are removed; the merged branches are deleted on origin (`docs/RUN-2026.md`, "Teardown").

## Deviations and incidents

- **Run 1 (box-2): one sample with 21 KB sent, 63 minutes after the install; not a request over the Cloud link; cause not established; footnoted; the median is not affected.** In the 10 seconds to 23:42:40Z on 2026-11-13 the unit sent 21,072 bytes and received 564; the minutes around it have 174 bytes. It is in the idle window (which began at 23:39:17Z on box-2) and is why run 1 reads 0.358 MB per 24 h against 0.338 and 0.339. What is known: the access log has no line between 23:09:24Z and 23:49:14Z and no request in the whole run; Netdata's journal has no line for it; the bursts of the retest slot looked different (15 to 311 KB sent and 2 to 95 KB received per sample, seven samples on box-2 and box-7 and eight on box-4, on all three nodes at once), and this sample received 0.6 KB, so it did not answer requests. Two readings, neither established. (1) The agent's own housekeeping: the same sample has a disk write of 2.2 MB and two more threads, and six of the nine runs measured for this row have that pair ten minutes after the install (+605 to +612 s: a write of 1.8 to 2.3 MB with 13 to 16 KB sent); this run has the 10 KB send at +603 s without the write, and no write of that size until this sample (every run then has one of 2.1 to 2.3 MB about every 2.9 hours, with no traffic). (2) The harness: the runner's +1 h check logged in to the three boxes over SSH at 23:40:02Z to 23:40:06Z, 2.5 minutes earlier, and Netdata registered the login's cgroup on all three (the journal's only lines of those minutes, with two of its eBPF plugin about its cgroup list). On box-2 that login fell 45 seconds into the idle window; on box-4 and box-7 it fell in the first hour, as the +1 h check did in every earlier run of this row (the retest slot's at 18:55:01Z, before the idle windows began at 18:58:45Z to 19:11:38Z; the first runs' 11 and 18 minutes before, and not run at all for run 1). So this is the only run of the row in which the check fell in a measured window. Against it: box-4 and box-7 had the same login and sent nothing of the kind then or at any time after their first eleven minutes. None of the six earlier Netdata Cloud runs has a lone sample like it in the idle window outside the retest slot's bursts (every run has one of 10 to 16 KB at +603 to +618 s, in the first hour). Left as measured. A later run should take its +1 h check at +50 minutes, inside the first hour on every box.
- No other deviation: no restart, no gap, no failure line, the version of the replaced runs (v2.12.3), the kernels of the retest slot.
