#!/bin/bash
# =============================================================================
# probe_pwr_go.sh -- STAGE-2 RX-OVERLOAD PROBES P7/P8 (coordinator ruling 2026-09-04).
#
# THE READING BEING TESTED. P1 (CFO 0) still failed: 0x124 617 f/s vs ROM's 1246, with
# d_rstcs 6,978 in 30 s = ~233 carrier-sync resets/s. Sync is ACQUIRED AND REPEATEDLY
# LOST, not never acquired. On the mission legs rstcs stayed ~0 (T2/T3), so this
# self-reception failure has a DIFFERENT signature from the on-air comb and is probably
# not the same defect at all. Leading candidate: RX OVERLOAD -- 148 transmits at
# out_voltage0_hardwaregain 0 dB (full power, set by arm_rom) into its own RX, which
# task-8a measured parked at the AGC max-gain rail (34.000000 dB = index 255). A PN
# payload is full-bandwidth QPSK and clips where the repetitive low-entropy ROM stream
# tolerates it -- which is exactly the ROM-passes / TGEN-fails split.
#
# PREDICTION (overload): rstcs/s falls toward 0 and 0x124 rises toward ~1,246 with
#   FILL=1516 at some attenuation.
# FALSIFIER: unchanged at every attenuation -> not a power problem.
#
# ORDERING CONSTRAINT (why TXATTEN lives inside arm148_rf_self.sh and not here):
# arm_rom writes `echo 0 > out_voltage0_hardwaregain` on EVERY arm, so an attenuation
# applied before the arm is silently overwritten. It must be applied AFTER the arm and
# before the gate. arm148_rf_self.sh takes TXATTEN and does exactly that, logging the
# read-back.
#
# 148's TX gain is restored to 0 dB and 146 to rf_enabled under one trap covering
# EXIT/INT/TERM, both with verified read-backs.
# =============================================================================
set -u
S=$(cd "$(dirname "$0")" && pwd); D=$(cd "$S/.." && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
DRY=${DRY:-1}
GATE_WIN=${GATE_WIN:-30}
LO_TX=${LO_TX:-2000000000}
LO_RX=${LO_RX:-2000000000}          # CFO 0: P1's setting, the best CFO seen so far
# name:TXATTEN:FILL
PROBES=${PROBES:-"P7_atten20:-20:1516 P8_atten40:-40:1516 P9_rom_atten20:-20:ROM"}
OUT=${OUT:-$D/comb/runs/$(date +%Y%m%d_%H%M%S)_s2pwr}
mkdir -p "$OUT"
log(){ echo "$(date -Is) [pwr] $*" | tee -a "$OUT/run.log"; }
b(){ if [ "$DRY" = 1 ]; then echo "[dry] $*"; else $W "$1" "$2" 2>/dev/null | tr -d '\r'; fi; }

ENSM_ORIG=""; GAIN_ORIG=""; RESTORED=0
restore_all(){
  [ "$RESTORED" = 1 ] && return 0; RESTORED=1
  if [ -n "$GAIN_ORIG" ]; then
    log "RESTORE_148_TXGAIN: writing out_voltage0_hardwaregain=$GAIN_ORIG"
    local g; g=$(b $A "P=/sys/bus/iio/devices/iio:device2; echo $GAIN_ORIG > \$P/out_voltage0_hardwaregain 2>/dev/null; sleep 0.5; cat \$P/out_voltage0_hardwaregain")
    log "RESTORE_148_TXGAIN: read-back='$g' (expect '$GAIN_ORIG')"
    if [ "$DRY" = 1 ]; then log "148_TXGAIN_RESTORE_VERIFIED=dry"
    elif [ "${g%%.*}" = "${GAIN_ORIG%%.*}" ]; then log "148_TXGAIN_RESTORE_VERIFIED=1"
    else log "148_TXGAIN_RESTORE_VERIFIED=0 *** 148 TX gain left at '$g' ***"; fi
  fi
  if [ -n "$ENSM_ORIG" ]; then
    log "RESTORE_146: writing out_voltage0_ensm_mode=$ENSM_ORIG"
    local v; v=$(b $B "P=/sys/bus/iio/devices/iio:device2; echo $ENSM_ORIG > \$P/out_voltage0_ensm_mode 2>/dev/null; sleep 1; cat \$P/out_voltage0_ensm_mode")
    log "RESTORE_146: read-back='$v' (expect '$ENSM_ORIG')"
    if [ "$DRY" = 1 ]; then log "146_RESTORE_VERIFIED=dry"
    elif [ "$v" = "$ENSM_ORIG" ]; then log "146_RESTORE_VERIFIED=1"
    else log "146_RESTORE_VERIFIED=0 *** PHYSICAL ATTENTION: 146 TX left at '$v' ***"; fi
  fi
}
trap restore_all EXIT INT TERM

GAIN_ORIG=$(b $A 'cat /sys/bus/iio/devices/iio:device2/out_voltage0_hardwaregain')
[ "$DRY" = 1 ] && GAIN_ORIG="0.000000"
log "148 out_voltage0_hardwaregain BEFORE='$GAIN_ORIG'"
ENSM_ORIG=$(b $B 'cat /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode')
[ "$DRY" = 1 ] && ENSM_ORIG=rf_enabled
log "146 ensm BEFORE='$ENSM_ORIG'"
if [ "$ENSM_ORIG" = rf_enabled ]; then
  NOW=$(b $B "P=/sys/bus/iio/devices/iio:device2; echo calibrated > \$P/out_voltage0_ensm_mode 2>/dev/null; sleep 1; cat \$P/out_voltage0_ensm_mode")
  log "146 keyed off: read-back='$NOW'"
  [ "$DRY" = 1 ] || [ "$NOW" = calibrated ] || { log "ABORT: 146 did not key off"; echo "PWR_ABORT_146"; exit 3; }
else
  log "146 already not rf_enabled -- leaving as found"; ENSM_ORIG=""
fi

rstcs(){ if [ "$DRY" = 1 ]; then echo 0; else
  $W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo 0x150 > $DRA; cat $DRA' 2>/dev/null | tr -d '\r' | tail -1; fi; }
rxgain(){ if [ "$DRY" = 1 ]; then echo "34.000000"; else
  $W $A 'cat /sys/bus/iio/devices/iio:device2/in_voltage0_hardwaregain' 2>/dev/null | tr -d '\r' | tail -1; fi; }

printf '%-16s %-8s %-6s %8s %8s %10s %10s %8s %10s %10s\n' probe txatten fill "a0(int)" "a1(rom)" "0x124f/s" "chk f/s" "dev%" "rstcs_gate" "rxgain" | tee "$OUT/table.txt"
for p in $PROBES; do
  NAME=${p%%:*}; rest=${p#*:}; ATT=${rest%%:*}; FILL=${rest##*:}
  log "--- $NAME: TXATTEN=${ATT} dB FILL=$FILL LO_RX=$LO_RX ---"
  # 0x150 rstcs is RESET BY THE ARM (the 0x000 pulse; survey line 16 / QPSK_Rx.v:649).
  # A delta taken ACROSS the arm is therefore meaningless -- probe_cfo_go.sh's P2 returned
  # d_rstcs = -9034, a negative "count", which is what exposed it. The ABSOLUTE value read
  # after the gate is the right number: the last 0x000 pulse is in stage (b)'s byte re-arm,
  # immediately before TGEN-on and the gate window, so the reading is resets accumulated
  # over (settle + gate) and nothing earlier. R0 is kept only to prove the reset happened.
  R0=$(rstcs); R0=$((R0))
  # FILL=ROM => the a0/a1 ROM gates at this attenuation are the whole point; run with a
  # normal FILL so the script is happy, and read only a0/a1 from the result.
  EFF_FILL=$FILL; [ "$FILL" = ROM ] && EFF_FILL=1516
  O=$(DRY=$DRY LO_TX=$LO_TX LO_RX=$LO_RX FILL=$EFF_FILL GAP=45000 GATE_WAIVE=1 GATE_WIN=$GATE_WIN \
        TXATTEN=$ATT bash "$S/arm148_rf_self.sh" 2>&1)
  echo "$O" >> "$OUT/$NAME.log"
  echo "$O" | grep -E "TXATTEN|arm-quality gate|self-coupling gate|SEQ-BIST gate|ARM_RF_SELF" | sed 's/^/    /' | tee -a "$OUT/run.log"
  R1=$(rstcs); R1=$((R1))
  A0=$(echo "$O" | sed -n 's/.*intfps=\(-*[0-9.]*\).*/\1/p' | tail -1)
  A1=$(echo "$O" | sed -n 's/.*romfps=\([0-9.]*\).*/\1/p' | tail -1)
  RSD=$(echo "$O" | sed -n 's/.*rstcs_gate=\(-*[0-9]*\).*/\1/p' | tail -1)
  FPS=$(echo "$O" | sed -n 's/.*fps124=\([0-9.]*\).*/\1/p' | tail -1)
  CHK=$(echo "$O" | sed -n 's/.*chk_fps=\([0-9.]*\).*/\1/p' | tail -1)
  DEV=$(echo "$O" | sed -n 's/.*dev_pct=\([0-9.]*\).*/\1/p' | tail -1)
  # absolute R1 over the gate window; R0 logged separately as the reset witness
  log "$NAME rstcs: pre_arm=$R0 post_gate=$R1 (pre_arm discarded -- the arm resets 0x150); in-gate delta=${RSD:-NA}"
  printf '%-16s %-8s %-6s %8s %8s %10s %10s %8s %10s %10s\n' "$NAME" "$ATT" "$FILL" "${A0:-NA}" "${A1:-NA}" "${FPS:-NA}" "${CHK:-NA}" "${DEV:-NA}" "${RSD:-NA}" "$(rxgain)" | tee -a "$OUT/table.txt"
done
log "=== P7/P8 done -> $OUT/table.txt ==="
cat "$OUT/table.txt"
echo "PWR_SWEEP_DONE $OUT"
