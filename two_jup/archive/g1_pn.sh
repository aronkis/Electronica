#!/bin/bash
# g1_pn.sh — deploy the PN-filler image to 146 (TX side) and run G1 on 146->148.
#   1. deploy BOOT.BIN -> 146 (backup .prev_pn), reboot, setup, arm modem Tx
#   2. ch2-based TRUE CFO measure on 148 (chip-pure path) -> re-trim 146 TX LO -> re-arm
#   3. 146 internal-loopback sanity (new ROM end-to-end on-chip)
#   4. 148 canonical arm -> 60 s BIST observation + forensic
#   5. anti-mirage (146 Tx RF off -> BIST must break -> restore -> re-lock)
# Usage: g1_pn.sh BOOT.BIN
set -u
BIN=$1
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
TX=10.0.0.146; RX=10.0.0.148; CARRIER=2000000000
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
wait_up(){ until ! ping -c1 -W1 $1 >/dev/null 2>&1; do sleep 2; done; until ping -c1 -W2 $1 >/dev/null 2>&1; do sleep 3; done; sleep 20; }

echo "[g1pn] deploy $(md5sum "$BIN" | cut -c1-12) -> $TX"
scpput "$BIN" root@$TX:/dev/shm/BOOT.new
$W $TX 'S=$(stat -c %s /dev/shm/BOOT.new); if [ "$S" -gt 6000000 ]; then cp /boot/BOOT.BIN /boot/BOOT.BIN.prev_pn; cp /dev/shm/BOOT.new /boot/BOOT.BIN; sync; echo "  swapped -> $(md5sum /boot/BOOT.BIN | cut -c1-12)"; else echo "  BAD SIZE $S"; exit 1; fi; (sleep 1; reboot) >/dev/null 2>&1 &' 2>/dev/null || exit 1
wait_up $TX

echo "[g1pn] 146 setup + internal sanity (new ROM on-chip)"
IL=$($W $TX 'P=/sys/bus/iio/devices/iio:device2; D2=/sys/kernel/debug/iio/iio:device2
 cat /root/lvds_1p92_mhz.bin > $P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > $P/profile_config 2>/dev/null; sleep 1
 echo calibrated > $P/out_voltage1_ensm_mode; echo calibrated > $P/in_voltage1_ensm_mode
 for g in 4 5 6 7; do echo 1 > $D2/agpio${g}_direction; echo 1 > $D2/agpio${g}_value; done
 echo tx_a > $P/out_voltage0_port_select
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA; cat $DRA; }
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; sleep 2; rd 0x144' 2>/dev/null)
echo "  146 internal cap=$IL (need 0x4922282)"
[ "$IL" = "0x4922282" ] || { echo "[g1pn] FAIL: internal loopback not golden on PN image"; exit 1; }

echo "[g1pn] arm 146 modem Tx @ nominal trim"
arm_tx(){ # $1 = TX LO
  $W $TX "P=/sys/bus/iio/devices/iio:device2
   echo $1 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x000 0x1'>\$DRA; sleep 0.5; echo '0x000 0x0'>\$DRA; echo '0x118 0x0'>\$DRA; echo '0x114 0x1'>\$DRA
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done); T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x2'>\$T; echo '0x458 0x2'>\$T; echo '0x044 0x1'>\$T; echo '0x110 0x1'>\$DRA; sleep 0.3; echo '0x110 0x0'>\$DRA; echo '  146 Tx armed @'$1" 2>/dev/null
}
arm_tx 2000005767

echo "[g1pn] TRUE CFO via ch2 (chip-pure) on 148"
$W $RX "P=/sys/bus/iio/devices/iio:device2
 echo $CARRIER > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 echo rf_enabled > \$P/in_voltage1_ensm_mode; echo automatic > \$P/in_voltage1_gain_control_mode 2>/dev/null; sleep 1
 rm -f /dev/shm/cfo.iq; timeout 6 iio_readdev -u local: -b 32768 -s 250000 axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /dev/shm/cfo.iq 2>/dev/null; echo \"  ch2 cap=\$(stat -c %s /dev/shm/cfo.iq)\"" 2>/dev/null
SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no root@$RX:/dev/shm/cfo.iq /dev/shm/g1pn_cfo.iq </dev/null 2>/dev/null
CFO=$(python3 - <<'PY'
import numpy as np
d=np.fromfile('/dev/shm/g1pn_cfo.iq',dtype=np.int16); I=d[0::2].astype(float);Q=d[1::2].astype(float)
n=min(len(I),len(Q)); x=I[:n]+1j*Q[:n]; x-=x.mean()
N=1<<16; w=(x[:N])**4
W=np.fft.fftshift(np.abs(np.fft.fft(w*np.hanning(N),1<<18))); f=np.linspace(-0.96e6,0.96e6,1<<18)
m=np.abs(f)<400e3; W2=W.copy(); W2[~m]=0
pk=int(np.argmax(W2))
snr=W2[pk]/np.median(W[m])
print(int(round(f[pk]/4)) if snr>30 else 99999)
PY
)
echo "  residual true CFO = ${CFO} Hz"
if [ "$CFO" = "99999" ]; then echo "[g1pn] WARN: no 4th-power line (weak signal?) — continuing at nominal trim"; CFO=0; fi
if [ "${CFO#-}" -gt 300 ]; then
  NEWLO=$((2000005767 + CFO)); echo "  re-trim: TX LO -> $NEWLO"; arm_tx $NEWLO
fi

echo "[g1pn] 148 air BIST (60 s observation)"
$W $RX "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 echo '0x000 0x1'>\$DRA; sleep 1; echo '0x000 0x0'>\$DRA; echo '0x118 0x0'>\$DRA; echo '0x114 0x1'>\$DRA; echo '0x110 0x1'>\$DRA; sleep 0.3; echo '0x110 0x0'>\$DRA; sleep 3
 r0=\$(rd 0x150); locks=0
 for t in \$(seq 1 12); do c=\$(rd 0x144); [ \"\$c\" = \"0x4922282\" ] && locks=\$((locks+1)); echo -n \"\$c \"; sleep 5; done
 r1=\$(rd 0x150); f=\$(rd 0x15C); e=\$(rd 0x108); p=\$(rd 0x104)
 echo \"\"
 echo \"  locks=\$locks/12 rstcs \$r0->\$r1 pkts=\$p err=\$e forensic=\$f\"" 2>/dev/null

echo "[g1pn] ANTI-MIRAGE (146 Tx RF off)"
$W $TX 'echo calibrated > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null
sleep 3
AM=$($W $RX 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA; cat $DRA; }
 p0=$(rd 0x104); sleep 5; p1=$(rd 0x104); [ "$p0" = "$p1" ] && echo FROZEN || echo COUNTING' 2>/dev/null)
echo "  far-Tx-off pkts: $AM (must be FROZEN — cap_out holds last value by design)"
$W $TX 'echo rf_enabled > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null
[ "$AM" = "COUNTING" ] && { echo "[g1pn] FAIL: MIRAGE (frames counted with far Tx off)"; exit 1; }
sleep 3
FIN=$($W $RX 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA; cat $DRA; }
 echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; sleep 6; rd 0x144' 2>/dev/null)
echo "  restored cap=$FIN"
if [ "$FIN" = "0x4922282" ]; then echo "[g1pn] G1 PASS (146->148)"; exit 0; else echo "[g1pn] G1 FAIL (no re-lock after restore)"; exit 1; fi
