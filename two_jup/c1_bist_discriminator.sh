#!/bin/bash
# c1_bist_discriminator.sh -- localize the forward corrupt-frame class to a STAGE,
# with no image build, by reading an instrument that already exists.
#
# THE IDEA. `Capture_Data_Bits` (Receiver.v:373) consumes `QPSK_Rx_dataOut` -- the
# decoded bit stream straight out of QPSK_Rx, UPSTREAM of the whole byte plane
# (ByteWordBuffer -> ByteSerializer -> ByteRxFifo -> breakout -> DMA). It produces
# packets_out (0x104) and bit_errors_out (0x108). Those counters are therefore a
# T1-equivalent tap that has been sitting in every image all along.
#
# The BIST comparison is only MEANINGFUL when the transmitter radiates the known
# in-fabric MSGGEN ROM pattern (tx_data_source 0x158 = 0). With host TUN traffic the
# RX compares live data against the ROM and every bit mismatches -- which is why
# 0x108 has never been usable during normal operation.
#
# DISCRIMINATION (forward = 146 TX -> 148 RX):
#   BER at the decoder output ~ 1e-5 or lower  => decoder output is CLEAN, so the
#       ~8.3 %/frame corruption is introduced DOWNSTREAM of the decoder, i.e. inside
#       the byte plane / DMA path. Names the stage.
#   BER large, ~8 % of frames worth of bit errors => corruption is AT OR BEFORE the
#       decoder, i.e. signal domain. Re-aims the campaign away from the byte plane.
# Expected separation is orders of magnitude, so this is not a marginal call.
#
# RAILS: read-only registers; the only write is the TX source mux on 146, restored at
# exit along with the watchdogs. No flash. 148 untouched except register reads.
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
TX=10.0.0.146      # forward transmitter
RX=10.0.0.148      # forward receiver (the board with the open class)
DWELL=${1:-90}

echo "C1_BIST start $(date -Is)  dwell=${DWELL}s  forward 146->148"

restore() {
  echo "=== restore: TX byte-source + watchdogs ==="
  $W $TX 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
    echo "0x158 0x1" > $DRA' 2>/dev/null
  for ip in $TX $RX; do
    $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null
      nohup setsid /root/lock_watchdog.sh </dev/null >/dev/shm/watchdog.log 2>&1 & exit 0' 2>/dev/null
    sleep 1
    $W $ip 'pgrep -f "[l]ock_watchdog" >/dev/null && echo "  '"$ip"' watchdog up" || echo "  '"$ip"' watchdog DOWN"' 2>/dev/null
  done
}
trap restore EXIT

echo "=== [1/4] bring up the link (arms RF, locks both directions) ==="
QPSK_FRAMELOG= "$D/bringup_r2r3.sh" r3 > /tmp/c1_bringup.log 2>&1 \
  && grep -E "ARM GATE|BRING-UP COMPLETE" /tmp/c1_bringup.log | tail -2 \
  || { echo "C1_FAIL: bringup failed"; tail -5 /tmp/c1_bringup.log; exit 1; }

echo "=== [2/4] stop watchdogs (they write 0x000 and clear the counters) ==="
for ip in $TX $RX; do
  $W $ip 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
    pkill -9 -f "[l]ock_watchdog" 2>/dev/null; echo "  wd stopped"' 2>/dev/null
done

echo "=== [3/4] put the forward TRANSMITTER (146) back on the ROM pattern ==="
$W $TX 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  echo "0x158 0x0" > $DRA; echo "  0x158 <- 0 (ROM); write-only, verified by effect"' 2>/dev/null
sleep 3

echo "=== [4/4] sample the RX BIST on 148 for ${DWELL}s ==="
$W $RX 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
rd(){ echo "$1" > $DRA; cat $DRA; }
N='"$DWELL"'
p0=$(( $(rd 0x104) )); e0=$(( $(rd 0x108) )); d0=$(( $(rd 0x130) )); b0=$(( $(rd 0x134) )); r0=$(( $(rd 0x150) ))
echo "  t=0  packets=$p0 biterr=$e0 decbits=$d0 biststart=$b0 rstcs=$r0"
sleep $N
p1=$(( $(rd 0x104) )); e1=$(( $(rd 0x108) )); d1=$(( $(rd 0x130) )); b1=$(( $(rd 0x134) )); r1=$(( $(rd 0x150) ))
echo "  t=$N  packets=$p1 biterr=$e1 decbits=$d1 biststart=$b1 rstcs=$r1"
dp=$(( p1 - p0 )); de=$(( e1 - e0 )); dd=$(( d1 - d0 )); db=$(( b1 - b0 )); dr=$(( r1 - r0 ))
echo "C1_DELTA packets=$dp biterr=$de decbits=$dd biststart=$db rstcs=$dr dwell=$N"
[ $dp -gt 0 ] && echo "C1_RATE fps=$(( dp / N )) biterr_per_s=$(( de / N )) biterr_per_frame=$(( de / dp ))"
[ $dd -gt 0 ] && awk -v e=$de -v d=$dd "BEGIN{printf \"C1_BER decoder_output_BER=%.3e (%d errors / %d decoded bits)\n\", e/d, e, d}"' 2>/dev/null

echo "C1_BIST_DONE $(date -Is)"
