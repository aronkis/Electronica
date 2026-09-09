#!/bin/bash
# =============================================================================
# probe_cfo_go.sh -- STAGE-2 GATE-ONLY PROBES (coordinator ruling 2026-09-04).
#
# THE QUESTION. Over the air, ROM self-couples perfectly (a1 = 1,246 f/s) but the TGEN
# stream collapses frame sync: 390.8 f/s at GAP=60,000 (filler every other slot) and
# 493 f/s at GAP=45,000 (NO filler). So it is not only filler -- the TGEN stream itself
# breaks sync over the air while decoding fine in digital loopback.
# Two things differ over the air: CFO (this arm sets LO_RX = LO_TX + 20 kHz), and
# noise/AGC/timing. One thing differs between ROM and TGEN: payload ENTROPY (ROM is a
# repeated short ASCII message -> low-entropy coded stream; TGEN is PN, like mission
# traffic). Leading reading: the 26-bit Barker preamble detector (Peak_Search) is not
# robust against payload-induced FALSE detections once CFO degrades the true peak.
#
# PRE-REGISTERED PREDICTIONS (written before the runs):
#   CFO-sensitivity   -> P1 and P2 PASS, P3 and P4 FAIL
#   payload-entropy   -> P5 (FILL=100, low entropy) PASSES at +20 kHz while P6 FAILS
#   both mechanisms   -> P1 PASSES and P5 PASSES
# P1 also tests the "CFO ~= 0 dead zone" claim directly instead of assuming it -- that
# claim comes from two-board legs and has never been tested in self-reception.
#
# Each probe is GATE-ONLY: a full RF arm + the a0/a1 ROM gates + a 30 s SEQ-BIST gate.
# No 600 s leg is spent. GATE_WAIVE=1 so a failing SEQ-BIST gate does not abort the
# sweep -- but a0 (arm quality) and a1 (self-coupling) still bite, because those would
# be genuine bring-up failures rather than the effect being measured.
#
# 146 is keyed off ONCE for the whole sweep and restored to rf_enabled under a trap
# covering EXIT/INT/TERM, with a verified read-back (ruling of 2026-09-04).
# Recorded per probe: 0x124 f/s, checker f/s, and the 0x150 rstcs delta (demod resets).
# =============================================================================
set -u
S=$(cd "$(dirname "$0")" && pwd); D=$(cd "$S/.." && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
DRY=${DRY:-1}
GATE_WIN=${GATE_WIN:-30}
LO_TX=${LO_TX:-2000000000}
# name:LO_RX:FILL
PROBES=${PROBES:-"P1_cfo0:2000000000:1516 P2_p5k:2000005000:1516 P3_p20k:2000020000:1516 P4_m20k:1999980000:1516 P5_p20k_fill100:2000020000:100 P6_p20k_ctrl:2000020000:1516"}
OUT=${OUT:-$D/comb/runs/$(date +%Y%m%d_%H%M%S)_s2probes}
mkdir -p "$OUT"
log(){ echo "$(date -Is) [cfo] $*" | tee -a "$OUT/run.log"; }
b(){ if [ "$DRY" = 1 ]; then echo "[dry] $*"; else $W "$1" "$2" 2>/dev/null | tr -d '\r'; fi; }

ENSM_ORIG=""; RESTORED=0
restore_146(){
  [ "$RESTORED" = 1 ] && return 0; RESTORED=1
  [ -z "$ENSM_ORIG" ] && { log "RESTORE_146: nothing to restore"; return 0; }
  log "RESTORE_146: writing out_voltage0_ensm_mode=$ENSM_ORIG"
  local v; v=$(b $B "P=/sys/bus/iio/devices/iio:device2; echo $ENSM_ORIG > \$P/out_voltage0_ensm_mode 2>/dev/null; sleep 1; cat \$P/out_voltage0_ensm_mode")
  log "RESTORE_146: read-back='$v' (expect '$ENSM_ORIG')"
  if [ "$DRY" = 1 ]; then log "146_RESTORE_VERIFIED=dry"
  elif [ "$v" = "$ENSM_ORIG" ]; then log "146_RESTORE_VERIFIED=1"
  else log "146_RESTORE_VERIFIED=0 *** PHYSICAL ATTENTION: 146 TX left at '$v' ***"; fi
}
trap restore_146 EXIT INT TERM

log "=== stage-2 gate-only probes: $PROBES ==="
ENSM_ORIG=$(b $B 'cat /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode')
[ "$DRY" = 1 ] && ENSM_ORIG=rf_enabled
log "146 ensm BEFORE='$ENSM_ORIG'"
if [ "$ENSM_ORIG" = rf_enabled ]; then
  NOW=$(b $B "P=/sys/bus/iio/devices/iio:device2; echo calibrated > \$P/out_voltage0_ensm_mode 2>/dev/null; sleep 1; cat \$P/out_voltage0_ensm_mode")
  log "146 keyed off: read-back='$NOW'"
  [ "$DRY" = 1 ] || [ "$NOW" = calibrated ] || { log "ABORT: 146 did not key off"; echo "PROBE_ABORT_146"; exit 3; }
else
  log "146 already not rf_enabled -- leaving as found"; ENSM_ORIG=""
fi

rstcs(){ if [ "$DRY" = 1 ]; then echo 0; else
  $W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo 0x150 > $DRA; cat $DRA' 2>/dev/null | tr -d '\r' | tail -1; fi; }

printf '%-18s %-12s %-6s %10s %10s %8s %8s\n' probe lo_rx fill "0x124f/s" "chk f/s" "dev%" "d_rstcs" | tee "$OUT/table.txt"
for p in $PROBES; do
  NAME=${p%%:*}; rest=${p#*:}; LORX=${rest%%:*}; FILL=${rest##*:}
  log "--- $NAME: LO_RX=$LORX (CFO $(( LORX - LO_TX )) Hz) FILL=$FILL ---"
  R0=$(rstcs); R0=$((R0))
  O=$(DRY=$DRY LO_TX=$LO_TX LO_RX=$LORX FILL=$FILL GAP=45000 GATE_WAIVE=1 GATE_WIN=$GATE_WIN \
        bash "$S/arm148_rf_self.sh" 2>&1)
  echo "$O" >> "$OUT/$NAME.log"
  echo "$O" | grep -E "arm-quality gate|self-coupling gate|SEQ-BIST gate|ARM_RF_SELF" | sed 's/^/    /' | tee -a "$OUT/run.log"
  R1=$(rstcs); R1=$((R1))
  FPS=$(echo "$O" | sed -n 's/.*fps124=\([0-9.]*\).*/\1/p' | tail -1)
  CHK=$(echo "$O" | sed -n 's/.*chk_fps=\([0-9.]*\).*/\1/p' | tail -1)
  DEV=$(echo "$O" | sed -n 's/.*dev_pct=\([0-9.]*\).*/\1/p' | tail -1)
  printf '%-18s %-12s %-6s %10s %10s %8s %8s\n' "$NAME" "$LORX" "$FILL" "${FPS:-NA}" "${CHK:-NA}" "${DEV:-NA}" "$((R1-R0))" | tee -a "$OUT/table.txt"
done
log "=== probes done -> $OUT/table.txt ==="
cat "$OUT/table.txt"
echo "PROBE_SWEEP_DONE $OUT"
