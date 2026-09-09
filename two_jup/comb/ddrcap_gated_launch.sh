#!/bin/bash
# ddrcap_gated_launch.sh -- T3 launch gate (predeclaration D5). Host-side only until it
# fires: polls the leg's capture_r3.log (a local file; NO board contact, no register
# reads) for capture_r3.sh:246 `CAP_START t=<epoch>` and the matching CAP_END at :248,
# then sleeps until CAP_START + WAIT_S and execs ddrcap_during_leg_go.sh with OFFSET_S=0
# (the offset is timed here, not inside that script).
#   LOG=<capture_r3.log> WAIT_S=120 SEL=13 OUT=<dir> MAXWAIT_S=<s>
set -u
D=$(cd "$(dirname "$0")" && pwd)
LOG=${LOG:?LOG}; WAIT_S=${WAIT_S:-120}; SEL=${SEL:?SEL}; OUT=${OUT:?OUT}
MAXWAIT_S=${MAXWAIT_S:-900}
mkdir -p "$OUT"; G="$OUT/gate.log"
log(){ echo "$(date -Is) $*" | tee -a "$G"; }
log "gate: log=$LOG wait_s=$WAIT_S sel=$SEL out=$OUT"
t0=$(date +%s)
CS=""
while :; do
  now=$(date +%s); [ $((now-t0)) -ge "$MAXWAIT_S" ] && { log "GATE_TIMEOUT after ${MAXWAIT_S}s (CAP_START/CAP_END never both seen)"; exit 4; }
  if [ -z "$CS" ]; then
    CS=$(grep -m1 -oE 'CAP_START t=[0-9.]+' "$LOG" 2>/dev/null | cut -d= -f2)
    [ -n "$CS" ] && log "CAP_START epoch=$CS"
  fi
  if [ -n "$CS" ] && grep -q 'CAP_END' "$LOG" 2>/dev/null; then
    log "CAP_END seen"
    break
  fi
  sleep 2
done
FIRE=$(awk -v a="$CS" -v w="$WAIT_S" 'BEGIN{printf "%d", a+w}')
while :; do
  now=$(date +%s); [ "$now" -ge "$FIRE" ] && break
  log "waiting $((FIRE-now))s to reach CAP_START+${WAIT_S}s"; sleep 5
done
log "FIRING ddrcap_during_leg_go.sh SEL=$SEL OFFSET_S=0 (t=+$(awk -v a="$CS" -v n="$(date +%s)" 'BEGIN{printf "%.0f", n-a}')s after CAP_START)"
exec env DRY=0 SEL="$SEL" OFFSET_S=0 OUT="$OUT" SKIP_GOLD="${SKIP_GOLD:-1}" "$D/ddrcap_during_leg_go.sh"
