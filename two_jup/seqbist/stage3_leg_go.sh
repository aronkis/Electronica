#!/bin/bash
# =============================================================================
# stage3_leg_go.sh -- one two-board fabric-only RF SEQ-BIST leg (task 8 stage 3).
#
# Geometry (DIRN):
#   fwd : TGEN on 146, checker on 148, SINK=tgenrx   (the 8.12 % forward leg)
#   rev : TGEN on 148, checker on 146, SINK=cyclic   (the 3.7 % reverse leg)
# Preconditions: bringup_fabric_only.sh has passed -- BOTH boards armed ROM
# (0x158=0, 0x114=1), no daemon, no watchdog, no DMA.
#
# ORDER (R2FINISH, see bringup_fabric_only.sh's header): TGEN ON FIRST, let the byte
# FIFO fill, and only THEN flip the transmitter to the byte source (double-tapped).
# The receiver is never re-armed after that point, so the checker window is not
# perturbed. seqbist_run.sh is then invoked with TGEN_EXTERNAL=1 so it does not
# stop/restart the generator underneath a live RF link.
#
# Bring-up gate BEFORE the window is spent (brief): on the RECEIVER, 0x124
# (cnt_frame_start) >= GATE_FPS124 f/s AND |chk_frames - 0x124| / 0x124 <= GATE_DEV %.
# On failure the leg is NOT run: TGEN off, sink disarmed, exit 7 with the numbers.
#
# Env: DIRN=fwd|rev  GAP=60000  DUR=600  FILL=1516  TAG=  DRY=1
#      GATE_FPS124=1100  GATE_DEV=2.0  GATE_WIN=15  PUMP_S=2
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); TJ=$(cd "$D/.." && pwd); W=$TJ/anyssh.sh
DIRN=${DIRN:?usage: DIRN=fwd|rev}
GAP=${GAP:-60000}; DUR=${DUR:-600}; FILL=${FILL:-1516}
TAG=${TAG:-$DIRN}; DRY=${DRY:-1}
GATE_FPS124=${GATE_FPS124:-1100}; GATE_DEV=${GATE_DEV:-2.0}
GATE_WIN=${GATE_WIN:-15}; PUMP_S=${PUMP_S:-2}
# SINK may be overridden per leg. SINK=none means the CALLER has provided the drain --
# used for the reverse fallback where 146's own plain daemon is started as the drain
# ("DMA as sink DOWNSTREAM of the measurement": the checker still snoops the DUT pins
# upstream of the DMAC, so the loss numbers stay fabric-side, but the leg is no longer
# host-free and must be labelled as such).
case "$DIRN" in
  fwd) TXB=146; RXB=148; SINK=${SINK:-tgenrx} ;;
  rev) TXB=148; RXB=146; SINK=${SINK:-cyclic} ;;
  *) echo "STAGE3_REFUSED: DIRN must be fwd|rev" >&2; exit 3 ;;
esac
ip(){ case "$1" in 148) echo 10.0.0.148 ;; 146) echo 10.0.0.146 ;; esac; }
TIP=$(ip $TXB); RIP=$(ip $RXB)
DM='DM=$(command -v devmem || echo "busybox devmem")'
CYC_DMA_BASE=${CYC_DMA_BASE:-0x9D200000}
CYC_DEST=${CYC_DEST:-0x7FE40000}
CYC_RING_BYTES=${CYC_RING_BYTES:-98304}
say(){ echo "$(date -Is) $*"; }
say "=== stage3 leg $DIRN: TGEN on $TXB -> checker on $RXB, SINK=$SINK, GAP=$GAP FILL=$FILL DUR=$DUR DRY=$DRY ==="

SINK_ARMED=0
sink_disarm(){
  [ "$SINK_ARMED" = 1 ] || return 0
  SINK_ARMED=0
  [ "$DRY" = 1 ] && { say "[dry] sink disarm ($SINK on $RXB)"; return 0; }
  case "$SINK" in
    tgenrx) $W "$RIP" "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C & ~1 ))" 2>/dev/null ;;
    cyclic) $W "$RIP" "$DM; \$DM \$(($CYC_DMA_BASE+0x400)) 32 0" 2>/dev/null ;;
  esac
  say "sink disarmed on $RXB"
}
tgen_off(){ [ "$DRY" = 1 ] && { say "[dry] TGEN off on $TXB"; return 0; }
  $W "$TIP" "$DM; \$DM 0x9D400000 32 0" 2>/dev/null; say "TGEN off on $TXB"; }
trap 'sink_disarm' EXIT INT TERM

# ---- 1. arm the RX sink FIRST (ORDER FIX, task 8) --------------------------
# The reverse leg's first attempt armed the drain AFTER starting the generator and
# flipping the transmitter to the byte source, so ~10 s of frames arrived at 146's RX
# byte seam with nothing draining it. Result: 0x124 = 1247.5 f/s (the air link was
# perfect) with chk_frames = 0, and a read-only probe afterwards found 146's 0x1B0
# byte_fifo_ovf at 22,936,204 -- the ByteRxFifo had overflowed, which is the documented
# "sustained drain stall is the #48 wedge trigger". The drain must be up BEFORE any
# traffic exists. (SINK=tgenrx survived the wrong order on 148; SINK=cyclic did not.)
if [ "$DRY" = 1 ]; then say "[dry] sink arm $SINK on $RXB"
else
  case "$SINK" in
    none) say "SINK=none: no drain armed here -- the caller owns it (daemon-as-sink fallback)" ;;
    tgenrx) say "sink tgenrx: $($W "$RIP" "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C | 1 )); echo pre=\$C post=\$(\$DM 0x9D410000)" 2>/dev/null | tr -d '\r')" ;;
    cyclic) say "sink cyclic: $($W "$RIP" "$DM; B=$CYC_DMA_BASE
        \$DM \$((B+0x400)) 32 0; \$DM \$((B+0x400)) 32 1
        \$DM \$((B+0x410)) 32 $CYC_DEST; \$DM \$((B+0x418)) 32 $((CYC_RING_BYTES-1))
        \$DM \$((B+0x40C)) 32 1; \$DM \$((B+0x408)) 32 1
        echo ctrl=\$(\$DM \$((B+0x400))) flags=\$(\$DM \$((B+0x40C)))" 2>/dev/null | tr -d '\r')" ;;
  esac
fi
SINK_ARMED=1

# ---- 2. TGEN on the transmitter (ctrl bit0 en, [15:4] fill; gap word) -------
GAPW=$(( GAP & 0x7FFFFFF ))
CTRLW=$(( (FILL << 4) | 1 ))
say "TGEN_WORDS ctrl=$(printf '0x%08X' $CTRLW) gap=$(printf '0x%08X' $GAPW)"
if [ "$DRY" = 1 ]; then say "[dry] $TXB TGEN on"
else say "$TXB TGEN: $($W "$TIP" "$DM; \$DM 0x9D400008 32 $GAPW; \$DM 0x9D400000 32 $CTRLW; echo ctrl=\$(\$DM 0x9D400000) gap=\$(\$DM 0x9D400008)" 2>/dev/null | tr -d '\r')"; fi

# ---- 3. let the byte FIFO fill, THEN flip the TX source to byte (double-tap) -
[ "$DRY" = 1 ] || sleep "$PUMP_S"
rearm_byte(){ # bringup_r2r3.sh rearm_byte VERBATIM
  [ "$DRY" = 1 ] && { say "[dry] rearm_byte $1"; return 0; }
  $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
 echo "byte re-arm done"' 2>/dev/null; }
say "flipping $TXB to the byte source with TGEN already pumping (R2FINISH order)"
rearm_byte "$TIP"; [ "$DRY" = 1 ] || sleep 3; rearm_byte "$TIP"

# ---- 4. checker clear on the receiver (RMW bit4 low -> high) ----------------
if [ "$DRY" = 1 ]; then say "[dry] checker clear on $RXB (RMW bit4)"
else $W "$RIP" "$DM; C=\$(\$DM 0x9D410000); \$DM 0x9D410000 32 \$(( C & ~16 )); sleep 0.05; \$DM 0x9D410000 32 \$(( C | 16 ))" 2>/dev/null; fi

# ---- 5. bring-up gate: two reads GATE_WIN apart on the receiver -------------
READ=$D/seqbist_read.py
if [ "$DRY" = 1 ]; then
  say "[dry] gate: two seqbist_read.py samples ${GATE_WIN}s apart on $RXB; need 0x124 >= $GATE_FPS124 f/s and dev <= $GATE_DEV %"
  GVERD=PASS; G124=1245.0; GCHK=1245.0; GDEV=0.01
else
  sleep 5
  S0=$(python3 "$READ" "$RXB") || { say "STAGE3_UNINFORMATIVE: receiver $RXB unreachable at the gate"; tgen_off; exit 6; }
  sleep "$GATE_WIN"
  S1=$(python3 "$READ" "$RXB") || { say "STAGE3_UNINFORMATIVE: receiver $RXB unreachable at the gate"; tgen_off; exit 6; }
  set -- $(python3 -c '
import json,sys
a,b=json.loads(sys.argv[1]),json.loads(sys.argv[2])
dt=b["ts_mono"]-a["ts_mono"] if "ts_mono" in a else float(sys.argv[4])
if dt<=0: dt=float(sys.argv[4])
d124=b["reg_0x124"]-a["reg_0x124"]; dchk=b["chk_frames"]-a["chk_frames"]; d104=b["reg_0x104"]-a["reg_0x104"]
f124=d124/dt; fchk=dchk/dt
dev=abs(fchk-f124)/f124*100 if f124>0 else 100.0
ok = (f124>=float(sys.argv[3])) and (dev<=float(sys.argv[5])) and d124>0
print("PASS" if ok else "FAIL", "%.1f"%f124, "%.1f"%fchk, "%.3f"%dev, "%.1f"%(d104/dt), "%.1f"%dt)' \
    "$S0" "$S1" "$GATE_FPS124" "$GATE_WIN" "$GATE_DEV")
  GVERD=$1; G124=$2; GCHK=$3; GDEV=$4; G104=$5; GDT=$6
  say "STAGE3_GATE $DIRN verdict=$GVERD dt=${GDT}s 0x124=$G124 f/s chk_frames=$GCHK f/s dev=$GDEV % 0x104=$G104 f/s (need 0x124>=$GATE_FPS124 and dev<=$GATE_DEV)"
  if [ "$GVERD" != PASS ]; then
    say "STAGE3_GATE_FAIL $DIRN -- NOT spending the ${DUR}s window. TGEN off, sink disarmed, boards left armed."
    tgen_off; exit 7
  fi
fi
say "STAGE3_GATE_PASS $DIRN"

# ---- 6. the leg. TGEN_EXTERNAL=1: the generator is NOT interrupted ----------
RC=0
DRY=$DRY BOARD=$RXB TGEN_BOARD=$TXB TGEN_EXTERNAL=1 TXCHK=1 MODE=rf SINK=$SINK SINK_PREARMED=1 \
  FILL=$FILL GAP=$GAP DUR=$DUR TAG=$TAG WINDOW_MIN=${WINDOW_MIN:-150} \
  bash "$D/seqbist_run.sh" || RC=$?
say "seqbist_run rc=$RC"
tgen_off
say "STAGE3_LEG_DONE $DIRN rc=$RC gate_0x124=$G124 gate_chk=$GCHK gate_dev=$GDEV"
exit $RC
