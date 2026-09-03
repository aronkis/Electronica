#!/bin/bash
# =============================================================================
# t8_smoke_tgen.sh -- TGEN generate-mode smoke (plan Task 8, silicon gate 2).
#
# On 148 (tgen image c183d42911b3): quiesce watchdog, arm internal loopback
# with the bringup-sequenced DRA batch (loopback_s_test.sh idiom -- stream
# would normally pump first, but in generate mode the TGEN block IS the byte
# stream; the scorer daemon is RX-only via QPSK_SEQ_RXONLY), start the -S
# scorer, enable the generator at the benign point (fill=1516, gap=200000 clk
# ~= 416 f/s offered), dwell 60 s, disable, verify 0x1C0 stops.
#
# Verdict criteria (brief): SEQRX ok ~= offered*60 (+/- few %), lost ~= 0,
# buckets 0/0/0/0; delta(0x1C0) ~= ok*191. On PN mismatch: STOP -- byte-lane
# order wrong => fix RTL packing, re-TB, rebuild.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.148
DUR=${DUR:-60}
GAP=${GAP:-200000}
FILL=${FILL:-1516}
OUT=$D/r3cap/t8_smoke_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
OFFERED=$(( 125000000 / (100400 + GAP) ))
echo "=== T8 generate-mode smoke on $B: fill=$FILL gap=$GAP (~${OFFERED} f/s offered), dwell ${DUR}s -> $OUT ==="

echo "--- [1] stop watchdog (single DRA writer; it would re-arm 0x114 to AIR) ---"
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; sleep 1
  pgrep -f "[l]ock_watchdog" >/dev/null && echo "  watchdog STILL UP" || echo "  watchdog stopped"' 2>/dev/null

echo "--- [2] start RX-only scorer (window covers the whole tgen dwell) ---"
$W $B "pkill -x qpsk_tun 2>/dev/null; sleep 1; cd /root/host_app_k5; rm -f /dev/shm/t8.log
  QPSK_FRAME=f1536 QPSK_SEQ_RXONLY=1 QPSK_RX_QUEUED=1 setsid chrt -f 50 \
    ./qpsk_tun -S -M 16 -r 15360 -d $((DUR + 20)) > /dev/shm/t8.log 2>&1 &
  exit 0" >/dev/null 2>&1
sleep 3

echo "--- [3] arm internal loopback (bringup-sequenced DRA batch, verbatim idiom) ---"
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x1">$DRA        # tx_data_source = byte DMA (same value bringup set)
  echo "0x118 0x0">$DRA        # tx_source_select = in-FPGA Tx
  echo "0x114 0x0">$DRA        # rx_input_select = LOOPBACK (not air)
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
  echo "  loopback armed (0x114=0)"' 2>/dev/null

echo "--- [4] baseline counters + enable generator (readback-verified) ---"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
  DM=\$(command -v devmem || echo 'busybox devmem')
  p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108))); w0=\$((\$(rd 0x1C0)))
  echo BASE \$p0 \$e0 \$w0 > /dev/shm/t8_base
  \$DM 0x9D400008 32 $GAP
  \$DM 0x9D400000 32 \$(( ($FILL << 4) | 1 ))
  echo \"TGEN_RB ctrl=\$(\$DM 0x9D400000) gap=\$(\$DM 0x9D400008)\"" 2>/dev/null | tee "$OUT/enable.txt"
EXPCTRL=$(printf '0x%08X' $(( (FILL << 4) | 1 )))
grep -q "ctrl=$EXPCTRL" "$OUT/enable.txt" || { echo "READBACK MISMATCH (want ctrl=$EXPCTRL) -- ABORT"; exit 1; }

echo "--- [5] dwell ${DUR}s ---"
sleep "$DUR"

echo "--- [6] end counters, disable, confirm 0x1C0 stops ---"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
  DM=\$(command -v devmem || echo 'busybox devmem')
  p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108))); w1=\$((\$(rd 0x1C0)))
  read _ p0 e0 w0 < /dev/shm/t8_base
  \$DM 0x9D400000 32 0
  sleep 0.1
  wA=\$((\$(rd 0x1C0))); sleep 1; wB=\$((\$(rd 0x1C0)))
  echo \"DELTAS d104=\$((p1-p0)) d108=\$((e1-e0)) d1C0=\$((w1-w0))\"
  echo \"POST_DISABLE d1C0_1s=\$((wB-wA)) (must be 0 within one frame time)\"" 2>/dev/null | tee "$OUT/deltas.txt"

echo "--- [7] wait for scorer summary + collect ---"
sleep 26
$W $B 'cat /dev/shm/t8.log' 2>/dev/null > "$OUT/scorer.log"
echo "  --- SEQRX/SEQDMA summary ---"
grep -E "^SEQRX|^SEQDMA" "$OUT/scorer.log" | sed 's/^/    /' || echo "    (none printed)"
tail -3 "$OUT/scorer.log" | sed 's/^/    /'

echo "--- [8] verdict aids ---"
echo "  offered*DUR = $(( OFFERED * DUR )) frames expected"
D1C0=$(grep -oE 'd1C0=[0-9-]+' "$OUT/deltas.txt" | cut -d= -f2)
echo "  d1C0=$D1C0  => d1C0/191 = $(( ${D1C0:-0} / 191 )) frames through DUT TX"
echo "T8_SMOKE_DONE $OUT"
