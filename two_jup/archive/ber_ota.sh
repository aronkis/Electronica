#!/bin/bash
# ber_ota.sh -- Tier-C: point the validated full-packet BER scorer at the live
# FDD OTA link. Arms BOTH boards for air, runs qpsk_tun -B on both SIMULTANEOUSLY
# (each radiates the fixed reference frame -> feeds the peer's acquisition AND
# scores what it receives), then reports per-direction full-packet BER + the
# error-structure buckets, correlated with the modem status regs.
#
# Each board measures the link INTO it:
#   148 -B  =  146 TX@2.00 -> 148 RX@2.00   (the stable side)
#   146 -B  =  148 TX@2.10 -> 146 RX@2.10   (the weak/cycling side)
#
# No watchdog: this also exercises the Tier-2 AGC image's autonomous acquisition
# (both armed, both TX continuously -> both should self-lock). Acquisition frames
# show up as MISS/PHASE early in the per-5s trace; steady CLEAN/NOISY once locked.
# Usage: ber_ota.sh   (env: DUR, TXA, FA, TXB, FB)
set -u
DUR=${DUR:-60}
SEED=${SEED:-}           # QBER_SEED for the reference (empty = built-in default);
                         # MUST be identical on both ends. Vary to test the OTA
                         # error map's pattern- vs position-dependence.
ZERO=${ZERO:-}           # QBER_ZERO=1 -> pathological all-zero payload (low entropy)
WHITEN=${WHITEN:-}       # QPSK_WHITEN=1 -> apply the frame-sync whitener
TXA=${TXA:-2000005489}   # 146 TX (-> 148 RX@2.00)
FB=${FB:-2100000000}     # 146 RX@2.10
TXB=${TXB:-2099994268}   # 148 TX (-> 146 RX@2.10)
FA=${FA:-2000000000}     # 148 RX@2.00
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=$(cd "$(dirname "$0")/.." && pwd)/host_app_k5
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

echo "=== Tier-C OTA BER: 146 TX@2.00->148 RX@2.00 ; 148 TX@2.10->146 RX@2.10 (dur=${DUR}s) ==="

# 1. quiesce both (separate call; '[l]ock_watchdog' regex avoids self-kill)
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4; echo "'$ip' quiesced"' 2>/dev/null
done

# 2. deploy + build updated host tool (incl qpsk_ber) on both
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'mkdir -p /root/host_app_k5' 2>/dev/null
  scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" \
         "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" root@$ip:/root/host_app_k5/ || { echo "scp $ip FAIL"; exit 1; }
  R=$($W $ip 'cd /root/host_app_k5 && gcc -O2 -Wall -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c 2>/tmp/gcc.err && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }' 2>/dev/null)
  echo "  $ip build: $(echo "$R" | tail -1)"; echo "$R" | grep -q BUILD_OK || exit 1
done

# 3. FDD air arm on both (LOs + trims + 0x114=1 air; byte_ctrl_gpio=1 for -B RX)
arm(){ # $1 ip $2 txlo $3 rxlo
  $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
   for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
   echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
   echo $3 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
   busybox devmem 0x9D300000 32 0x1
   echo '$1 armed air tx=$2 rx=$3'" 2>/dev/null
}
arm 10.0.0.146 $TXA $FB &
arm 10.0.0.148 $TXB $FA &
wait

# 4. snapshot modem status regs PRE
snap(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA;cat $DRA; }
   p=$(rd 0x104);r=$(rd 0x150);c=$(rd 0x154);f=$(rd 0x15C); echo "pkts=$p rstcs=$r cfc=$c fx=$f"' 2>/dev/null; }
P146=$(snap 10.0.0.146); P148=$(snap 10.0.0.148)
echo "  PRE  146: $P146"; echo "  PRE  148: $P148"

# 5. launch watchdog (re-arms out of the armed-before-signal wedge -> lock) +
#    -B (radiates the ref frame AND scores) on both. Watchdog owns the modem
#    regfile (debugfs); -B owns the byte DMAs (/dev/mem) -> disjoint, no
#    contention. Once locked the watchdog goes quiet; acquisition/cycling frames
#    fall in MISS/PHASE/ROTATED and are EXCLUDED from the BER (only ALIGNED
#    frames count), so the reported BER is the true post-lock rate.
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
  $W $ip "cd /root/host_app_k5; rm -f /dev/shm/ber_ota.log; setsid sh -c 'QBER_SEED=$SEED QBER_ZERO=$ZERO QPSK_WHITEN=$WHITEN ./qpsk_tun -B -d $DUR > /dev/shm/ber_ota.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
done
echo "  watchdog + -B running on both for ${DUR}s (seed=${SEED:-default} zero=${ZERO:-0} whiten=${WHITEN:-0}) ..."
sleep $((DUR + 8))

# 6. stop watchdogs, snapshot POST + fetch reports
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; echo "'$ip' wd stopped"' 2>/dev/null
done
Q146=$(snap 10.0.0.146); Q148=$(snap 10.0.0.148)
echo "  POST 146: $Q146"; echo "  POST 148: $Q148"
for ip in 10.0.0.146 10.0.0.148; do
  echo "----- $ip  (link INTO this board) -----"
  $W $ip 'echo "  [wd] $(tail -1 /dev/shm/watchdog.log 2>/dev/null)"; cat /dev/shm/ber_ota.log 2>/dev/null' 2>/dev/null \
    | grep -E 'ber:|===|frames_scored|buckets|per-offset|burst|len|\[|wd' | tail -48
done
echo "=== OTA run complete ==="
