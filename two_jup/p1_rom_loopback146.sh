#!/bin/bash
# p1_rom_loopback146.sh -- P1 leg L1: ROM-source FPGA-internal loopback on 146,
# scored by the fabric BIST (0x104 packets / 0x108 biterr vs the ROM golden at
# the DECODER OUTPUT) -- a bit-exact TX+RX check with zero air, zero host DMA.
# Arm recipe = loopback_s_test.sh's arm_loopback with 0x158=0 (ROM) and no
# daemon (ROM self-pumps; stream-first is a byte-source concern).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.146
DWELL=${1:-60}
echo "P1_L1 start $(date -Is) dwell=${DWELL}s"
$W $B 'pkill -x qpsk_tun 2>/dev/null
  PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; sleep 1; echo "  daemon+watchdog stopped"' 2>/dev/null
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x0">$DRA        # tx_data_source = ROM/MSGGEN (BIST reference)
  echo "0x118 0x0">$DRA        # tx_source_select = in-FPGA Tx
  echo "0x114 0x0">$DRA        # rx_input_select = LOOPBACK
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
  echo "  ROM loopback armed"' 2>/dev/null
sleep 5
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
  p0=\$(rd 0x104); e0=\$(rd 0x108); r0=\$(rd 0x150)
  echo \"T0 pkts=\$p0 biterr=\$e0 rstcs=\$r0\"
  sleep $DWELL
  p1=\$(rd 0x104); e1=\$(rd 0x108); r1=\$(rd 0x150)
  echo \"T1 pkts=\$p1 biterr=\$e1 rstcs=\$r1\"
  echo \"DELTA pkts=\$(( \$((p1)) - \$((p0)) )) biterr=\$(( \$((e1)) - \$((e0)) )) rstcs=\$(( \$((r1)) - \$((r0)) ))\"" 2>/dev/null
echo "P1_L1_DONE $(date -Is)"
