#!/bin/bash
# g3_ota_byte.sh -- G3: OTA arbitrary-byte test of the Path A byte image.
# 146 = byte-Tx AIR radiating arbitrary qpsk_frames (daemon -e); 148 = byte-Rx AIR
# decoding them (daemon -e, own TX RF OFF so no self-interference). Validates the
# resolver fix holds OTA with arbitrary data (the advisor's real judge) + envelope.
#   deploy Path A image to 146 -> arm 146 byte-Tx AIR + daemon TX -> arm 148
#   byte-Rx AIR (TX off) + daemon RX 30s -> 148 rx_ok/crc_drop/seq_gap + rstcs +
#   ch2 QPSK envelope. GATE: 148 rx_ok>0 climbing, crc_drop/rx_ok<10%, rstcs low,
#   envelope QPSK (occ-bw ~170k, not a CW tone).
set -u
BIN=${1:-/mnt/onetb/scratch/qpsk_byte_resolver_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN}
TX=10.0.0.146; RX=10.0.0.148; CARRIER=2000000000; TXLO=2000005767
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=/mnt/onetb/scratch/qpsk_variants/host_app_k5
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
wait_up(){ until ! ping -c1 -W1 $1 >/dev/null 2>&1; do sleep 2; done; until ping -c1 -W2 $1 >/dev/null 2>&1; do sleep 3; done; sleep 20; }

echo "[g3] deploy Path A $(md5sum "$BIN" | cut -c1-12) -> 146"
scpput "$BIN" root@$TX:/dev/shm/BOOT.new
$W $TX 'S=$(stat -c %s /dev/shm/BOOT.new); if [ "$S" -gt 6000000 ]; then cp /boot/BOOT.BIN /boot/BOOT.BIN.prebyteA; cp /dev/shm/BOOT.new /boot/BOOT.BIN; sync; echo "  146 swapped -> $(md5sum /boot/BOOT.BIN|cut -c1-12)"; else echo BADSIZE; exit 1; fi; (sleep 1; reboot)>/dev/null 2>&1 &' 2>/dev/null || exit 1
wait_up $TX
# build host_app on 146
$W $TX 'mkdir -p /root/host_app_k5' 2>/dev/null
scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" root@$TX:/root/host_app_k5/
$W $TX 'cd /root/host_app_k5 && gcc -O2 -Wall -o qpsk_tun qpsk_tun.c qpsk_frame.c 2>/dev/null && echo 146_BUILD_OK || echo 146_BUILD_FAIL' 2>/dev/null

echo "[g3] arm 146 byte-Tx AIR @${TXLO} + start daemon (radiating arbitrary frames)"
$W $TX "P=/sys/bus/iio/devices/iio:device2; D2=/sys/kernel/debug/iio/iio:device2
 cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
 echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
 for g in 4 5 6 7; do echo 1 > \$D2/agpio\${g}_direction; echo 1 > \$D2/agpio\${g}_value; done
 echo tx_a > \$P/out_voltage0_port_select
 echo $TXLO > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x000 0x1'>\$DRA; sleep 0.5; echo '0x000 0x0'>\$DRA; echo '0x158 0x1'>\$DRA; echo '0x118 0x0'>\$DRA; echo '0x114 0x1'>\$DRA
 TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done); T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
 echo '0x418 0x2'>\$T; echo '0x458 0x2'>\$T; echo '0x044 0x1'>\$T; echo '0x110 0x1'>\$DRA; sleep 0.3; echo '0x110 0x0'>\$DRA
 cd /root/host_app_k5; pkill -x qpsk_tun 2>/dev/null; sleep 0.5; (setsid nohup ./qpsk_tun -F -e -d 90 > /dev/shm/tx.log 2>&1 &); sleep 2
 echo \"  146 Tx armed, daemon=\$(pgrep -c qpsk_tun) rssi=\$(cat \$P/in_voltage0_rssi)\"" 2>/dev/null

echo "[g3] arm 148 byte-Rx AIR (own TX off) + daemon RX 30s"
$W $RX "P=/sys/bus/iio/devices/iio:device2
 echo calibrated > \$P/out_voltage0_ensm_mode   # 148 TX OFF (one-direction test, no self-interference)
 echo $CARRIER > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 echo rf_enabled > \$P/in_voltage1_ensm_mode; echo automatic > \$P/in_voltage1_gain_control_mode 2>/dev/null
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 echo '0x000 0x1'>\$DRA; sleep 0.5; echo '0x000 0x0'>\$DRA; echo '0x158 0x1'>\$DRA; echo '0x118 0x0'>\$DRA; echo '0x114 0x1'>\$DRA; echo '0x110 0x1'>\$DRA; sleep 0.3; echo '0x110 0x0'>\$DRA
 r0=\$(rd 0x150)
 cd /root/host_app_k5; pkill -x qpsk_tun 2>/dev/null; sleep 0.5
 ./qpsk_tun -F -e -d 30 2>&1 | tail -2
 r1=\$(rd 0x150)
 echo \"  148 rstcs \$r0 -> \$r1  (stable/low => locked on 146 OTA arbitrary data)\"
 rm -f /dev/shm/env.iq; timeout 6 iio_readdev -u local: -b 32768 -s 250000 axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /dev/shm/env.iq 2>/dev/null; echo \"  ch2 env cap=\$(stat -c %s /dev/shm/env.iq) rssi=\$(cat \$P/in_voltage0_rssi)\"" 2>/dev/null
scpput root@$RX:/dev/shm/env.iq "$D/g3_env.iq"
echo "[g3] ch2 envelope (146 radiating byte-Tx):"
python3 - "$D/g3_env.iq" <<'PY'
import numpy as np, sys
d=np.fromfile(sys.argv[1],dtype=np.int16)
if d.size<2000: print("  no capture"); sys.exit()
I=d[0::2].astype(float);Q=d[1::2].astype(float);n=min(len(I),len(Q));x=I[:n]+1j*Q[:n];x-=x.mean()
rms=np.sqrt(np.mean(np.abs(x)**2))
N=1<<16; X=np.fft.fftshift(np.abs(np.fft.fft(x[:N]*np.hanning(N)))**2); f=np.linspace(-0.96e6,0.96e6,N)
pmr=X.max()/np.median(X); occ=np.sum(X>X.max()*0.01)/N*1.92e6/1e3
v="CW-TONE (BAD)" if (pmr>5000 and occ<40) else "QPSK-like (OK)"
print(f"  rms={rms:.0f} peak/med={pmr:.0f} occ-bw~{occ:.0f}kHz -> {v}")
PY
