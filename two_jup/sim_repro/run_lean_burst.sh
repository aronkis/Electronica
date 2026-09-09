#!/bin/bash
# Lineage test for the 120-s burst: flash 148 with the CLEAN lean image e49c011b7a75 (08-13, pre-beat-overlay),
# run the ROM-source loopback BIST series (5 min), then flash probe-4 back (02e8c97d6181) and restore the link.
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem; cd $ROOT/two_jup; . sim_repro/riglock.sh; W=./anyssh.sh; A=10.0.0.148
log(){ echo "$(date +%F_%T) $*" | tee -a $S/lean_burst_chain.log; }
until grep -q "TSG_CHAIN_DONE\|TSG_STOP" $S/tseries_gain.log 2>/dev/null; do sleep 30; done; until [ ! -e "$RIG_LOCK" ]; do sleep 20; done; sleep 30
rig_lock lean_burst || { log "LB_STOP lock busy"; exit 1; }; trap rig_unlock EXIT
systemctl --user stop 'sentinelkeeper-*' 2>/dev/null; for p in $(pgrep -f "[d]elivery_sentinel.sh"); do kill $p; done; touch /home/tcollins/modem-status/SENTINEL_STOP
CUR=$($W $A "md5sum /boot/BOOT.BIN | cut -c1-12" 2>/dev/null); log "148 runs $CUR; flashing lean e49c011b7a75"
BB=$ROOT/boot_known_good/BOOT.BIN.148.lean.e49c011b7a75 BAK_MD5=$CUR bash skidfix/flash_148_rxfifo_diag.sh e49c011b7a75 > $S/flash_lean.log 2>&1; RC=$?
tail -3 $S/flash_lean.log | tee -a $S/lean_burst_chain.log
grep -q "FLASH_RXFIFO_DIAG_DONE" $S/flash_lean.log || { log "LB_STOP flash rc=$RC (rolled back or fatal; NO retry)"; exit 1; }
# ROM-source loopback series on the lean image (0x104/0x108/0x150 only)
$W $A 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1' 2>/dev/null
$W $A "cd /root/host_app_k5; QPSK_FRAME=f1536 QPSK_SEQ_RXONLY=1 QPSK_RX_QUEUED=1 QPSK_WHITEN=0 setsid chrt -f 50 ./qpsk_tun -S -M 16 -r 15360 -d 400 > /dev/shm/ts_lean.log 2>&1 & exit 0" >/dev/null 2>&1; sleep 3
$W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  for k in 1 2; do echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
    echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; [ $k = 1 ] && sleep 3; done; echo "armed ROM loopback (lean)"' 2>/dev/null | tee -a $S/lean_burst_chain.log; sleep 5
rd(){ $W $A "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; for r in 0x104 0x108 0x150; do echo \$r > \$DRA; printf '%d ' \$(cat \$DRA); done; date +%s.%N" 2>/dev/null; }
T0=$(date +%s.%N); prev=""; log "TSL lean start"; end=$(( $(date +%s) + 300 ))
while [ $(date +%s) -lt $end ]; do cur=$(rd); if [ -n "$prev" ]; then python3 - "$prev" "$cur" "$T0" <<'PY' | tee -a $S/lean_burst_chain.log
import sys
a=[int(float(x)) for x in sys.argv[1].split()[:3]]; z=[int(float(x)) for x in sys.argv[2].split()[:3]]; t=float(sys.argv[2].split()[3])-float(sys.argv[3])
d=[(z[i]-a[i])&0xFFFFFFFF for i in range(3)]; print(f"TSL {t:6.1f}s frames={d[0]} biterr={d[1]} rstcs={d[2]}" + ("  <== BURST" if d[1]>20000 else ""))
PY
fi; prev=$cur; sleep 10; done
$W $A 'pkill -x qpsk_tun' 2>/dev/null
log "flashing probe-4 back (02e8c97d6181)"
BB=$ROOT/jupiter_byte_probe4_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN BAK_MD5=e49c011b7a75 bash skidfix/flash_148_rxfifo_diag.sh 02e8c97d6181 > $S/flash_p4back.log 2>&1; RC=$?
tail -3 $S/flash_p4back.log | tee -a $S/lean_burst_chain.log
grep -q "FLASH_RXFIFO_DIAG_DONE" $S/flash_p4back.log || { log "LB_STOP re-flash rc=$RC (148 may be on lean or rolled back) -- rig stays held"; exit 1; }
rig_unlock; rm -f /home/tcollins/modem-status/SENTINEL_STOP; systemd-run --user --unit=sentinelkeeper-$(date +%H%M%S) --collect bash $S/sentinel_keeper.sh; log "rig released, keeper relaunched"
log "LB_CHAIN_DONE"
