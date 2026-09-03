#!/bin/bash
# launch_rig_unit.sh -- the ONLY sanctioned way to start a rig-holding unit.
#
# Any script that arms a board must be able to finish its gated restore before
# systemd kills it. The default TimeoutStopSec is 90 s; a gated restore needs
# about that long by itself, so a plain `systemd-run --user` leaves a SIGKILL
# landing mid-arm on `systemctl stop` -- which is exactly how board 148 was
# hung at 22:10 on 2026-08-31 with nobody present to power-cycle it.
#
# Usage: launch_rig_unit.sh <unit-name> <script> [env=val ...]
set -eu
UNIT=$1; shift
SCRIPT=$1; shift
ENVS=()
for kv in "$@"; do ENVS+=(--setenv="$kv"); done
exec systemd-run --user --unit="$UNIT" \
  -p TimeoutStopSec=600 \
  -p KillSignal=SIGTERM \
  -p SendSIGKILL=yes \
  --setenv=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  "${ENVS[@]}" \
  /bin/bash "$SCRIPT"
