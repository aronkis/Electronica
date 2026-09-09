#!/bin/bash
# =============================================================================
# arq_r3.sh [opts] -- R3/f1536 ARQ delivered-PER measurement, BOTH directions.
#
# Brings up the R3 link with the in-process ARQ FORCED ON (-A via bringup's
# DAEMON_EXTRA passthrough) and measures END-TO-END delivered PER with saturating
# bidirectional qpsk_perf UDP, cross-checked against the raw modem PER (framelog)
# and the daemon's ARQ stats (retx/dups/recovered).
#
# CAVEAT (qpsk_tun.c:745-751): the in-process ARQ recovers LOCALLY -- it resubmits
# from ITS OWN tx history because "both RF endpoints terminate in this process".
# On the TWO-RADIO link each board's history holds its own sent frames, not the
# peer's, so this measurement's job is to DETERMINE whether the existing ARQ
# reduces delivered PER across two radios or is a no-op needing NAK-over-link
# rework. qpsk_perf's unique-delivery is mechanism-agnostic, so the delivered-PER
# numbers are valid regardless.
#
# Delivered PER per dir = lost/tx (first-attempt); reorder ~= ARQ gap-fills, so
# delivered loss after ARQ ~= (lost-reorder)/tx. Compare vs the ARQ-off raw PER
# (fwd ~13.9% / rev ~21.3%, r3cap 20260729_135508/135821).
#
# Options: -d DUR (measure secs, def 60)  -b BPS (offered each dir, def 15000000)
#          -l BYTES (UDP payload, def 1400)  -o OUTDIR (def arqmeas/<ts>)  -k keep
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=$(cd "$D/.." && pwd)/host_app_k5
A_IP=10.0.0.148; B_IP=10.0.0.146; TA=10.66.0.2; TB=10.66.0.1
FPORT=5001; RPORT=5002        # fwd 146->148:5001 ; rev 148->146:5002

DUR=60; BPS=15000000; PAY=1400; OUT=""; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    -d) DUR=$2; shift 2;; -b) BPS=$2; shift 2;; -l) PAY=$2; shift 2;;
    -o) OUT=$2; shift 2;; -k) KEEP=1; shift;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[ -n "$OUT" ] || OUT=$D/arqmeas/$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
rearm_byte(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }
crc_health(){ $W $1 'L=/dev/shm/qpsk_tun.log; g(){ grep "stats:" $L 2>/dev/null | tail -1; }
 s1=$(g); ok1=$(echo "$s1"|grep -o "dma_rx_ok=[0-9]*"|cut -d= -f2); c1=$(echo "$s1"|grep -o "crc_drop=[0-9]*"|cut -d= -f2)
 sleep 6; s2=$(g); ok2=$(echo "$s2"|grep -o "dma_rx_ok=[0-9]*"|cut -d= -f2); c2=$(echo "$s2"|grep -o "crc_drop=[0-9]*"|cut -d= -f2)
 dok=$(( ${ok2:-0} - ${ok1:-0} )); dc=$(( ${c2:-0} - ${c1:-0} )); tot=$((dok+dc)); [ $tot -gt 0 ] && echo $((100*dok/tot)) || echo -1' 2>/dev/null; }
# start the bidirectional qpsk_perf pair (servers + clients); $1 = client -t secs
start_perf(){
  $W $A_IP "pkill -x qpsk_perf 2>/dev/null; cd /root/host_app_k5; setsid ./qpsk_perf -s -p $FPORT </dev/null >/dev/shm/perf_fwd_srv.log 2>&1 &" 2>/dev/null
  $W $B_IP "pkill -x qpsk_perf 2>/dev/null; cd /root/host_app_k5; setsid ./qpsk_perf -s -p $RPORT </dev/null >/dev/shm/perf_rev_srv.log 2>&1 &" 2>/dev/null
  sleep 1
  $W $B_IP "cd /root/host_app_k5; setsid ./qpsk_perf -c $TA -b $BPS -l $PAY -t $1 -p $FPORT </dev/null >/dev/shm/perf_fwd_cli.log 2>&1 &" 2>/dev/null
  $W $A_IP "cd /root/host_app_k5; setsid ./qpsk_perf -c $TB -b $BPS -l $PAY -t $1 -p $RPORT </dev/null >/dev/shm/perf_rev_cli.log 2>&1 &" 2>/dev/null
}
stop_perf(){ for ip in $A_IP $B_IP; do $W $ip 'pkill -x qpsk_perf 2>/dev/null' 2>/dev/null; done; }

echo "=== arq_r3: R3 ARQ-ON delivered-PER, both dirs, ${DUR}s @ $((BPS/1000000))Mbit -> $OUT ==="

# 1. deploy + build (qpsk_tun logger + qpsk_perf, f1536 carve)
for ip in $B_IP $A_IP; do
  $W $ip 'mkdir -p /root/host_app_k5' 2>/dev/null
  scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" \
         "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" \
         "$SRC/qpsk_uio.c" "$SRC/qpsk_uio.h" "$SRC/qpsk_perf.c" root@$ip:/root/host_app_k5/ \
         || { echo "scp $ip FAIL"; exit 1; }
  R=$($W $ip 'cd /root/host_app_k5 && gcc -O2 -Wall -DQPSK_CARVE_2MB -o qpsk_tun \
        qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c 2>/tmp/gcc.err \
        && gcc -O2 -Wall -o qpsk_perf qpsk_perf.c 2>>/tmp/gcc.err \
        && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }' 2>/dev/null)
  echo "  $ip build: $(echo "$R" | tail -1)"; echo "$R" | grep -q BUILD_OK || exit 1
done

# 2. R3 bring-up with ARQ FORCED ON
echo "--- bringup_r2r3.sh r3 (ARQ -A, logger on) ---"
DAEMON_EXTRA="-A" QPSK_FRAMELOG=/dev/shm/frames.bin "$D/bringup_r2r3.sh" r3 || { echo "R3 BRINGUP FAILED"; exit 1; }
echo "  daemon flags check:"; $W $A_IP 'grep -o "qpsk_tun .*" /dev/shm/qpsk_tun.log 2>/dev/null | head -1' 2>/dev/null

# 3. watchdogs off (steady-state measurement)
for ip in $B_IP $A_IP; do $W $ip 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
   pkill -9 -f "[l]ock_watchdog" 2>/dev/null' 2>/dev/null; done
sleep 2

# 4. warm-up traffic + wedge check BOTH RX (rearm a clearable wedge); then stop
start_perf $(( DUR + 120 ))
sleep 4
WTRY=1; WMAX=4; WTHRESH=50
while [ $WTRY -le $WMAX ]; do
  HF=$(crc_health $A_IP); HR=$(crc_health $B_IP)
  echo "  wedge try $WTRY: fwd(148)=${HF}%  rev(146)=${HR}% (need >= ${WTHRESH}%)"
  if [ "${HF:--1}" -ge "$WTHRESH" ] 2>/dev/null && [ "${HR:--1}" -ge "$WTHRESH" ] 2>/dev/null; then break; fi
  rearm_byte $B_IP; rearm_byte $A_IP; sleep 3; rearm_byte $B_IP; rearm_byte $A_IP; sleep 4
  WTRY=$(( WTRY + 1 ))
done
stop_perf; sleep 1

# 5. FRESH measurement window (clean qpsk_perf seq baseline; fresh framelog)
for ip in $A_IP $B_IP; do $W $ip 'pkill -USR2 -x qpsk_tun 2>/dev/null' 2>/dev/null; done  # rotate framelog
sleep 1
echo "--- MEASURE ${DUR}s (ARQ on, both dirs saturating) ---"
start_perf $DUR
sleep $(( DUR + 8 ))
stop_perf

# 6. collect: flush framelogs, pull perf logs + daemon stats + framelog
for ip in $A_IP $B_IP; do $W $ip 'pkill -USR1 -x qpsk_tun 2>/dev/null; sleep 0.5' 2>/dev/null; done
scpput root@$A_IP:/dev/shm/perf_fwd_srv.log "$OUT/perf_fwd_srv.log" 2>/dev/null || true
scpput root@$B_IP:/dev/shm/perf_fwd_cli.log "$OUT/perf_fwd_cli.log" 2>/dev/null || true
scpput root@$B_IP:/dev/shm/perf_rev_srv.log "$OUT/perf_rev_srv.log" 2>/dev/null || true
scpput root@$A_IP:/dev/shm/perf_rev_cli.log "$OUT/perf_rev_cli.log" 2>/dev/null || true
scpput root@$A_IP:/dev/shm/frames.bin "$OUT/frames_fwd_rx148.bin" 2>/dev/null || true
scpput root@$B_IP:/dev/shm/frames.bin "$OUT/frames_rev_rx146.bin" 2>/dev/null || true
$W $A_IP 'grep "stats:" /dev/shm/qpsk_tun.log | tail -1' 2>/dev/null > "$OUT/daemon_148.txt"
$W $B_IP 'grep "stats:" /dev/shm/qpsk_tun.log | tail -1' 2>/dev/null > "$OUT/daemon_146.txt"

# 7. report
echo ""; echo "=== ARQ-ON delivered PER (both directions) ==="
report_dir(){ # $1 label  $2 srv.log  $3 cli.log
  local S=$(grep PERF_SRV_DONE "$2" 2>/dev/null | tail -1); local C=$(grep PERF_CLI_DONE "$3" 2>/dev/null | tail -1)
  local rx=$(echo "$S"|grep -o "rx_pkts=[0-9]*"|cut -d= -f2); local lost=$(echo "$S"|grep -o "lost=[0-9]*"|cut -d= -f2)
  local dup=$(echo "$S"|grep -o "dup=[0-9]*"|cut -d= -f2); local reo=$(echo "$S"|grep -o "reorder=[0-9]*"|cut -d= -f2)
  local tx=$(echo "$C"|grep -o "tx_pkts=[0-9]*"|cut -d= -f2)
  awk -v l="$1" -v tx="${tx:-0}" -v rx="${rx:-0}" -v lost="${lost:-0}" -v dup="${dup:-0}" -v reo="${reo:-0}" 'BEGIN{
    if(tx>0){ fa=100.0*lost/tx; da=100.0*(lost>reo?lost-reo:0)/tx; rec=100.0*reo/tx }
    printf "%-8s tx=%d rx=%d lost=%d reorder=%d dup=%d | first-attempt PER=%.2f%%  ARQ-recovered=%.2f%%  delivered PER=%.2f%%\n", l, tx, rx, lost, reo, dup, fa, rec, da }'
}
report_dir "FWD" "$OUT/perf_fwd_srv.log" "$OUT/perf_fwd_cli.log" | tee "$OUT/summary.txt"
report_dir "REV" "$OUT/perf_rev_srv.log" "$OUT/perf_rev_cli.log" | tee -a "$OUT/summary.txt"
echo "--- daemon ARQ stats (retx/dups/recovered) ---"
echo "148: $(grep -o 'retx=[0-9]* dups=[0-9]* recovered=[0-9]*' "$OUT/daemon_148.txt" 2>/dev/null)"
echo "146: $(grep -o 'retx=[0-9]* dups=[0-9]* recovered=[0-9]*' "$OUT/daemon_146.txt" 2>/dev/null)"
{ echo "dur=$DUR bps=$BPS pay=$PAY arq=on ts=$(date -Is)"
  echo "148_daemon: $(cat "$OUT/daemon_148.txt")"; echo "146_daemon: $(cat "$OUT/daemon_146.txt")"; } >> "$OUT/summary.txt"

# 8. quiesce (unless -k)
stop_perf
if [ "$KEEP" = 0 ]; then
  for ip in $B_IP $A_IP; do
    $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4
     ip link del tun0 2>/dev/null; busybox devmem 0x9D000000 32 0 2>/dev/null; busybox devmem 0x9D000114 32 0 2>/dev/null
     echo "'$ip' quiesced"' 2>/dev/null
  done
fi
echo "ARQ_R3_DONE $OUT"
