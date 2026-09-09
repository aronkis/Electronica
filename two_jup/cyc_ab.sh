#!/bin/bash
# =============================================================================
# cyc_ab.sh [reps] -- N1: cyclic-vs-queued RX causal A/B in LOOPBACK on 148.
#
# THE QUESTION. The forward 8.55% class is boundary-locked corrupt singles whose
# mechanism (FWD_SINGLES_ROOT_CAUSE.md) is inter-transfer DMAC backpressure at
# the ByteSerializer. CYCLIC mode has NO transfer boundaries; if the class is
# boundary-born it MUST vanish in the cyclic arm. 148's new image (e49c011b) is
# the first CYCLIC-capable bitstream on the correct DMAC (rx_byte_dma) -- the
# 2026-08-09 "cyclic delivers nothing" probe ran on a CYCLIC-0 build and is void.
#
# ARMS (interleaved, same board, same loopback config, -G daemon):
#   q16 : QPSK_RX_QUEUED=1 -M 16     (production path; boundaries every 12.85 ms)
#   cyc : QPSK_RX_CYCLIC=1 -M 16     (one-time arm, no boundaries)
# Oracles per rep: framelog hole census (singles/doubles + cadence), crc_drop &
# delivered rate from the stats line, CP1 wordcnt continuity, fslog checksums.
#
# BASELINE REQUIREMENT: the q16 arm must show the boundary singles in loopback
# at all; if it does not, this A/B cannot discriminate off-air and says so.
#
# Loopback on 148 ONLY (0x114=0). Watchdog stopped (DRA) and restarted; air
# select restored at the end. Never sets FLAGS bit0 on 146.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.148
REPS=${1:-3}
DUR=${DUR:-70}
OUT=$D/r3cap/cycab_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
CSV=$OUT/cycab.csv
echo "arm,rep,recs,delivered_fps,crc_bad,singles,doubles,gap3plus,wordcnt_fps" > "$CSV"

echo "=== cyc_ab: $REPS reps x ${DUR}s per arm on $B (loopback) -> $OUT ==="
SRC=$(cd "$D/../host_app_k5" && pwd)
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
  -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no "$@" </dev/null 2>>/tmp/capture_scp_err.txt; }
echo "--- deploy + build on $B ---"
scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" \
       "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" \
       "$SRC/qpsk_uio.c" "$SRC/qpsk_uio.h" "$SRC/qpsk_perf.c" root@$B:/root/host_app_k5/ \
       || { echo "scp FAIL"; exit 1; }
NAKKEEP=$($W $B 'strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -q "nakstat:" \
       && echo "-DQPSK_ARQ_NAKSTAT" || echo ""' 2>/dev/null)
R=$($W $B "cd /root/host_app_k5 && gcc -O2 -Wall -DQPSK_CARVE_2MB -DQPSK_RXQ_STAT $NAKKEEP \
      -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c 2>/tmp/gcc.err \
      && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }" 2>/dev/null)
echo "  $B: $R"
[ "${R%%$'\n'*}" = BUILD_OK ] || exit 1

echo "--- stopping watchdog on $B ---"
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; sleep 1
  pgrep -f "[l]ock_watchdog" >/dev/null && echo "  watchdog STILL UP" || echo "  watchdog stopped"' 2>/dev/null

arm_loopback(){ $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' >/dev/null 2>&1; }

wordcnt_rate(){ $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  rd(){ echo "$1" > $DRA; cat $DRA; }
  w0=$(rd 0x1C0); sleep 3; w1=$(rd 0x1C0)
  echo $(( ( ( $(( $w1 )) - $(( $w0 )) ) & 0xFFFFFFFF ) / 3 / 191 ))' 2>/dev/null; }

run_rep(){ # $1 arm-tag  $2 env-string  $3 rep
  local tag=$1 env=$2 r=$3
  echo "--- $tag rep $r ---"
  $W $B "pkill -x qpsk_tun 2>/dev/null; sleep 1; cd /root/host_app_k5
    rm -f /dev/shm/lb.log /dev/shm/frames.bin /dev/shm/fslog.bin
    QPSK_FRAME=f1536 $env QPSK_FRAMELOG=/dev/shm/frames.bin QPSK_FSLOG=/dev/shm/fslog.bin \
      setsid chrt -f 50 ./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5 -d $DUR \
      > /dev/shm/lb.log 2>&1 &
    exit 0" >/dev/null 2>&1
  sleep 6; arm_loopback
  sleep 15
  WFPS=$(wordcnt_rate)
  # -d is not honored by the -G tun loop (it never exits on its own); run the
  # window by wall clock and SIGTERM for a clean exit (atexit dumps fslog).
  sleep $((DUR - 18 > 0 ? DUR - 18 : 10)) 2>/dev/null || sleep 45
  $W $B 'pkill -x qpsk_tun 2>/dev/null; sleep 2' >/dev/null 2>&1
  $W $B 'cat /dev/shm/lb.log' 2>/dev/null > "$OUT/${tag}_r$r.log"
  $W $B 'cat /dev/shm/frames.bin 2>/dev/null' 2>/dev/null > "$OUT/${tag}_r$r.frames.bin"
  $W $B 'cat /dev/shm/fslog.bin 2>/dev/null' 2>/dev/null > "$OUT/${tag}_r$r.fslog.bin"
  python3 - "$OUT/${tag}_r$r.frames.bin" "$OUT/${tag}_r$r.log" "$tag" "$r" "$WFPS" "$CSV" <<'PY'
import struct, sys
try: raw = open(sys.argv[1],'rb').read()
except: raw = b''
n = len(raw)//48
fr = [struct.unpack_from("<QQIIIIII", raw, i*48) for i in range(n)]
bad = sum(1 for r in fr if r[3]==0)
s1=s2=s3=0; prev=None
for r in fr:
    s,c=r[2],r[3]
    if c==1 and s>0:
        if prev is not None and s>prev:
            d=s-prev-1
            if d==1: s1+=1
            elif d==2: s2+=1
            elif d>2: s3+=1
        prev=s
dur=(fr[-1][0]-fr[0][0])/1e9 if n>1 else 0
fps = n/dur if dur else 0
print(f"    recs={n} ({fps:.0f}/s) crc_bad={bad} singles={s1} doubles={s2} gap3+={s3} wordcnt_fps={sys.argv[5]}")
open(sys.argv[6],'a').write(f"{sys.argv[3]},{sys.argv[4]},{n},{fps:.0f},{bad},{s1},{s2},{s3},{sys.argv[5]}\n")
PY
}

for r in $(seq 1 "$REPS"); do
  run_rep q16 "QPSK_RX_QUEUED=1" "$r"
  run_rep cyc "QPSK_RX_CYCLIC=1" "$r"
done

echo
echo "=== SUMMARY ==="
column -s, -t "$CSV" | sed 's/^/  /'
echo
echo "--- restoring air select + watchdog on $B ---"
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; echo "0x114 0x1">$DRA; exit 0' >/dev/null 2>&1
$W $B 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; : > /dev/shm/watchdog.log
  nohup setsid /root/lock_watchdog.sh </dev/null >/dev/shm/watchdog.log 2>&1 & disown; exit 0' >/dev/null 2>&1
sleep 2
$W $B 'pgrep -f "[l]ock_watchdog" >/dev/null && echo "  watchdog VERIFIED up" || echo "  watchdog FAILED TO START"' 2>/dev/null
echo "=== artifacts in $OUT ==="
