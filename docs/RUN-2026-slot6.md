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
- [x] Netdata Cloud Space has room for three nodes (the founder deletes the three offline nodes; one node of his own remains): 2026-11-13 ~22:45Z, the founder in chat: "Nodes are deleted. Netdata Cloud is closed in my browser".
- [x] `bench.env` points at this run; plan file and `run.json` in place; `./bench cycle plan 0`: 2026-11-13 22:31Z, between two runner ticks. `bench.env`: `YEAR=2026-slot6`, `BENCH_SLOT_COUNT=1`, `RUNLOG_BRANCH=data/run-2026-slot6`, `RUNLOG_DIR` = a worktree of that branch (before: the same four lines for slot 5). `run.json`: the bed and the four method notes of the retest slot. `./bench cycle plan 0` printed the three lines of the table above and no other box; `./bench cycle plan 1` was refused ("slot 1 is outside this run"); `./bench auto status`: "next: none", so the runner starts nothing by itself.

## Slot 6 (s = 0 of this run)

- [x] founder's words for `./bench cycle start 0` (date, words): 2026-11-13 ~22:25Z, asked "Re-measuring needs three of the boxes. What should I do?" with the two ways forward set out, he chose "Re-measure, then teardown": measure the three Netdata Cloud runs again in one 26-hour slot with nobody opening the Space, replace them by the same rule, then destroy all ten boxes. The question said the three boxes would be rebuilt on that answer.
- [x] `./bench cycle start 0` at: 2026-11-13T22:36:19Z → 2026-11-13T22:44:34Z (by hand, main 12c959b). Failures log: empty. 3 boxes in the manifest (box-2, box-4, box-7), AMD EPYC-Rome Processor / 2 vCPU; no other box was rebuilt. Every provision printed "apt-timers: … masked, unattended-upgrades stopped". Installs: 31.0 s, 25.7 s, 25.2 s, all v2.12.3, the version of the replaced runs. Kernels as in the retest slot: box-2 7.0.0-15, box-4 and box-7 7.0.0-30. Collect after 2026-11-14T23:44:23Z. `cycle status 0` right after (22:44Z): 3/3 rows active, the metadata tracer counting on box-2 and box-4 (box-7 had five samples). Read on the boxes, not in Netdata Cloud (`netdatacli aclk-state`): all three claimed and online. Requests over the Cloud link in each access log at 22:45Z: 0.
- [ ] `./bench collect 0` at:

## Data

- [ ] Access logs read after the collect (requests over the Cloud link during the run, per box):
- [ ] `python3 summarize.py data/2026-slot6 --harness-commit <main sha>`:
- [ ] Runs filed in `data/2026/` by the rule above; data PR:

## Teardown

- [ ] Boxes deleted (the founder's words of 2026-11-13: "Teardown the 10 Hetzner boxes please, if we don't need them any more", then "Re-measure, then teardown"):
- [ ] Cron line removed; `bench.env` back to the 2026 run:

## Deviations and incidents

(none yet)
