#!/usr/bin/env bash
# Source: https://github.com/hetrixtools/agent (installer: hetrixtools_install.sh) (read 2026-10-29)
# Installed exactly as that page says for a fresh Ubuntu server; the harness passes keys through ./env (0600).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd "$(dirname "$0")"
# shellcheck disable=SC1091
[[ -f env ]] && . ./env
# The dashboard's "Install Monitoring Agent" pop-up: SID then 7 options. HETRIX_INSTALL_ARGS holds the
# pop-up's options verbatim (default: hetrixtools user, no extra checks, reboot check on).
wget -q https://raw.githubusercontent.com/hetrixtools/agent/master/hetrixtools_install.sh
# shellcheck disable=SC2086
bash hetrixtools_install.sh "$HETRIX_KEY" ${HETRIX_INSTALL_ARGS:-0 0 0 0 0 0 1}
# Measurement-only edit: the vendor launcher starts one transient unit per minute (a new cgroup
# each run, gone before it can be read). Putting those runs in a persistent slice keeps the kernel's
# accounting (cpu.stat, io.stat include exited children) and lets one nft rule match them all.
launcher=/usr/local/sbin/hetrixtools_systemd_launcher.sh
if [[ -f "$launcher" ]]; then
  sed -i -E 's/(systemd-run )/\1--slice=system-hetrixtools.slice /' "$launcher"
  grep -q -- '--slice=system-hetrixtools.slice' "$launcher"
else
  echo "vendor systemd launcher not found at $launcher (is cron installed on this box?)" >&2; exit 2
fi
echo "VERSION=$(grep -m1 -oE '[Vv]ersion[: ]+[0-9.]+' /etc/hetrixtools/hetrixtools_agent.sh | grep -oE '[0-9.]+$' || echo unknown)"
echo "UNITS=$(systemctl list-units 'hetrixtools*' --all --no-legend --plain | awk '{print $1}' | paste -sd, -)"
