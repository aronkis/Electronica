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
# systemd-run does not inherit this shell's cwd: a relative script path fails with
# exit 127 inside the unit (deploy148-T1, 2026-09-03). Resolve it here, fail loudly.
SCRIPT=$(realpath -e "$SCRIPT") || { echo "launch_rig_unit: script not found: $1" >&2; exit 2; }
# Snapshot the script per unit: bash reads scripts incrementally, so editing a script
# while a unit executes it corrupts the run (seqbist-s1-ctrlA, 2026-09-04 00:15: syntax
# error mid-window after a concurrent edit). The unit runs the frozen copy.
# The copy lives in the SAME directory (scripts locate siblings via dirname "$0");
# .snap_* is git-ignored.
SNAP="$(dirname "$SCRIPT")/.snap_${UNIT}_$(basename "$SCRIPT")"; cp "$SCRIPT" "$SNAP"; chmod +x "$SNAP"
export RIG_UNIT_SCRIPT_ORIG="$SCRIPT"; SCRIPT="$SNAP"
ENVS=()
for kv in "$@"; do ENVS+=(--setenv="$kv"); done
exec systemd-run --user --unit="$UNIT" \
  -p TimeoutStopSec=600 \
  -p KillSignal=SIGTERM \
  -p SendSIGKILL=yes \
  --setenv=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  --setenv=RIG_UNIT_SCRIPT_ORIG="$RIG_UNIT_SCRIPT_ORIG" \
  "${ENVS[@]}" \
  /bin/bash "$SCRIPT"
