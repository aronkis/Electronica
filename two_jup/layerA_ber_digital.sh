#!/bin/bash
# layerA_ber_digital.sh -- Layer A INTRINSIC DSP FLOOR (spec 2026-08-18):
# in-fabric BER, digital loopback, Layer B fully out of the loop.
# TX reference = Message_Generator ROM (0x158=0); RX scored by the fabric's own
# post-Viterbi comparator (0x108 bit_errors_out) + frame counter (0x104).
# Host role = polling two AXI counters. No byte plane, no DMA, no host data path.
#
# POSITIVE CONTROL (C1 lesson): first arm with 0x158=1 (byte source, no feeder ->
# underrun garbage payloads). The comparator must count HIGH vs its ROM
# expectation. Then arm 0x158=0 (ROM): the rate must collapse to the floor.
# A floor reading without the high control is not evidence.
# All reads are DELTA-based (two samples per dwell). Arms use the FULL
# bringup-sequenced batch (never ad-hoc mid-stream pokes).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.148
BITS_PER_FRAME=12224   # decoded payload bits/frame assumption (1528B*8); stated in report

echo "=== Layer A digital: in-fabric BER on $B ==="
echo "--- [1] quiesce watchdog + daemon (single DRA writer; watchdog re-arms 0x114) ---"
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1
  echo "  quiesced"' 2>/dev/null

arm(){ # $1 = tx_data_source value (0=ROM reference, 1=byte/underrun-garbage)
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo \"0x000 0x1\">\$DRA; sleep 0.5; echo \"0x000 0x0\">\$DRA
  echo \"0x158 0x$1\">\$DRA
  echo \"0x118 0x0\">\$DRA
  echo \"0x114 0x0\">\$DRA
  TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9001-tx-lpc ] && echo \${d##*/}; done)
  T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
  echo \"0x418 0x2\">\$T; echo \"0x458 0x2\">\$T; echo \"0x044 0x1\">\$T
  echo \"0x110 0x1\">\$DRA; sleep 0.3; echo \"0x110 0x0\">\$DRA
  echo \"  armed (0x158=$1, 0x114=0 digital loopback)\"" 2>/dev/null
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

echo "--- [2] POSITIVE CONTROL: 0x158=1 (underrun garbage) -- comparator must count HIGH ---"
arm 1; sleep 4
probe 15 CTRL_HIGH

echo "--- [3] REFERENCE: 0x158=0 (ROM) -- floor dwells ---"
arm 0; sleep 4
probe 60 ROM_A1
probe 60 ROM_A2
echo "--- [3b] independent re-arm (arm-to-arm variance) ---"
arm 0; sleep 4
probe 60 ROM_B1
probe 60 ROM_B2
echo "--- [3c] long dwell ---"
probe 300 ROM_LONG

echo "--- [4] restore rig ---"
bash "$D/restore_known_good.sh" > /tmp/layerA_restore.log 2>&1
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo "$1">$DRA; cat $DRA; }
  p0=$(($(rd 0x104))); sleep 3; p1=$(($(rd 0x104))); echo "RIG: fsync/s=$(( (p1-p0)/3 ))"' 2>/dev/null
echo "LAYERA_DIGITAL_DONE (BER denominator assumption: $BITS_PER_FRAME bits/frame)"
