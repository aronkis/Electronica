#!/bin/bash
# layerB_txchk.sh -- TX-side Layer B isolation on silicon (needs the tx_seam_checker
# image). Two legs, both scored by the IN-FABRIC checker @0x9D420000
# (ch1 0x9D420000 = bit_errors, ch2 0x9D420008 = frames_checked):
#   Leg A (continuous-valid): host pushes TGEN-format frames down the real byte
#     TX DMA (QPSK_SEQ_TGENTX=1516) -- the spec measurement.
#   Leg B (gapped-valid): the TX-seam generator (0x9D400000) supplies the same
#     frames at its 8-clk-bubble word cadence -- the ByteWordBuffer divergence probe.
# PASS per leg: d(bit_errors)==0 and d(frames_checked) ~= expected frames.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.148
DUR=${DUR:-30}

rdchk(){ $W $B 'DM=$(command -v devmem || echo "busybox devmem")
  echo "$(( $($DM 0x9D420000) )) $(( $($DM 0x9D420008) ))"' 2>/dev/null; }

echo "=== TX-seam checker legs on $B (dwell ${DUR}s each) ==="
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1
  echo "  quiesced"' 2>/dev/null
# loopback arm (T8 idiom) -- keeps the modem self-contained; checker taps pre-modulator
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
  echo "  armed"' 2>/dev/null

echo "--- LEG A: continuous-valid (host DMA, QPSK_SEQ_TGENTX=1516) ---"
read A0e A0f <<< "$(rdchk)"
$W $B "cd /root/host_app_k5
  QPSK_FRAME=f1536 QPSK_SEQ_TGENTX=1516 QPSK_RX_QUEUED=1 setsid chrt -f 50 \
    ./qpsk_tun -S -M 16 -r 15360 -d $DUR > /dev/shm/txchkA.log 2>&1 &
  exit 0" >/dev/null 2>&1
sleep $((DUR + 6))
read A1e A1f <<< "$(rdchk)"
$W $B 'pkill -x qpsk_tun 2>/dev/null; exit 0' >/dev/null 2>&1
DAe=$(( (A1e - A0e) & 0xFFFFFFFF )); DAf=$(( (A1f - A0f) & 0xFFFFFFFF ))
echo "LEGA d_bit_errors=$DAe d_frames=$DAf"
[ "$DAe" -eq 0 ] && [ "$DAf" -gt 0 ] && echo "LEGA_PASS" || echo "LEGA_FAIL"

echo "--- LEG B: gapped-valid (TX-seam generator, fill=1516, gap=100000) ---"
read B0e B0f <<< "$(rdchk)"
$W $B "DM=\$(command -v devmem || echo 'busybox devmem')
  \$DM 0x9D400008 32 100000; \$DM 0x9D400000 32 \$(( (1516<<4)|1 ))" 2>/dev/null
sleep "$DUR"
$W $B 'DM=$(command -v devmem || echo "busybox devmem"); $DM 0x9D400000 32 0' 2>/dev/null
sleep 2
read B1e B1f <<< "$(rdchk)"
DBe=$(( (B1e - B0e) & 0xFFFFFFFF )); DBf=$(( (B1f - B0f) & 0xFFFFFFFF ))
echo "LEGB d_bit_errors=$DBe d_frames=$DBf (expected ~$(( DUR * 620 )))"
[ "$DBe" -eq 0 ] && [ "$DBf" -gt 0 ] && echo "LEGB_PASS" || echo "LEGB_FAIL"

echo "--- restore ---"
if [ "${NO_RESTORE:-0}" = 1 ]; then echo "  restore SKIPPED (NO_RESTORE=1, 146 down)"; else
bash "$D/restore_known_good.sh" > /tmp/txchk_restore.log 2>&1; fi
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo "$1">$DRA; cat $DRA; }
  p0=$(($(rd 0x104))); sleep 3; p1=$(($(rd 0x104))); echo "RIG: fsync/s=$(( (p1-p0)/3 ))"' 2>/dev/null
echo "TXCHK_DONE"
