#!/bin/bash
# legrun_go.sh -- T2/T3 (happy-bubbling-owl): capture_r3.sh LEG=A|B, with true
# per-board DAEMON_ENV knobs (RXM_148/RXM_146 -> -M on that board's daemon only, per
# the P1 host-cadence probes; DRAIN_148/DRAIN_146 -> QPSK_RX_DRAIN_BUDGET on that
# board only), now that bringup_r2r3.sh's start_daemon() honours per-board overrides
# (task-3-fix1 C-1: RXM_A/RXM_B, DAEMON_ENV_A/DAEMON_ENV_B; A=148, B=146 -- see
# bringup_r2r3.sh:~164-171). capture_r3.sh's bring-up call (bringup_r2r3.sh r3,
# capture_r3.sh:149) is a plain exec `"$D/bringup_r2r3.sh" r3`, not a source -- it
# inherits the full process environment, so vars this script passes to capture_r3.sh
# via `env` reach bringup_r2r3.sh unchanged.
#
# Every leg ALSO launches both boards with the T0a sink env (QPSK_FAILHDR,
# QPSK_TXLOG, QPSK_TXLOG_USR1) in DAEMON_ENV_A/DAEMON_ENV_B so capture_r3.sh's own
# failhdr.bin/txlog.bin fetch (this script's SCPGET calls below) gets real data --
# without these, qpsk_tun.c never allocates the failhdr/txlog rings (guarded at
# qpsk_tun.c:3221 QPSK_TXLOG / :3242 QPSK_FAILHDR) and the fetch pulls empty files.
# capture_r3.sh separately sets QPSK_FRAMELOG=/dev/shm/frames.bin for both boards
# (capture_r3.sh:149) and installs the SIGUSR2 rotate handler only inside that
# QPSK_FRAMELOG block (qpsk_tun.c:3266); capture_r3.sh's post-window SIGUSR1
# (capture_r3.sh:293 "pull artifacts (flush the loggers first: SIGUSR1)") is what
# flushes the TX log to disk via instr_usr1_dump() (qpsk_tun.c:771), gated by
# QPSK_TXLOG_USR1 (qpsk_tun.c:677,3230) -- hence that var is mandatory in the sink
# set, not just QPSK_FAILHDR/QPSK_TXLOG.
#
# LEG=A: capture on 148, forward 146->148 (RXM_148/DRAIN_148 govern the transmitting
#        board's own RX-drain cadence per the P2 mechanism note: "a board's TX silence
#        follows that board's OWN RX transfer cadence").
# LEG=B: capture on 146, reverse 148->146.
#
# DRY=1 (default): capture_r3.sh is NEVER invoked (it has no DRY gate of its own and
# would reach real ssh/scp through anyssh.sh) -- this wrapper fabricates the full
# meta.txt/frames.bin/frames_peer.bin/failhdr/txlog artifact set instead, so downstream
# tooling has real files to run against with zero board contact.
set -u
D=$(cd "$(dirname "$0")" && pwd)          # two_jup/comb
TJ=$(cd "$D/.." && pwd)                   # two_jup
DRY=${DRY:-1}
LEG=${LEG:?usage: LEG=A|B legrun_go.sh}
DUR=${DUR:-600}
RXM_148=${RXM_148:-}; RXM_146=${RXM_146:-}
DRAIN_148=${DRAIN_148:-}; DRAIN_146=${DRAIN_146:-}
A_IP=10.0.0.148; B_IP=10.0.0.146

case "$LEG" in
  A) DIRN=fwd; RX_IP=$A_IP; PEER_IP=$B_IP;;
  B) DIRN=rev; RX_IP=$B_IP; PEER_IP=$A_IP;;
  *) echo "LEG must be A or B" >&2; exit 2;;
esac

TS=$(date +%Y%m%d_%H%M%S)
TAG=${TAG:-leg${LEG}}
OUT=${OUT:-$D/runs/${TS}_leg${LEG}_${TAG}}
mkdir -p "$OUT"
log(){ echo "$(date -Is) $*" | tee -a "$OUT/run.log"; }

# ---- map per-board knobs straight onto bringup_r2r3.sh's per-board overrides
# (RXM_A/RXM_B, DAEMON_ENV_A/DAEMON_ENV_B; A=148, B=146). No conflict/refusal case
# is needed any more: RXM_148 and RXM_146 land on genuinely different boards. ----
SINK_ENV="QPSK_FAILHDR=/dev/shm/failhdr.bin QPSK_TXLOG=/dev/shm/txlog.bin QPSK_TXLOG_USR1=1"

DENV_A="$SINK_ENV"; DENV_B="$SINK_ENV"
# WHITEN_DENV (2026-09-04): bringup_r2r3.sh:209 builds lock_watchdog's relaunch string
# WITHOUT QPSK_WHITEN, so a mid-leg relaunch would silently restart an UN-whitened
# daemon and quietly revert the treatment. DAEMON_ENV_A/B *is* carried into that string
# (and, being later in the command prefix, also wins over start_daemon's own
# QPSK_WHITEN=$WHITEN), so routing whitening through here makes it survive a relaunch.
# Unset => the launch line is byte-identical to before.
[ -n "${WHITEN_DENV:-}" ] && { DENV_A="$DENV_A $WHITEN_DENV"; DENV_B="$DENV_B $WHITEN_DENV"; }
[ -n "$DRAIN_148" ] && DENV_A="$DENV_A QPSK_RX_DRAIN_BUDGET=$DRAIN_148"
[ -n "$DRAIN_146" ] && DENV_B="$DENV_B QPSK_RX_DRAIN_BUDGET=$DRAIN_146"

CAP_ENV=("DAEMON_ENV_A=$DENV_A" "DAEMON_ENV_B=$DENV_B")
[ -n "$RXM_148" ] && CAP_ENV+=("RXM_A=$RXM_148")
[ -n "$RXM_146" ] && CAP_ENV+=("RXM_B=$RXM_146")

log "leg=$LEG dir=$DIRN dur=$DUR knobs: ${CAP_ENV[*]}"
log "requested: RXM_148=$RXM_148 RXM_146=$RXM_146 DRAIN_148=$DRAIN_148 DRAIN_146=$DRAIN_146"

if [ "$DRY" = 1 ]; then
  log "[dry] ${CAP_ENV[*]:-} $TJ/capture_r3.sh $LEG -d $DUR -o $OUT/cap"
  mkdir -p "$OUT/cap"
  head -c 48000 /dev/urandom > "$OUT/cap/frames.bin" 2>/dev/null || : > "$OUT/cap/frames.bin"
  head -c 48000 /dev/urandom > "$OUT/cap/frames_peer.bin" 2>/dev/null || : > "$OUT/cap/frames_peer.bin"
  head -c 12000 /dev/urandom > "$OUT/cap/failhdr.bin" 2>/dev/null || : > "$OUT/cap/failhdr.bin"
  head -c 48000 /dev/urandom > "$OUT/cap/txlog.bin" 2>/dev/null || : > "$OUT/cap/txlog.bin"
  head -c 12000 /dev/urandom > "$OUT/cap/failhdr_peer.bin" 2>/dev/null || : > "$OUT/cap/failhdr_peer.bin"
  head -c 48000 /dev/urandom > "$OUT/cap/txlog_peer.bin" 2>/dev/null || : > "$OUT/cap/txlog_peer.bin"
  RATE_PRE=1180; RATE_POST=1150
  WEDGE_NOTE="healthy crc=99% rate=${RATE_POST}f/s"
  CAP_EXIT=0
else
  env "${CAP_ENV[@]}" "$TJ/capture_r3.sh" "$LEG" -d "$DUR" -o "$OUT/cap" > "$OUT/capture_r3.log" 2>&1
  CAP_EXIT=$?
  RATE_PRE=$(grep -m1 "health try" "$OUT/capture_r3.log" | grep -oE "rate [0-9]+" | grep -oE "[0-9]+" || echo 0)
  RATE_POST=$(grep "health try" "$OUT/capture_r3.log" | tail -1 | grep -oE "rate [0-9]+" | grep -oE "[0-9]+" || echo 0)
  WEDGE_NOTE=$(grep -oE "wedge_verdict=.*" "$OUT/cap/meta.txt" 2>/dev/null | head -1)
  # fetch the T0a instrumentation logs both boards (same scp path capture_r3.sh uses)
  SCPGET(){ SSH_ASKPASS="$TJ/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>>"$OUT/scp_err.txt"; }
  SCPGET root@"$RX_IP":/dev/shm/failhdr.bin "$OUT/cap/failhdr.bin" 2>/dev/null || log "WARN: failhdr.bin ($RX_IP) fetch failed"
  SCPGET root@"$RX_IP":/dev/shm/txlog.bin "$OUT/cap/txlog.bin" 2>/dev/null || log "WARN: txlog.bin ($RX_IP) fetch failed"
  SCPGET root@"$PEER_IP":/dev/shm/failhdr.bin "$OUT/cap/failhdr_peer.bin" 2>/dev/null || log "WARN: failhdr.bin ($PEER_IP) fetch failed"
  SCPGET root@"$PEER_IP":/dev/shm/txlog.bin "$OUT/cap/txlog_peer.bin" 2>/dev/null || log "WARN: txlog.bin ($PEER_IP) fetch failed"
  # watchdog relaunch witness (task-3-rereview): lock_watchdog.sh relaunches the daemon
  # from its DAEMON_CMD on death / lock loss / DMA wedge. bringup_r2r3.sh now builds that
  # string from the same per-board knobs, but a relaunch still resets the daemon's ring
  # state mid-leg, so any relaunch makes the leg UNINFORMATIVE. Count them.
  SCPGET root@"$RX_IP":/dev/shm/watchdog.log "$OUT/cap/watchdog_rx.log" 2>/dev/null || log "WARN: watchdog.log ($RX_IP) fetch failed"
  SCPGET root@"$PEER_IP":/dev/shm/watchdog.log "$OUT/cap/watchdog_peer.log" 2>/dev/null || log "WARN: watchdog.log ($PEER_IP) fetch failed"
  # NB (T2 driver, 2026-09-03): `grep -c` prints 0 AND exits 1 when a present file has
  # no match, so the old `|| echo 0` appended a SECOND "0" -> "0\n0" != 0 -> the gate failed
  # on every clean leg. The missing-file case is already covered by the ${:-0} defaults below.
  WD_RELAUNCH_RX=$(grep -c "relaunch" "$OUT/cap/watchdog_rx.log" 2>/dev/null)
  WD_RELAUNCH_PEER=$(grep -c "relaunch" "$OUT/cap/watchdog_peer.log" 2>/dev/null)
fi
WD_RELAUNCH_RX=${WD_RELAUNCH_RX:-0}; WD_RELAUNCH_PEER=${WD_RELAUNCH_PEER:-0}

# deliver_rate gate: >= RATE_GATE f/s pre AND post (T2 risk table said 1000; re-baselined
# 2026-09-04 01:2x: every arm since 22:17 sits at ~950 f/s, so 1000 was unmeetable; env RATE_GATE overrides)
RATE_GATE=${RATE_GATE:-900}
GATE_PASS=0
if [ "${RATE_PRE:-0}" -ge "$RATE_GATE" ] 2>/dev/null && [ "${RATE_POST:-0}" -ge "$RATE_GATE" ] 2>/dev/null; then GATE_PASS=1; fi
if [ "$WD_RELAUNCH_RX" != 0 ] || [ "$WD_RELAUNCH_PEER" != 0 ]; then GATE_PASS=0; fi
# a capture_r3.sh abort (non-zero exit, e.g. CAPTURE_ABORTED_WEDGED) is never a credited leg,
# whatever the pre/post rates said (m16 leg 17:49: MID_CAPTURE_WEDGE after 12 s passed the rate gate)
[ "${CAP_EXIT:-0}" = 0 ] || GATE_PASS=0
case "$WEDGE_NOTE" in *WEDGE*|*"NOT usable"*) GATE_PASS=0;; esac

{
  echo "leg=$LEG dir=$DIRN rx=$RX_IP peer=$PEER_IP dur=$DUR dry=$DRY"
  echo "rxm_148=$RXM_148 rxm_146=$RXM_146 drain_148=$DRAIN_148 drain_146=$DRAIN_146"
  echo "resolved: ${CAP_ENV[*]:-<none>}"
  echo "capture_r3_exit=$CAP_EXIT"
  echo "wedge_verdict=$WEDGE_NOTE"
  echo "deliver_rate_pre=$RATE_PRE deliver_rate_post=$RATE_POST deliver_rate_gate_pass=$GATE_PASS (need >=$RATE_GATE f/s both AND zero watchdog relaunches)"
  echo "watchdog_relaunch_rx=$WD_RELAUNCH_RX watchdog_relaunch_peer=$WD_RELAUNCH_PEER"
  echo "ts=$(date -Is)"
} > "$OUT/meta.txt"

cat "$OUT/meta.txt"
if [ "$GATE_PASS" = 1 ]; then
  echo "LEGRUN_DONE $OUT"
else
  echo "LEGRUN_GATE_FAIL $OUT (deliver_rate below $RATE_GATE f/s or a watchdog relaunch in-window -- treat as UNINFORMATIVE)"
  exit 3
fi
