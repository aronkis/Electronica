#!/bin/bash
# layerA_stage_poll.sh -- Phase-1 RX-processor stage bisection on the LIVE
# build-1 beat-ILA image (NO rebuild). Arms the in-fabric BIST ROM digital
# loopback, gates on a healthy 1245 f/s link, then polls the pipeline forensic
# registers (cap_in/cap_deint/cap_out + cnt_* + bit_errors_out) at high rate
# across the 119.75 s beat bursts. First cap_* that leaves its golden value
# during a burst names the corruption stage.
#
# Beat law: bursts at arm+34.75s + n*119.75s. First cleanly-separable burst is
# ~arm+153s (n=1; the n=0 burst hides under the ~65s arm transient). A 340s poll
# from ~arm+68 catches bursts at ~153, ~273, ~393 (>=2 of each species).
#
# Arm-health gate (advisor: the unattended-night killer): #48 fresh-arm lottery
# fails 40-100%; a degraded 341 f/s link gives a 6.7s period, NOT comparable.
# We verify >=1000 f/s after arm; on failure restore x2 and retry (<=2 attempts).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=${BOARD:-10.0.0.148}
POLL_MS=${POLL_MS:-100}
POLL_S=${POLL_S:-340}
OUT=$D/r3cap/stagepoll_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
echo "=== Phase-1 stage poll -> $OUT (period ${POLL_MS}ms, dwell ${POLL_S}s) ==="

echo "--- [0] push + build stage_poll on-board ---"
SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
  -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  "$D/stage_poll.c" root@$B:/root/ </dev/null 2>/dev/null
$W $B 'gcc -O2 -o /root/stage_poll /root/stage_poll.c && echo POLLER_BUILT || { echo POLLER_FAIL; exit 1; }' 2>/dev/null | tail -1

# ---- arm helper (BIST ROM digital loopback) ----
arm_bist() {
  $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
    echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
    echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
    TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
    T=/sys/kernel/debug/iio/$TXD/direct_reg_access
    echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
    echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
    echo ARMED_ROM' 2>/dev/null | tail -1
}
fsync_now() {
  $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
    rd(){ echo "$1">$DRA; cat $DRA; }
    p0=$(($(rd 0x104))); sleep 3; p1=$(($(rd 0x104))); echo $(( (p1-p0)/3 ))' 2>/dev/null | tail -1
}

echo "--- [1] quiesce live link ---"
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1; echo quiesced' 2>/dev/null | tail -1

ATT=0; HEALTHY=0
while [ $ATT -lt 3 ]; do
  ATT=$((ATT+1))
  echo "--- [2.$ATT] arm BIST ROM loopback ---"; arm_bist
  echo "    waiting out ~65s arm transient ..."; sleep 65
  FS=$(fsync_now); echo "    ARM-HEALTH: fsync=${FS} f/s (need >=1000)"
  if [ "${FS:-0}" -ge 1000 ] 2>/dev/null; then HEALTHY=1; break; fi
  echo "    DEGRADED arm (attempt $ATT) -> restore x2 and retry"
  bash "$D/restore_known_good.sh" > "$OUT/restore_pre$ATT.log" 2>&1
  bash "$D/restore_known_good.sh" >> "$OUT/restore_pre$ATT.log" 2>&1
  $W $B 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1' 2>/dev/null
done

if [ $HEALTHY -ne 1 ]; then
  echo "STAGEPOLL_ABORT: could not get a healthy 1245 f/s arm in 3 attempts (#48 lottery)."
  echo "  Restoring link and leaving rig healthy."
  bash "$D/restore_known_good.sh" > "$OUT/restore_final.log" 2>&1
  bash "$D/restore_known_good.sh" >> "$OUT/restore_final.log" 2>&1
  echo "STAGEPOLL_DONE aborted out=$OUT"; exit 2
fi

echo "--- [3] baseline (quiet) stage read ---"
$W $B '/root/stage_poll 100 2' 2>/dev/null | tee "$OUT/baseline.csv" | tail -3

echo "--- [4] high-rate stage poll ${POLL_S}s (catches bursts ~arm+153,+273,+393) ---"
$W $B "/root/stage_poll $POLL_MS $POLL_S" 2>/dev/null > "$OUT/stage.csv"
echo "    captured $(wc -l < "$OUT/stage.csv") samples"

echo "--- [5] quick burst summary (d(bit_errors_out) threshold) ---"
python3 "$D/analyze_stage_poll.py" "$OUT/stage.csv" | tee "$OUT/summary.txt"

echo "--- [6] restore rig (two-pass) ---"
$W $B 'pkill -x stage_poll 2>/dev/null; exit 0' 2>/dev/null
bash "$D/restore_known_good.sh" > "$OUT/restore_post.log" 2>&1
FS=$(fsync_now); echo "    post-restore fsync=${FS} f/s"
if [ "${FS:-0}" -lt 1000 ] 2>/dev/null; then
  echo "    second restore pass"; bash "$D/restore_known_good.sh" >> "$OUT/restore_post.log" 2>&1
  FS=$(fsync_now); echo "    post-restore(2) fsync=${FS} f/s"
fi
echo "STAGEPOLL_DONE out=$OUT fsync=${FS}"
