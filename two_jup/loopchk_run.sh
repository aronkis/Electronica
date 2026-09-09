#!/bin/bash
# loopchk_run.sh -- 148-only LOOPBACK split of the ~9 % bad-magic frames seen at the decoder output on air.
#  Test A: internal loopback, TX = the daemon's own frames via MM2S (host byte-TX path) -> mod -> demod -> checker
#  Test B: internal loopback, TX = fabric TGEN source at the TX byte pins (no MM2S/host)  -> mod -> demod -> checker
# Metric: fabric magic_bad / frames (TGEN frames have a constant CRC and count as crc_fail by design).
# RF is excluded in both; A vs B splits host/MM2S byte-TX plane vs modulator/demod/decoder. 146 untouched.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; B=10.0.0.148; DUR=${DUR:-60}
. $D/sim_repro/riglock.sh 2>/dev/null || true
[ "${RIGLOCK_PARENT:-0}" = 1 ] || { rig_lock loopchk || exit 2; trap rig_unlock EXIT; }
DM='DM=$(command -v devmem || echo "busybox devmem")'
rdc(){ $W $B "$DM; DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo 0x104 > \$DRA; p=\$(cat \$DRA)
  names='acc_user frames crc_ok crc_fail magic_bad short orphan acc_beats'; i=0; out=''
  for n in \$names; do \$DM 0x9D410008 32 \$((i << 28)) >/dev/null; v=\$(\$DM 0x9D450008); out=\"\$out \$n=\$((v))\"; i=\$((i+1)); done
  \$DM 0x9D410008 32 0 >/dev/null; echo \"CNT\$out p104=\$((p)) t=\$(date +%s.%N)\"" 2>/dev/null; }
delta(){ python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys,re
a,z,dur,tag=sys.argv[1],sys.argv[2],float(sys.argv[3]),sys.argv[4]
ka={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',a)}; kz={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',z)}
d={k:(kz[k]-ka[k])&0xFFFFFFFF for k in ka if k in kz}; fr=d.get('frames',0)
print(f"LOOPCHK_{tag} {dur:.0f}s: frames={fr} ({fr/dur:.0f}/s) crc_ok={d.get('crc_ok',0)} crc_fail={d.get('crc_fail',0)} magic_bad={d.get('magic_bad',0)} short={d.get('short',0)} orphan={d.get('orphan',0)} 0x104d={d.get('p104',0)}"
      + (f"  magic_bad/frames={100*d.get('magic_bad',0)/fr:.3f}%  crc_fail/frames={100*d.get('crc_fail',0)/fr:.3f}%" if fr else ""))
PY
}
arm_loop(){ $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  for k in 1 2; do
    echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
    echo "0x158 '$1'">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
    echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
    echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; [ $k = 1 ] && sleep 3
  done' 2>/dev/null; }
echo "=== LOOPCHK on $B (probe-3 image) dur=${DUR}s ==="
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1' 2>/dev/null
$W $B "$DM; \$DM 0x9D400000 32 0; \$DM 0x9D410000 32 0" 2>/dev/null   # both injectors off
# ---- Test A: daemon TX via MM2S, loopback
$W $B "cd /root/host_app_k5; rm -f /dev/shm/loopchk.log; QPSK_FRAME=f1536 QPSK_RX_QUEUED=1 setsid chrt -f 50 ./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5 > /dev/shm/loopchk.log 2>&1 & exit 0" >/dev/null 2>&1
sleep 3; arm_loop 0x1; sleep 5
A0=$(rdc); sleep "$DUR"; A1=$(rdc); delta "$A0" "$A1" "$DUR" A_daemon_mm2s_loopback | tee -a "$D/LOOPCHK_$(date +%Y%m%d).txt"
$W $B 'grep "qpsk_tun stats" /dev/shm/loopchk.log | tail -1' 2>/dev/null | cut -c1-200
$W $B 'pkill -x qpsk_tun; sleep 1' 2>/dev/null
# ---- Test B: fabric TGEN at the TX byte pins (fill 1516, gap 200000 clk ~620 f/s), loopback.
# The RX DMA must be armed or the DUT byte plane stalls (first run: 0 words at the pins) -> keep the daemon running.
$W $B "cd /root/host_app_k5; QPSK_FRAME=f1536 QPSK_RX_QUEUED=1 setsid chrt -f 50 ./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5 > /dev/shm/loopchk_b.log 2>&1 & exit 0" >/dev/null 2>&1; sleep 3
$W $B "$DM; \$DM 0x9D400008 32 200000; \$DM 0x9D400000 32 \$(( (1516 << 4) | 1 )); echo TGEN_TX ctrl=\$(\$DM 0x9D400000)" 2>/dev/null
arm_loop 0x1; sleep 5
B0=$(rdc); sleep "$DUR"; B1=$(rdc); delta "$B0" "$B1" "$DUR" B_tgen_fabric_tx_loopback | tee -a "$D/LOOPCHK_$(date +%Y%m%d).txt"
$W $B "$DM; \$DM 0x9D400000 32 0" 2>/dev/null; $W $B 'pkill -x qpsk_tun' 2>/dev/null
echo "LOOPCHK_DONE"
