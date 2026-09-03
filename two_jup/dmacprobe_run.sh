#!/bin/bash
# dmacprobe_run.sh -- ONE deterministic RX-seam point on 148 (DMAC-probe image, injector v2).
# No RF, no modem DSP: qpsk_traffic_gen_rx v2 -> rx_byte_breakout -> axi_dmac S2MM -> DDR -> qpsk_tun -S scorer.
# Knobs (env): RXQ=0|1  M=16|32  WORDGAP=<extra clks between words; period=WORDGAP+10>  GAP=<clks frame->frame>
#              MASK=0|1 (1: set ctrl[2] user_mask MASK_AFTER s after enable = Option E probe)  FILL=1516  DUR=60
# Witness: injector counters @0x9D450000 (acc_beats) / 0x9D450008 (acc_user), modem 0x1C0 (pins), scorer EVT lines.
# Derived from rxseam_zeroloss.sh (arm idiom verbatim). Takes RIG_LOCK unless RIGLOCK_PARENT=1.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; B=10.0.0.148
RXQ=${RXQ:-1}; M=${M:-16}; WORDGAP=${WORDGAP:-535}; GAP=${GAP:-545}; MASK=${MASK:-0}; MASK_AFTER=${MASK_AFTER:-3}
FILL=${FILL:-1516}; DUR=${DUR:-60}
TAG=rxq${RXQ}_m${M}_wg${WORDGAP}_gap${GAP}_mask${MASK}
OUT=${OUT:-$D/r3cap/dmacprobe_$(date +%Y%m%d_%H%M%S)_$TAG}; mkdir -p "$OUT"
. "$D/sim_repro/riglock.sh" 2>/dev/null || true
[ "${RIGLOCK_PARENT:-0}" = 1 ] || { type rig_lock >/dev/null 2>&1 && { rig_lock dmacprobe || { echo "DMACPROBE_ABORT rig busy"; exit 2; }; }; }
echo "=== DMACPROBE $TAG fill=$FILL dur=${DUR}s -> $OUT ==="
CTRL=$(( (WORDGAP << 16) | (FILL << 4) | 1 ))
DM='DM=$(command -v devmem || echo "busybox devmem")'

$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1' 2>/dev/null
$W $B "$DM; \$DM 0x9D410000 32 0" 2>/dev/null     # injector off, pass-through
$W $B "cd /root/host_app_k5; rm -f /dev/shm/rxseam.log
  QPSK_FRAME=f1536 QPSK_SEQ_RXONLY=1 QPSK_RX_QUEUED=$RXQ setsid chrt -f 50 \
    ./qpsk_tun -S -M $M -r 15360 -d $((DUR + 30)) > /dev/shm/rxseam.log 2>&1 &
  exit 0" >/dev/null 2>&1
sleep 3
# bringup-sequenced loopback arm (double-tap, verbatim rxseam_zeroloss.sh) -- modem stream is
# consumed-and-discarded at the seam once the injector is enabled
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  for k in 1 2; do
    echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
    echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
    echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
    echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; [ $k = 1 ] && sleep 3
  done' 2>/dev/null
sleep 2
wit(){ $W $B "$DM; DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo 0x1C0 > \$DRA; echo \"WIT $1 beats=\$(\$DM 0x9D450000) user=\$(\$DM 0x9D450008) pins=\$(cat \$DRA) t=\$(date +%s.%N)\"" 2>/dev/null; }
wit pre | tee -a "$OUT/witness.txt"
$W $B "$DM; N=\$(grep -c '^seq: t=' /dev/shm/rxseam.log 2>/dev/null || echo 0); \$DM 0x9D410008 32 $GAP; \$DM 0x9D410000 32 $CTRL
  echo \"TGENRX_RB ctrl=\$(\$DM 0x9D410000) gap=\$(\$DM 0x9D410008) nbefore=\$N\"" 2>/dev/null | tee "$OUT/enable.txt"
grep -q "ctrl=$(printf '0x%08X' $CTRL)" "$OUT/enable.txt" || { echo "DMACPROBE_ABORT readback mismatch"; type rig_unlock >/dev/null 2>&1 && [ "${RIGLOCK_PARENT:-0}" != 1 ] && rig_unlock; exit 1; }
if [ "$MASK" = 1 ]; then sleep "$MASK_AFTER"; $W $B "$DM; \$DM 0x9D410000 32 $((CTRL | 4)); echo MASK_ON ctrl=\$(\$DM 0x9D410000) t=\$(date +%s.%N)" 2>/dev/null | tee -a "$OUT/enable.txt"; wit mask | tee -a "$OUT/witness.txt"; fi
sleep "$DUR"
wit post | tee -a "$OUT/witness.txt"
$W $B "$DM; \$DM 0x9D410000 32 0" 2>/dev/null
sleep 5
$W $B 'cat /dev/shm/rxseam.log' 2>/dev/null > "$OUT/scorer.log"
NB=$(grep -oE 'nbefore=[0-9]+' "$OUT/enable.txt" | tr -dc 0-9)
python3 "$D/dmacprobe_score.py" "$OUT/scorer.log" "$OUT/witness.txt" "$NB" "$M" "$TAG" | tee "$OUT/verdict.txt"
[ "${RIGLOCK_PARENT:-0}" = 1 ] || { type rig_unlock >/dev/null 2>&1 && rig_unlock; }
echo "DMACPROBE_DONE $OUT"
