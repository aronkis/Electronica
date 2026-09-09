#!/bin/bash
# ROM-source loopback BIST series on 146 (v_endh image; NO flash): does 146's RX chain show the 120-s burst?
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup; . sim_repro/riglock.sh; W=./anyssh.sh; B=10.0.0.148
until grep -q "P4B_CHAIN_DONE\|P4B_STOP" $S/p4back_chain.log 2>/dev/null; do sleep 30; done; until [ ! -e "$RIG_LOCK" ]; do sleep 20; done; sleep 30
rig_lock tseries_nodaemon || { echo TND_STOP; exit 1; }; trap rig_unlock EXIT
systemctl --user stop 'sentinelkeeper-*' 2>/dev/null; for p in $(pgrep -f "[d]elivery_sentinel.sh"); do kill $p; done
log(){ echo "$(date +%F_%T) $*"; }
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1' 2>/dev/null
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  for k in 1 2; do echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
    echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; [ $k = 1 ] && sleep 3; done; echo "armed ROM loopback (148, no daemon)"' 2>/dev/null; sleep 5
rd(){ $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; for r in 0x104 0x108 0x150; do echo \$r > \$DRA; printf '%d ' \$(cat \$DRA); done; date +%s.%N" 2>/dev/null; }
T0=$(date +%s.%N); prev=""; log "TND start (NO qpsk_tun, no RX DMA)"; end=$(( $(date +%s) + 300 ))
while [ $(date +%s) -lt $end ]; do cur=$(rd); if [ -n "$prev" ]; then python3 - "$prev" "$cur" "$T0" <<'PY'
import sys
a=[int(float(x)) for x in sys.argv[1].split()[:3]]; z=[int(float(x)) for x in sys.argv[2].split()[:3]]; t=float(sys.argv[2].split()[3])-float(sys.argv[3])
d=[(z[i]-a[i])&0xFFFFFFFF for i in range(3)]; print(f"TND {t:6.1f}s frames={d[0]} biterr={d[1]} rstcs={d[2]}" + ("  <== BURST" if d[1]>20000 else ""))
PY
fi; prev=$cur; sleep 10; done
log "RESTORE"; GATE_DIR=A GATE_TRIES=8 bash bringup_r2r3.sh r3 > $S/tnd_restore_bringup.log 2>&1; tail -1 $S/t146_restore_bringup.log
grep -q "BRING-UP COMPLETE" $S/tnd_restore_bringup.log && { rig_unlock; rm -f /home/tcollins/modem-status/SENTINEL_STOP; systemd-run --user --unit=sentinelkeeper-$(date +%H%M%S) --collect bash $S/sentinel_keeper.sh; log "rig released, keeper relaunched"; } || log "TND_STOP restore failed -- rig stays held"
log "TND_CHAIN_DONE"
