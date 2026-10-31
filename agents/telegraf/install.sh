#!/usr/bin/env bash
# Source: https://docs.influxdata.com/telegraf/v1/install/ (read 2026-10-29)
# Installed exactly as that page says for a fresh Ubuntu server; the harness passes keys through ./env (0600).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd "$(dirname "$0")"
# shellcheck disable=SC1091
[[ -f env ]] && . ./env
curl --silent --location -O https://repos.influxdata.com/influxdata-archive.key
gpg --show-keys --with-fingerprint --with-colons ./influxdata-archive.key 2>&1 | grep -q '^fpr:\+24C975CBA61A024EE1B631787C3D57159FC2F927:$' \
  && install -d /etc/apt/keyrings \
  && gpg --dearmor < influxdata-archive.key > /etc/apt/keyrings/influxdata-archive.gpg \
  && echo 'deb [signed-by=/etc/apt/keyrings/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main' > /etc/apt/sources.list.d/influxdata.list
apt-get update -q && apt-get install -y -q telegraf
# The stock config enables no output at all (every [[outputs.*]] is commented). The only edit: the
# stock [[outputs.influxdb]] block is enabled with the sink's URL (its header line and its
# http URL line, nothing else), so Telegraf has somewhere to write.
n=$(grep -nE '^# \[\[outputs\.influxdb\]\]' /etc/telegraf/telegraf.conf | cut -d: -f1)
[[ -n "$n" ]] || { echo "stock [[outputs.influxdb]] block not found" >&2; exit 2; }
sed -i -E "${n}s/^# \[\[outputs\.influxdb\]\]/[[outputs.influxdb]]/" /etc/telegraf/telegraf.conf
sed -i -E "$n,$((n + 12))s|^#   # urls = \[\"http://127\.0\.0\.1:8086\"\]|  urls = [\"http://$SINK_IP:8086\"]|" /etc/telegraf/telegraf.conf
grep -q "^\[\[outputs.influxdb\]\]" /etc/telegraf/telegraf.conf
grep -q "^  urls = \[\"http://$SINK_IP:8086\"\]" /etc/telegraf/telegraf.conf
systemctl enable --now telegraf
systemctl restart telegraf
echo "VERSION=$(telegraf --version 2>/dev/null | head -1)"
echo "UNITS=telegraf.service"
