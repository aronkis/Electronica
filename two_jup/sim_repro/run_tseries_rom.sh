#!/bin/bash
# Burst side test: 148 loopback with the FABRIC ROM/BIST TX source (0x158=0: no byte plane, no DMA, no host TX).
# Sample 0x104 (frames), 0x108 (BIST bit errors), 0x150 (carrier resets), checker magic_bad every 10 s for 5 min.
# Bursts in 0x108/0x150 -> RX-side (or clock) periodic event; none -> TX byte plane / DMA side.
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup; . sim_repro/riglock.sh; W=./anyssh.sh; A=10.0.0.148
until grep -q "TSN_CHAIN_DONE\|TSN_STOP" $S/tseries_nocal.log 2>/dev/null; do sleep 20; done; until [ ! -e "$RIG_LOCK" ]; do sleep 20; done; sleep 20
rig_lock tseries_rom || { echo TSR_STOP; exit 1; }; trap rig_unlock EXIT
systemctl --user stop 'sentinelkeeper-*' 2>/dev/null; for p in $(pgrep -f "[d]elivery_sentinel.sh"); do kill $p; done
log(){ echo "$(date +%F_%T) $*"; }
$W $A 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1' 2>/dev/null
# RX DMA must be armed for the byte plane to flow (checker needs accepted words): run the -S scorer (RX only)
$W $A "cd /root/host_app_k5; QPSK_FRAME=f1536 QPSK_SEQ_RXONLY=1 QPSK_RX_QUEUED=1 QPSK_WHITEN=0 setsid chrt -f 50 ./qpsk_tun -S -M 16 -r 15360 -d 400 > /dev/shm/ts_rom.log 2>&1 & exit 0" >/dev/null 2>&1; sleep 3
$W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  for k in 1 2; do echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
    echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; [ $k = 1 ] && sleep 3; done
  echo "armed ROM source loopback (0x158=0, 0x114=0)"' 2>/dev/null; sleep 5
DM='DM=$(command -v devmem || echo "busybox devmem")'
rd(){ $W $A "$DM; DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; for r in 0x104 0x108 0x150; do echo \$r > \$DRA; printf '%d ' \$(cat \$DRA); done; for i in 1 4; do \$DM 0x9D410008 32 \$((i << 28)) >/dev/null; printf '%d ' \$(\$DM 0x9D450008); done; \$DM 0x9D410008 32 0 >/dev/null; date +%s.%N" 2>/dev/null; }
T0=$(date +%s.%N); prev=""; log "TSERIES rom-loop start (cols: t frames_d biterr_d rstcs_d chk_frames_d magic_bad_d)"; end=$(( $(date +%s) + 300 ))
while [ $(date +%s) -lt $end ]; do cur=$(rd); if [ -n "$prev" ]; then python3 - "$prev" "$cur" "$T0" <<'PY'
import sys
a=[int(float(x)) for x in sys.argv[1].split()[:5]]; z=[int(float(x)) for x in sys.argv[2].split()[:5]]; t=float(sys.argv[2].split()[5])-float(sys.argv[3])
d=[(z[i]-a[i])&0xFFFFFFFF for i in range(5)]
print(f"TSR {t:6.1f}s frames={d[0]} biterr={d[1]} rstcs={d[2]} chk_frames={d[3]} magic_bad={d[4]}")
PY
fi; prev=$cur; sleep 10; done
$W $A 'pkill -x qpsk_tun' 2>/dev/null
log "RESTORE"; GATE_DIR=A GATE_TRIES=8 bash bringup_r2r3.sh r3 > $S/tsr_restore_bringup.log 2>&1; tail -1 $S/tsr_restore_bringup.log
grep -q "BRING-UP COMPLETE" $S/tsr_restore_bringup.log && { rig_unlock; rm -f /home/tcollins/modem-status/SENTINEL_STOP; systemd-run --user --unit=sentinelkeeper-$(date +%H%M%S) --collect bash $S/sentinel_keeper.sh; log "rig released, keeper relaunched"; } || log "TSR_STOP restore failed -- rig stays held"
log "TSR_CHAIN_DONE"
