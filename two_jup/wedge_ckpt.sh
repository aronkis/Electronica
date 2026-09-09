#!/bin/bash
# =============================================================================
# wedge_ckpt.sh [reps] -- W1/W2 of the no-ARQ PER plan: seam checkpoints against
# the loopback wedge.
#
# PHASE 1 (A/B, mandatory before trusting the instrument): one -S loopback run
# with QPSK_CKPT=0 and one with QPSK_CKPT=1, same duration. If cp-on moves
# rxq_loop_us_max / rxq_pump_us_max materially, the checksum is perturbing the
# path under study (the rxq_drain_delay_us lesson) and QPSK_CKPT_N must rise
# before phase 2's verdicts count.
#
# PHASE 2 (repro): reps of -S loopback with QPSK_CKPT=1. The wedge is detected
# LIVE (ok frozen across 2 stat intervals while tx climbs) and the register
# signature is read DURING the wedge -- 0x104 twice 3 s apart (framesync rate),
# 0x150 (rstcs), 0x154 (cfc), 0x15C (adc forensic). The daemon does not use DRA
# and the watchdog is stopped, so this is the single DRA reader.
#
# PER-REP VERDICT (the pre-committed W3 table -- decided before the data):
#   cp2_bytes frozen  + completions frozen  -> NOTHING REACHES THE DMA BUFFER
#       (fabric/DMAC side; checkpoint 1 / flash is the next instrument)
#   cp2 advancing + mismatch>0              -> TORN COPY at the carve->host seam
#   cp2 advancing + mismatch=0 + junk up    -> bytes flow, copies clean, PN wrong
#       (content corrupted AT/BEFORE the DMA write)
#   0x104 rate ~0 during the wedge          -> demod lost framing upstream of the
#       byte path entirely (regardless of the above)
#
# Registers 0x114/0x118/0x158 are WRITE-ONLY (set, never verified by readback).
# Each rep re-arms from a 0x000 soft reset. NEVER-FRAMED (ok==0) is not a wedge.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=${BOARD:-10.0.0.146}
M=${M:-32}
REPS=${1:-4}
DUR=${DUR:-75}
CKN=${CKN:-1}
OUT=$D/r3cap/wedgeck_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"

echo "=== wedge_ckpt: A/B + $REPS reps x ${DUR}s on $B (CKPT_N=$CKN) -> $OUT ==="

# ---- deploy + build (mirrors layerb_run.sh, INCLUDING the NAK-stat guard; adds
# -DQPSK_RXQ_STAT because the rxq counters ARE the instrument here) ------------
SRC=$(cd "$D/../host_app_k5" && pwd)
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
  -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
echo "--- deploying + building qpsk_tun (with RXQ_STAT) on $B ---"
scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" \
       "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" \
       "$SRC/qpsk_uio.c" "$SRC/qpsk_uio.h" "$SRC/qpsk_perf.c" root@$B:/root/host_app_k5/ \
       || { echo "scp $B FAIL"; exit 1; }
NAKKEEP=$($W $B 'strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -q "nakstat:" \
       && echo "-DQPSK_ARQ_NAKSTAT" || echo ""' 2>/dev/null)
[ -n "$NAKKEEP" ] && echo "  $B: preserving deployed NAK-stat instrumentation ($NAKKEEP)"
R=$($W $B "cd /root/host_app_k5 && gcc -O2 -Wall -DQPSK_CARVE_2MB -DQPSK_RXQ_STAT $NAKKEEP \
      -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c 2>/tmp/gcc.err \
      && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }" 2>/dev/null)
echo "  $B: $R"
[ "${R%%$'\n'*}" = "BUILD_OK" ] || { echo "ABORT: build failed"; exit 1; }
$W $B 'grep -c "SEAM CKPT" /root/host_app_k5/qpsk_tun >/dev/null 2>&1' 2>/dev/null
CKB=$($W $B 'strings /root/host_app_k5/qpsk_tun | grep -c "qpsk_tun ckpt:"' 2>/dev/null)
[ "${CKB:-0}" -ge 1 ] || { echo "ABORT: deployed binary lacks the ckpt instrument"; exit 1; }
echo "  $B: ckpt instrument VERIFIED in deployed binary"

echo "--- stopping watchdog (single DRA reader for the in-wedge signature) ---"
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

reg_sig(){ # in-wedge register signature; sole DRA reader (watchdog stopped)
  $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
    rd(){ echo "$1" > $DRA; cat $DRA; }
    p0=$(rd 0x104); sleep 3; p1=$(rd 0x104)
    echo "pkt0=$p0 pkt1=$p1 rate=$(( ( $(( $p1 )) - $(( $p0 )) ) / 3 ))/s"
    echo "rstcs=$(rd 0x150) cfc=$(rd 0x154) adcf=$(rd 0x15C)"' 2>/dev/null; }

launch(){ # $1 = QPSK_CKPT value
  # seq_raw.log is opened APPEND by the daemon and grows ~3 KB per junk frame;
  # at never-framed junk rates it filled /dev/shm (981 MB) and every daemon on
  # the board died ~9 s in when tmpfs writes started failing (2026-08-12,
  # wedgeck_100854: all four logs truncated mid-line, no atexit). Rotate it
  # per launch -- the wedge verdicts only need the CURRENT rep's dumps.
  $W $B "pkill -x qpsk_tun 2>/dev/null; sleep 1; cd /root/host_app_k5
    rm -f /dev/shm/lb.log /dev/shm/txlog.bin /dev/shm/seq_raw.log /dev/shm/seq_events.log
    QPSK_FRAME=f1536 QPSK_SEQ_KEEPM=1 QPSK_RX_QUEUED=1 QPSK_CKPT=$1 QPSK_CKPT_N=$CKN \
      QPSK_TXLOG=/dev/shm/txlog.bin QPSK_RX_DRAIN_BUDGET=${BUDGET:-0} \
      setsid chrt -f 50 ./qpsk_tun -S -M $M -r 15360 -d $DUR > /dev/shm/lb.log 2>&1 &
    exit 0" >/dev/null 2>&1
  sleep 6; arm_loopback; }

# =============================================================================
# PHASE 1: perturbation A/B
# =============================================================================
echo
echo "##### PHASE 1: perturbation A/B (ckpt off vs on) #####"
for arm in 0 1; do
  echo "--- A/B arm ckpt=$arm ---"
  launch $arm
  sleep $((DUR + 4))
  $W $B 'cat /dev/shm/lb.log' 2>/dev/null > "$OUT/ab_ckpt$arm.log"
  $W $B 'pkill -x qpsk_tun 2>/dev/null; exit 0' >/dev/null 2>&1
done
python3 - "$OUT" <<'PY'
import re, sys, os
o = sys.argv[1]
def last(p, pat):
    v = None
    for ln in open(p):
        m = re.search(pat, ln)
        if m: v = m.groups()
    return v
res = {}
for arm in (0, 1):
    p = os.path.join(o, f"ab_ckpt{arm}.log")
    lp = last(p, r"loop_n=(\d+) loop_us_max=(\d+)")
    pm = last(p, r"pump_us_max=(\d+)")
    ok = last(p, r"^seq: t=(\d+)s tx=\d+ ok=(\d+)")
    res[arm] = dict(loop_max=int(lp[1]) if lp else None,
                    pump_max=int(pm[0]) if pm else None,
                    ok=int(ok[1]) if ok else None, t=int(ok[0]) if ok else None)
    print(f"  ckpt={arm}: loop_us_max={res[arm]['loop_max']} pump_us_max={res[arm]['pump_max']} "
          f"ok={res[arm]['ok']} @t={res[arm]['t']}s")
a, b = res[0], res[1]
if a['loop_max'] and b['loop_max']:
    # us_max is an extreme-value statistic; only a multiple, not a delta, means anything
    r = b['loop_max'] / max(a['loop_max'], 1)
    if r > 3:
        print(f"  >>> PERTURBATION: loop_us_max x{r:.1f} with ckpt on. RAISE QPSK_CKPT_N")
        print("      before trusting phase 2 verdicts.")
    else:
        print(f"  A/B OK: loop_us_max ratio x{r:.1f} -- instrument not moving the path.")
PY

# =============================================================================
# PHASE 2: repro with live in-wedge readout
# =============================================================================
CSV=$OUT/wedgeck.csv
echo "rep,ttw_s,ok_final,junk_final,cp2_frozen,mismatch,fsync_rate,verdict" > "$CSV"
for r in $(seq 1 "$REPS"); do
  echo
  echo "##### PHASE 2 rep $r/$REPS #####"
  launch 1
  WEDGE_AT=""
  SECS=0
  PREV_OK=-1; PREV2_OK=-2
  while [ $SECS -lt $DUR ]; do
    sleep 10; SECS=$((SECS + 10))
    LINE=$($W $B 'grep "^seq: t=" /dev/shm/lb.log 2>/dev/null | tail -1' 2>/dev/null)
    OK=$(echo "$LINE" | sed -n 's/.* ok=\([0-9]*\).*/\1/p')
    [ -z "$OK" ] && continue
    if [ "$OK" -gt 0 ] && [ "$OK" = "$PREV_OK" ] && [ "$OK" = "$PREV2_OK" ]; then
      WEDGE_AT=$SECS
      echo "  wedge detected at ~t=${SECS}s (ok frozen at $OK) -- reading registers IN-WEDGE"
      reg_sig | sed 's/^/    /' | tee "$OUT/rep$r.regs"
      break
    fi
    PREV2_OK=$PREV_OK; PREV_OK=$OK
  done
  # let the daemon finish on its own so the end-of-run summary lands
  while $W $B 'pgrep -x qpsk_tun >/dev/null' 2>/dev/null; do sleep 5; done
  $W $B 'cat /dev/shm/lb.log' 2>/dev/null > "$OUT/rep$r.log"
  $W $B 'cat /dev/shm/txlog.bin 2>/dev/null' 2>/dev/null > "$OUT/rep$r.txlog"
  python3 - "$OUT/rep$r.log" "$r" "$CSV" "$OUT/rep$r.regs" <<'PY'
import re, sys, os
prog, ck = [], []
for ln in open(sys.argv[1]):
    m = re.search(r"^seq: t=(\d+)s tx=(\d+) ok=(\d+) biterr=\d+ lost=(\d+) dup=\d+ junk=(\d+)", ln)
    if m: prog.append(tuple(int(x) for x in m.groups()))
    m = re.search(r"ckpt: cp2_bytes=(\d+) cp2_sum=\S+ cp3_bytes=(\d+) cp3_sum=\S+ "
                  r"mismatch=(\d+) slices=(\d+)", ln)
    if m: ck.append(tuple(int(x) for x in m.groups()))
rate = ""
if len(sys.argv) > 4 and os.path.exists(sys.argv[4]):
    m = re.search(r"rate=(-?\d+)/s", open(sys.argv[4]).read())
    if m: rate = m.group(1)
if not prog:
    print("    no stats"); open(sys.argv[3],"a").write(f"{sys.argv[2]},NA,0,0,NA,NA,{rate},NOSTATS\n"); raise SystemExit
last = 0
for i in range(1, len(prog)):
    if prog[i][2] > prog[i-1][2]: last = prog[i][0]
t, tx, ok, lost, junk = prog[-1]
mism = ck[-1][2] if ck else -1
# cp2 frozen? compare cp2_bytes across the LAST TWO ckpt dumps (the wedge window)
cp2f = "NA"
if len(ck) >= 2:
    cp2f = 1 if ck[-1][0] == ck[-2][0] else 0
if ok == 0:
    verdict = "NEVER_FRAMED"
    ttw = "NEVER"
elif last < t:
    ttw = last
    if cp2f == 1:
        verdict = "CP2_STALLED->FABRIC/DMAC"
    elif mism > 0:
        verdict = "TORN_COPY->HOST_SEAM"
    elif cp2f == 0:
        verdict = "BYTES_FLOW_PN_WRONG->PRE_DMA_CONTENT"
    else:
        verdict = "WEDGED_NO_CKPT_DATA"
    if rate and int(rate) < 100:
        verdict += "+FSYNC_DEAD"
else:
    ttw = "NONE"; verdict = "NO_WEDGE"
print(f"    ttw={ttw}s ok={ok} junk={junk} cp2_frozen={cp2f} mismatch={mism} fsync={rate}/s")
print(f"    VERDICT: {verdict}")
open(sys.argv[3],"a").write(f"{sys.argv[2]},{ttw},{ok},{junk},{cp2f},{mism},{rate},{verdict}\n")
PY
  $W $B 'pkill -x qpsk_tun 2>/dev/null; exit 0' >/dev/null 2>&1
done

echo
echo "=== SUMMARY ($CSV) ==="
column -s, -t "$CSV" | sed 's/^/  /'
echo
echo "--- restoring air select + watchdog ---"
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; echo "0x114 0x1">$DRA; exit 0' >/dev/null 2>&1
$W $B 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; exit 0' >/dev/null 2>&1
$W $B ': > /dev/shm/watchdog.log; exit 0' >/dev/null 2>&1
$W $B 'nohup setsid /root/lock_watchdog.sh </dev/null >/dev/shm/watchdog.log 2>&1 & disown; exit 0' >/dev/null 2>&1
sleep 2
$W $B 'pgrep -f "[l]ock_watchdog" >/dev/null && echo "  watchdog VERIFIED up" || echo "  watchdog FAILED TO START"' 2>/dev/null
echo "=== artifacts in $OUT ==="
