T=/sys/kernel/tracing; E=$T/events/writeback/writeback_single_inode/enable
BDEV=$(( ($(stat -c %d /) ) )); MAJ=$((BDEV>>8)); MIN=$((BDEV&255)); INO=$(( (MAJ<<20)|MIN )); echo "root dev $MAJ:$MIN -> block-device inode $INO"
snap() { for f in /sys/fs/cgroup/system.slice/*/io.stat; do w=$(awk '{for(i=2;i<=NF;i++) if($i ~ /^wbytes=/){split($i,a,"="); s+=a[2]}} END{print s+0}' $f); echo "$w $(stat -c %i ${f%/io.stat}) ${f%/io.stat}"; done | sort -k3; }
snap > /tmp/s0; echo > $T/trace; echo 1 > $E; sleep 240; echo 0 > $E; snap > /tmp/s1
grep -v '^#' $T/trace | grep "ino=$INO " | sed -E 's/.* wrote=([0-9]+) cgroup_ino=([0-9]+).*/\2 \1/' | awk '{n[$1]++; w[$1]+=$2} END{for(k in n) print "TRACE block-device inode: cgroup_ino", k, "events", n[k], "bytes", w[k]*4096}'
echo > $T/trace
echo "io.stat deltas over the same 240 s (bytes cgroup_ino path):"; join -j 3 /tmp/s0 /tmp/s1 | awk '{d=$4-$2; if(d>0 && $1 !~ /journald/) print d, $3, $1}' | sort -rn | head -8
rm -f /tmp/s0 /tmp/s1
