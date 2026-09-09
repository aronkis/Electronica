#!/bin/bash
# t8_tx148_tgen.sh -- put 148 into the reverse-leg TRANSMIT condition and HOLD it:
# TGEN on (GAP, FILL), let the byte FIFO fill, then flip 0x158 to the byte source
# (double-tap, R2FINISH order). Holds for HOLD_S so a DDRCAP sel8 capture can be taken
# of the TRANSMITTED baseband, then turns TGEN off and leaves the board armed.
# This needs no receiver and no gate: it asks only whether the stream 148 PUTS ON AIR
# already carries a 32-frame anomaly.
# Env: GAP=45000 FILL=1516 HOLD_S=240 DRY=1
set -u
D=$(cd "$(dirname "$0")/.." && pwd); W=$D/anyssh.sh
A=10.0.0.148; GAP=${GAP:-45000}; FILL=${FILL:-1516}; HOLD_S=${HOLD_S:-240}; DRY=${DRY:-1}
DM='DM=$(command -v devmem || echo "busybox devmem")'
GAPW=$(( GAP & 0x7FFFFFF )); CTRLW=$(( (FILL << 4) | 1 ))
say(){ echo "$(date -Is) $*"; }
say "=== t8_tx148_tgen: 148 TX = TGEN byte stream, gap=$GAP fill=$FILL, hold ${HOLD_S}s, DRY=$DRY ==="
if [ "$DRY" = 1 ]; then say "[dry] TGEN on 148 ctrl=$(printf 0x%08X $CTRLW) gap=$(printf 0x%08X $GAPW); pump 2 s; rearm_byte x2; hold; TGEN off"; exit 0; fi
say "TGEN: $($W $A "$DM; \$DM 0x9D400008 32 $GAPW; \$DM 0x9D400000 32 $CTRLW; echo ctrl=\$(\$DM 0x9D400000) gap=\$(\$DM 0x9D400008)" 2>/dev/null | tr -d '\r')"
sleep 2
rb(){ $W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; echo byte_rearm_done' 2>/dev/null; }
rb; sleep 3; rb
say "148 transmitting the TGEN byte stream; holding ${HOLD_S}s"
sleep "$HOLD_S"
$W $A "$DM; \$DM 0x9D400000 32 0" 2>/dev/null
say "TGEN off; board left armed (0x158=1, 0x114=1)"
