# Slot manifests of the 2026 run

`slot-0.json` … `slot-3.json` are the four slots of the re-run (2026-11-07 → 2026-11-12) as they ran,
written by `cycle start`. They list all 36 role-runs of those slots, including the eight that were
later replaced: Monitorable run 1, Beszel run 3 and the three runs of each Netdata row. Those eight
runs' files are in `../superseded/cycle-N/`.

The runs that replace them were measured in one more slot on 2026-11-12/13. That slot is a run of its
own with its own manifest and plan, `data/2026-slot5/slots/slot-0.json` and `slot-0.plan`, so the
replacing runs' `meta.json` and `schedule-<agent>.json` in `../cycle-N/` say `"slot": 0`: slot 0 of the
retest, not `slot-0.json` here. `run` and the cycle directory say which run each one stands for, and
each row's `runs` in `../results.json` gives the box and the dates of every published run.
`docs/RUN-2026-slot5.md` has the reason and the rule.
