#!/bin/bash
# Zero-build test of the 120-s burst source: loopback time series on 148 with ALL ADRV9002 tracking
# calibrations disabled (RX0/RX1/TX0/TX1) after the arm; then restore the cal enables and the link.
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup; . sim_repro/riglock.sh; W=./anyssh.sh; A=10.0.0.148
rig_lock tseries_nocal || { echo TSN_STOP; exit 1; }; trap rig_unlock EXIT; export RIGLOCK_PARENT=1
systemctl --user stop 'sentinelkeeper-*' 2>/dev/null; for p in $(pgrep -f "[d]elivery_sentinel.sh"); do kill $p; done
log(){ echo "$(date +%F_%T) $*"; }
# snapshot + disable tracking cals (writes to the phy sysfs = SPI to the transceiver; done only when NO arm is in flight)
SNAP=$($W $A 'D=/sys/bus/iio/devices/iio:device2; for a in $(ls $D | grep "_tracking_en$"); do printf "%s=%s " $a "$(cat $D/$a 2>/dev/null)"; done' 2>/dev/null); log "CAL_SNAPSHOT $SNAP"
# loopback arm first (tseries does it), then disable cals inside the dwell: we hook by running the arm here, disabling, then sampling
$W $A 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1' 2>/dev/null
$W $A "cd /root/host_app_k5; QPSK_FRAME=f1536 QPSK_RX_QUEUED=1 setsid chrt -f 50 ./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5 > /dev/shm/ts_nocal.log 2>&1 & exit 0" >/dev/null 2>&1; sleep 3
$W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  for k in 1 2; do echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
    echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; [ $k = 1 ] && sleep 3; done' 2>/dev/null
sleep 5
R=$($W $A 'D=/sys/bus/iio/devices/iio:device2; for a in $(ls $D | grep "_tracking_en$"); do echo 0 > $D/$a 2>/dev/null; done; for a in $(ls $D | grep "_tracking_en$"); do printf "%s=%s " $a "$(cat $D/$a 2>/dev/null)"; done' 2>/dev/null); log "CALS_DISABLED $R"
DM='DM=$(command -v devmem || echo "busybox devmem")'
rd(){ $W $A "$DM; DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo 0x104 > \$DRA; p=\$(cat \$DRA); for i in 1 4; do \$DM 0x9D410008 32 \$((i << 28)) >/dev/null; printf '%d ' \$(\$DM 0x9D450008); done; \$DM 0x9D410008 32 0 >/dev/null; echo \"\$((p)) \$(date +%s.%N)\"" 2>/dev/null; }
T0=$(date +%s.%N); prev=""; log "TSERIES nocal-loop start"; end=$(( $(date +%s) + 300 ))
while [ $(date +%s) -lt $end ]; do cur=$(rd); if [ -n "$prev" ]; then python3 - "$prev" "$cur" "$T0" <<'PY'
import sys
a=sys.argv[1].split(); z=sys.argv[2].split(); t0=float(sys.argv[3])
fr=int(z[0])-int(a[0]); mb=int(z[1])-int(a[1]); p=int(z[2])-int(a[2]); t=float(z[3])-t0
print(f"TSN {t:6.1f}s frames={fr} magic_bad={mb} ({100*mb/fr if fr else 0:.2f}%) p104={p}")
PY
fi; prev=$cur; sleep 10; done
# restore cal enables exactly as snapshotted
$W $A "D=/sys/bus/iio/devices/iio:device2; for kv in $SNAP; do a=\${kv%%=*}; v=\${kv#*=}; [ -n \"\$v\" ] && echo \$v > \$D/\$a 2>/dev/null; done; for a in \$(ls \$D | grep '_tracking_en$'); do printf '%s=%s ' \$a \"\$(cat \$D/\$a 2>/dev/null)\"; done" 2>/dev/null | sed 's/^/CALS_RESTORED /'
$W $A 'pkill -x qpsk_tun' 2>/dev/null
log "RESTORE"; GATE_DIR=A GATE_TRIES=8 bash bringup_r2r3.sh r3 > $S/tsn_restore_bringup.log 2>&1; tail -1 $S/tsn_restore_bringup.log
grep -q "BRING-UP COMPLETE" $S/tsn_restore_bringup.log && { rig_unlock; rm -f /home/tcollins/modem-status/SENTINEL_STOP; systemd-run --user --unit=sentinelkeeper-$(date +%H%M%S) --collect bash $S/sentinel_keeper.sh; log "rig released, keeper relaunched"; } || log "TSN_STOP restore failed -- rig stays held"
log "TSN_CHAIN_DONE"
