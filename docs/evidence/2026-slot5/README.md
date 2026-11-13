# Probe outputs behind `docs/RUN-2026-slot5.md`

Raw outputs of one-off checks run on the bed's boxes, kept so that the statements in the run log that
rest on them can be read against something. Nothing here was produced by the benchmark's collector.

- `trace3.sh`, `trace3-1.txt`, `trace3-4.txt`, `trace3-7.txt` (2026-11-12, box-1, box-4, box-7, still
  running after the re-run's last slot): 240 s of the tracepoint `writeback:writeback_single_inode` for the root
  filesystem's block-device inode, with the `io.stat` change of every unit over the same 240 s. They
  show which cgroup the kernel charged for the metadata writeback on each box: `sysroot.mount`
  (cgroup inode 886) on box-1, the root cgroup (1) on box-4, `rsyslog.service` (4760) on box-7.
- `validate-long.sh`, `validate-long-0.txt`, `validate-long-1.txt`, `validate-long-7.txt` (2026-11-12,
  40 minutes on box-0, box-1, box-7 with the collector of harness PR #10 run from a temporary
  directory): the tracer's count next to the kernel's charge. On box-1 the charged unit has no
  process, so the two can be compared exactly: 1,552,384 bytes recorded against 1,392,640 charged.
  On box-0 and box-7 the charged unit is rsyslog, whose own writes are in its charge.
- `host-probe-2026-11-13.txt`: the CPU clock each box reports and a single-thread timing.
