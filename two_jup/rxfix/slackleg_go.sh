#!/bin/bash
# slackleg_go.sh -- RXFIX Task 3 (T0c, happy-bubbling-owl): a capture_r3 FORWARD leg
# (LEG=A, 146 TX -> 148 RX) with the Preamble_Detector realignment FIFO's runtime
# slack bit (enSlack = fixctl bit 3, modem register 0x208, Validate_Input_Push_Pop.v:136
# / FixCtlDec.v:34,42 / addr_decoder.v:869) set on BOTH boards after the RF arm and
# before the scored window, restored under a trap. This is T1's instrument: T1 runs
# SLACK=0 (control, expect the ~8% comb) then SLACK=1 (enSlack ON) and compares.
#
# fixctl (0x208) IS WRITE-ONLY per the address decoder (confirmed: no read_fixctl
# input anywhere in TxRxCompo_ip_addr_decoder.v) -- there is no register readback to
# verify against, and fixctl is shared with other bits (e.g. bit13 selects the DBGCAP
# capture source, TxRxCompo_ip_src_QPSK_Rx.v:816,818), so this script cannot
# read-modify-write against silicon. It keeps a SHADOW of the intended value
# (FIXCTL_SHADOW below) and writes the full absolute value each time (0x0 or 0x8),
# which is what the brief specifies. The pre-window rate/health line legrun_go.sh
# already captures (RATE_PRE/RATE_POST in meta.txt) is the effect witness in place of
# a readback -- if enSlack changes delivery behaviour, the leg's own gate reflects it.
#
# TWO DIFFERENT INSERTION MECHANISMS -- read capture_r3.sh section 5b-5d before
# changing this script:
#   148 (RX board on a LEG=A forward leg): capture_r3.sh:209-217 (5b LOOP_POKE) is
#     ALREADY a clean, existing insertion point -- a generic direct_reg_access k=v
#     poke on the RX board, applied AFTER the wedge re-arms/health gate and BEFORE
#     the framelog rotate that starts the scored window (same position section 5c's
#     RX_ATTR_POKE uses for the ADRV9002 phy, just a DRA register instead of a sysfs
#     attribute). We reuse it VERBATIM: LOOP_POKE="0x208=<val>" exported before
#     calling legrun_go.sh, which execs capture_r3.sh without clearing the caller's
#     environment (`env "${CAP_ENV[@]}" ...` only adds/overrides the listed vars), so
#     LOOP_POKE reaches capture_r3.sh unchanged. NO EDIT to capture_r3.sh or
#     legrun_go.sh was needed or made.
#   146 (peer/TX board on a LEG=A leg): NO equivalent hook exists. capture_r3.sh has
#     PEER_ATTR_POKE (5d) but that is the ADRV9002 sysfs-attribute path, not
#     direct_reg_access -- there is no "PEER_LOOP_POKE".
#
#     TIMING (review fix round 1, I-1): the PRIOR version cited "radioprobe_go.sh's
#     model" for a fixed WAIT_146=20s settle. That citation was wrong -- read
#     radioprobe_go.sh: it has no sleep/wait/timed-poke anywhere; its peer probe
#     (PROBE=D) lands via capture_r3.sh's own in-script PEER_ATTR_POKE hook (5d), not
#     an external timer. There is no precedent in this codebase for an external timed
#     poke, and an asserted 20s was not shown to land before the window opens.
#
#     Walking capture_r3.sh's own sequence instead (the brief's instruction): the
#     "  wedge verdict: $WEDGE_NOTE" line (capture_r3.sh:198) is printed the INSTANT
#     the health gate resolves, and section 5b's LOOP_POKE (:211, the SAME hook this
#     script uses for 148) fires immediately after it, before the framelog rotate
#     (:273), the CAP_SETTLE sleep, and the Tap-A capture (:296) that precede the
#     "${LEFT}s traffic remaining" watchdog line (:316) which is the closest thing to
#     a "window open" marker downstream. So: trigger 146's write on the SAME
#     capture_r3.log marker ("wedge verdict:") that opens 148's LOOP_POKE window --
#     option 1 from the review, which also satisfies option 2 (>=5s before "traffic
#     remaining") by construction, since it fires strictly earlier than 148's own poke
#     completes. No WAIT_146 settle is added; the write races 148's poke, which is
#     correct -- both boards' fixctl should change together, not one before the other
#     by an arbitrary margin. peer_poke.log records the trigger timestamp so a real T1
#     run can be audited against capture_r3.log's own LOOP_POKE timestamp after the
#     fact.
#
#     Implemented as a TIMED ACTION (background watcher on capture_r3.log), not an
#     edit to capture_r3.sh: this script waits for "wedge verdict:" to appear, then
#     writes 0x208 on 146 directly via anyssh.sh direct_reg_access -- the same
#     primitive LOOP_POKE uses inside capture_r3.sh, just invoked from this wrapper.
#
# RESTORE IS INSIDE THIS SCRIPT, UNDER A TRAP on EXIT/INT/TERM (systemd stops a unit
# with SIGTERM -- see launch_rig_unit.sh), same discipline as radioprobe_go.sh /
# whiten_leg_go.sh: fixctl=0x0 written on BOTH boards, reverse order of the poke
# (146 first, then 148), idempotent, safe to call twice. Because 0x208 cannot be read
# back, "restored" here means "the restore write was issued and its exit status was
# 0", not a verified value -- meta.txt says so explicitly (fixctl_restored=).
#
# RACE FIX (review fix round 1, C-1): on a mid-window SIGTERM the trap used to write
# the restores WITHOUT first stopping the backgrounded 146 peer-write watcher
# (PEER_PID), so a peer write already dispatched or still asleep in its wait loop
# could land AFTER the restore wrote fixctl=0x0 to 146, silently re-arming the probe
# state even though meta.txt reported fixctl_restored=1. restore() now kills and
# waits on $PEER_PID FIRST, unconditionally, before issuing either restore write, in
# both the trap path and the normal-completion path (where the kill is a harmless
# no-op since the watcher already exited on its own via `wait "$PEER_PID"` earlier in
# the script).
#
# K=V: SLACK=0|1 (required)   DUR=600   DRY=1(default)   TAG=<tag>   OUT=<dir>
#      PEER_POKE_TEST_SLEEP=<secs>  TEST SEAM ONLY (see peer_poke_bg below) -- makes
#      the 146 watcher a plain `sleep` instead of watching capture_r3.log, so the
#      kill+wait+restore-order path can be tested deterministically without a leg
#      ever reaching its health gate. Never set on a real leg.
#
# DRY=1 (default): NO ssh/scp of any kind. legrun_go.sh's own DRY fast-path already
# never invokes capture_r3.sh (so LOOP_POKE is never actually evaluated by silicon in
# DRY -- there is nothing there to evaluate); this wrapper mirrors that by logging the
# two intended pokes (148 via LOOP_POKE, 146 via direct anyssh.sh) and the two
# intended restores as [dry] plan lines, in the real ordering, and by never launching
# the background 146-write watcher for real (no sleep, no ssh) -- so the SIGTERM race
# this task fixes is DRY-unreachable by construction; the new test exercises it with
# DRY=0 + a shimmed ssh + PEER_POKE_TEST_SLEEP instead (see test file).
set -u
D=$(cd "$(dirname "$0")" && pwd)          # two_jup/rxfix
TJ=$(cd "$D/.." && pwd)                   # two_jup
COMB=$TJ/comb
W=$TJ/anyssh.sh
DRY=${DRY:-1}
SLACK=${SLACK:?usage: SLACK=0|1 slackleg_go.sh}
DUR=${DUR:-600}
A_IP=10.0.0.148; B_IP=10.0.0.146   # 148=RX (LOOP_POKE target), 146=peer/TX (timed-action target)

case "$SLACK" in
  0) FIXVAL=0x0 ;;
  1) FIXVAL=0x8 ;;
  *) echo "SLACK must be 0 or 1" >&2; exit 2 ;;
esac
FIXCTL_SHADOW=$FIXVAL   # the value we BELIEVE is live on both boards; never read back

TS=$(date +%Y%m%d_%H%M%S)
TAG=${TAG:-slack$SLACK}
OUT=${OUT:-$D/runs/${TS}_slack${SLACK}_${TAG}}
mkdir -p "$OUT"
log(){ echo "$(date -Is) $*" | tee -a "$OUT/run.log"; }
log "=== slackleg_go.sh: SLACK=$SLACK fixctl=$FIXVAL dur=$DUR dry=$DRY -> $OUT ==="

# ---------------------------------------------------------------------------
# background: peer (146) write, triggered on the same capture_r3.log marker
# ("wedge verdict:") that fires 148's LOOP_POKE inside capture_r3.sh's own
# timeline. Started BEFORE legrun so it can watch the leg's own log as it appears.
# ---------------------------------------------------------------------------
PEER_PID=""
peer_poke_bg(){
  # TEST SEAM (PEER_POKE_TEST_SLEEP): see the K=V doc above. Real legs never set this.
  if [ -n "${PEER_POKE_TEST_SLEEP:-}" ]; then
    echo "$(date -Is) TEST SEAM: peer_poke_bg faked as sleep ${PEER_POKE_TEST_SLEEP}s (PEER_POKE_TEST_SLEEP set)" >> "$OUT/peer_poke.log"
    sleep "$PEER_POKE_TEST_SLEEP"
    echo "$(date -Is) TEST SEAM: fake sleep finished WITHOUT being killed -- this run did not exercise the race" >> "$OUT/peer_poke.log"
    return 0
  fi
  local leglog="$OUT/capture_r3.log"
  local waited=0 max=420
  while :; do
    [ -f "$leglog" ] && grep -q "wedge verdict:" "$leglog" 2>/dev/null && break
    waited=$((waited+2)); [ "$waited" -ge "$max" ] && { echo "$(date -Is) PEER_POKE_ABORT: no health-gate line within ${max}s" >> "$OUT/peer_poke.log"; return 1; }
    sleep 2
  done
  echo "$(date -Is) 146 fixctl=$FIXVAL (triggered on the 'wedge verdict:' marker -- the same event that fires 148's LOOP_POKE -- so this lands strictly before capture_r3.sh's framelog rotate/Tap-A capture/traffic window)" >> "$OUT/peer_poke.log"
  $W "$B_IP" "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; echo '0x208 $FIXVAL'>\$DRA" >>"$OUT/peer_poke.log" 2>&1
  echo "$(date -Is) 146 fixctl write exit=$?" >> "$OUT/peer_poke.log"
}
if [ "$DRY" = 1 ]; then
  log "[dry] poke plan: 1) 148 fixctl=$FIXVAL via LOOP_POKE (capture_r3.sh:209-217, on the 'wedge verdict:' marker, before window)"
  log "[dry] poke plan: 2) 146 fixctl=$FIXVAL on the SAME 'wedge verdict:' marker via anyssh.sh direct_reg_access (no clean in-script hook for the peer board)"
else
  peer_poke_bg & PEER_PID=$!
  log "peer (146) write watcher started (pid $PEER_PID), waiting on $OUT/capture_r3.log for 'wedge verdict:'"
fi

# ---------------------------------------------------------------------------
# restore (idempotent, trap-guarded). ALWAYS kills+waits the peer watcher FIRST
# (C-1 fix), then writes restores in reverse poke order: 146 then 148.
# ---------------------------------------------------------------------------
RESTORE_DONE=0
RESTORE_146_OK=0; RESTORE_148_OK=0
restore(){
  [ "$RESTORE_DONE" = 1 ] && return 0
  RESTORE_DONE=1
  if [ -n "$PEER_PID" ]; then
    log "restore: stopping the peer (146) write watcher (pid $PEER_PID) BEFORE issuing any restore write, so an in-flight or still-sleeping 146 poke cannot land after the restore"
    kill "$PEER_PID" 2>/dev/null
    wait "$PEER_PID" 2>/dev/null
    PEER_PID=""
  fi
  if [ "$DRY" = 1 ]; then
    log "[dry] restore plan: 1) 146 fixctl=0x0 (direct_reg_access) 2) 148 fixctl=0x0 (direct_reg_access)"
    RESTORE_146_OK=1; RESTORE_148_OK=1
    return 0
  fi
  log "RESTORE 1/2: 146 fixctl=0x0"
  if $W "$B_IP" "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; echo '0x208 0x0'>\$DRA" >>"$OUT/restore_146.log" 2>&1; then
    RESTORE_146_OK=1
  else
    log "!!! RESTORE FAILED on 146 (fixctl may still be $FIXCTL_SHADOW) -- see restore_146.log"
  fi
  log "RESTORE 2/2: 148 fixctl=0x0"
  if $W "$A_IP" "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; echo '0x208 0x0'>\$DRA" >>"$OUT/restore_148.log" 2>&1; then
    RESTORE_148_OK=1
  else
    log "!!! RESTORE FAILED on 148 (fixctl may still be $FIXCTL_SHADOW) -- see restore_148.log"
  fi
  FIXCTL_SHADOW=0x0
  if [ "$RESTORE_146_OK" = 1 ] && [ "$RESTORE_148_OK" = 1 ]; then
    log "RESTORE ISSUED on both boards (exit 0; UNVERIFIED -- 0x208 is write-only, no readback exists)"
  else
    log "!!! RESTORE NOT FULLY ISSUED -- a board may be left with fixctl=$FIXCTL_SHADOW, see restore_*.log"
  fi
}
trap restore EXIT INT TERM

# ---------------------------------------------------------------------------
# stage3h_reader.sh on 148, during the window (background; joins before scoring)
# ---------------------------------------------------------------------------
S3H_OUT=$OUT/s3h
S3H_PID=""
if [ "$DRY" = 1 ]; then
  log "[dry] stage3h_reader.sh plan: BOARD=148 LEGLOG=$OUT/capture_r3.log OUT=$S3H_OUT DUR=$((DUR>120?DUR-60:DUR)) DRY=1"
else
  DRY=0 BOARD=148 LEGLOG="$OUT/capture_r3.log" OUT="$S3H_OUT" DUR=$((DUR>120?DUR-60:DUR)) \
    "$TJ/seqbist/stage3h_reader.sh" > "$OUT/stage3h_wrapper.log" 2>&1 &
  S3H_PID=$!
  log "stage3h_reader.sh started (pid $S3H_PID) -> $S3H_OUT"
fi

# ---------------------------------------------------------------------------
# the leg itself: legrun_go.sh LEG=A, with LOOP_POKE exported so capture_r3.sh's
# own 5b hook lands the 148 write at the right point in ITS timeline.
# ---------------------------------------------------------------------------
export LOOP_POKE="0x208=$FIXVAL"
log "leg: LEG=A DUR=$DUR OUT=$OUT (LOOP_POKE=$LOOP_POKE exported for capture_r3.sh's 5b hook)"
LEG_RC=0
DRY=$DRY LEG=A DUR=$DUR TAG="$TAG" OUT="$OUT" "$COMB/legrun_go.sh" || LEG_RC=$?
log "legrun_go.sh exit=$LEG_RC"

# join the background jobs (normal-completion path; restore()'s own kill+wait makes
# this safe to skip on a signal -- it is never reached in that case)
if [ -n "$PEER_PID" ]; then wait "$PEER_PID" 2>/dev/null; log "peer (146) write watcher joined"; fi
if [ -n "$S3H_PID" ]; then wait "$S3H_PID" 2>/dev/null; log "stage3h_reader.sh joined"; fi

# restore now (before final meta), trap re-call is a no-op
restore

LEG_META=""
[ -f "$OUT/meta.txt" ] && LEG_META=$(cat "$OUT/meta.txt")

{
  echo "$LEG_META"
  echo "slack=$SLACK"
  echo "fixctl_written=$FIXVAL"
  echo "fixctl_restored=$([ "$RESTORE_146_OK" = 1 ] && [ "$RESTORE_148_OK" = 1 ] && echo 1 || echo 0) (write issued+exit0 on both boards; UNVERIFIED, 0x208 is write-only)"
  echo "peer_poke_trigger=wedge_verdict_marker (same event that fires 148's LOOP_POKE; no fixed settle)"
  echo "stage3h_out=$S3H_OUT"
  echo "leg_exit=$LEG_RC"
  echo "ts=$(date -Is)"
} > "$OUT/meta.txt"
cat "$OUT/meta.txt"

if [ "$LEG_RC" = 0 ]; then
  echo "SLACKLEG_DONE $OUT"
else
  echo "SLACKLEG_GATE_FAIL $OUT (legrun_go.sh exit=$LEG_RC -- treat as UNINFORMATIVE)"
  exit 3
fi
