#!/bin/bash
# loopchk_b.sh -- Test B done the CANONICAL way (tgen_sweep.sh idiom): single loopback arm, enable the
# fabric TGEN at the TX byte pins, then start the -S scorer (it arms the RX DMA); read the decoder-output
# checker (probe-3 mux) twice inside the dwell. Metric: magic_bad/frames (TGEN CRC is a constant -> crc_fail).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; A=10.0.0.148; DWELL=${DWELL:-70}
. $D/sim_repro/riglock.sh 2>/dev/null || true
[ "${RIGLOCK_PARENT:-0}" = 1 ] || { rig_lock loopchk_b || exit 2; trap rig_unlock EXIT; }
DM='DM=$(command -v devmem || echo "busybox devmem")'
rdc(){ $W $A "$DM; DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo 0x104 > \$DRA; p=\$(cat \$DRA); echo 0x108 > \$DRA; e=\$(cat \$DRA)
  names='acc_user frames crc_ok crc_fail magic_bad short orphan acc_beats'; i=0; out=''
  for n in \$names; do \$DM 0x9D410008 32 \$((i << 28)) >/dev/null; v=\$(\$DM 0x9D450008); out=\"\$out \$n=\$((v))\"; i=\$((i+1)); done
  \$DM 0x9D410008 32 0 >/dev/null; echo \"CNT\$out p104=\$((p)) e108=\$((e)) t=\$(date +%s.%N)\"" 2>/dev/null; }
delta(){ python3 - "$1" "$2" "$3" <<'PY'
import sys,re
a,z,tag=sys.argv[1],sys.argv[2],sys.argv[3]
ka={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',a)}; kz={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',z)}
ta=float(re.search(r't=([\d.]+)',a).group(1)); tz=float(re.search(r't=([\d.]+)',z).group(1)); dur=max(tz-ta,1e-9)
d={k:(kz[k]-ka[k])&0xFFFFFFFF for k in ka if k in kz}; fr=d.get('frames',0)
print(f"LOOPCHK_{tag} {dur:.0f}s: frames={fr} ({fr/dur:.0f}/s) crc_ok={d.get('crc_ok',0)} crc_fail={d.get('crc_fail',0)} magic_bad={d.get('magic_bad',0)} short={d.get('short',0)} orphan={d.get('orphan',0)} 0x104d={d.get('p104',0)} 0x108d={d.get('e108',0)}"
      + (f"  magic_bad/frames={100*d.get('magic_bad',0)/fr:.3f}%  headers-ok(crc_ok+crc_fail)/frames={100*(d.get('crc_ok',0)+d.get('crc_fail',0))/fr:.3f}%" if fr else "  (no frames at the pins)"))
PY
}
$W $A 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; pkill -9 -f "[l]ock_watchdog"; pkill -x qpsk_tun; exit 0' 2>/dev/null
$W $A "$DM; \$DM 0x9D400000 32 0; \$DM 0x9D410000 32 0" 2>/dev/null
# canonical single loopback arm (tgen_sweep.sh verbatim)
$W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; echo "  loopback armed (0x114=0)"' 2>/dev/null
for g in ${GAPS:-200000 100000}; do
  $W $A "$DM; \$DM 0x9D400008 32 $g; \$DM 0x9D400000 32 \$(( (1516 << 4) | 1 )); echo TGEN_TX gap=$g ctrl=\$(\$DM 0x9D400000)" 2>/dev/null
  $W $A "cd /root/host_app_k5; rm -f /dev/shm/loopchk_b.log; QPSK_FRAME=f1536 QPSK_SEQ_RXONLY=1 QPSK_RX_QUEUED=1 QPSK_WHITEN=0 setsid chrt -f 50 ./qpsk_tun -S -M 16 -r 15360 -d $DWELL > /dev/shm/loopchk_b.log 2>&1 & exit 0" >/dev/null 2>&1
  sleep 8; B0=$(rdc); echo "RAW0 $B0"; sleep $((DWELL - 16)); B1=$(rdc); echo "RAW1 $B1"
  delta "$B0" "$B1" "B_tgen_tx_loopback_gap$g" | tee -a "$D/LOOPCHK_$(date +%Y%m%d).txt"
  sleep 10; $W $A 'grep -E "SEQRX frames_scored" /dev/shm/loopchk_b.log | tail -1' 2>/dev/null | cut -c1-200
  $W $A "$DM; \$DM 0x9D400000 32 0; pkill -x qpsk_tun" 2>/dev/null; sleep 2
done
echo "LOOPCHK_B_DONE"
