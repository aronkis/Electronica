#!/bin/bash
# rxseam_sweep.sh -- Layer B seam ENVELOPE: walk {fill,gap} at the fabric->processor
# boundary and find where (if anywhere) it stops being bit-exact/zero-loss.
# Per point: quiesce -> fresh scorer -> FULL bringup-sequenced arm batch (mandatory:
# a fresh queued arm on an un-reset fabric replays stale DDR, #48 signature) ->
# enable(fill,gap) -> dwell -> disable -> collect -> CSV row.
# PASS per point: in-window lost==0 && biterr==0 (dups/junk outside the window are
# the documented pre-arm artifact and filler; recorded, not counted against).
# Offered rate at the seam = 125e6 / (1719 + gap) f/s (frame emission ~1719 clk).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.148
DWELL=${DWELL:-30}
GAPS=${GAPS:-"200000"}
FILLS=${FILLS:-"1516"}
STAMP=$(date +%Y%m%d_%H%M%S); CSV=$D/rxseam_sweep_$STAMP.csv
echo "fill,gap,offered_fps,ok,lost,gaps_ev,biterr,dup,junk,ok_per_s,verdict" > "$CSV"

point(){ # $1=fill $2=gap
  local f=$1 g=$2
  if [ "${RESTORE_PER_POINT:-0}" = 1 ]; then
    bash "$D/restore_known_good.sh" > /tmp/rxs_point_restore.log 2>&1
  fi
  $W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
    pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1' 2>/dev/null
  $W $B "cd /root/host_app_k5; rm -f /dev/shm/rxs.log
    QPSK_FRAME=f1536 QPSK_SEQ_RXONLY=1 QPSK_RX_QUEUED=1 setsid chrt -f 50 \
      ./qpsk_tun -S -M 16 -r 15360 -d $((DWELL + 18)) > /dev/shm/rxs.log 2>&1 &
    exit 0" >/dev/null 2>&1
  sleep 2
  $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
    echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
    echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
    TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
    T=/sys/kernel/debug/iio/$TXD/direct_reg_access
    echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
    echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null
  sleep 1
  RB=$($W $B "DM=\$(command -v devmem || echo 'busybox devmem')
    \$DM 0x9D410008 32 $g; \$DM 0x9D410000 32 \$(( ($f << 4) | 1 ))
    echo \$(\$DM 0x9D410000)" 2>/dev/null)
  case "$RB" in *$(printf '0x%08X' $(( (f << 4) | 1 )))*) : ;; *) echo "READBACK MISMATCH fill=$f -- abort"; exit 1;; esac
  sleep "$DWELL"
  $W $B 'DM=$(command -v devmem || echo "busybox devmem"); $DM 0x9D410000 32 0' 2>/dev/null
  sleep 22
  R=$($W $B 'grep -E "^SEQRX frames" /dev/shm/rxs.log | tail -1' 2>/dev/null)
  echo "  $R"
  echo "$R" | sed 's/(\([0-9]*\) gaps)/gapsev=\1/' | awk -v f=$f -v g=$g -v dw=$DWELL '
    { for(i=1;i<=NF;i++){n=split($i,kv,"="); if(n==2) v[kv[1]]=kv[2]} }
    END { off = 125000000/(1719+g);
      ok=v["ok"]+0; lost=v["lost"]+0; be=v["biterr"]+0;
      expf = off*dw;
      verdict = (lost==0 && be==0 && ok >= 0.9*expf) ? "PASS" : (ok < 0.02*expf ? "NO_DELIVERY" : "FAIL");
      printf "%s,%s,%.0f,%d,%d,%s,%d,%s,%s,%.1f,%s\n", f,g,off,
        ok,lost,v["gapsev"],be,v["dup"],v["junk"],ok/dw,verdict }' >> "$CSV"
  tail -1 "$CSV"
}

for f in $FILLS; do for g in $GAPS; do
  for try in 1 2 3; do
    echo "=== point fill=$f gap=$g try=$try (offered ~$(( 125000000/(1719+g) )) f/s) ==="
    point "$f" "$g"
    V=$(tail -1 "$CSV" | awk -F, '{print $NF}')
    if [ "$V" != "NO_DELIVERY" ]; then break; fi
    if [ $try -lt 3 ]; then sed -i '$d' "$CSV"; echo "  arm lottery miss (attempt $try) -- retrying with restore"; RESTORE_PER_POINT=1; fi
  done
done; done

echo "--- restore rig ---"
bash "$D/restore_known_good.sh" > /tmp/rxseam_sweep_restore.log 2>&1
echo "RXSEAM_SWEEP_DONE $CSV"
