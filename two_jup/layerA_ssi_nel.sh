#!/bin/bash
# layerA_ssi_nel.sh -- Layer A with ADRV9002 NEAR-END SSI LOOPBACK (beat discriminator).
# Path: fabric ROM (0x158=0) -> modulator -> TX SSI lanes -> ADRV9002 SSI block
# (rx0/rx1_near_end_loopback=1) -> RX SSI lanes -> demod -> in-fabric comparator
# (0x104 frames / 0x108 bit errors). RF cut out entirely; SSI lanes + clock chain
# fully in the loop. 0x114=1 (RX from SSI, the on-air mux value).
#
# QUESTION UNDER TEST: does the 119.75 s periodic burst appear on this path?
#   - FPGA-internal digital loopback (0x114=0) SHOWS the beat.
#   - If NEL also shows it -> beat is upstream of / within the common SSI-clocked
#     fabric domain (both paths share the SSI-derived clock).
#   - If NEL amplitude/behaviour differs -> localizes relative to the SSI interface.
# Controls: positive control (0x158=1 garbage -> comparator counts HIGH) and a
# lock gate (fsync/s must be nonzero after arm; NEL path lock is not guaranteed).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=${BOARD:-10.0.0.148}
DWELL=${DWELL:-600}

echo "=== Layer A SSI near-end loopback on $B (poll ${DWELL}s at 1 s) ==="
echo "--- [1] quiesce ---"
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1
  echo "  quiesced"' 2>/dev/null

echo "--- [2] enable near-end loopback (rx0+rx1) ---"
$W $B 'PHY=$(for d in /sys/kernel/debug/iio/iio:device*; do
    [ -f $d/rx0_near_end_loopback ] && echo $d; done | head -1)
  [ -z "$PHY" ] && { echo "NEL_ATTR_MISSING"; exit 1; }
  echo 1 > $PHY/rx0_near_end_loopback
  echo 1 > $PHY/rx1_near_end_loopback
  echo "  NEL on ($PHY): rx0=$(cat $PHY/rx0_near_end_loopback) rx1=$(cat $PHY/rx1_near_end_loopback)"' 2>/dev/null

arm(){ # $1 = tx_data_source (0=ROM reference, 1=garbage control); 0x114=1 = SSI RX
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo \"0x000 0x1\">\$DRA; sleep 0.5; echo \"0x000 0x0\">\$DRA
  echo \"0x158 0x$1\">\$DRA
  echo \"0x118 0x0\">\$DRA
  echo \"0x114 0x1\">\$DRA
  TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9001-tx-lpc ] && echo \${d##*/}; done)
  T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
  echo \"0x418 0x2\">\$T; echo \"0x458 0x2\">\$T; echo \"0x044 0x1\">\$T
  echo \"0x110 0x1\">\$DRA; sleep 0.3; echo \"0x110 0x0\">\$DRA
  echo \"  armed (0x158=$1, 0x114=1 SSI RX, NEL on)\"" 2>/dev/null
}

probe(){ # $1 = dwell seconds, $2 = label
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
  p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108)))
  sleep $1
  p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
  dp=\$(( (p1-p0) & 0xFFFFFFFF )); de=\$(( (e1-e0) & 0xFFFFFFFF ))
  echo \"PROBE $2 dwell=$1 d104=\$dp d108=\$de fps=\$((dp/$1)) errps=\$((de/$1))\"" 2>/dev/null
}

echo "--- [3] LOCK GATE: ROM arm, fsync must be nonzero on the NEL path ---"
arm 0; sleep 6
LOCK=$(probe 10 LOCK_GATE); echo "$LOCK"
FPS=$(echo "$LOCK" | grep -oE "fps=[0-9]+" | tr -dc 0-9)
if [ "${FPS:-0}" -eq 0 ]; then
  echo "NEL_NO_LOCK: demod does not lock on near-end loopback path -- aborting to restore"
else
echo "--- [4] POSITIVE CONTROL: 0x158=1 garbage -- comparator must count HIGH ---"
arm 1; sleep 4
probe 15 CTRL_HIGH
echo "--- [5] REFERENCE re-arm + arm-transient wait (65 s) ---"
arm 0; sleep 65
echo "--- [6] ${DWELL}s poll at 1 s (on-board loop -> /dev/shm/burst.csv) ---"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
  : > /dev/shm/burst.csv
  p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108)))
  for i in \$(seq 1 $DWELL); do
    sleep 1
    p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
    echo \"\$i \$(( (p1-p0) & 0xFFFFFFFF )) \$(( (e1-e0) & 0xFFFFFFFF ))\" >> /dev/shm/burst.csv
    p0=\$p1; e0=\$e1
  done
  echo POLL_DONE" 2>/dev/null
OUT=$D/r3cap/ssinel_burstpoll_$(date +%Y%m%d_%H%M%S).csv
$W $B 'cat /dev/shm/burst.csv' 2>/dev/null > "$OUT"
echo "CSV: $OUT ($(wc -l < "$OUT") samples)"
echo "--- burst analysis (threshold: d108 > 200/s) ---"
awk '{ if ($3 > 200) { if (!inb) { start=$1; sum=0; inb=1 }
         sum += $3; last=$1 }
       else if (inb) { printf "BURST t=%d..%d dur=%ds size=%d", start, last, last-start+1, sum;
         if (prevend) printf " gap_from_prev=%ds interval_start_to_start=%ds", start-prevend, start-prevstart;
         printf "\n"; prevend=last; prevstart=start; inb=0 } }
     END { if (inb) printf "BURST t=%d..%d dur=%ds size=%d (open at end)\n", start, last, last-start+1, sum }' "$OUT"
awk '$3<=200 {q+=$3; n++} END { if (n) printf "QUIET floor: %.1f err/s over %d quiet seconds\n", q/n, n }' "$OUT"
awk '{f+=$2} END { printf "fsync mean %.1f f/s over %d s\n", f/NR, NR }' "$OUT"
fi

echo "--- [7] disable NEL + restore rig ---"
$W $B 'PHY=$(for d in /sys/kernel/debug/iio/iio:device*; do
    [ -f $d/rx0_near_end_loopback ] && echo $d; done | head -1)
  echo 0 > $PHY/rx0_near_end_loopback; echo 0 > $PHY/rx1_near_end_loopback
  echo "  NEL off: rx0=$(cat $PHY/rx0_near_end_loopback) rx1=$(cat $PHY/rx1_near_end_loopback)"' 2>/dev/null
bash "$D/restore_known_good.sh" > /tmp/ssinel_restore.log 2>&1
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo "$1">$DRA; cat $DRA; }
  p0=$(($(rd 0x104))); sleep 3; p1=$(($(rd 0x104))); echo "RIG: fsync/s=$(( (p1-p0)/3 ))"' 2>/dev/null
echo "SSINEL_DONE"
