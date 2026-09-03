#!/bin/bash
# loopA_cadence.sh -- does the TX bad-magic cadence follow the RX S2MM transfer cadence?
# 148 internal loopback, daemon TX via MM2S (legacy, batching off), 4 points: M16/M32 x RXQ 1/0.
# Per point: 60-s checker delta (bad-magic rate) + framelog hole analysis (lag at M vs 2M).
set -u
D=$(cd "$(dirname "$0")" && pwd); cd $D; W=./anyssh.sh; A=10.0.0.148
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad
. sim_repro/riglock.sh; rig_lock loopA_cadence || { echo "LOOPA_STOP lock busy"; exit 1; }; trap rig_unlock EXIT
systemctl --user stop 'sentinelkeeper-*' 2>/dev/null; for p in $(pgrep -f "[d]elivery_sentinel.sh"); do kill $p; done
log(){ echo "$(date +%F_%T) $*"; }
DM='DM=$(command -v devmem || echo "busybox devmem")'
rdc(){ $W $A "$DM; DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo 0x104 > \$DRA; p=\$(cat \$DRA)
  names='acc_user frames crc_ok crc_fail magic_bad short orphan acc_beats'; i=0; out=''
  for n in \$names; do \$DM 0x9D410008 32 \$((i << 28)) >/dev/null; v=\$(\$DM 0x9D450008); out=\"\$out \$n=\$((v))\"; i=\$((i+1)); done
  \$DM 0x9D410008 32 0 >/dev/null; echo \"CNT\$out p104=\$((p)) t=\$(date +%s.%N)\"" 2>/dev/null; }
delta(){ python3 - "$1" "$2" "$3" <<'PY'
import sys,re
a,z,tag=sys.argv[1],sys.argv[2],sys.argv[3]
ka={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',a)}; kz={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',z)}
ta=float(re.search(r't=([\d.]+)',a).group(1)); tz=float(re.search(r't=([\d.]+)',z).group(1)); dur=max(tz-ta,1e-9)
d={k:(kz[k]-ka[k])&0xFFFFFFFF for k in ka if k in kz}; fr=d.get('frames',0)
print(f"CAD_{tag} {dur:.0f}s: frames={fr} ({fr/dur:.0f}/s) magic_bad={d.get('magic_bad',0)} ({d.get('magic_bad',0)/dur:.1f}/s) crc_fail={d.get('crc_fail',0)} short={d.get('short',0)} orphan={d.get('orphan',0)} 0x104d={d.get('p104',0)}" + (f"  magic_bad/frames={100*d.get('magic_bad',0)/fr:.3f}%" if fr else ""))
PY
}
arm_loop(){ $W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  for k in 1 2; do
    echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
    echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
    echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
    echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; [ $k = 1 ] && sleep 3
  done' 2>/dev/null; }
for pt in "16 1" "32 1" "16 0" "32 0"; do set -- $pt; M=$1; Q=$2; TAG=M${M}_RXQ${Q}
  $W $A 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1; rm -f /dev/shm/cad_frames.bin' 2>/dev/null
  $W $A "$DM; \$DM 0x9D400000 32 0; \$DM 0x9D410000 32 0" 2>/dev/null
  $W $A "cd /root/host_app_k5; QPSK_FRAME=f1536 QPSK_RX_QUEUED=$Q QPSK_FRAMELOG=/dev/shm/cad_frames.bin setsid chrt -f 50 ./qpsk_tun -G -M $M -r 15360 -i tun0 -s 5 > /dev/shm/cad_$TAG.log 2>&1 & exit 0" >/dev/null 2>&1
  sleep 3; arm_loop; sleep 8
  C0=$(rdc); sleep 60; C1=$(rdc); delta "$C0" "$C1" "$TAG"
  $W $A 'pkill -x qpsk_tun; sleep 1; grep "qpsk_tun stats" /dev/shm/cad_'$TAG'.log | tail -1' 2>/dev/null | cut -c1-160
  mkdir -p r3cap/cad_$TAG; SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no root@$A:/dev/shm/cad_frames.bin r3cap/cad_$TAG/frames.bin 2>/dev/null
  [ -f r3cap/cad_$TAG/frames.bin ] && python3 accept_analyze.py r3cap/cad_$TAG/frames.bin 2>&1 | grep -E "PER=|lag|UNUSABLE" | head -2 | sed "s/^/HOLES_$TAG /"
done
log "RESTORE"; GATE_DIR=A GATE_TRIES=8 bash bringup_r2r3.sh r3 > $S/postcad_bringup.log 2>&1; tail -1 $S/postcad_bringup.log
grep -q "BRING-UP COMPLETE" $S/postcad_bringup.log && { rig_unlock; rm -f /home/tcollins/modem-status/SENTINEL_STOP; systemd-run --user --unit=sentinelkeeper-$(date +%H%M%S) --collect bash $S/sentinel_keeper.sh; log "rig released, keeper relaunched"; } || log "LOOPA_STOP restore failed -- rig stays held"
log "LOOPA_CADENCE_DONE"
