#!/bin/bash
# txq_session.sh -- SINGLE rig actor: deploy the txgap-witness daemon on both boards, then
#  A1 148 loopback, TXQ off : txgap gt20us vs fabric bad-magic (witness, predicted ~1:1)
#  A2 148 loopback, TXQ=5   : predicted gt20us -> ~0 and bad-magic -> ~0
#  B1 air, legacy daemons   : forward checker window (baseline)
#  B2 air, TXQ=5 both ends  : forward checker window x2
#  C  defect-B witness      : RXQ=0 bring-up, 200 rapid samples of the v5 FIFO debug word 0x1B0 (guarded)
#  restore default bring-up, release.
set -u
D=$(cd "$(dirname "$0")" && pwd); cd $D; W=./anyssh.sh; A=10.0.0.148; B=10.0.0.146
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad
. sim_repro/riglock.sh; rig_lock txq_session || { echo "TXQ_STOP lock busy"; exit 1; }; trap rig_unlock EXIT
systemctl --user stop 'sentinelkeeper-*' 2>/dev/null; for p in $(pgrep -f "[d]elivery_sentinel.sh"); do kill $p; done
log(){ echo "$(date +%F_%T) $*"; }
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no "$@" 2>/dev/null; }
DM='DM=$(command -v devmem || echo "busybox devmem")'
for H in $A $B; do
  scpput ../host_app_k5/qpsk_tun.c ../host_app_k5/qpsk_frame.c ../host_app_k5/qpsk_frame.h ../host_app_k5/qpsk_uio.c ../host_app_k5/qpsk_uio.h ../host_app_k5/qpsk_seq.c ../host_app_k5/qpsk_seq.h ../host_app_k5/qpsk_ber.c ../host_app_k5/qpsk_ber.h root@$H:/root/host_app_k5/ || { log "TXQ_STOP scp to $H failed"; exit 1; }
  R=$($W $H 'cd /root/host_app_k5 && cp -n qpsk_tun qpsk_tun.pre_txq; gcc -O2 -Wall -Wextra -DQPSK_CARVE_2MB -o qpsk_tun.new qpsk_tun.c qpsk_frame.c qpsk_uio.c qpsk_seq.c qpsk_ber.c 2>&1 | tail -3; [ -x qpsk_tun.new ] && mv qpsk_tun.new qpsk_tun && echo BUILD_OK || echo BUILD_FAIL' 2>/dev/null)
  log "deploy $H: $(echo "$R" | tr '\n' ' ' | cut -c1-200)"; echo "$R" | grep -q BUILD_OK || { log "TXQ_STOP build failed on $H"; exit 1; }
done
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
print(f"CHK_{tag} {dur:.0f}s: frames={fr} ({fr/dur:.0f}/s) crc_ok={d.get('crc_ok',0)} crc_fail={d.get('crc_fail',0)} magic_bad={d.get('magic_bad',0)} short={d.get('short',0)} orphan={d.get('orphan',0)} 0x104d={d.get('p104',0)}" + (f"  magic_bad/frames={100*d.get('magic_bad',0)/fr:.3f}%" if fr else ""))
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
loopA(){ # $1 = tag, $2 = env
  $W $A 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1' 2>/dev/null
  $W $A "$DM; \$DM 0x9D400000 32 0; \$DM 0x9D410000 32 0" 2>/dev/null
  $W $A "cd /root/host_app_k5; rm -f /dev/shm/txq_$1.log; QPSK_FRAME=f1536 QPSK_RX_QUEUED=1 $2 setsid chrt -f 50 ./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5 > /dev/shm/txq_$1.log 2>&1 & exit 0" >/dev/null 2>&1
  sleep 3; arm_loop; sleep 8
  C0=$(rdc); G0=$($W $A "grep -c 'qpsk_tun txgap' /dev/shm/txq_$1.log" 2>/dev/null); sleep 60; C1=$(rdc)
  delta "$C0" "$C1" "$1"
  $W $A "grep 'qpsk_tun txgap' /dev/shm/txq_$1.log | tail -n +$((G0+1)) | head -12" 2>/dev/null | sed "s/^/TXGAP_$1 /"
  $W $A 'pkill -x qpsk_tun; sleep 1' 2>/dev/null
}
log "A1 loopback, TXQ off"; loopA A1_txq0 ""
log "A2 loopback, QPSK_TX_QUEUED=5"; loopA A2_txq5 "QPSK_TX_QUEUED=5"
log "B1 air, legacy daemons (bring-up)"; GATE_DIR=A GATE_TRIES=8 bash bringup_r2r3.sh r3 > $S/txq_b1_bringup.log 2>&1; tail -1 $S/txq_b1_bringup.log
grep -q "BRING-UP COMPLETE" $S/txq_b1_bringup.log && { DUR=60 bash rxchk_run.sh 2>&1 | sed 's/^/B1 /'; $W $B 'grep "qpsk_tun txgap" /dev/shm/qpsk_tun.log | tail -2' 2>/dev/null | sed 's/^/TXGAP_146_B1 /'; }
log "B2 air, QPSK_TX_QUEUED=5 both ends (bring-up)"; DAEMON_ENV="QPSK_TX_QUEUED=5" GATE_DIR=A GATE_TRIES=8 bash bringup_r2r3.sh r3 > $S/txq_b2_bringup.log 2>&1; tail -1 $S/txq_b2_bringup.log
grep -q "BRING-UP COMPLETE" $S/txq_b2_bringup.log && { for i in 1 2; do DUR=60 bash rxchk_run.sh 2>&1 | sed "s/^/B2_$i /"; $W $B 'grep "qpsk_tun txgap" /dev/shm/qpsk_tun.log | tail -1' 2>/dev/null | sed "s/^/TXGAP_146_B2_$i /"; done; }
log "C defect-B witness: RXQ=0 bring-up + 200 rapid 0x1B0 samples (guarded)"; RXQ=0 GATE_DIR=A GATE_TRIES=8 bash bringup_r2r3.sh r3 > $S/txq_c_bringup.log 2>&1; tail -1 $S/txq_c_bringup.log
if grep -q "BRING-UP COMPLETE" $S/txq_c_bringup.log; then . sim_repro/no_arm_inflight.sh; arm_guard txq_c && $W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; for i in $(seq 200); do echo 0x1B0 > $DRA; cat $DRA; done' 2>/dev/null > $S/defectB_1b0_samples.txt; python3 - <<'PY'
import re,collections,subprocess,sys
S='/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad'
vals=[int(l,16) for l in open(S+'/defectB_1b0_samples.txt') if l.strip()]
# v5 debug word: {rdyRun[7:0], ready_1, valid_i, ready, stateControl_2, enb, nonempty, byp_sel, ovf_nz, wr[7:0], rd[7:0]}
def dec(v): return dict(rdyRun=(v>>24)&0xFF, ready_1=(v>>23)&1, valid_i=(v>>22)&1, ready=(v>>21)&1, nonempty=(v>>18)&1, wr=(v>>8)&0xFF, rd=v&0xFF)
ds=[dec(v) for v in vals]
c=collections.Counter((d['ready'],d['nonempty']) for d in ds)
occ=[(d['wr']-d['rd'])&0xFF for d in ds]
print(f"DEFECTB_1B0 n={len(vals)} (ready,nonempty) hist={dict(c)} rdyRun<255 samples={sum(1 for d in ds if d['rdyRun']<255)} occupancy(low8) max={max(occ) if occ else -1} mean={sum(occ)/len(occ) if occ else -1:.1f}")
PY
fi
log "RESTORE default bring-up"; GATE_DIR=A GATE_TRIES=8 bash bringup_r2r3.sh r3 > $S/txq_restore_bringup.log 2>&1; tail -1 $S/txq_restore_bringup.log
grep -q "BRING-UP COMPLETE" $S/txq_restore_bringup.log && { rig_unlock; rm -f /home/tcollins/modem-status/SENTINEL_STOP; systemd-run --user --unit=sentinelkeeper-$(date +%H%M%S) --collect bash $S/sentinel_keeper.sh; log "rig released, keeper relaunched"; } || log "TXQ_STOP restore failed -- rig stays held"
log "TXQ_SESSION_DONE"
