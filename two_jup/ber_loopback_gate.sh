#!/bin/bash
# ber_loopback_gate.sh -- Tier-A CALIBRATION gate for the full-packet BER tool.
#
# Arms ONE board for INTERNAL loopback (0x114=0, byte DMA source) and runs BOTH
# the already-trusted -e echo (whole-frame CRC, G2-proven ~99.9%) and the NEW -B
# full-packet BER scorer on the SAME arm. This disambiguates a tool bug from a
# modem/arm problem -- a wrong byte/word order in the scorer reads as ~50% BER,
# the SAME bucket as a real modem artifact, so -B alone is not conclusive.
# Decision table (advisor):
#   echo CRC-passes AND -B ~0 CLEAN   -> tool + modem good -> OTA UNBLOCKED
#   echo CRC-passes BUT -B has errors -> TOOL BUG (reference/compare/byte order)
#   both fail                         -> arm/image problem, NOT the tool
#
# Internal loopback is digital (no RF, no peer), so this touches one board only.
# Usage: ber_loopback_gate.sh [BOARD_IP]   (default 10.0.0.148); DUR=secs each.
set -u
IP=${1:-10.0.0.148}
DUR=${DUR:-20}
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=$(cd "$(dirname "$0")/.." && pwd)/host_app_k5
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

echo "[cal] === Tier-A loopback calibration on $IP (dur=${DUR}s each) ==="

# 1. quiesce: kill daemon + watchdog (separate call; '[l]ock_watchdog' regex + no
#    literal 'lock_watchdog.sh' in the cmd -> the kill never self-terminates)
$W $IP 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.5; echo "  quiesced ($(pgrep -c -x qpsk_tun 2>/dev/null || echo 0) qpsk_tun left)"' 2>/dev/null

# 2. profile + INTERNAL loopback arm (reuse G2 arm; NO reboot -- byte image is
#    already deployed on both boards). byte_ctrl_gpio=1 => per-packet TLAST, which
#    the -B legacy single-packet RX path requires (a -9'd -M daemon can leave it 0).
$W $IP 'P=/sys/bus/iio/devices/iio:device2; D2=/sys/kernel/debug/iio/iio:device2
 cat /root/lvds_1p92_mhz.bin > $P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > $P/profile_config 2>/dev/null; sleep 1
 echo calibrated > $P/out_voltage1_ensm_mode; echo calibrated > $P/in_voltage1_ensm_mode
 for g in 4 5 6 7; do echo 1 > $D2/agpio${g}_direction; echo 1 > $D2/agpio${g}_value; done
 echo tx_a > $P/out_voltage0_port_select
 echo 0 > $P/out_voltage0_hardwaregain; echo rf_enabled > $P/out_voltage0_ensm_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA; cat $DRA; }
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
 echo "0x158 0x1">$DRA        # tx_data_source = byte DMA
 echo "0x118 0x0">$DRA        # tx_source_select = in-FPGA Tx
 echo "0x114 0x0">$DRA        # rx_input_select = INTERNAL loopback (not air)
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
 echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
 busybox devmem 0x9D300000 32 0x1
 echo "  armed loopback: 0x158=$(rd 0x158) 0x118=$(rd 0x118) 0x114=$(rd 0x114) gpio=$(busybox devmem 0x9D300000 32)"' 2>/dev/null

# 3. deploy updated sources (incl the new qpsk_ber module) + on-board build
$W $IP 'mkdir -p /root/host_app_k5' 2>/dev/null
scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" \
       "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" root@$IP:/root/host_app_k5/ \
  || { echo "[cal] FAIL: scp sources"; exit 1; }
$W $IP 'cd /root/host_app_k5 && gcc -O2 -Wall -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c 2>/tmp/gcc.err && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }' 2>/dev/null | tee /dev/shm/cal_build.txt
grep -q BUILD_OK /dev/shm/cal_build.txt || { echo "[cal] FAIL: on-board build"; exit 1; }

# 3b. scorer self-test on the on-board binary (same -T path as the host suite)
echo "[cal] on-board self-test:"; $W $IP 'cd /root/host_app_k5 && ./qpsk_tun -T 2>&1' 2>/dev/null

# 4a. trusted echo cross-check (whole-frame CRC) -- the disambiguator
echo "[cal] --- echo (-e, whole-frame CRC) ---"
ECHO=$($W $IP "cd /root/host_app_k5; ./qpsk_tun -F -e -d $DUR 2>&1 | tail -2" 2>/dev/null)
echo "$ECHO"
TX=$(echo "$ECHO"   | grep -oE 'tx=[0-9]+'       | tail -1 | cut -d= -f2)
RXOK=$(echo "$ECHO" | grep -oE 'rx_ok=[0-9]+'    | tail -1 | cut -d= -f2)
CRC=$(echo "$ECHO"  | grep -oE 'crc_drop=[0-9]+' | tail -1 | cut -d= -f2)

# 4b. full-packet BER scorer
echo "[cal] --- BER (-B, full-packet 1024-bit compare) ---"
BER=$($W $IP "cd /root/host_app_k5; ./qpsk_tun -B -d $DUR 2>&1" 2>/dev/null)
echo "$BER"

# 5. verdict (advisor decision table)
echo "[cal] === VERDICT ==="
python3 - "$TX" "$RXOK" "$CRC" <<PY
import sys, re
tx=int(sys.argv[1] or 0); rxok=int(sys.argv[2] or 0); crc=int(sys.argv[3] or 0)
berlog='''$BER'''
m=re.search(r'BER=([0-9.eE+-]+)', berlog)
ber=float(m.group(1)) if m else None
mc=re.search(r'CLEAN=(\d+)\(([0-9.]+)%\)', berlog)
clean, clean_pct=(int(mc.group(1)), float(mc.group(2))) if mc else (0,0.0)
mf=re.search(r'frames_scored=(\d+)', berlog)
frames=int(mf.group(1)) if mf else 0
echo_pass = tx>0 and rxok>=0.90*tx and crc<=0.01*tx
ber_pass  = ber is not None and ber<1e-4 and frames>0 and clean_pct>95.0
print(f"  echo: tx={tx} rx_ok={rxok} crc_drop={crc} -> {'PASS' if echo_pass else 'FAIL'}"
      + (f" (rx/tx={rxok/tx:.3f} crc/tx={crc/tx:.4f})" if tx else ""))
print(f"  BER : frames={frames} BER={ber} CLEAN={clean}({clean_pct:.1f}%) -> {'PASS' if ber_pass else 'FAIL'}")
if echo_pass and ber_pass:
    print("  >>> GREEN: tool + modem both good on loopback -> OTA measurement UNBLOCKED"); sys.exit(0)
if echo_pass and not ber_pass:
    print("  >>> TOOL BUG: bytes decode fine (echo CRC-pass) but -B sees errors ->"
          " reference/byte-order/endianness in qpsk_ber is wrong. Fix before OTA."); sys.exit(2)
if (not echo_pass) and (not ber_pass):
    print("  >>> ARM/IMAGE problem: both paths fail -> loopback arm or byte image,"
          " NOT the scorer. Re-check arm / image before blaming the tool."); sys.exit(3)
print("  >>> ANOMALY: echo fails but -B passes -> investigate the echo/CRC path."); sys.exit(4)
PY
