#!/bin/bash
# =============================================================================
# loopback_soak.sh [ip] [secs] -- INTERNAL-LOOPBACK tick discriminator.
#
# Tests whether the board-148 device tick (256-sample BBDC insertion) occurs when
# the radio transmits to ITSELF via internal digital loopback (rx_input_select=0,
# ADC bypassed) -- while the RX stays rf_enabled so the BBDC cal still runs. If
# the tick is an ADC-delivery phenomenon, the fabric loopback stays CLEAN (no
# ~1.5 s bit-error episodes); if it were a fabric-domain event, episodes appear.
#
# ROM/BIST source (tx_data_source=0): decodes golden (cap_out 0x04922282) at the
# CFO=0 of internal loopback, avoiding the R2/R3 demod dead-zone that -B hits.
# Monitors 0x104 packets / 0x108 bit_errors / 0x144 cap_out / 0x150 rstcs /
# 0x154 cfc at 10 Hz on-board, then analyzes bit_errors deltas for periodicity.
#
#   loopback_soak.sh 10.0.0.148 120
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
IP=${1:-10.0.0.148}; SECS=${2:-120}
PROF=lvds_61p44_fdd_jupiter                 # Image B (R3) resident profile
OUT=$D/loopsoak/$(date +%Y%m%d_%H%M%S)_$(echo $IP | tr . _)
mkdir -p "$OUT"
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

echo "=== loopback_soak $IP: internal loopback (0x114=0), ROM BIST, ${SECS}s -> $OUT ==="

# 1. quiesce this board
$W $IP 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4; echo quiesced' 2>/dev/null

# 2. arm INTERNAL LOOPBACK ROM (RX rf_enabled so BBDC runs; 0x114=0 = loopback)
$W $IP "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 cat /root/$PROF.bin > \$P/stream_config 2>/dev/null; cat /root/$PROF.json > \$P/profile_config 2>/dev/null; sleep 2
 echo calibrated > \$P/out_voltage1_ensm_mode 2>/dev/null; echo calibrated > \$P/in_voltage1_ensm_mode 2>/dev/null
 for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
 echo 2000000000 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
 echo 2000000000 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA
 echo '0x158 0x0'>\$DRA        # tx_data_source = ROM/BIST
 echo '0x118 0x0'>\$DRA
 echo '0x114 0x0'>\$DRA        # rx_input_select = 0 -> INTERNAL LOOPBACK (ADC bypassed)
 echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
 sleep 1
 rd(){ echo \"\$1\">\$DRA;cat \$DRA; }
 echo \"armed loopback: rxsel=\$(rd 0x114) txsrc=\$(rd 0x158) cap=\$(rd 0x144) pkts=\$(rd 0x104) biterr=\$(rd 0x108)\"" 2>/dev/null | tee "$OUT/arm.txt"

# 3. on-board 10 Hz monitor for SECS (fabric-regfile reads, not SPI RSSI -> no poller artifact)
N=$(( SECS * 10 ))
$W $IP "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; rd(){ echo \"\$1\">\$DRA;cat \$DRA; }
 : > /dev/shm/loop_soak.log
 for i in \$(seq $N); do
   echo \"t=\$(date +%s.%N) pkts=\$(rd 0x104) biterr=\$(rd 0x108) cap=\$(rd 0x144) rstcs=\$(rd 0x150) cfc=\$(rd 0x154)\" >> /dev/shm/loop_soak.log
   sleep 0.1
 done
 echo SOAK_DONE" 2>/dev/null
scpput root@$IP:/dev/shm/loop_soak.log "$OUT/loop_soak.log" || echo "WARN: soak log fetch failed"

# 4. quiesce
$W $IP 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access
 echo "0x114 0x0">$DRA; busybox devmem 0x9D000000 32 0 2>/dev/null; echo quiesced' 2>/dev/null

# 5. analyze periodicity of bit_errors deltas
python3 "$D/loopsoak_analyze.py" "$OUT/loop_soak.log" | tee "$OUT/verdict.txt"
echo "LOOPBACK_SOAK_DONE $OUT"
