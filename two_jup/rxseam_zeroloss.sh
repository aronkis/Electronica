#!/bin/bash
# rxseam_zeroloss.sh -- Layer B PROPER: zero-loss check of the RX-seam injector.
# Path under test: qpsk_traffic_gen_rx -> rx_byte_breakout -> axi_dmac S2MM ->
# DDR -> qpsk_tun -S scorer. NO modem DSP anywhere (no loopback arm needed; the
# generator stalls the DUT RX stream while enabled).
# Spec expectation: ok == offered exactly, lost=0, biterr=0, dup=0, BER=0.
# Any deviation is a DMA/host-boundary defect by construction.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.148
DUR=${DUR:-60}
GAP=${GAP:-200000}
FILL=${FILL:-1516}
OUT=$D/r3cap/rxseam_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
echo "=== RX-seam zero-loss on $B: fill=$FILL gap=$GAP dwell=${DUR}s -> $OUT ==="

echo "--- [1] stop watchdog + daemon (scorer owns the RX DMA) ---"
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1
  echo "  watchdog+daemon stopped"' 2>/dev/null

echo "--- [2] start RX-only scorer ---"
$W $B "cd /root/host_app_k5; rm -f /dev/shm/rxseam.log
  QPSK_FRAME=f1536 QPSK_SEQ_RXONLY=1 QPSK_RX_QUEUED=1 setsid chrt -f 50 \
    ./qpsk_tun -S -M ${MOPT:-16} -r 15360 -d $((DUR + 20)) > /dev/shm/rxseam.log 2>&1 &
  exit 0" >/dev/null 2>&1
sleep 3

echo "--- [2b] full bringup-sequenced arm (T8 idiom: reset + mux config; queued arm needs a fresh fabric) ---"
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x1">$DRA        # tx_data_source = byte DMA (bringup value)
  echo "0x118 0x0">$DRA
  echo "0x114 0x0">$DRA        # LOOPBACK: self-contained, matches proven T8 idiom
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
  sleep 3
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
  echo "  armed (loopback, byte source, DOUBLE-TAP per bringup ARMCAUSE)"' 2>/dev/null
sleep 2

echo "--- [3] enable RX-seam generator (readback-verified; summary-line count snapshotted atomically at enable) ---"
# NBEFORE = number of periodic scorer summary lines already printed when the enable
# lands. The first line AFTER that (index NBEFORE+1) is the in-dwell baseline: stale
# ring replay (dups of the prior session's frames, 2026-08-19 finding) stops at the
# enable instant, so that line carries ALL arm residue and none of the dwell.
$W $B "DM=\$(command -v devmem || echo 'busybox devmem')
  N=\$(grep -c '^seq: t=' /dev/shm/rxseam.log 2>/dev/null || echo 0)
  \$DM 0x9D410008 32 $GAP
  \$DM 0x9D410000 32 \$(( ($FILL << 4) | 1 ))
  echo \"TGENRX_RB ctrl=\$(\$DM 0x9D410000) gap=\$(\$DM 0x9D410008) nbefore=\$N\"" 2>/dev/null | tee "$OUT/enable.txt"
EXPCTRL=$(printf '0x%08X' $(( (FILL << 4) | 1 )))
grep -q "ctrl=$EXPCTRL" "$OUT/enable.txt" || { echo "READBACK MISMATCH (want $EXPCTRL) -- ABORT"; exit 1; }
NBEFORE=$(grep -oE 'nbefore=[0-9]+' "$OUT/enable.txt" | tr -dc 0-9)

echo "--- [4] dwell ${DUR}s ---"
sleep "$DUR"

echo "--- [5] disable + collect ---"
$W $B 'DM=$(command -v devmem || echo "busybox devmem"); $DM 0x9D410000 32 0' 2>/dev/null
sleep 25
$W $B 'cat /dev/shm/rxseam.log' 2>/dev/null > "$OUT/scorer.log"
grep -E "^SEQRX|^SEQDMA" "$OUT/scorer.log" | tail -4 | sed 's/^/  /'

echo "--- [6] verdict (in-dwell deltas vs baseline summary line $((NBEFORE+1)); arm residue reported separately) ---"
awk -v nb="$NBEFORE" '
  /^seq: t=/ { ns++; if (ns == nb+1) { for(i=1;i<=NF;i++){n=split($i,kv,"="); if(n==2) b[kv[1]]=kv[2]} ; have=1 } }
  /SEQRX frames_scored/ { for(i=1;i<=NF;i++){n=split($i,kv,"="); if(n==2) v[kv[1]]=kv[2]} }
  END {
    if (!have) { b["ok"]=0; b["lost"]=0; b["biterr"]=0; b["dup"]=0;
      print "WARN: no post-enable baseline summary line found -- verdict uses raw totals" }
    ok=v["ok"]-b["ok"]; lost=v["lost"]-b["lost"]; be=v["biterr"]-b["biterr"]; dup=v["dup"]-b["dup"];
    printf "ARM_RESIDUE (pre-enable, excluded): ok=%d lost=%d biterr=%d dup=%d\n",
      b["ok"]+0, b["lost"]+0, b["biterr"]+0, b["dup"]+0;
    if (ok > 0 && lost == 0 && be == 0 && dup == 0)
      printf "RXSEAM_ZEROLOSS_PASS ok=%d lost=0 biterr=0 dup=0\n", ok;
    else
      printf "RXSEAM_ZEROLOSS_FAIL ok=%d lost=%d biterr=%d dup=%d\n", ok, lost, be, dup }' "$OUT/scorer.log"
echo "RXSEAM_DONE $OUT"
