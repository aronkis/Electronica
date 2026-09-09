#!/bin/bash
# =============================================================================
# stage2_self_go.sh -- SEQ-BIST stage 2 (plan T3) as ONE unit, so 146's TX is
# keyed off and restored under a single trap that covers every exit path.
#
# Ruling (coordinator, 2026-09-04, ledgered): 146 may be keyed off via
#   out_voltage0_ensm_mode = calibrated
# with a VERIFIED rf_enabled restore under a trap. That is a radio-state write,
# not an image change; 146's image, profile, LOs and gains are never touched.
#
# WHY: task-6 PHASE A found 146 sitting ensm=rf_enabled, 0x158=0, hardwaregain
# 0 dB -- i.e. radiating ROM at 2.000 000 GHz, the exact carrier 148's RX is
# tuned to (2.000 020 GHz, +20 kHz). Those ROM frames carry no TGEN magic, so
# they land in chk_garbage/magic_bad and make the leg uninterpretable; worse,
# the self-coupling gate (a1) would be measuring 146's carrier rather than
# 148's own transmission.
#
# Sequence: read 146's ensm -> key off -> verify -> arm 148 (arm148_rf_self.sh)
#           -> seqbist_run.sh MODE=rf -> [trap] restore 146 -> verify restore.
# The trap fires on success, on any failure, and on SIGTERM (systemd stop), so
# 146 never stays keyed off. TimeoutStopSec=600 from launch_rig_unit.sh gives
# the trap room to finish.
#
# Env: DUR=600 GAP=<mission> FILL=1516 DRY=1 (default) plus everything
#      arm148_rf_self.sh takes (LO_RX, SSI, GATE_*).
# =============================================================================
set -u
S=$(cd "$(dirname "$0")" && pwd); D=$(cd "$S/.." && pwd); W=$D/anyssh.sh
B=10.0.0.146
DRY=${DRY:-1}
DUR=${DUR:-600}
GAP=${GAP:-0}
FILL=${FILL:-1516}
TAG=${TAG:-s2self}

log(){ echo "$(date -Is) [s2] $*"; }
b146(){ if [ "$DRY" = 1 ]; then echo "[dry] ssh $B: $*"; else $W $B "$@" 2>/dev/null | tr -d '\r'; fi; }

ENSM_ORIG=""
RESTORED=0
restore_146(){
  [ "$RESTORED" = 1 ] && return 0
  RESTORED=1
  [ -z "$ENSM_ORIG" ] && { log "RESTORE_146: nothing to restore (never keyed off)"; return 0; }
  log "RESTORE_146: writing out_voltage0_ensm_mode=$ENSM_ORIG back to 146"
  local v
  v=$(b146 "P=/sys/bus/iio/devices/iio:device2; echo $ENSM_ORIG > \$P/out_voltage0_ensm_mode 2>/dev/null; sleep 1; cat \$P/out_voltage0_ensm_mode")
  log "RESTORE_146: read-back = '$v' (expect '$ENSM_ORIG')"
  if [ "$DRY" = 1 ]; then log "146_RESTORE_VERIFIED=dry"
  elif [ "$v" = "$ENSM_ORIG" ]; then log "146_RESTORE_VERIFIED=1"
  else log "146_RESTORE_VERIFIED=0  *** PHYSICAL ATTENTION: 146 TX left at '$v', expected '$ENSM_ORIG' ***"; fi
}
trap restore_146 EXIT INT TERM

log "=== stage 2: OTA self-reception on 148, 146 keyed off (DRY=$DRY DUR=$DUR GAP=$GAP) ==="

# ---- 1. key 146 off, verified -----------------------------------------------
ENSM_ORIG=$(b146 'cat /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode')
[ "$DRY" = 1 ] && ENSM_ORIG=rf_enabled
log "146 out_voltage0_ensm_mode BEFORE = '$ENSM_ORIG'"
if [ "$ENSM_ORIG" != rf_enabled ]; then
  log "146 TX is already not rf_enabled -- nothing to key off; leaving 146 exactly as found"
  ENSM_ORIG=""
else
  NOW=$(b146 "P=/sys/bus/iio/devices/iio:device2; echo calibrated > \$P/out_voltage0_ensm_mode 2>/dev/null; sleep 1; cat \$P/out_voltage0_ensm_mode")
  log "146 keyed off: read-back = '$NOW' (expect 'calibrated')"
  if [ "$DRY" != 1 ] && [ "$NOW" != calibrated ]; then
    log "S2_ABORT: 146 did not key off (read '$NOW'); refusing to run an uninterpretable leg"
    echo "S2_ABORT_146_KEYOFF"; exit 3
  fi
fi

# ---- 2. arm 148 for RF self-reception ---------------------------------------
log "--- arming 148 (arm148_rf_self.sh) ---"
DRY=$DRY FILL=$FILL GAP=$GAP GATE_WAIVE=${GATE_WAIVE:-0} bash "$S/arm148_rf_self.sh"; ARC=$?
log "arm148_rf_self.sh exit=$ARC"
if [ "$ARC" != 0 ]; then
  log "S2_ABORT: bring-up gate did not pass (exit $ARC) -- no 600 s leg is spent"
  echo "S2_ABORT_ARM rc=$ARC"; exit "$ARC"
fi

# ---- 3. the leg --------------------------------------------------------------
log "--- seqbist_run.sh MODE=rf DUR=$DUR GAP=$GAP ---"
# SINK=tgenrx is MANDATORY here, not optional: rx_seq_checker counts valid && ready at
# the DUT RX byte pins, and with no daemon and no DMA armed the seam's ready is LOW, so
# every counter reads 0 while 0x104 runs at line rate (measured as ctrlA att.1). Omitting
# it was a real defect in the first draft of this script -- the leg would have produced a
# confident-looking all-zero result on a stalled seam.
DRY=$DRY BOARD=148 MODE=rf FILL=$FILL GAP=$GAP DUR=$DUR SINK=tgenrx TAG=$TAG \
  ${WINDOW_MIN:+WINDOW_MIN=$WINDOW_MIN} bash "$S/seqbist_run.sh"; RRC=$?
log "seqbist_run.sh exit=$RRC"
echo "S2_DONE rc=$RRC"
exit "$RRC"
