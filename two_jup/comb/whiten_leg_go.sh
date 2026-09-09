#!/bin/bash
# =============================================================================
# whiten_leg_go.sh -- the pre-registered host-WHITENING fix-candidate leg
# (coordinator ruling 2026-09-04, content-locked framing-slip lead).
#
# HYPOTHESIS: the TX scrambler is hard-disabled (HDL_Data_Scrambler.v:71), there is no
# RX descrambler, and the campaign runs host whitening OFF (bringup_r2r3.sh:53
# WHITEN=0), so payload bytes reach the air un-randomised. qpsk_perf's periodic
# payload then re-aligns a fatal byte pattern with the frame boundary every ~32.4
# frames = 26 ms, which is the on-air comb. Turning host whitening ON randomises the
# payload and should destroy that alignment.
# PREDICTION: forward PER 8.1 % -> <= 1 %, and the 26 ms line gone (lag-32 < 0.1).
# FALSIFIER: PER unchanged in the 7.6-8.6 % null band.
#
# WHITENING IS BOTH-ENDS-OR-NOTHING: qpsk_frame.c:88-92 -- "a whitened build
# interoperates only with another whitened build (set QPSK_WHITEN on BOTH ends)".
# bringup_r2r3.sh passes the same $WHITEN to both boards' start_daemon, so one
# WHITEN=1 covers both; this script verifies it on both boards rather than assuming.
#
# THREE THINGS THIS SCRIPT EXISTS TO GET RIGHT:
#
# 1. PRECONDITION -- the fabric SINK must be OFF. The SEQ-BIST legs arm
#    qpsk_traffic_gen_rx2 (0x9D410000 bit0), which holds dut_ready HIGH and
#    CONSUMES AND DISCARDS the DUT RX stream at the seam. Left armed, the daemon
#    would receive nothing and the leg would read as catastrophic loss for an
#    entirely self-inflicted reason. Likewise TGEN (0x9D400000 bit0) must be off or
#    it injects frames into the TX byte plane alongside the daemon. Both are checked
#    on 148 and the leg REFUSES rather than producing a garbage number.
#
# 2. VERIFICATION -- qpsk_tun has no startup banner naming its whitening state
#    (qpsk_frame.c:94-102 reads QPSK_WHITEN once, silently), and the env prefix is
#    not in the process cmdline, so `ps` cannot show it and neither can
#    capture_r3.log. The only ground truth is /proc/<pid>/environ, read on BOTH
#    boards while the daemons are actually running (mid-leg, ~90 s in).
#
# 3. WATCHDOG SURVIVAL -- bringup_r2r3.sh:209 builds the watchdog's relaunch string
#    WITHOUT QPSK_WHITEN, so a mid-leg relaunch would silently restart an
#    UN-whitened daemon. legrun_go.sh counts relaunches and flags the leg
#    UNINFORMATIVE, which covers it; belt-and-braces, this script also puts
#    QPSK_WHITEN into DAEMON_ENV via legrun_go.sh's WHITEN_DENV hook so the
#    relaunch string carries it too.
#
# Env: DUR=600 LEG=A DRY=1 (default)
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)          # two_jup/comb
TJ=$(cd "$D/.." && pwd)
W=$TJ/anyssh.sh
A=10.0.0.148; B=10.0.0.146
DUR=${DUR:-600}
LEG=${LEG:-A}
DRY=${DRY:-1}
log(){ echo "$(date -Is) [whiten] $*"; }

log "=== whitening fix-candidate leg: LEG=$LEG DUR=$DUR DRY=$DRY ==="

# ---- 1. preconditions on 148: fabric injectors OFF -------------------------
if [ "$DRY" = 1 ]; then
  log "[dry] would verify 148: TGEN 0x9D400000 bit0 == 0 AND tgen_rx 0x9D410000 bit0 == 0"
else
  PRE=$($W $A 'DM=$(command -v devmem || echo "busybox devmem"); echo "tgen=$($DM 0x9D400000) tgenrx=$($DM 0x9D410000)"' 2>/dev/null | tr -d '\r')
  log "148 injector state: $PRE"
  case "$PRE" in
    *tgen=*) : ;;
    *) log "WHITEN_ABORT: could not read 148 injector state (ssh empty)"; echo "WHITEN_ABORT_UNREACHABLE"; exit 3 ;;
  esac
  TG=$(printf %s "$PRE" | sed -n 's/.*tgen=\([^ ]*\).*/\1/p'); TG=$((TG))
  TR=$(printf %s "$PRE" | sed -n 's/.*tgenrx=\([^ ]*\).*/\1/p'); TR=$((TR))
  if [ $(( TG & 1 )) -ne 0 ]; then
    log "WHITEN_ABORT: TGEN still enabled (0x9D400000=$TG) -- it would inject into the TX byte plane"
    echo "WHITEN_ABORT_TGEN_ON"; exit 4
  fi
  if [ $(( TR & 1 )) -ne 0 ]; then
    log "WHITEN_ABORT: fabric SINK still armed (0x9D410000 bit0, =$TR) -- it consumes+discards the"
    log "  DUT RX stream at the seam, so the daemon would receive nothing. Refusing."
    echo "WHITEN_ABORT_SINK_ARMED"; exit 5
  fi
  log "preconditions OK: TGEN off, sink disarmed"
fi

# ---- 2. launch the leg with WHITEN=1 ---------------------------------------
OUT=${OUT:-$D/runs/$(date +%Y%m%d_%H%M%S)_legA_whiten}
mkdir -p "$OUT"
log "launching legrun_go.sh LEG=$LEG DUR=$DUR WHITEN=1 -> $OUT"
if [ "$DRY" = 1 ]; then
  DRY=1 LEG=$LEG DUR=$DUR OUT=$OUT WHITEN=1 WHITEN_DENV="QPSK_WHITEN=1" bash "$D/legrun_go.sh" &
else
  DRY=0 LEG=$LEG DUR=$DUR OUT=$OUT WHITEN=1 WHITEN_DENV="QPSK_WHITEN=1" bash "$D/legrun_go.sh" &
fi
LEGPID=$!

# ---- 3. mid-leg verification on BOTH boards --------------------------------
verify_board(){ # $1 = ip
  $W "$1" 'P=$(pgrep -x qpsk_tun | head -1)
    if [ -z "$P" ]; then echo "NO_DAEMON"; else
      V=$(tr "\0" "\n" < /proc/$P/environ 2>/dev/null | grep "^QPSK_WHITEN=" | head -1)
      echo "pid=$P ${V:-QPSK_WHITEN=<unset>}"
    fi' 2>/dev/null | tr -d '\r'
}
if [ "$DRY" = 1 ]; then
  log "[dry] would sleep 90 then read /proc/<qpsk_tun>/environ on $A and $B for QPSK_WHITEN"
  V148="pid=1 QPSK_WHITEN=1"; V146="pid=1 QPSK_WHITEN=1"
else
  sleep 90
  V148=$(verify_board $A); V146=$(verify_board $B)
fi
log "WHITEN_VERIFY 148: $V148"
log "WHITEN_VERIFY 146: $V146"
OK148=0; OK146=0
case "$V148" in *QPSK_WHITEN=1*) OK148=1 ;; esac
case "$V146" in *QPSK_WHITEN=1*) OK146=1 ;; esac
log "WHITEN_VERIFIED_148=$OK148 WHITEN_VERIFIED_146=$OK146"
if [ "$OK148" != 1 ] || [ "$OK146" != 1 ]; then
  log "WARNING: whitening NOT confirmed on both boards -- this leg is UNINFORMATIVE as a"
  log "  fix-candidate test regardless of the PER it produces (both ends must whiten:"
  log "  qpsk_frame.c:88-92). Letting the leg finish so the rig is left in a known state."
fi

wait $LEGPID; LRC=$?
log "legrun_go.sh exit=$LRC"
echo "whiten_verified_148=$OK148 whiten_verified_146=$OK146 leg_rc=$LRC out=$OUT" > "$OUT/whiten_meta.txt"
log "WHITEN_LEG_DONE out=$OUT verified=${OK148}${OK146} rc=$LRC"
echo "WHITEN_LEG_DONE $OUT"
[ "$OK148" = 1 ] && [ "$OK146" = 1 ] || exit 6
exit $LRC
