#!/bin/bash
# =============================================================================
# echo_loopback.sh -- ATTRIBUTE the ~2% "burst" loss (host/DMA vs PHY).
#
# Runs qpsk_tun echo mode (-e: host generates incrementing-seq frames over the
# DMA path, checks RX) on ONE board in INTERNAL LOOPBACK (rx_input_select=0,
# byte TX source) with f1536 geometry + -M 32 multi-drain -- i.e. the SAME
# modem+DMA path as the deployed link but with NO RF / channel.
#
#   bursts PRESENT here  -> host/DMA or modem-internal (NOT the RF channel)
#   bursts ABSENT (only DMA-boundary singles) -> the bursts NEED the RF channel = PHY
#
# The framelog (host_seq per RX frame) gives the same reliable gap metric used on
# the air captures, so the burst structure is directly comparable.
#
# Usage: echo_loopback.sh [ip] [dur_s]     (default 146, 120s)
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
IP=${1:-10.0.0.146}; DUR=${2:-120}
PROF=lvds_61p44_fdd_jupiter
SRC=$(cd "$D/../host_app_k5" && pwd)
OUT=$D/echoloop/$(date +%Y%m%d_%H%M%S)_$(echo $IP | tr . _); mkdir -p "$OUT"
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

echo "=== echo_loopback $IP: f1536 byte echo, INTERNAL LOOPBACK, -M 32, ${DUR}s -> $OUT ==="

# 1. deploy+build qpsk_tun (framelog + f1536 2MB carve), same binary as the air link
echo "--- build qpsk_tun (-DQPSK_CARVE_2MB) on $IP ---"
scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" \
       "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" \
       "$SRC/qpsk_uio.c" "$SRC/qpsk_uio.h" root@$IP:/root/host_app_k5/ || { echo "scp FAIL"; exit 1; }
R=$($W $IP 'cd /root/host_app_k5 && gcc -O2 -Wall -DQPSK_CARVE_2MB -o qpsk_tun \
      qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c 2>/tmp/gcc.err \
      && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }' 2>/dev/null)
echo "  build: $(echo "$R" | tail -1)"; echo "$R" | grep -q BUILD_OK || exit 1

# 2. arm INTERNAL LOOPBACK, BYTE TX source (echo DMAs host frames to the modem TX)
$W $IP "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 pkill -9 -f '[l]ock_watchdog' 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.5
 cat /root/$PROF.bin > \$P/stream_config 2>/dev/null; cat /root/$PROF.json > \$P/profile_config 2>/dev/null; sleep 2
 echo calibrated > \$P/out_voltage1_ensm_mode 2>/dev/null; echo calibrated > \$P/in_voltage1_ensm_mode 2>/dev/null
 for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
 echo 2000000000 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
 echo calibrated > \$P/in_voltage0_ensm_mode 2>/dev/null; echo 2000000000 > \$P/out_altvoltage0_RX1_LO_frequency
 echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 echo 'RF armed'" 2>/dev/null
# byte + INTERNAL LOOPBACK via the ssi-fix: AIR=0 -> 0x114=0 (loopback); it also sets
# 0x158=1 (byte), 0x118=0, tx-lpc SSI, and pulses 0x000/0x110 (clean demod-state arm).
echo "  ssi-fix (AIR=0 byte+loopback): $(AIR=0 $D/apply_146_ssi_fix.sh $IP 3 4 2>&1 | tail -1)"
# GATE: confirm loopback (0x114=0) + byte (0x158=1) actually took
$W $IP 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA;cat $DRA; }
 echo "armed: rxsel=$(rd 0x114) txsrc=$(rd 0x158) cap=$(rd 0x144)"' 2>/dev/null | tee "$OUT/arm.txt"
# 0x158 (byte src) is write-effective but reads 0 (like the loop_gain regs); gate on
# loopback (0x114=0) only, then validate byte source FUNCTIONALLY (echo rx_ok>0 +
# host_seq dense-incrementing from ~0) after the run.
grep -q "rxsel=0x0" "$OUT/arm.txt" || { echo "ARM GATE FAIL (loopback 0x114 not set)"; cat "$OUT/arm.txt"; exit 1; }

# 2b. optional: disable RX tracking cals (test the modem-cal dropout-cluster hypothesis)
if [ -n "${CAL_OFF:-}" ]; then
  echo "  CAL_OFF: disabling RX tracking cals: $CAL_OFF"
  $W $IP "P=/sys/bus/iio/devices/iio:device2; for c in $CAL_OFF; do echo 0 > \$P/in_voltage0_\${c}_tracking_en 2>/dev/null; done
    printf '  cals now:'; for c in $CAL_OFF; do printf ' %s=%s' \"\$c\" \"\$(cat \$P/in_voltage0_\${c}_tracking_en)\"; done; echo" 2>/dev/null | tee -a "$OUT/arm.txt"
fi

# 2c. optional pre-echo delay: if the dropout cluster is RF-enable-locked (chip warmup)
#     it fires during this wait, before echo starts, so the echo window is clean.
if [ -n "${PRE_DELAY:-}" ]; then
  echo "  PRE_DELAY: waiting ${PRE_DELAY}s after arm before echo (test RF-enable-locked warmup)"
  sleep "$PRE_DELAY"
fi

# 3. run echo mode over DMA (host frames -> TX -> loopback -> RX -> framelog)
echo "--- qpsk_tun -G -e -M 32 (echo, framelog) for ${DUR}s ---"
$W $IP "cd /root/host_app_k5; pkill -x qpsk_tun 2>/dev/null; sleep 0.3
 QPSK_FRAMELOG=/dev/shm/frames.bin QPSK_RX_CYCLIC=${RXCYC:-0} QPSK_RX_QUEUED=${RXQ:-0} setsid chrt -f 50 ./qpsk_tun -G -e -M 32 -d $DUR </dev/null >/dev/shm/echo.log 2>&1 &
 echo started" 2>/dev/null
# let it settle, then rotate framelog so the pulled window is steady-state
sleep 20
$W $IP 'pkill -USR2 -x qpsk_tun 2>/dev/null' 2>/dev/null
echo "  (settled 20s, framelog rotated; running $((DUR-20))s more)"
# wait out the run
sleep $(( DUR - 20 + 5 ))
$W $IP 'pkill -USR1 -x qpsk_tun 2>/dev/null; sleep 0.5' 2>/dev/null
$W $IP 'grep -E "^ECHO|echo: t" /dev/shm/echo.log | tail -3' 2>/dev/null | tee "$OUT/echo_tail.txt"
scpput root@$IP:/dev/shm/frames.bin "$OUT/frames.bin" || echo "WARN: frames.bin fetch failed"
scpput root@$IP:/dev/shm/echo.log   "$OUT/echo.log"   2>/dev/null || true

# 4. quiesce
$W $IP 'pkill -x qpsk_tun 2>/dev/null; DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; busybox devmem 0x9D000000 32 0 2>/dev/null; echo quiesced' 2>/dev/null
echo "ECHO_LOOPBACK_DONE $OUT"
