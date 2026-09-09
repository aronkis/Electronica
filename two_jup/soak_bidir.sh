#!/bin/bash
# =============================================================================
# soak_bidir.sh {A|B} [opts] -- BIDIRECTIONAL clone of capture_r3.sh (Task 10
# Step 2 acceptance soak): identical in every way except a second qpsk_perf
# flow saturates the reverse direction concurrently. Score frames.bin (target
# dir) AND frames_peer.bin (peer dir) with accept_analyze.py.
# ORIGINAL HEADER:
# capture_r3.sh {A|B} [opts] -- THE R3/f1536 PAIRED CAPTURE: per-frame telemetry
# (QPSK_FRAMELOG frames.bin) + a concurrent Tap-A raw ADC I/Q window on the RX
# target, over a live 61.44 MSPS / 15.36 Msym/s f1536 link, for the PER<1%
# reproduction campaign (Workstream R at R3 -- the open 148-RX-tick vs 146-TX-EVM
# question the 240k taxonomy never settled).
#
#   A : capture on 148, forward  146 TX -> 148 RX   (the ~6.7% forward loss dir)
#   B : capture on 146, reverse  148 TX -> 146 RX
#
# Reuses the PROVEN R3 bring-up verbatim (bringup_r2r3.sh r3: CFO offset policy,
# safe SSI overrides, ROM arm-quality gate + double-tap) via a QPSK_FRAMELOG
# passthrough, so the daemons it starts log per-frame telemetry. Sequence:
#   deploy+build qpsk_tun (logger + -DQPSK_CARVE_2MB) -> bringup_r2r3.sh r3 ->
#   KILL WATCHDOGS (a mid-capture re-arm corrupts both records) -> verify lock ->
#   drive saturating traffic (peer -> target tun) -> Tap-A iio_readdev on target
#   with pkts=0x104 anchor -> pull frames.bin + pair.iq + regs -> quiesce.
#
# Correlate offline: two_jup/frame_taxonomy.py frames.bin (fresh R3 taxonomy);
#   two_jup/align_frames.py frames.bin regs_cap.txt --spf 49332  (errored frames
#   -> pair.iq windows); reproduce via jupiter_240k5_byte/rtl_sim (obj_byte_f1536)
#   + evm_ideal_ref(evm_config_1536k).
#
# Options: -d DUR (traffic secs, def 60)  -n NSAMP (Tap complex samp, def 4000000
#          ~65 ms @61.44 Msps)  -o OUTDIR (def r3cap/<ts>_<dir>)  -k (keep link up
#          -- default quiesces both boards at the end to the known state)
#          -P (ping payload bytes, def 1400)
# Output:  pair.iq (int16 I,Q @61.44 Msps), frames.bin (+frames_peer.bin), 48 B/
#          frame, correlate to pair.iq via CAP_START pkts=0x104), regs_{pre,cap,
#          post}.txt, meta.txt, qpsk_tun.log(+peer)
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=$(cd "$D/.." && pwd)/host_app_k5
A_IP=10.0.0.148; B_IP=10.0.0.146
TA=10.66.0.2; TB=10.66.0.1          # tun endpoints (148 / 146), per bringup_r2r3.sh
SPF_F1536=49332                     # 12333 sym x 4 sps -- for align_frames.py --spf

TGT=${1:?usage: capture_r3.sh A-or-B [-d dur] [-n nsamp] [-o out] [-k] [-P payload]}
shift
DUR=60; NSAMP=4000000; OUT=""; KEEP=0; PAY=1400
while [ $# -gt 0 ]; do
  case "$1" in
    -d) DUR=$2; shift 2;;
    -n) NSAMP=$2; shift 2;;
    -o) OUT=$2; shift 2;;
    -k) KEEP=1; shift;;
    -P) PAY=$2; shift 2;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
case "$TGT" in
  A) RX_IP=$A_IP; PEER_IP=$B_IP; TUN_TGT=$TA; DIRN=fwd;;
  B) RX_IP=$B_IP; PEER_IP=$A_IP; TUN_TGT=$TB; DIRN=rev;;
  *) echo "target must be A (capture on 148, fwd) or B (capture on 146, rev)" >&2; exit 2;;
esac
[ -n "$OUT" ] || OUT=$D/r3cap/$(date +%Y%m%d_%H%M%S)_${DIRN}
mkdir -p "$OUT"

# scp stderr goes to a logfile, not /dev/null: 6/6 fetches failed silently in
# sweep_130815 (completed captures lost) while the identical command succeeded
# by hand -- the next failure must leave its actual error behind.
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>>/tmp/capture_scp_err.txt; }
snap(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA;cat $DRA; }
   echo "t=$(date +%s.%N) pkts=$(rd 0x104) biterr=$(rd 0x108) rstcs=$(rd 0x150) cfc=$(rd 0x154) fx=$(rd 0x15C)"' 2>/dev/null; }
# byte-source double-tap re-arm (mirrors bringup_r2r3.sh rearm_byte): clears a
# sync-but-CRC wedge. If the link is genuinely degraded (146 TX margin), this
# does NOT clear it -> the wedge check will exhaust its tries and flag it.
rearm_byte(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }
# CRC pass-fraction over ~6 s from the daemon's own stats (needs traffic
# flowing). Echoes an integer percent, or -1 if no frames moved.
crc_health(){ $W $1 'L=/dev/shm/qpsk_tun.log; g(){ grep "stats:" $L 2>/dev/null | tail -1; }
 s1=$(g); ok1=$(echo "$s1"|grep -o "dma_rx_ok=[0-9]*"|cut -d= -f2); c1=$(echo "$s1"|grep -o "crc_drop=[0-9]*"|cut -d= -f2)
 sleep 6; s2=$(g); ok2=$(echo "$s2"|grep -o "dma_rx_ok=[0-9]*"|cut -d= -f2); c2=$(echo "$s2"|grep -o "crc_drop=[0-9]*"|cut -d= -f2)
 dok=$(( ${ok2:-0} - ${ok1:-0} )); dc=$(( ${c2:-0} - ${c1:-0} )); tot=$((dok+dc))
 [ $tot -gt 0 ] && echo $(( 100 * dok / tot )) || echo -1' 2>/dev/null; }

# DELIVERY RATE (frames/s of dma_rx_ok). This is the check crc_health cannot make: a
# ratio of good-to-total is ~100% in a wedge because the host decodes almost nothing and
# what little it decodes is clean. Only a rate distinguishes "healthy" from "flatlined".
# R3 nominal is ~1245 f/s (12333 sym/frame at 15.36 Msym/s).
deliver_rate(){ $W $1 'L=/dev/shm/qpsk_tun.log; g(){ grep "stats:" $L 2>/dev/null | tail -1; }
 o1=$(g|grep -o "dma_rx_ok=[0-9]*"|cut -d= -f2); t1=$(date +%s)
 sleep 6; o2=$(g|grep -o "dma_rx_ok=[0-9]*"|cut -d= -f2); t2=$(date +%s)
 dt=$(( t2 - t1 )); [ $dt -le 0 ] && dt=1
 echo $(( ( ${o2:-0} - ${o1:-0} ) / dt ))' 2>/dev/null; }

# forward-path health (peer side): counts idle_rx as OK (in a reverse capture the
# forward direction carries keepalives + ARQ NAKs, which land as idle_rx/rx_ok).
fwd_health(){ $W $1 'L=/dev/shm/qpsk_tun.log; g(){ grep "stats:" $L 2>/dev/null | tail -1; }
 s1=$(g); ok1=$(echo "$s1"|grep -o "dma_rx_ok=[0-9]*"|cut -d= -f2); i1=$(echo "$s1"|grep -o "idle_rx=[0-9]*"|cut -d= -f2); c1=$(echo "$s1"|grep -o "crc_drop=[0-9]*"|cut -d= -f2)
 sleep 6; s2=$(g); ok2=$(echo "$s2"|grep -o "dma_rx_ok=[0-9]*"|cut -d= -f2); i2=$(echo "$s2"|grep -o "idle_rx=[0-9]*"|cut -d= -f2); c2=$(echo "$s2"|grep -o "crc_drop=[0-9]*"|cut -d= -f2)
 dok=$(( ${ok2:-0} - ${ok1:-0} + ${i2:-0} - ${i1:-0} )); dc=$(( ${c2:-0} - ${c1:-0} )); tot=$((dok+dc))
 [ $tot -gt 0 ] && echo $(( 100 * dok / tot )) || echo -1' 2>/dev/null; }

echo "=== capture_r3 $TGT ($DIRN): R3/f1536 link, ${DUR}s traffic, Tap-A ${NSAMP} samp on $RX_IP -> $OUT ==="

# 1. deploy qpsk_tun source (with the QPSK_FRAMELOG logger) + build on-board with
#    the f1536 2 MB carve so bringup's daemons are the logger build.
for ip in $B_IP $A_IP; do
  $W $ip 'mkdir -p /root/host_app_k5' 2>/dev/null
  scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" \
         "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" \
         "$SRC/qpsk_uio.c" "$SRC/qpsk_uio.h" "$SRC/qpsk_perf.c" root@$ip:/root/host_app_k5/ \
         || { echo "scp $ip FAIL"; exit 1; }
  # GUARD (2026-08-07): this rebuild used to SILENTLY STRIP deployed instrumentation.
  # The NAK-path counters are compile-time gated on -DQPSK_ARQ_NAKSTAT; rebuilding
  # with only -DQPSK_CARVE_2MB removes them, and nothing tells you -- the daemon just
  # stops emitting the nakstat line. Detect what the board is ALREADY running (the
  # counter's format string is in the binary) and preserve it, so the safe behaviour
  # is the default and needs no env var anyone has to remember.
  # HOST_CFLAGS appends extra flags explicitly; NAKSTAT=0 force-disables the carry-over.
  # NAKKEEP, not KEEP: KEEP is already the -k (keep-link-up) option variable, and the
  # first version of this guard clobbered it -- silently disabling -k for every caller.
  NAKKEEP=$($W $ip 'strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -q "nakstat:" \
         && echo "-DQPSK_ARQ_NAKSTAT" || echo ""' 2>/dev/null)
  [ "${NAKSTAT:-1}" = 0 ] && NAKKEEP=""
  [ -n "$NAKKEEP" ] && echo "  $ip: preserving deployed NAK-stat instrumentation ($NAKKEEP)"
  # HOST_CFLAGS_B: extra flags for board B (146) ONLY. The queued-RX instrumentation
  # (-DQPSK_RXQ_STAT) belongs on the RX board, and board A (148) must rebuild to a
  # functionally untouched binary -- with the flag off the source is byte-identical, so
  # scoping it here keeps 148's AXR-counter build exactly as deployed.
  BCF=""; [ "$ip" = "$B_IP" ] && BCF="${HOST_CFLAGS_B:-}"
  R=$($W $ip "cd /root/host_app_k5 && gcc -O2 -Wall -DQPSK_CARVE_2MB $NAKKEEP ${HOST_CFLAGS:-} $BCF -o qpsk_tun \
        qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c 2>/tmp/gcc.err \
        && gcc -O2 -Wall -o qpsk_perf qpsk_perf.c 2>>/tmp/gcc.err \
        && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }" 2>/dev/null)
  echo "  $ip build: $(echo "$R" | tail -1)"; echo "$R" | grep -q BUILD_OK || exit 1
  # verify the instrumentation survived, rather than assuming the flag did its job
  if [ -n "$NAKKEEP" ]; then
    $W $ip 'strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -q "nakstat:" \
      && echo "  '"$ip"': NAK-stat counter VERIFIED present after rebuild" \
      || echo "  '"$ip"': WARNING NAK-stat counter LOST in rebuild"' 2>/dev/null
  fi
  # same discipline for the queued-RX instrumentation: verify, never assume the flag took
  case "$BCF" in *QPSK_RXQ_STAT*)
    $W $ip 'strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -q "rxqstat:" \
      && echo "  '"$ip"': RXQ-stat counter VERIFIED present after rebuild" \
      || echo "  '"$ip"': WARNING RXQ-stat counter MISSING after rebuild"' 2>/dev/null ;;
  esac
done

# 2. proven R3 bring-up with per-frame logging (QPSK_FRAMELOG passthrough).
echo "--- bringup_r2r3.sh r3 (logger on) ---"
QPSK_FRAMELOG=/dev/shm/frames.bin "$D/bringup_r2r3.sh" r3 || { echo "R3 BRINGUP FAILED"; exit 1; }

# 3. kill watchdogs BOTH (a mid-capture re-arm corrupts the record; the wedge
#    check below replaces the watchdog's role for the capture window)
for ip in $B_IP $A_IP; do
  $W $ip 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
   pkill -9 -f "[l]ock_watchdog" 2>/dev/null; echo "'$ip' wd stopped"' 2>/dev/null
done
sleep 2

# 4. saturating traffic: qpsk_perf UDP, peer -> target tun (server sinks on the
#    target, client paces near the R3 ceiling). Runs long enough to cover the
#    wedge-check re-arms + settle + the Tap window + DUR.
PERF_T=$(( DUR + 140 ))
$W $RX_IP  "pkill -x qpsk_perf 2>/dev/null; cd /root/host_app_k5; setsid ./qpsk_perf -s -p 5001 </dev/null >/dev/shm/perf_srv.log 2>&1 &" 2>/dev/null
$W $PEER_IP "pkill -x qpsk_perf 2>/dev/null; cd /root/host_app_k5; setsid ./qpsk_perf -c $TUN_TGT -b 15000000 -l $PAY -t $PERF_T -p 5001 </dev/null >/dev/shm/perf_cli.log 2>&1 &" 2>/dev/null
# BIDIR SOAK (Task 10 Step 2, 2026-08-25): simultaneous reverse traffic
# (target -> peer tun) on port 5002 so BOTH directions carry saturating load.
# No pkill here -- the launches above already cleaned qpsk_perf per board and
# a pkill now would kill the forward flow.
[ "$TGT" = A ] && TUN_PEER=$TB || TUN_PEER=$TA
$W $PEER_IP "cd /root/host_app_k5; setsid ./qpsk_perf -s -p 5002 </dev/null >/dev/shm/perf_srv_rev.log 2>&1 &" 2>/dev/null
$W $RX_IP  "cd /root/host_app_k5; setsid ./qpsk_perf -c $TUN_PEER -b 15000000 -l $PAY -t $PERF_T -p 5002 </dev/null >/dev/shm/perf_cli_rev.log 2>&1 &" 2>/dev/null
echo "  traffic (rev): $RX_IP -> $TUN_PEER (port 5002, same pacing)"
echo "  traffic: $PEER_IP -> $TUN_TGT (qpsk_perf -b 15Mbit -l $PAY -t $PERF_T), settling 4s ..."
sleep 4

# 5. WEDGE CHECK: re-arm until CRC-healthy. A sync-but-CRC wedge clears on the
#    byte double-tap; genuine forward degradation (146 TX margin) does NOT ->
#    tries exhaust and we flag PERSISTENT (that IS the real PER, not a wedge).
WTRY=1; WMAX=${WMAX:-4}; WTHRESH=${WTHRESH:-50}; HLAST=-1
# RATE_MIN: minimum delivered frames/s to call the link live. ~25% of the R3 nominal
# 1245 f/s. A wedge delivers single digits, so this separates cleanly.
RATE_MIN=${RATE_MIN:-300}; RLAST=-1
while [ $WTRY -le $WMAX ]; do
  HLAST=$(crc_health $RX_IP)
  RLAST=$(deliver_rate $RX_IP)
  FH=100
  [ "${FWD_GATE:-0}" = 1 ] && FH=$(fwd_health $PEER_IP)
  echo "  health try $WTRY: rev ${HLAST}% fwd ${FH}% (need >= ${WTHRESH}%)  rate ${RLAST} f/s (need >= ${RATE_MIN})"
  if [ "${HLAST:--1}" -ge "$WTHRESH" ] 2>/dev/null && [ "${FH:--1}" -ge "$WTHRESH" ] 2>/dev/null \
     && [ "${RLAST:--1}" -ge "$RATE_MIN" ] 2>/dev/null; then
    echo "  link healthy: CRC $HLAST% AND delivering $RLAST f/s"; break
  fi
  [ "${RLAST:--1}" -lt "$RATE_MIN" ] 2>/dev/null && \
    echo "  !! DELIVERY FLATLINE (${RLAST} f/s) -- this is the wedge crc-health cannot see" 
  echo "  wedged/degraded -> byte double-tap re-arm (both boards)"
  rearm_byte $B_IP; rearm_byte $A_IP; sleep 3; rearm_byte $B_IP; rearm_byte $A_IP; sleep 4
  WTRY=$(( WTRY + 1 ))
done
if [ "${HLAST:--1}" -ge "$WTHRESH" ] 2>/dev/null && [ "${RLAST:--1}" -ge "$RATE_MIN" ] 2>/dev/null; then
  WEDGE_NOTE="healthy crc=${HLAST}% rate=${RLAST}f/s"
elif [ "${RLAST:--1}" -lt "$RATE_MIN" ] 2>/dev/null; then
  WEDGE_NOTE="WEDGED delivery=${RLAST}f/s (crc=${HLAST}%) after $WMAX re-arms -- NOT usable data"
else
  WEDGE_NOTE="PERSISTENT_DEGRADED ${HLAST}% after $WMAX re-arms (NOT a clearable wedge -- real PER)"
fi
echo "  wedge verdict: $WEDGE_NOTE"
# Refuse to spend a capture window on a wedged link. GATE_HARD=0 opts out (diagnostic
# runs that deliberately want the wedged data).
if [ "${GATE_HARD:-1}" = 1 ] && [ "${RLAST:--1}" -lt "$RATE_MIN" ] 2>/dev/null; then
  echo "CAPTURE_ABORTED_WEDGED: delivery ${RLAST} f/s < ${RATE_MIN} after $WMAX re-arms"
  echo "  (not banking empty data; re-run or clear the wedge first)"
  for ip in $B_IP $A_IP; do $W $ip 'pkill -x qpsk_perf 2>/dev/null' 2>/dev/null; done
  exit 3
fi

# 5b. optional carrier-loop tuning: poke receiver loop_gain regs (0x170-0x184)
#     AFTER the wedge re-arms (which soft-reset), so the tuned values are live for
#     the steady-state capture window. LOOP_POKE="0x184=0 0x170=49" (space-sep kv).
if [ -n "${LOOP_POKE:-}" ]; then
  echo "  LOOP_POKE on $RX_IP: $LOOP_POKE"
  $W $RX_IP "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access
    for kv in $LOOP_POKE; do echo \"\${kv%=*} \${kv#*=}\">\$DRA; done
    echo 'loop regs now:'; for r in 0x170 0x174 0x184; do echo \"\$r\">\$DRA; printf ' %s=%s' \"\$r\" \"\$(cat \$DRA)\"; done; echo" 2>/dev/null
fi

# rotate the framelog (SIGUSR2) so the PULLED frames.bin is the steady-state
# post-heal window only (drops the wedge + re-arm transient).
for ip in $RX_IP $PEER_IP; do $W $ip 'pkill -USR2 -x qpsk_tun 2>/dev/null' 2>/dev/null; done
sleep 1
S1=$(snap $RX_IP); sleep 2; S2=$(snap $RX_IP)

# CAP_SETTLE (2026-08-09): seconds to wait AFTER the framelog rotate before the Tap-A
# IQ grab. Default 0 preserves the historical behaviour exactly.
#
# WHY THIS EXISTS. Measured across 8 captures: the Tap-A window lands at t=8.0-8.1 s in
# the framelog timebase, EVERY TIME, and 160/160 of the frames inside it are errored --
# while the same captures run ~6% bad overall. The acceptance PER window deliberately
# starts at t>=15 s to exclude the post-rotate transient, so the IQ we grab for
# root-cause replay is taken from the exact region the PER metric throws away. Every
# errored frame we have IQ for is a transient artifact, not a steady-state error, which
# is very likely why Workstream R never produced an attribution.
# Set CAP_SETTLE=20 to grab IQ from the same steady-state window the PER number
# describes. Also lets us test whether the t~8 s error burst is caused BY the readdev
# (it moves with the capture) or is independent of it (it stays at 8 s).
if [ "${CAP_SETTLE:-0}" -gt 0 ] 2>/dev/null; then
  echo "  CAP_SETTLE: waiting ${CAP_SETTLE}s after rotate so the IQ window is steady-state"
  sleep "$CAP_SETTLE"
fi
{ echo "$S1"; echo "$S2"; echo "$WEDGE_NOTE"; } > "$OUT/regs_pre.txt"

# 6. THE PAIRED WINDOW: Tap-A capture during live traffic (single ssh session)
$W $RX_IP "rm -f /dev/shm/pair.iq
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; rd(){ echo \"\$1\">\$DRA;cat \$DRA; }
  echo \"CAP_START t=\$(date +%s.%N) pkts=\$(rd 0x104) biterr=\$(rd 0x108) rstcs=\$(rd 0x150) cfc=\$(rd 0x154)\"
  iio_readdev -u local: -b 32768 -s $NSAMP axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/pair.iq 2>/tmp/iio.err || cat /tmp/iio.err
  echo \"CAP_END   t=\$(date +%s.%N) pkts=\$(rd 0x104) biterr=\$(rd 0x108) rstcs=\$(rd 0x150) cfc=\$(rd 0x154)\"
  ls -la /dev/shm/pair.iq" 2>/dev/null | tee "$OUT/regs_cap.txt"

# 7. wait out the traffic window -- WITH a stall watchdog. Previously a blind sleep, so
#    a link that wedged mid-capture still produced a full-length, wholly empty frames.bin
#    that downstream tooling happily analysed. Now delivery is sampled and the run aborts
#    the moment it flatlines.
STALL_MAX=${STALL_MAX:-12}          # seconds of flatline before declaring a wedge
LEFT=$((DUR - 20))
# BUGFIX: this used to gate the stall watchdog on LEFT>0, i.e. DUR>20. Every capture of
# 20 s or less -- exactly the short verification/recovery captures -- ran with NO
# mid-capture watchdog at all, so a link that wedged after the pre-capture gate still
# banked a full-length empty frames.bin. Observed: recover2 passed the rate gate at
# 1027 f/s and then scored "UNUSABLE (live window 0s of 15s, WEDGED)". A check that
# cannot fire is worse than no check, because it reads as coverage.
# Always sample; if there is no tail left, still watch the settle+capture window.
[ $LEFT -le 0 ] && LEFT=$(( DUR > 8 ? 8 : DUR ))
if [ $LEFT -gt 0 ]; then
  echo "  ${LEFT}s traffic remaining (stall watchdog: abort after ${STALL_MAX}s flatline) ..."
  MID_WEDGE=0; STALL=0; WAITED=0
  PREV=$($W $RX_IP 'grep "stats:" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1 | grep -o "dma_rx_ok=[0-9]*" | cut -d= -f2' 2>/dev/null)
  while [ $WAITED -lt $((LEFT + 4)) ]; do
    sleep 4; WAITED=$((WAITED + 4))
    NOW=$($W $RX_IP 'grep "stats:" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1 | grep -o "dma_rx_ok=[0-9]*" | cut -d= -f2' 2>/dev/null)
    # DFRAMES, not D: reusing D here clobbered the script-dir variable that
    # scpput builds its askpass path from, so EVERY capture that entered this
    # watchdog loop lost its artifact fetch ("ssh_askpass: exec(<delta>/
    # askpass.sh)") -- sweep_130815's six completed captures among them.
    DFRAMES=$(( ${NOW:-0} - ${PREV:-0} )); PREV=$NOW
    # 4 s of live link delivers ~5000 frames; treat <200 as flatlined
    if [ "$DFRAMES" -lt 200 ] 2>/dev/null; then
      STALL=$((STALL + 4))
      echo "    !! delivery stalled ${STALL}s (+${DFRAMES} frames in 4s)"
      if [ $STALL -ge $STALL_MAX ]; then MID_WEDGE=1; break; fi
    else
      STALL=0
    fi
  done
  if [ "$MID_WEDGE" = 1 ]; then
    WEDGE_NOTE="MID_CAPTURE_WEDGE after ${WAITED}s (delivery flatlined ${STALL}s) -- NOT usable data"
    echo "CAPTURE_ABORTED_WEDGED: $WEDGE_NOTE"
  fi
fi
snap $RX_IP > "$OUT/regs_post.txt"; cat "$OUT/regs_post.txt"

# 8. pull artifacts (flush the loggers first: SIGUSR1)
for ip in $RX_IP $PEER_IP; do $W $ip 'pkill -USR1 -x qpsk_tun 2>/dev/null; sleep 0.5' 2>/dev/null; done
scpput root@$RX_IP:/dev/shm/pair.iq   "$OUT/pair.iq"   || { echo "scp pair.iq FAIL"; exit 1; }

# CAPTURE-PATH HEALTH GATE (added 2026-08-24). The IQ DMA can sit in the #48
# stale-DDR-replay state and return a stale ~256-sample buffer on every read while
# every board-side check still passes (framesync 1243 f/s throughout). An entire
# investigation was spent debugging receivers fed by such captures. Two cheap checks
# -- occupied bandwidth and envelope periodicity -- catch it. Non-fatal here so the
# rest of the capture is still collected, but the verdict is LOUD.
if ! python3 "$D/check_capture_health.py" "$OUT/pair.iq"; then
  echo "  *** CAPTURE HEALTH FAILED -- pair.iq is DEGENERATE. Do NOT draw IQ-based"
  echo "  *** conclusions from this run. frames.bin / host-side counters are unaffected."
fi
scpput root@$RX_IP:/dev/shm/frames.bin "$OUT/frames.bin" || echo "WARN: frames.bin fetch failed"
scpput root@$PEER_IP:/dev/shm/frames.bin "$OUT/frames_peer.bin" 2>/dev/null || true
scpput root@$RX_IP:/dev/shm/qpsk_tun.log "$OUT/qpsk_tun.log" 2>/dev/null || true
{ echo "target=$TGT dir=$DIRN rx=$RX_IP peer=$PEER_IP rung=r3 profile=lvds_61p44_fdd_jupiter"
  echo "ksym=15360 sps=4 fs=61440000 spf=$SPF_F1536 dur=$DUR nsamp=$NSAMP payload=$PAY traffic=qpsk_perf_15Mbit"
  echo "wedge_verdict=$WEDGE_NOTE"
  echo "image_md5=$($W $RX_IP 'md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-32' 2>/dev/null)"
  echo "ts=$(date -Is)"; } > "$OUT/meta.txt"

# 9. stop traffic, then quiesce to the known state (unless -k)
for ip in $B_IP $A_IP; do $W $ip 'pkill -x qpsk_perf 2>/dev/null' 2>/dev/null; done
if [ "$KEEP" = 0 ]; then
  for ip in $B_IP $A_IP; do
    $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4
     ip link del tun0 2>/dev/null
     busybox devmem 0x9D000000 32 0 2>/dev/null; busybox devmem 0x9D000114 32 0 2>/dev/null
     echo "'$ip' quiesced"' 2>/dev/null
  done
else
  echo "  -k: R3 link left UP (both daemons running)"
fi

echo "--- frames.bin summary ---"
[ -f "$OUT/frames.bin" ] && echo "frames.bin: $(( $(stat -c%s "$OUT/frames.bin") / 48 )) records" || echo "(no frames.bin)"
echo "NEXT: python3 $D/frame_taxonomy.py $OUT/frames.bin --frame-period-s 0.000803"
echo "      python3 $D/align_frames.py $OUT/frames.bin $OUT/regs_cap.txt --spf $SPF_F1536 --pair $OUT/pair.iq -o $OUT"
case "${WEDGE_NOTE:-}" in
  MID_CAPTURE_WEDGE*|WEDGED*)
    echo "CAPTURE_R3_WEDGED $OUT  -- $WEDGE_NOTE"
    echo "  run flagged; callers should discard it (exit 3)"
    exit 3 ;;
esac
echo "CAPTURE_R3_DONE $OUT"
