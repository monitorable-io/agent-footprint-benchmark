#!/usr/bin/env bash
# Mask Ubuntu's apt-daily and apt-daily-upgrade timers and stop unattended-upgrades. Idempotent; run by
# base/provision.sh. The pilot (data/2026-pilot) left Ubuntu's default on: unattended-upgrades ran once a
# day between 06:00 and 07:00 UTC and its package triggers restarted dynamically linked agents (Glances,
# Netdata, Datadog, Fivenines) and Beszel mid-cycle, and a Netdata restart rewrote its database (~250 MB
# of disk writes in that hour). The re-run measures agents on a box that does not upgrade itself; the
# results page says so (run.json notes).
set -euo pipefail
timers=(apt-daily.timer apt-daily-upgrade.timer)
# `mask` on an already-masked unit is a redo, whatever it prints or returns; the check below decides.
systemctl mask --now "${timers[@]}" || true
systemctl stop unattended-upgrades.service 2> /dev/null || true   # absent on a minimal image
for t in "${timers[@]}"; do
  state=$(systemctl is-enabled "$t" 2> /dev/null || true)
  [[ "$state" == masked ]] || { echo "apt-timers: $t is ${state:-unknown}, not masked" >&2; exit 1; }
done
echo "apt-timers: ${timers[*]} masked, unattended-upgrades stopped"
