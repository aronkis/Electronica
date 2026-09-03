#!/bin/bash
# probe-4 chain: wait for image + free rig -> flash 148 (rails, no retry) -> loopback Test A with the
# starvation witness (prediction: ep>3k per window == bad-magic per window) -> air window -> restore/release.
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem; B=$ROOT/jupiter_byte_probe4_build; Z=$B/hdl_prj_jupiter_composite/vivado_ip_prj
cd $ROOT/two_jup; . sim_repro/riglock.sh; W=./anyssh.sh; A=10.0.0.148
log(){ echo "$(date +%F_%T) $*" | tee -a $S/flash_probe4_chain.log; }
until grep -q "PROBE4_IMAGE_DONE" $B/build_probe4.log 2>/dev/null; do sleep 60; done
MD5=$(md5sum $Z/boot/BOOT.BIN | cut -c1-12)
WNS=$(python3 - $Z/vivado_prj.runs/impl_1/system_top_timing_summary_routed.rpt <<'PY'
import sys,re
L=open(sys.argv[1]).read().splitlines()
for i,l in enumerate(L):
    if 'Design Timing Summary' in l:
        for j in range(i+1,i+12):
            m=re.match(r'\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)',L[j])
            if m: print(m.group(1)); sys.exit(0)
print('nan')
PY
)
log "BUILD_ACCEPT md5=$MD5 WNS=$WNS"; python3 -c "import sys; sys.exit(0 if float('$WNS')>=0 else 1)" || { log "CHAIN_STOP WNS negative"; exit 1; }
cp $Z/boot/BOOT.BIN $ROOT/boot_known_good/BOOT.BIN.148.probe4.$MD5
until grep -q "LOOPA_CADENCE_DONE\|LOOPA_STOP" $S/loopA_cadence.log 2>/dev/null; do sleep 60; done
until [ ! -e "$RIG_LOCK" ]; do sleep 30; done; sleep 30
n=0; until [ $n -ge 30 ]; do h=$(bash health_probe_reset_aware.sh $A 6 2>/dev/null | tail -1); f=$(echo "$h" | grep -oE 'fsync=[0-9]+' | tr -dc 0-9); w=$(echo "$h" | grep -oE 'wcnt=[0-9]+' | tr -dc 0-9); [ "${f:-0}" -ge 1100 ] && [ "${w:-0}" -ge 1100 ] && break; n=$((n+1)); sleep 60; done
[ $n -lt 30 ] || { log "CHAIN_STOP 148 not healthy: $h"; exit 1; }
rig_lock flash_probe4 || { log "CHAIN_STOP lock busy"; exit 1; }; trap rig_unlock EXIT
systemctl --user stop 'sentinelkeeper-*' 2>/dev/null; for p in $(pgrep -f "[d]elivery_sentinel.sh"); do kill $p; done; touch /home/tcollins/modem-status/SENTINEL_STOP
log "FLASH start md5=$MD5"
BB=$Z/boot/BOOT.BIN BAK_MD5=$($W $A "md5sum /boot/BOOT.BIN | cut -c1-12" 2>/dev/null) bash skidfix/flash_148_rxfifo_diag.sh $MD5 > $S/flash_probe4.log 2>&1; RC=$?
tail -3 $S/flash_probe4.log | tee -a $S/flash_probe4_chain.log
grep -q "FLASH_RXFIFO_DIAG_DONE" $S/flash_probe4.log || { log "CHAIN_STOP flash rc=$RC (rolled back or fatal; NO retry)"; exit 1; }
log "AIR window (legacy daemons from the flash bring-up), 16-counter readout"; DUR=60 bash rxchk16_run.sh 2>&1 | tee -a $S/flash_probe4_chain.log
log "LOOPBACK Test A with the starvation witness"
DM='DM=$(command -v devmem || echo "busybox devmem")'
$W $A 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1' 2>/dev/null
$W $A "cd /root/host_app_k5; QPSK_FRAME=f1536 QPSK_RX_QUEUED=1 setsid chrt -f 50 ./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5 > /dev/shm/p4_loop.log 2>&1 & exit 0" >/dev/null 2>&1; sleep 3
$W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  for k in 1 2; do echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
    echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; [ $k = 1 ] && sleep 3; done' 2>/dev/null; sleep 8
for i in 1 2; do DUR=60 bash rxchk16_run.sh 2>&1 | sed "s/^/LOOP_$i /" | tee -a $S/flash_probe4_chain.log; done
$W $A 'pkill -x qpsk_tun' 2>/dev/null
log "RESTORE"; GATE_DIR=A GATE_TRIES=8 bash bringup_r2r3.sh r3 > $S/postp4_bringup.log 2>&1; tail -1 $S/postp4_bringup.log | tee -a $S/flash_probe4_chain.log
grep -q "BRING-UP COMPLETE" $S/postp4_bringup.log && { rig_unlock; rm -f /home/tcollins/modem-status/SENTINEL_STOP; systemd-run --user --unit=sentinelkeeper-$(date +%H%M%S) --collect bash $S/sentinel_keeper.sh; log "rig released, keeper relaunched"; } || log "CHAIN_STOP restore failed -- rig stays held"
log "CHAIN_DONE"
