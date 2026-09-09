#!/bin/bash
# loopfloor_go.sh -- T1 (happy-bubbling-owl): 148-only internal loopback floor with the
# INSTRUMENTED daemon, the loopchk_run.sh Test-A leg (host byte-DMA TX via MM2S -> mod ->
# demod -> checker, RF excluded), scored every 10 s in the tseries_badmagic.sh cadence,
# for DUR seconds (default 600).
#
# Daemon launch (per loopchk_run.sh Test A + the T0a instrumentation this task assumes):
#   QPSK_FRAME=f1536 QPSK_RX_QUEUED=1 QPSK_FRAMELOG=/dev/shm/frames.bin \
#   QPSK_FAILHDR=/dev/shm/failhdr.bin QPSK_TXLOG=/dev/shm/txlog.bin \
#     ./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5
#
# Arm sequence: loopchk_run.sh's arm_loop 0x1 (byte source, double-tap).
# Checker: rdc()/delta() from loopchk_run.sh, sampled every 10 s (tseries_badmagic.sh
# cadence) into a CSV instead of one 600 s aggregate -- P1 correction: a single
# aggregate cannot separate a floor from a burst.
# Close: SIGUSR1 (flush frames/failhdr/txlog + txgap dump), fetch the three logs +
# txgap_dump to runs/<ts>_loopfloor/, then the loopchk_run.sh Test-A restore step
# (pkill qpsk_tun; injectors off).
#
# DRY=1 (default): every board action is [dry]-logged, no ssh/scp is invoked, and the
# checker fabricates a plausible 0.2-0.35% magic_bad time series plus placeholder
# frames.bin/failhdr.bin/txlog.bin so Task 2's (T0b) analysis tools have real files to
# exercise end to end.
set -u
D=$(cd "$(dirname "$0")" && pwd)          # two_jup/comb
TJ=$(cd "$D/.." && pwd)                   # two_jup
W=${W:-$TJ/anyssh.sh}
BRD=${BRD:-10.0.0.148}
DUR=${DUR:-600}
DRY=${DRY:-1}
TS=$(date +%Y%m%d_%H%M%S)
OUT=${OUT:-$D/runs/${TS}_loopfloor}
mkdir -p "$OUT"

log(){ echo "$(date -Is) $*" | tee -a "$OUT/run.log"; }

# ---- register delta helpers (loopchk_run.sh's rdc/delta, board-scoped) -------------
DM='DM=$(command -v devmem || echo "busybox devmem")'
rdc_real(){ $W "$BRD" "$DM; DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo 0x104 > \$DRA; p=\$(cat \$DRA)
  names='acc_user frames crc_ok crc_fail magic_bad short orphan acc_beats'; i=0; out=''
  for n in \$names; do \$DM 0x9D410008 32 \$((i << 28)) >/dev/null; v=\$(\$DM 0x9D450008); out=\"\$out \$n=\$((v))\"; i=\$((i+1)); done
  \$DM 0x9D410008 32 0 >/dev/null; echo \"CNT\$out p104=\$((p)) t=\$(date +%s.%N)\"" 2>/dev/null; }

# DRY fabrication: a monotone counter walk giving ~0.28% magic_bad/frames, one 10 s
# sample at a time (no board contact, no sleeps).
DRY_RATE_FPS=1245
dry_sample(){ # $1 = sample index (0-based, one per 10 s tick)
  local i=$1 fr=$((DRY_RATE_FPS * 10)) mb ok
  mb=$(( fr * 28 / 10000 ))            # ~0.28%
  ok=$(( fr - mb ))
  echo "CNT acc_user=0 frames=$((fr*(i+1))) crc_ok=$((ok*(i+1))) crc_fail=0 magic_bad=$((mb*(i+1))) short=0 orphan=0 acc_beats=0 p104=$((fr*(i+1))) t=$(date +%s.%N)"
}

rdc(){ if [ "$DRY" = 1 ]; then dry_sample "${1:-0}"; else rdc_real; fi; }

delta_py(){ python3 - "$1" "$2" "$3" <<'PY'
import sys,re
a,z,t=sys.argv[1],sys.argv[2],float(sys.argv[3])
ka={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',a)}; kz={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',z)}
d={k:(kz[k]-ka[k])&0xFFFFFFFF for k in ka if k in kz}; fr=d.get('frames',0); mb=d.get('magic_bad',0)
pct=(100*mb/fr) if fr else 0.0
print(f"{t:.1f},{fr},{mb},{pct:.4f},{d.get('p104',0)}")
PY
}

arm_loop_real(){ $W "$BRD" 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  for k in 1 2; do
    echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
    echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
    echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
    echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; [ $k = 1 ] && sleep 3
  done' 2>/dev/null; }

REARM_COUNT=0
arm_loop(){
  if [ "$DRY" = 1 ]; then
    log "[dry] $W $BRD arm_loop (0x1 byte source, double-tap)"
  else
    arm_loop_real; REARM_COUNT=$((REARM_COUNT+1))
  fi
}

pre_cleanup(){
  if [ "$DRY" = 1 ]; then
    log "[dry] $W $BRD kill watchdog + qpsk_tun, injectors off"
  else
    $W "$BRD" 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1' 2>/dev/null
    $W "$BRD" "$DM; \$DM 0x9D400000 32 0; \$DM 0x9D410000 32 0" 2>/dev/null
  fi
}

start_daemon(){
  local env="QPSK_FRAME=f1536 QPSK_RX_QUEUED=1 QPSK_FRAMELOG=/dev/shm/frames.bin QPSK_FAILHDR=/dev/shm/failhdr.bin QPSK_TXLOG=/dev/shm/txlog.bin QPSK_TXLOG_USR1=1"
  # QPSK_TXLOG_USR1=1 (T1 defect D3): without it the TX log dumps only at atexit, i.e.
  # AFTER the scp below, so txlog.bin could never exist in the run dir.
  if [ "$DRY" = 1 ]; then
    log "[dry] $W $BRD cd /root/host_app_k5; $env setsid chrt -f 50 ./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5"
  else
    $W "$BRD" "cd /root/host_app_k5; rm -f /dev/shm/frames.bin /dev/shm/failhdr.bin /dev/shm/txlog.bin
      $env setsid chrt -f 50 ./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5 > /dev/shm/loopfloor.log 2>&1 & exit 0" >/dev/null 2>&1
  fi
}

snap(){ # register snapshot (0x104/0x108/0x150/0x154/0x15C)
  if [ "$DRY" = 1 ]; then
    local pkts=0; [ "$1" = 1 ] && pkts=$(( DRY_RATE_FPS * NSAMP * 10 ))
    echo "t=$(date +%s.%N) pkts=$pkts biterr=0 rstcs=0 cfc=0 fx=0"
  else
    $W "$BRD" 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA;cat $DRA; }
       echo "t=$(date +%s.%N) pkts=$(rd 0x104) biterr=$(rd 0x108) rstcs=$(rd 0x150) cfc=$(rd 0x154) fx=$(rd 0x15C)"' 2>/dev/null
  fi
}

echo "=== loopfloor_go.sh: 148-only internal loopback floor, DUR=${DUR}s DRY=$DRY -> $OUT ===" | tee -a "$OUT/run.log"
pre_cleanup
start_daemon
sleep_or_dry(){ [ "$DRY" = 1 ] || sleep "$1"; }
sleep_or_dry 3
arm_loop
# The pre-window arm is NOT a re-arm: reset the counter so uninformative.txt's
# "re-arm in-window" flag only ever fires for an arm issued INSIDE the window.
REARM_COUNT=0
sleep_or_dry 5

NSAMP=$(( (DUR + 9) / 10 ))
SNAP_PRE=$(snap 0); echo "$SNAP_PRE" > "$OUT/regs_pre.txt"

echo "t_s,frames,magic_bad,magic_bad_pct,p104" > "$OUT/badmagic_10s.csv"
prev=$(rdc 0)
i=1
WINDOW_S=0
while [ "$i" -le "$NSAMP" ]; do
  sleep_or_dry 10
  cur=$(rdc "$i")
  delta_py "$prev" "$cur" "$((i*10))" >> "$OUT/badmagic_10s.csv"
  prev=$cur
  WINDOW_S=$((i*10))
  i=$((i+1))
done

SNAP_POST=$(snap 1); echo "$SNAP_POST" > "$OUT/regs_post.txt"

# flush (SIGUSR1) + fetch
if [ "$DRY" = 1 ]; then
  log "[dry] $W $BRD pkill -USR1 -x qpsk_tun (flush frames/failhdr/txlog + txgap dump)"
  # fabricate plausible artifacts so downstream (T0b) tools have real files to run on
  head -c 4800 /dev/urandom > "$OUT/frames.bin" 2>/dev/null || : > "$OUT/frames.bin"
  head -c 1200 /dev/urandom > "$OUT/failhdr.bin" 2>/dev/null || : > "$OUT/failhdr.bin"
  head -c 4800 /dev/urandom > "$OUT/txlog.bin" 2>/dev/null || : > "$OUT/txlog.bin"
  cat > "$OUT/txgap_dump.txt" <<'EOF'
qpsk_tun txgap: n=6000 empty=6000 gt20us=0 gt50us=0 gt200us=0 max_us=18 p99_us=12 mean_us=6.4 idle_batch=0
EOF
else
  $W "$BRD" 'pkill -USR1 -x qpsk_tun 2>/dev/null; sleep 0.5' 2>/dev/null
  SCPPUT(){ SSH_ASKPASS="$TJ/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>>"$OUT/scp_err.txt"; }
  SCPPUT root@"$BRD":/dev/shm/frames.bin "$OUT/frames.bin" || log "WARN: frames.bin fetch failed"
  SCPPUT root@"$BRD":/dev/shm/failhdr.bin "$OUT/failhdr.bin" || log "WARN: failhdr.bin fetch failed"
  SCPPUT root@"$BRD":/dev/shm/txlog.bin "$OUT/txlog.bin" || log "WARN: txlog.bin fetch failed"
  # every txgap dump line, not tail -3 (T1 defect D4: ~1.5 % coverage)
  $W "$BRD" 'grep "qpsk_tun txgap" /dev/shm/loopfloor.log 2>/dev/null' 2>/dev/null > "$OUT/txgap_dump.txt"
fi

# restore step (loopchk_run.sh Test-A close: pkill qpsk_tun)
if [ "$DRY" = 1 ]; then
  log "[dry] $W $BRD pkill -x qpsk_tun (restore)"
else
  $W "$BRD" 'pkill -x qpsk_tun; sleep 1' 2>/dev/null
fi

IMG_MD5=$([ "$DRY" = 1 ] && echo "dry-no-board" || $W "$BRD" 'md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-32' 2>/dev/null)
DAEMON_MD5=$([ "$DRY" = 1 ] && echo "dry-no-board" || $W "$BRD" 'md5sum /root/host_app_k5/qpsk_tun 2>/dev/null | cut -c1-32' 2>/dev/null)
NAKSTAT_N=$([ "$DRY" = 1 ] && echo 4 || $W "$BRD" 'strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -c nakstat' 2>/dev/null)
RXQSTAT_N=$([ "$DRY" = 1 ] && echo 1 || $W "$BRD" 'strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -c rxqstat' 2>/dev/null)

# ---- UNINFORMATIVE checklist (P1 §rails): 0x104 delta ~= 0 / rate far from 1250 f/s /
# window < 150 s / any re-arm in-window / capTAP not golden (N/A -- no DDRCAP tap here) ----
python3 - "$SNAP_PRE" "$SNAP_POST" "$WINDOW_S" "$REARM_COUNT" "$OUT/badmagic_10s.csv" > "$OUT/uninformative.txt" <<'PY'
import sys, re, csv
pre, post, window_s, rearms, csvpath = sys.argv[1:6]
window_s = int(window_s); rearms = int(rearms)
def parse(s):
    # snap() prints hex (pkts=0x2034): int(v, 0) reads 0x.. and plain decimal alike
    # (T1 defect D2: the decimal-only regex read every hex value as 0 -> d104=0).
    return {k: int(v, 0) for k, v in re.findall(r'(\w+)=(0x[0-9A-Fa-f]+|\d+)', s)}
p0, p1 = parse(pre), parse(post)
d104 = p1.get('pkts', 0) - p0.get('pkts', 0)
tot_frames = 0
with open(csvpath) as f:
    r = csv.DictReader(f)
    for row in r:
        tot_frames += int(row['frames'])   # sum of per-10s deltas = frames over the whole window
rate = tot_frames / window_s if window_s else 0
flags = []
if abs(d104) < 10:
    flags.append(f'0x104 delta ~= 0 ({d104})')
if abs(rate - 1245) > 400:
    flags.append(f'rate far from 1245 f/s ({rate:.0f})')
if window_s < 150:
    flags.append(f'window < 150s ({window_s})')
if rearms > 0:
    flags.append(f'{rearms} re-arm(s) in-window')
verdict = 'UNINFORMATIVE' if flags else 'INFORMATIVE'
print(f'{verdict} window_s={window_s} rate_fps={rate:.1f} d104={d104} rearms_in_window={rearms}')
for f in flags:
    print(f'  - {f}')
PY

{
  echo "leg=loopfloor board=$BRD dur=$DUR window_s=$WINDOW_S dry=$DRY"
  echo "image_md5=$IMG_MD5"
  echo "daemon_md5=$DAEMON_MD5"
  echo "nakstat_strings=$NAKSTAT_N"
  echo "rxqstat_strings=$RXQSTAT_N"
  echo "rearms_in_window=$REARM_COUNT"
  echo "$(cat "$OUT/uninformative.txt" | head -1)"
  echo "ts=$(date -Is)"
} > "$OUT/meta.txt"

cat "$OUT/uninformative.txt"
echo "LOOPFLOOR_DONE $OUT"
