#!/bin/bash
# t8_diag146.sh -- ONE read-only diagnosis of 146's RX byte-plane drain after the
# reverse-leg gate saw 0x124=1247 f/s but chk_frames=0. No writes. Short remote
# strings (146 returns nothing for long multi-block commands).
set -u
D=$(cd "$(dirname "$0")/.." && pwd); W=$D/anyssh.sh
B=10.0.0.146
echo "=== t8_diag146 $(date -Is) (read-only) ==="
echo "-- DMAC 0x9D200000 window (CONTROL 0x400, IRQ 0x404/0x408?, FLAGS 0x40C, DEST 0x410, XLEN 0x418, and the status block 0x420-0x43C) --"
$W $B 'DM=$(command -v devmem || echo "busybox devmem"); for o in 0x400 0x404 0x408 0x40C 0x410 0x418 0x420 0x424 0x428 0x42C 0x430 0x434 0x438 0x43C; do echo "$o=$($DM $((0x9D200000+$o)))"; done' 2>&1 | tr -d '\r' | tr '\n' ' '; echo
echo "-- byte_ctrl_gpio 0x9D300000 and tgen_rx ctrl --"
$W $B 'DM=$(command -v devmem || echo "busybox devmem"); echo "byte_ctrl=$($DM 0x9D300000) tgenrx=$($DM 0x9D410000)"' 2>&1 | tr -d '\r'
echo "-- 0x1B0 byte_fifo_ovf trend (3 reads 2 s apart) + 0x104/0x124 --"
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
rd(){ echo "$1" > $DRA; cat $DRA; }
for i in 1 2 3; do echo "ovf=$(rd 0x1B0) p104=$(rd 0x104) p124=$(rd 0x124)"; sleep 2; done' 2>&1 | tr -d '\r'
echo "=== t8_diag146 DONE ==="
