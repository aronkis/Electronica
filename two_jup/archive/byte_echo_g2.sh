#!/bin/bash
# byte_echo_g2.sh -- G2 gate: deploy the byte image to one board and validate the
# byte datapath by INTERNAL loopback echo (no RF), then check the Tx RF ENVELOPE.
#   1. deploy BOOT.BIN -> board (backup .prebyte), reboot, profile setup
#   2. byte arm for INTERNAL loopback: 0x000 pulse -> 0x158=1 (byte src) ->
#      0x118=0 (in-FPGA Tx) -> 0x114=0 (INTERNAL, not air) -> DAC mux -> rstCS
#   3. scp host_app_k5 sources + on-board gcc build
#   4. qpsk_tun -F -e -d 60  -> parse tx / rx_ok / crc_drop
#      GATE: rx_ok >= 90% of tx AND crc_drop <= 1% of tx
#   5. ENVELOPE CHECK (mandatory, README CW-tone risk): arm Tx RF, capture the
#      chip-pure ch2 on THIS board, confirm a QPSK envelope (not a CW tone)
#      BEFORE trusting any OTA CRC. Reported, not gated here (informational for G3).
# Usage: byte_echo_g2.sh BOOT.BIN BOARD_IP
set -u
BIN=$1; IP=$2
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=/mnt/onetb/scratch/qpsk_variants/host_app_k5
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
scpget(){ scpput "$@"; }
wait_up(){ until ! ping -c1 -W1 $1 >/dev/null 2>&1; do sleep 2; done; until ping -c1 -W2 $1 >/dev/null 2>&1; do sleep 3; done; sleep 20; }

echo "[g2] deploy $(md5sum "$BIN" | cut -c1-12) -> $IP"
scpput "$BIN" root@$IP:/dev/shm/BOOT.new
$W $IP 'S=$(stat -c %s /dev/shm/BOOT.new); if [ "$S" -gt 6000000 ]; then cp /boot/BOOT.BIN /boot/BOOT.BIN.prebyte; cp /dev/shm/BOOT.new /boot/BOOT.BIN; sync; echo "  swapped -> $(md5sum /boot/BOOT.BIN | cut -c1-12)"; else echo "  BAD SIZE $S"; exit 1; fi; (sleep 1; reboot) >/dev/null 2>&1 &' 2>/dev/null || exit 1
wait_up $IP
$W $IP 'P=/sys/bus/iio/devices/iio:device2; D2=/sys/kernel/debug/iio/iio:device2
 echo "  boot=$(md5sum /boot/BOOT.BIN | cut -c1-12) devs=$(ls /sys/bus/iio/devices | wc -l)"
 cat /root/lvds_1p92_mhz.bin > $P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > $P/profile_config 2>/dev/null; sleep 1
 echo "  fs=$(cat $P/in_voltage0_sampling_frequency)"
 echo calibrated > $P/out_voltage1_ensm_mode; echo calibrated > $P/in_voltage1_ensm_mode
 for g in 4 5 6 7; do echo 1 > $D2/agpio${g}_direction; echo 1 > $D2/agpio${g}_value; done
 echo tx_a > $P/out_voltage0_port_select
 grep -q "qpsk_byte_buf@7ff00000" /proc/device-tree/reserved-memory/* 2>/dev/null && echo "  dtb carve present" || echo "  WARN: no dtb carve (byte DMA mmap unsafe)"' 2>/dev/null

echo "[g2] byte arm (INTERNAL loopback: 0x114=0, 0x158=1)"
$W $IP 'P=/sys/bus/iio/devices/iio:device2
 echo 0 > $P/out_voltage0_hardwaregain; echo rf_enabled > $P/out_voltage0_ensm_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA; cat $DRA; }
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
 echo "0x158 0x1">$DRA        # tx_data_source = byte DMA
 echo "0x118 0x0">$DRA        # tx_source_select = in-FPGA Tx
 echo "0x114 0x0">$DRA        # rx_input_select = INTERNAL loopback
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
 echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
 echo "  armed: 0x158=$(rd 0x158) 0x118=$(rd 0x118) 0x114=$(rd 0x114) tx_data_source_reg ok"' 2>/dev/null

echo "[g2] deploy + on-board gcc build of host_app_k5"
$W $IP 'mkdir -p /root/host_app_k5' 2>/dev/null
scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" root@$IP:/root/host_app_k5/ || { echo "[g2] FAIL: scp sources"; exit 1; }
$W $IP 'cd /root/host_app_k5 && gcc -O2 -Wall -o qpsk_tun qpsk_tun.c qpsk_frame.c 2>/tmp/gcc.err && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }' 2>/dev/null | tee /dev/shm/g2_build.txt
grep -q BUILD_OK /dev/shm/g2_build.txt || { echo "[g2] FAIL: on-board gcc build"; exit 1; }

echo "[g2] INTERNAL byte echo (qpsk_tun -F -e -d 60)"
ECHO=$($W $IP 'cd /root/host_app_k5; pkill -x qpsk_tun 2>/dev/null; sleep 0.5; ./qpsk_tun -F -e -d 60 2>&1 | tail -3' 2>/dev/null)
echo "$ECHO"
TX=$(echo "$ECHO" | grep -oE 'tx=[0-9]+' | tail -1 | cut -d= -f2)
RXOK=$(echo "$ECHO" | grep -oE 'rx_ok=[0-9]+' | tail -1 | cut -d= -f2)
CRC=$(echo "$ECHO" | grep -oE 'crc_drop=[0-9]+' | tail -1 | cut -d= -f2)
echo "  parsed: tx=$TX rx_ok=$RXOK crc_drop=$CRC"
if [ -z "${TX:-}" ] || [ -z "${RXOK:-}" ] || [ "$TX" = "0" ]; then echo "[g2] FAIL: no echo stats (tx=0?)"; exit 1; fi
PASS=$(python3 -c "tx=$TX; rx=$RXOK; crc=${CRC:-0}; print(1 if (rx>=0.90*tx and crc<=0.01*tx) else 0)")
echo "  echo gate: rx_ok/tx=$(python3 -c "print('%.3f'%($RXOK/$TX))") crc/tx=$(python3 -c "print('%.4f'%(${CRC:-0}/$TX))")"

echo "[g2] ENVELOPE CHECK (Tx RF on -> chip-pure ch2 -> QPSK vs CW-tone; informational)"
$W $IP 'P=/sys/bus/iio/devices/iio:device2
 echo 2000000000 > $P/out_altvoltage2_TX1_LO_frequency
 echo rf_enabled > $P/in_voltage1_ensm_mode; echo automatic > $P/in_voltage1_gain_control_mode 2>/dev/null; sleep 1
 rm -f /dev/shm/env.iq; timeout 6 iio_readdev -u local: -b 32768 -s 250000 axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /dev/shm/env.iq 2>/dev/null; echo "  ch2 cap=$(stat -c %s /dev/shm/env.iq)"' 2>/dev/null
scpget root@$IP:/dev/shm/env.iq "$D/g2_envelope.iq"
python3 - "$D/g2_envelope.iq" <<'PY'
import numpy as np, sys
d=np.fromfile(sys.argv[1],dtype=np.int16)
if d.size<2000: print("  ENVELOPE: no capture"); sys.exit()
I=d[0::2].astype(float);Q=d[1::2].astype(float);n=min(len(I),len(Q));x=I[:n]+1j*Q[:n];x-=x.mean()
rms=np.sqrt(np.mean(np.abs(x)**2))
N=1<<16; X=np.fft.fftshift(np.abs(np.fft.fft(x[:N]*np.hanning(N)))**2); f=np.linspace(-0.96e6,0.96e6,N)
peak=X.max(); med=np.median(X); pmr=peak/med
occ=np.sum(X> peak*0.01)/N*1.92e6/1e3   # rough occupied bw (kHz) at -20dB
# a CW tone => huge peak/median, tiny occupied bw; QPSK => spread, moderate pmr, ~170kHz
verdict = "CW-TONE (BAD)" if (pmr>5000 and occ<40) else "QPSK-like (OK)"
print(f"  ENVELOPE: rms={rms:.0f} peak/med={pmr:.0f} occ-bw~{occ:.0f}kHz -> {verdict}")
PY

if [ "$PASS" = "1" ]; then echo "[g2] G2 PASS (internal byte echo)"; exit 0; else echo "[g2] G2 FAIL (echo gate)"; exit 1; fi
