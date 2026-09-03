#!/bin/bash
# byte_link_up.sh -- per-board bring-up for the two-radio K5 byte link (K.3).
#
# Runs ON THE HOST, once per board (the two boards get mirrored TX/RX
# carriers and mirrored tun addresses):
#   ./byte_link_up.sh BOARD_IP TX_CARRIER RX_CARRIER TRIM [TUN_ADDR] [PEER_ADDR]
# e.g. (link A on 2.40 GHz, link B on 2.45 GHz, Tx-side CFO trim on .146):
#   ./byte_link_up.sh 10.0.0.146 2400000000 2450000000 5420 10.66.0.1 10.66.0.2
#   ./byte_link_up.sh 10.0.0.148 2450000000 2400000000 0    10.66.0.2 10.66.0.1
#
# Does, in order (patterns from gonogo.sh / the K.3 plan):
#   1. radio setup: 1.92 MHz LVDS profile load, ch2 kill, LNAs on
#      (debugfs agpio4-7 numeric), tx_a port select
#   2. LOs: TX1 LO = TX_CARRIER + TRIM (the trim pre-compensates the
#      measured CFO at the transmitter, as in gonogo.sh), RX1 LO =
#      RX_CARRIER; ensm rf_enabled both directions; Rx gain automatic,
#      Tx attenuation 0 dB
#   3. canonical K5 byte arm via the mwipcore debugfs direct_reg_access
#      (devmem writes to 0x9D000xxx are SILENTLY IGNORED on this image --
#      the mwipcore driver owns the region). Order:
#        0x000 pulse -> 0x158=1 (tx_data_source=DMA bytes; K5 offset, the
#        legacy 0x11C is the K5 debug sentinel) -> 0x118=0 -> 0x114=1 ->
#        tx-lpc DAC mux 0x418/0x458=0x2 + 0x044=1 -> 0x110 rstCS pulse
#   4. deploy host_app_k5 sources, build with plain gcc on the board
#      (no aarch64 cross-compiler on the host), launch
#      `setsid nohup ./qpsk_tun -F -i tun0 -s 60`
#   5. tun0 addressing: TUN_ADDR peer PEER_ADDR, MTU 116 (= 128 B K5 unit
#      - 12 B qpsk_frame header), advmss 56, rto_min 25ms
#
# ============================================================================
# HARDWARE-UNTESTED: this script has NOT been run against the boards.
# Verified locally: host_app_k5 compiles clean (gcc -Wall -Wextra -Werror)
# and its unit tests pass; the ssh/scp wrapper pattern and the radio/arm
# sysfs recipes are copied from the proven gonogo.sh. Untested pieces are
# the K5 register offsets against a live K5 image (0x158), the on-board
# gcc build, the daemon launch, and the tun addressing block.
# ============================================================================
set -u
IP=${1:?usage: byte_link_up.sh BOARD_IP TX_CARRIER RX_CARRIER TRIM [TUN_ADDR] [PEER_ADDR]}
TXC=${2:?TX_CARRIER (Hz)}
RXC=${3:?RX_CARRIER (Hz)}
TRIM=${4:?TRIM (Hz, Tx-side CFO pre-compensation; 0 for none)}
TUN_ADDR=${5:-10.66.0.1}
PEER_ADDR=${6:-10.66.0.2}
TXLO=$((TXC+TRIM))
MTU=116                       # QPSK_FRAME_MAX_PAYLOAD(128)
ADVMSS=$((MTU-60))            # keep TCP segments inside one K5 frame

D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=$D/../host_app_k5
# askpass scp pattern EXACTLY as gonogo.sh (push variant of its scpget)
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

fail(){ echo "[byte_link_up] FAIL: $*"; exit 1; }

echo "[byte_link_up] $IP: Tx@$TXLO (carrier $TXC + trim $TRIM) Rx@$RXC tun0 $TUN_ADDR peer $PEER_ADDR"
[ -f "$SRC/qpsk_tun.c" ] || fail "missing $SRC/qpsk_tun.c (build tree)"
$W $IP 'echo BOARD_UP' 2>/dev/null | grep -q BOARD_UP || \
  fail "ssh to $IP failed (check board power + anyssh.sh askpass path)"

# --- 1. radio setup: profile + ch2 kill + LNAs + tx_a (gonogo setup_board) ---
$W $IP 'P=/sys/bus/iio/devices/iio:device2; D=/sys/kernel/debug/iio/iio:device2
 cat /root/lvds_1p92_mhz.bin > $P/stream_config 2>/dev/null
 cat /root/lvds_1p92_mhz.json > $P/profile_config 2>/dev/null; sleep 1
 echo calibrated > $P/out_voltage1_ensm_mode; echo calibrated > $P/in_voltage1_ensm_mode
 for g in 4 5 6 7; do echo 1 > $D/agpio${g}_direction; echo 1 > $D/agpio${g}_value; done
 echo tx_a > $P/out_voltage0_port_select' 2>/dev/null
echo "[byte_link_up] radio setup done (profile + ch2 kill + LNAs + tx_a)"

# --- 2. LOs (trimmed) + ensm rf_enabled + gains ---
$W $IP "P=/sys/bus/iio/devices/iio:device2
 echo $TXLO > \$P/out_altvoltage2_TX1_LO_frequency
 echo 0 > \$P/out_voltage0_hardwaregain
 echo rf_enabled > \$P/out_voltage0_ensm_mode
 echo $RXC > \$P/out_altvoltage0_RX1_LO_frequency
 echo rf_enabled > \$P/in_voltage0_ensm_mode
 echo automatic > \$P/in_voltage0_gain_control_mode" 2>/dev/null
R=$($W $IP 'P=/sys/bus/iio/devices/iio:device2; echo $(cat $P/out_altvoltage2_TX1_LO_frequency) $(cat $P/out_altvoltage0_RX1_LO_frequency) $(cat $P/in_voltage0_sampling_frequency)' 2>/dev/null)
echo "[byte_link_up] LO/fs readback: $R (want: $TXLO $RXC 1920000)"
echo "$R" | grep -q "^$TXLO $RXC 1920000" || fail "LO/fs readback mismatch"

# --- 3. canonical K5 byte arm via mwipcore direct_reg_access -------------
# mwipcore + tx-lpc found BY NAME (device indices shift across images).
# HARDWARE-UNTESTED against a live K5 image.
ARM=$($W $IP 'MW=$(for d in /sys/bus/iio/devices/iio:device*; do case "$(cat $d/name 2>/dev/null)" in mwipcore*) echo ${d##*/};; esac; done | head -1)
 [ -n "$MW" ] || { echo NO_MWIPCORE; exit 1; }
 echo enabled > /sys/bus/iio/devices/$MW/reg_access
 DRA=/sys/kernel/debug/iio/$MW/direct_reg_access
 echo "0x000 0x1" > $DRA; sleep 0.5; echo "0x000 0x0" > $DRA   # soft reset pulse
 echo "0x158 0x1" > $DRA   # tx_data_source = DMA bytes (K5 offset; NOT 0x11C)
 echo "0x118 0x0" > $DRA   # tx_source_select = in-FPGA Tx -> DAC
 echo "0x114 0x1" > $DRA   # rx_input_select = ADC (air)
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
 [ -n "$TXD" ] || { echo NO_TXLPC; exit 1; }
 T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2" > $T; echo "0x458 0x2" > $T; echo "0x044 0x1" > $T
 echo "0x110 0x1" > $DRA; sleep 0.3; echo "0x110 0x0" > $DRA   # rstCS pulse
 echo ARM_OK $MW $TXD' 2>/dev/null)
echo "[byte_link_up] byte arm: $ARM"
echo "$ARM" | grep -q ARM_OK || fail "byte arm failed ($ARM)"

# --- 4. deploy + on-board build + launch the daemon ----------------------
# No aarch64 cross-compiler on the host: ship sources, build with the
# board's plain gcc (HARDWARE-UNTESTED).
$W $IP 'mkdir -p /root/host_app_k5' 2>/dev/null
scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" \
       "$SRC/qpsk_hw.h" "$SRC/Makefile" root@$IP:/root/host_app_k5/ \
  || fail "scp of host_app_k5 sources failed"
$W $IP 'cd /root/host_app_k5 && gcc -O2 -Wall -o qpsk_tun qpsk_tun.c qpsk_frame.c && echo BUILD_OK' 2>/dev/null | grep -q BUILD_OK \
  || fail "on-board gcc build failed"
$W $IP 'pkill -x qpsk_tun 2>/dev/null; sleep 0.5
 cd /root/host_app_k5 && setsid nohup ./qpsk_tun -F -i tun0 -s 60 > /dev/shm/qpsk_tun.log 2>&1 &
 sleep 1; echo LAUNCHED' 2>/dev/null | grep -q LAUNCHED || fail "daemon launch failed"
TUN_OK=""
for i in $(seq 20); do
  $W $IP 'ip link show tun0 >/dev/null 2>&1 && echo TUN_OK' 2>/dev/null | grep -q TUN_OK && { TUN_OK=1; break; }
  sleep 1
done
[ -n "$TUN_OK" ] || fail "tun0 never appeared (see /dev/shm/qpsk_tun.log on the board)"
echo "[byte_link_up] daemon up, tun0 present (log: /dev/shm/qpsk_tun.log)"

# --- 5. tun0 addressing (single-interface two-radio topology) -------------
# rto_min 25ms: link RTT is a few frame periods; the default 200 ms RTO
# turns every residual loss into a long stall. advmss keeps TCP segments
# inside one 128 B K5 frame. HARDWARE-UNTESTED.
$W $IP "ip addr replace $TUN_ADDR peer $PEER_ADDR dev tun0
 ip link set tun0 up mtu $MTU
 ip route replace $PEER_ADDR dev tun0 advmss $ADVMSS rto_min 25ms" 2>/dev/null
NET=$($W $IP "ip -o addr show tun0 2>/dev/null; ip route show $PEER_ADDR 2>/dev/null" 2>/dev/null)
echo "[byte_link_up] tun0 net state:"
echo "$NET"
echo "$NET" | grep -q "$TUN_ADDR" || fail "tun0 address not applied"

# --- watchdog -------------------------------------------------------------
# TODO(K.3 follow-up): on-board watchdog loop -- every ~10 s check that
# (a) the qpsk_tun process is alive and (b) dma_tx in /dev/shm/qpsk_tun.log
# is still advancing (the -F keepalive guarantees ~212 frames/s even with
# an idle tun); on failure re-run the byte arm (section 3) and relaunch the
# daemon. Left out until the arm sequence is hardware-verified.

echo "[byte_link_up] $IP DONE -- verify with: ping -c3 $PEER_ADDR (from the peer board's shell)"
