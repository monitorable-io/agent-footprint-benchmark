set -u; V=/tmp/bench-val; cd $V
timeout -s INT 2400 python3 $V/bench_collector.py --interval 10 --out $V/samples.csv --events $V/events.csv --blockdev-trace --blockdev-out $V/blockdev.csv \
  --globs system.slice/rsyslog.service --globs system.slice/sysroot.mount --globs system.slice/ssh.service --globs system.slice/containerd.service 2>/dev/null
python3 - <<'PY'
import csv
rows=list(csv.DictReader(open("/tmp/bench-val/samples.csv")))
byc={}
for r in rows: byc.setdefault(r["cgroup"],[]).append(r)
for c,rs in byc.items():
    if c=="box": print("box blockdev total:", rs[-1]["box_wbytes_blockdev"], "samples", len(rs)); continue
    print(f"{c}: io_wbytes +{int(rs[-1]['io_wbytes'])-int(rs[0]['io_wbytes'])}  io_wbytes_blockdev +{int(rs[-1]['io_wbytes_blockdev'] or 0)-int(rs[0]['io_wbytes_blockdev'] or 0)}")
import collections
own=collections.Counter(); n=collections.Counter()
for l in list(open("/tmp/bench-val/blockdev.csv"))[1:]:
    ts,ino,name,b=l.strip().split(","); own[name]+=int(b); n[name]+=1
print("owners:", dict(own), dict(n))
PY
T=/sys/kernel/tracing/instances/bench; echo 0 > $T/events/writeback/writeback_single_inode/enable; rmdir $T && echo "instance removed"; rm -rf $V
