#!/bin/bash
# Zero-build E5 witness: ROM-source loopback BIST series with the symbol-timing integral gain (0x17C, sfix24_En24,
# default -2180) at 1x, 0.5x, 2x, 0, and cs_integ_gain (0x174) 2x as control. 200-s points (bursts expected ~34 s, ~154 s).
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup; . sim_repro/riglock.sh; W=./anyssh.sh; A=10.0.0.148
rig_lock tseries_gain || { echo TSG_STOP; exit 1; }; trap rig_unlock EXIT
systemctl --user stop 'sentinelkeeper-*' 2>/dev/null; for p in $(pgrep -f "[d]elivery_sentinel.sh"); do kill $p; done
log(){ echo "$(date +%F_%T) $*"; }
DM='DM=$(command -v devmem || echo "busybox devmem")'
rd(){ $W $A "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; for r in 0x104 0x108 0x150; do echo \$r > \$DRA; printf '%d ' \$(cat \$DRA); done; date +%s.%N" 2>/dev/null; }
point(){ # $1 tag, $2 reg, $3 value(hex) ; "" = default
  $W $A 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1' 2>/dev/null
  $W $A "cd /root/host_app_k5; QPSK_FRAME=f1536 QPSK_SEQ_RXONLY=1 QPSK_RX_QUEUED=1 QPSK_WHITEN=0 setsid chrt -f 50 ./qpsk_tun -S -M 16 -r 15360 -d 260 > /dev/shm/ts_gain.log 2>&1 & exit 0" >/dev/null 2>&1; sleep 3
  $W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
    TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
    for k in 1 2; do echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
      '"$( [ -n "$2" ] && echo "echo \"$2 $3\">\$DRA; " )"'echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; [ $k = 1 ] && sleep 3; done
    for r in 0x17C 0x174; do echo $r > $DRA; printf "%s=%s " $r $(cat $DRA); done; echo' 2>/dev/null | sed "s/^/GAINS_$1 /"
  sleep 5; T0=$(date +%s.%N); prev=""; log "TSG $1 start"; end=$(( $(date +%s) + 200 ))
  while [ $(date +%s) -lt $end ]; do cur=$(rd); if [ -n "$prev" ]; then python3 - "$prev" "$cur" "$T0" "$1" <<'PY'
import sys
a=[int(float(x)) for x in sys.argv[1].split()[:3]]; z=[int(float(x)) for x in sys.argv[2].split()[:3]]; t=float(sys.argv[2].split()[3])-float(sys.argv[3])
d=[(z[i]-a[i])&0xFFFFFFFF for i in range(3)]; print(f"TSG_{sys.argv[4]} {t:6.1f}s frames={d[0]} biterr={d[1]} rstcs={d[2]}" + ("  <== BURST" if d[1]>20000 else ""))
PY
fi; prev=$cur; sleep 10; done
  $W $A 'pkill -x qpsk_tun' 2>/dev/null; sleep 2
}
# sfix24_En24 values as 24-bit two's complement: -2180=0xFFF77C, -1090=0xFFFBBE, -4360=0xFFEEF8, 0=0x0
point ss_default "" ""
point ss_half  0x17C 0xFFFBBE
point ss_double 0x17C 0xFFEEF8
point ss_zero  0x17C 0x0
point cs_double 0x174 0x2
log "RESTORE"; GATE_DIR=A GATE_TRIES=8 bash bringup_r2r3.sh r3 > $S/tsg_restore_bringup.log 2>&1; tail -1 $S/tsg_restore_bringup.log
grep -q "BRING-UP COMPLETE" $S/tsg_restore_bringup.log && { rig_unlock; rm -f /home/tcollins/modem-status/SENTINEL_STOP; systemd-run --user --unit=sentinelkeeper-$(date +%H%M%S) --collect bash $S/sentinel_keeper.sh; log "rig released, keeper relaunched"; } || log "TSG_STOP restore failed -- rig stays held"
log "TSG_CHAIN_DONE"
