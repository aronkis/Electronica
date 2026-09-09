#!/bin/bash
# tseries_badmagic.sh -- time series of the decoder-output checker on 148 (probe-4 mux), every 10 s for DUR s:
# bad-magic and starvation counters vs time since arm. Modes: loop (148 loopback, own daemon TX) | air (normal link).
set -u
D=$(cd "$(dirname "$0")" && pwd); cd $D; W=./anyssh.sh; A=10.0.0.148; B=10.0.0.146; MODE=${1:-loop}; DUR=${DUR:-300}
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad
. sim_repro/riglock.sh; [ "${RIGLOCK_PARENT:-0}" = 1 ] || { rig_lock tseries || exit 1; trap rig_unlock EXIT; }
systemctl --user stop 'sentinelkeeper-*' 2>/dev/null; for p in $(pgrep -f "[d]elivery_sentinel.sh"); do kill $p; done
log(){ echo "$(date +%F_%T) $*"; }
DM='DM=$(command -v devmem || echo "busybox devmem")'
rd(){ $W $A "$DM; DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo 0x104 > \$DRA; p=\$(cat \$DRA)
  for i in 1 4 10 14; do \$DM 0x9D410008 32 \$((i << 28)) >/dev/null; printf '%d ' \$(\$DM 0x9D450008); done; \$DM 0x9D410008 32 0 >/dev/null; echo \"\$((p)) \$(date +%s.%N)\"" 2>/dev/null; }
if [ "$MODE" = loop ]; then
  $W $A 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1' 2>/dev/null
  $W $A "cd /root/host_app_k5; QPSK_FRAME=f1536 QPSK_RX_QUEUED=1 setsid chrt -f 50 ./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5 > /dev/shm/ts_loop.log 2>&1 & exit 0" >/dev/null 2>&1; sleep 3
  $W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
    TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
    for k in 1 2; do echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
      echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; [ $k = 1 ] && sleep 3; done' 2>/dev/null
else
  GATE_DIR=A GATE_TRIES=8 bash bringup_r2r3.sh r3 > $S/ts_air_bringup.log 2>&1; tail -1 $S/ts_air_bringup.log
fi
T0=$(date +%s.%N); prev=""; log "TSERIES $MODE start (columns: t_since_arm frames_d magic_bad_d ep_gt3k_d max_len p104_d)"
end=$(( $(date +%s) + DUR )); while [ $(date +%s) -lt $end ]; do cur=$(rd); if [ -n "$prev" ]; then python3 - "$prev" "$cur" "$T0" <<'PY'
import sys
a=sys.argv[1].split(); z=sys.argv[2].split(); t0=float(sys.argv[3])
fr=int(z[0])-int(a[0]); mb=int(z[1])-int(a[1]); ep=int(z[2])-int(a[2]); ml=int(z[3]); p=int(z[4])-int(a[4]); t=float(z[5])-t0
print(f"TS {t:6.1f}s frames={fr} magic_bad={mb} ({100*mb/fr if fr else 0:.2f}%) ep_gt3k={ep} max_len={ml} p104={p}")
PY
fi; prev=$cur; sleep 10; done
$W $A 'grep "qpsk_tun txgap" /dev/shm/ts_loop.log 2>/dev/null | tail -3; grep "qpsk_tun stats" /dev/shm/qpsk_tun.log /dev/shm/ts_loop.log 2>/dev/null | tail -1' 2>/dev/null | cut -c1-200
[ "$MODE" = loop ] && $W $A 'pkill -x qpsk_tun' 2>/dev/null
log "TSERIES_DONE $MODE"
