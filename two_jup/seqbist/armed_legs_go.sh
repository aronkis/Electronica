#!/bin/bash
# =============================================================================
# armed_legs_go.sh -- run a FULL arm, then a set of SEQ-BIST legs, in one unit.
#
# WHY THIS EXISTS (2026-09-04, knee trials rc=6 on both gaps):
# seqbist_run.sh MODE=loopback writes only 0x158/0x118/0x114 -- the
# loopchk_run.sh:31-33 register triple. That is NOT a full arm: no modem enable
# (0x004 / the 0x000 reset pulse), no byte-plane re-arm (0x9D300000 bit0), no rstCS.
# Every SEQ-BIST leg that worked tonight had INHERITED the armed mode-1 state left by
# the flash chain's arm148_mode1.sh gate. capture_r3.sh's quiesce zeroes 0x9D000000 and
# 0x9D000114 (modem enable + RX input select) and deletes tun0, so the first SEQ-BIST
# leg after ANY daemon leg or quiesce starts from an unarmed board -- which is exactly
# the d0x104>0 / d_chk_frames=0 signature both knee trials returned.
#
# arm148_mode1.sh is the flash chain's own gate arm: it discovers the profile (a miss is
# FATAL, never silent), does the full enable, and leaves 148 in mode-1 internal loopback
# decoding ROM at ~1248 f/s with capTAP golden. seqbist_run.sh then flips 0x158=1 for TGEN.
#
# PHASE=knee     -> the two knee-bracket gaps, 60 s each
# PHASE=controls -> ctrlB (CORRUPT_EVERY=1000, 180 s) then the clean 600 s leg
# GAP is required for PHASE=controls (the chosen mission gap).
# =============================================================================
set -u
S=$(cd "$(dirname "$0")" && pwd); D=$(cd "$S/.." && pwd)
PHASE=${PHASE:?PHASE=knee|controls}
GAP=${GAP:-0}
log(){ echo "$(date -Is) [armed] $*"; }

log "=== full arm (arm148_mode1.sh) before PHASE=$PHASE ==="
AOUT=$(bash "$D/arm148_mode1.sh" 2>&1); ARC=$?
echo "$AOUT" | tail -3
if ! echo "$AOUT" | grep -q ARM_OK; then
  log "ARMED_LEGS_ABORT: arm148_mode1.sh did not report ARM_OK (rc=$ARC) -- refusing to run legs"
  log "  on an unarmed board; that would just reproduce the NEEDS_ARM signature."
  echo "ARMED_LEGS_ABORT_ARM"; exit 4
fi
FPS=$(echo "$AOUT" | sed -n 's/.*fps=\([0-9]*\).*/\1/p' | tail -1)
log "arm OK, fps=$FPS"

RC=0
run_leg(){ # $1=tag, rest=env assignments
  local tag=$1; shift
  log "--- leg $tag: $* ---"
  env "$@" DRY=0 BOARD=148 MODE=loopback FILL=1516 SINK=tgenrx TAG="$tag" \
      bash "$S/seqbist_run.sh"
  local rc=$?
  log "--- leg $tag rc=$rc ---"
  [ "$rc" = 0 ] || RC=$rc
  return 0
}

case "$PHASE" in
  knee)
    run_leg knee45 GAP=45000 DUR=60 WINDOW_MIN=30
    run_leg knee60 GAP=60000 DUR=60 WINDOW_MIN=30
    ;;
  controls)
    [ "$GAP" -gt 0 ] || { log "ARMED_LEGS_ABORT: PHASE=controls needs GAP=<mission>"; exit 3; }
    run_leg ctrlB  GAP=$GAP DUR=180 CORRUPT_EVERY=1000 WINDOW_MIN=150
    run_leg clean  GAP=$GAP DUR=600 WINDOW_MIN=550
    ;;
  *) log "unknown PHASE=$PHASE"; exit 2 ;;
esac
log "=== PHASE=$PHASE done rc=$RC ==="
exit $RC
