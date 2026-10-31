#!/usr/bin/env bash
# Dry run of the collector + nft counters in a provisioned LXD VM (not part of tests/run.sh).
# Asserts: ~18 rows in 3 min, collector CPU < 0.5 %, nft cgroupv2 match accepted, counters count a
# docker pull, and a docker restart is logged as a restart with counters re-armed.
set -euo pipefail
cd "$(dirname "$0")/.."
VM=${1:-bench-dry}
lxc file push -r -q collector "$VM/opt/bench/"
x() { lxc exec "$VM" -- bash -c "$*"; }
x "rm -f /var/lib/bench/samples.csv /var/lib/bench/events.csv; docker rmi -f alpine:3.20 > /dev/null 2>&1 || true
   printf 'GLOBS=--globs system.slice/docker.service\n' > /etc/bench-collector.env
   cp /opt/bench/collector/bench-collector.service /etc/systemd/system/ && systemctl daemon-reload
   systemctl restart bench-collector && sleep 2 && systemctl is-active bench-collector"
x "nft list chain inet bench out | grep -q 'socket cgroupv2 level 2 \"system.slice/docker.service\"' && echo 'ok   nft cgroupv2 rule accepted'"
x "docker pull -q alpine:3.20 > /dev/null && sleep 12 && nft -j list counters | python3 -c 'import json,sys; c=[x[\"counter\"] for x in json.load(sys.stdin)[\"nftables\"] if \"counter\" in x and x[\"counter\"][\"name\"]==\"in_system_slice_docker_service\"][0][\"bytes\"]; print(\"ok   in_docker bytes\", c) if c > 1000000 else sys.exit(\"FAIL in_docker only %d bytes\" % c)'"
x "systemctl restart docker && sleep 25 && grep -q restart /var/lib/bench/events.csv && echo 'ok   restart event logged'"
x "docker rmi -f alpine:3.20 > /dev/null 2>&1; before=\$(nft -j list counters | python3 -c 'import json,sys; print([x[\"counter\"][\"bytes\"] for x in json.load(sys.stdin)[\"nftables\"] if \"counter\" in x and x[\"counter\"][\"name\"]==\"in_system_slice_docker_service\"][0])'); docker pull -q alpine:3.20 > /dev/null; sleep 3; after=\$(nft -j list counters | python3 -c 'import json,sys; print([x[\"counter\"][\"bytes\"] for x in json.load(sys.stdin)[\"nftables\"] if \"counter\" in x and x[\"counter\"][\"name\"]==\"in_system_slice_docker_service\"][0])'); [ \"\$after\" -gt \"\$before\" ] && echo \"ok   counters keep counting after restart (\$before -> \$after)\" || echo \"FAIL counters stuck after restart (\$before -> \$after)\""
echo "sampling 3 minutes ..."
x "sleep 150"
x "rows=\$(grep -c ',system.slice/docker.service,' /var/lib/bench/samples.csv); ns=\$(systemctl show -p CPUUsageNSec --value bench-collector); up=\$(( \$(date +%s) - \$(date -d \"\$(systemctl show -p ActiveEnterTimestamp --value bench-collector)\" +%s) )); pct=\$(awk -v n=\"\$ns\" -v u=\"\$up\" 'BEGIN{printf \"%.3f\", n/1e9/u*100}'); echo \"rows=\$rows over \${up}s collector_cpu=\${pct}%\"; [ \"\$rows\" -ge 15 ] && echo 'ok   ~18 rows' || echo 'FAIL rows'; awk -v p=\"\$pct\" 'BEGIN{exit !(p < 0.5)}' && echo 'ok   collector under 0.5% CPU' || echo 'FAIL collector CPU'"
x "head -2 /var/lib/bench/samples.csv; tail -3 /var/lib/bench/events.csv"
