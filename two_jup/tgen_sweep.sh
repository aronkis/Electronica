#!/bin/bash
# tgen_sweep.sh [dwell_s] -- walk {fill,gap} on 148 loopback; one CSV row per point.
# Per point: write regs -> READBACK-VERIFY -> scorer up -> dwell -> disable -> collect.
# Health gate per point: 0x104 advancing AND 0x1C0 advancing (DELTAS row).
# Exit restores enable=0 + watchdog. Requires the tgen image (Task 7) on 148 and the
# TGEN-aware scorer (qpsk_seq.c 1fd6db2) deployed. Arms internal loopback ONCE at
# start with the bringup-sequenced batch (T8 idiom); watchdog restart at exit re-arms
# 0x114 to AIR on its own.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; A=10.0.0.148
DWELL=${1:-60}
# RXM / KEEPM: -S WITHOUT QPSK_SEQ_KEEPM=1 forces rx_multi=0 (qpsk_tun.c ~2682:
#   "if (ber || (seqmode && !keepm)) rx_multi = 0"), i.e. the daemon silently drops to
# single-packet-per-transfer DMA and -M does nothing. The source comment is explicit:
# without KEEPM, "-S bypasses the very path we are bisecting". Every tgen_sweep result
# banked before 2026-08-23 ran that way and therefore says NOTHING about batched DMA.
# KEEPM=1 (default OFF, so prior behaviour is unchanged) engages the batched path and
# makes RXM meaningful; verify by SEQDMA batch_m == RXM in the output.
RXM=${RXM:-16}
KEEPMENV=""; [ "${KEEPM:-0}" = 1 ] && KEEPMENV="QPSK_SEQ_KEEPM=1"
GAPS=${GAPS:-"400000 200000 100000 50000 20000 8000 2000 0"}
FILLS=${FILLS:-"1516 700 100 1"}
STAMP=$(date +%Y%m%d_%H%M%S); CSV=$D/tgen_sweep_$STAMP.csv
echo "fill,gap,offered_fps,ok,lost,gaps,biterr,dup,junk,torn_zero,torn_stale,scattered,batch_drop,d104,d108,d1C0" > "$CSV"
restore(){ $W $A 'DM=$(command -v devmem || echo "busybox devmem"); $DM 0x9D400000 32 0' 2>/dev/null
  $W $A 'nohup setsid /root/lock_watchdog.sh </dev/null >/dev/shm/watchdog.log 2>&1 & exit 0' 2>/dev/null; }
trap restore EXIT
$W $A 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog"; exit 0' 2>/dev/null

# arm internal loopback once (bringup-sequenced batch, verbatim T8/loopback_s_test idiom)
$W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x1">$DRA
  echo "0x118 0x0">$DRA
  echo "0x114 0x0">$DRA
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
  echo "  loopback armed (0x114=0)"' 2>/dev/null

for f in $FILLS; do for g in $GAPS; do
  $W $A "DM=\$(command -v devmem || echo 'busybox devmem'); \$DM 0x9D400008 32 $g; \$DM 0x9D400000 32 \$(( ($f << 4) | 1 ))" 2>/dev/null
  RB=$($W $A "DM=\$(command -v devmem || echo 'busybox devmem'); echo \$(\$DM 0x9D400000) \$(\$DM 0x9D400008)" 2>/dev/null)
  echo "point fill=$f gap=$g readback: $RB"
  case "$RB" in *$(printf '0x%08X' $(( (f << 4) | 1 )))*) : ;; *) echo "READBACK MISMATCH -- abort"; exit 1;; esac
  R=$($W $A "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
    rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
    p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108))); w0=\$((\$(rd 0x1C0)))
    pkill -x qpsk_tun 2>/dev/null; sleep 1
    cd /root/host_app_k5 && QPSK_FRAME=f1536 QPSK_SEQ_RXONLY=1 QPSK_RX_QUEUED=1 QPSK_WHITEN=0 $KEEPMENV \
      setsid chrt -f 50 ./qpsk_tun -S -M $RXM -r 15360 -d $DWELL 2>&1 | grep -E 'SEQRX|SEQDMA' | tail -4
    p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108))); w1=\$((\$(rd 0x1C0)))
    echo DELTAS \$((p1-p0)) \$((e1-e0)) \$((w1-w0))" 2>/dev/null)
  $W $A 'DM=$(command -v devmem || echo "busybox devmem"); $DM 0x9D400000 32 0' 2>/dev/null
  echo "$R" | sed 's/^/  /'
  echo "$R" | sed 's/(\([0-9]*\) gaps)/gaps=\1/' | awk -v f=$f -v g=$g -v dw=$DWELL '
    /SEQRX frames_scored/ { for(i=1;i<=NF;i++){n=split($i,kv,"="); if(n==2) v[kv[1]]=kv[2]} }
    /SEQDMA/ { for(i=1;i<=NF;i++){n=split($i,kv,"="); if(n==2) v[kv[1]]=kv[2]} }
    /^DELTAS/ { d104=$2; d108=$3; d1c0=$4 }
    END { off = 125000000/(100400+g);
      printf "%s,%s,%.1f,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", f,g,off,
        v["ok"],v["lost"],v["gaps"],v["biterr"],v["dup"],v["junk"],
        v["torn_zero"],v["torn_stale"],v["scattered"],v["batch_drop"],d104,d108,d1c0 }' >> "$CSV"
  tail -1 "$CSV"
  # per-point health gate: 0x104 AND 0x1C0 must have advanced
  LAST=$(tail -1 "$CSV"); D104=$(echo "$LAST" | cut -d, -f14); D1C0=$(echo "$LAST" | cut -d, -f16)
  if [ "${D104:-0}" -le 0 ] || [ "${D1C0:-0}" -le 0 ]; then
    echo "HEALTH_GATE_FAIL at fill=$f gap=$g (d104=$D104 d1C0=$D1C0) -- abort sweep"; exit 2
  fi
done; done
echo "SWEEP_DONE $CSV"
