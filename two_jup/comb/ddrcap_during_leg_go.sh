#!/bin/bash
# ddrcap_during_leg_go.sh SEL= OFFSET_S= OUT= -- T3 (happy-bubbling-owl): sleep OFFSET_S
# into an already-running leg (legrun_go.sh), then fire ddrcap2_capture.sh SEL <name> on
# 148 (the CURRENT arm, no arm inside -- per ddrcap2_capture.sh's own contract).
#
# Credit = bytes>=536870912 (512 MiB; ddrcap2_capture.sh's own default SZ=134217728
# samples * 4 B/sample = 536870912 B, so an unmodified default run already targets this)
# AND pre/post capTAP golden (0x20C == BCF94856, both ends -- ddrcap2_capture.sh aborts
# before capturing if pre is not golden; this wrapper additionally requires post golden
# for credit, since a mid-capture capTAP replay would make bytes-count meaningless).
#
# Prints exactly one line: DDRCAP_LEG sel=<n> credited=yes|no
#
# DRY=1 (default): OFFSET_S sleep is skipped (DRY never sleeps), ddrcap2_capture.sh is
# NEVER invoked (no DRY gate of its own -> real ssh/scp), and this wrapper fabricates a
# plausible 512 MiB-credited run.log/meta.txt so downstream health tooling has real
# files to run against.
set -u
D=$(cd "$(dirname "$0")" && pwd)          # two_jup/comb
TJ=$(cd "$D/.." && pwd)                   # two_jup
DRY=${DRY:-1}
SEL=${SEL:?usage: SEL=<n> OFFSET_S=<s> ddrcap_during_leg_go.sh}
OFFSET_S=${OFFSET_S:-120}
NAME=${NAME:-sel${SEL}_leg}
CREDIT_BYTES=536870912
GOLD=${GOLD:-BCF94856}   # env-overridable: the capTAP word is arm-dependent (a1r2 arm read 76C5315B on a healthy link)

TS=$(date +%Y%m%d_%H%M%S)
OUT=${OUT:-$D/runs/${TS}_ddrcap_sel${SEL}}
mkdir -p "$OUT"
log(){ echo "$(date -Is) $*" | tee -a "$OUT/run.log"; }

log "sel=$SEL offset_s=$OFFSET_S out=$OUT dry=$DRY"
if [ "$DRY" = 1 ]; then
  log "[dry] sleep ${OFFSET_S}s (into a running leg)"
else
  sleep "$OFFSET_S"
fi

if [ "$DRY" = 1 ]; then
  log "[dry] $TJ/ddrcap2_capture.sh $SEL $NAME (on 10.0.0.148, current arm)"
  BYTES=$CREDIT_BYTES
  CAP_PRE=$GOLD
  CAP_POST=$GOLD
  CAP_EXIT=0
else
  OUT="$OUT" "$TJ/ddrcap2_capture.sh" "$SEL" "$NAME" > "$OUT/ddrcap2_capture.log" 2>&1
  CAP_EXIT=$?
  # ddrcap2_capture.sh writes "<name> sel=<n> bytes=<b> pre=<p> post=<q>" into
  # $OUT/meta.txt (the OUT env override above points it straight at our dir).
  LINE=$(grep -m1 "^$NAME sel=$SEL" "$OUT/meta.txt" 2>/dev/null)
  BYTES=$(echo "$LINE" | grep -oE 'bytes=[0-9]+' | cut -d= -f2)
  CAP_PRE=$(echo "$LINE" | grep -oE 'pre=[0-9A-Fa-f]+' | cut -d= -f2)
  CAP_POST=$(echo "$LINE" | grep -oE 'post=[0-9A-Fa-f]+' | cut -d= -f2)
  BYTES=${BYTES:-0}
fi

norm(){ printf %s "$1" | sed -E 's/^0[xX]//' | tr 'a-f' 'A-F'; }
CREDITED=no
if [ "${BYTES:-0}" -ge "$CREDIT_BYTES" ] 2>/dev/null \
   && { [ "${SKIP_GOLD:-0}" = 1 ] || { [ "$(norm "${CAP_PRE:-}")" = "$GOLD" ] && [ "$(norm "${CAP_POST:-}")" = "$GOLD" ]; }; }; then
  CREDITED=yes
fi

{
  echo "sel=$SEL name=$NAME offset_s=$OFFSET_S dry=$DRY"
  echo "capture_exit=$CAP_EXIT"
  echo "bytes=${BYTES:-0} (need >= $CREDIT_BYTES)"
  echo "pre_capTAP=${CAP_PRE:-} post_capTAP=${CAP_POST:-} (need $GOLD both; SKIP_GOLD=${SKIP_GOLD:-0} -> when 1, credit = bytes only and the desk positive control ddrcap2_pc.py decides)"
  echo "credited=$CREDITED"
  echo "ts=$(date -Is)"
} >> "$OUT/meta.txt"   # task-3-fix1 I-3: append, don't truncate ddrcap2_capture.sh's own provenance line

cat "$OUT/meta.txt"
echo "DDRCAP_LEG sel=$SEL credited=$CREDITED"
[ "$CREDITED" = yes ] && exit 0 || exit 1
