#!/bin/bash
# =============================================================================
# phaseB_tone.sh -- TONE demonstration (run only after Phase A validates tap).
# 146 emits a pure CW complex tone via the hardware DDS (no host waveform, no
# modem framing). 148 receives OTA and we capture the modem-consumed AGC-out
# tap (0x10C mode 0). A pure tone has linear phase; a +256-sample block repeat
# shows as a periodic phase discontinuity every ~1.5s. BBDC on/off A/B nails it
# to the calibration. Independent LOs (146 TX vs 148 RX) supply the time-varying
# offset the refined hypothesis needs; if the CW tone is too static to tick,
# TONEHZ can be swept / AM applied (see FALLBACK below).
# =============================================================================
set -u
TJ=/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
W=$TJ/anyssh.sh
A_IP=10.0.0.148; B_IP=10.0.0.146
FWD=2000000000; REV=1900000000
TONEHZ=${TONEHZ:-300000}          # tone offset from LO (within 1.92 MHz band)
SCALE=${SCALE:-0.25}
DUR=${DUR:-12}; FS=1920000; NS=$(( DUR*FS ))
OUT=${OUT:-/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/99c1d537-a8f8-481c-b665-21aeee224f33/scratchpad/phaseB_$(date +%Y%m%d_%H%M%S)}
mkdir -p "$OUT"
scpget(){ SSH_ASKPASS=$TJ/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

# --- 146: arm TX as a pure DDS tone (NOT DMA source) ------------------------
tone_tx(){
  $W $B_IP "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
   for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
   echo $FWD > \$P/out_altvoltage2_TX1_LO_frequency; echo tx_a > \$P/out_voltage0_port_select
   echo rf_enabled > \$P/out_voltage0_ensm_mode; echo 0 > \$P/out_voltage0_hardwaregain   # gain AFTER rf_enabled (transition resets to -40 default)
   TXP=/sys/bus/iio/devices/iio:device5
   # single complex tone on F1 (I=cos @90deg, Q=sin @0deg); raw=1 enables the DDS tone
   echo $TONEHZ > \$TXP/out_altvoltage0_TX1_I_F1_frequency; echo 90000 > \$TXP/out_altvoltage0_TX1_I_F1_phase; echo $SCALE > \$TXP/out_altvoltage0_TX1_I_F1_scale; echo 1 > \$TXP/out_altvoltage0_TX1_I_F1_raw
   echo $TONEHZ > \$TXP/out_altvoltage2_TX1_Q_F1_frequency; echo 0     > \$TXP/out_altvoltage2_TX1_Q_F1_phase; echo $SCALE > \$TXP/out_altvoltage2_TX1_Q_F1_scale; echo 1 > \$TXP/out_altvoltage2_TX1_Q_F1_raw
   # force DAC channel source = DDS (0), not DMA (2)
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x0'>\$T; echo '0x458 0x0'>\$T; echo '0x044 0x1'>\$T
   echo '146 tone tx: '\$TONEHZ' Hz @ '$FWD' LO, scale '$SCALE" 2>/dev/null
}

# --- 148: arm RX only, pin a fixed gain (no lock needed for a tone) ----------
rx_arm(){
  $W $A_IP "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/in_voltage1_ensm_mode
   echo $FWD > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode
   echo automatic > \$P/in_voltage0_gain_control_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x10C 0x0' > \$DRA
   echo '148 rx armed @'$FWD" 2>/dev/null
}

cap(){ # $1 label $2 bbdc
  local lbl=$1 bb=$2
  $W $A_IP "echo $bb > /sys/bus/iio/devices/iio:device2/in_voltage0_bbdc_rejection_tracking_en" 2>/dev/null; sleep 2
  echo "--- tone capture $lbl (bbdc_track=$bb) ---"
  $W $A_IP "rm -f /dev/shm/$lbl.bin
    iio_readdev -u local: -b 65536 -s $NS axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /dev/shm/$lbl.bin 2>/dev/shm/e.txt || cat /dev/shm/e.txt
    ls -l /dev/shm/$lbl.bin" 2>/dev/null
  scpget root@$A_IP:/dev/shm/$lbl.bin "$OUT/$lbl.bin" || echo "WARN pull $lbl"
  $W $A_IP "rm -f /dev/shm/$lbl.bin" 2>/dev/null
}

echo "=== PHASE B tone $(date -Is) tone=$TONEHZ -> $OUT ==="
for ip in $B_IP $A_IP; do $W $ip 'pkill -x qpsk_tun 2>/dev/null; pkill -x iio_readdev 2>/dev/null; pkill -9 -f "[l]ock_watchdog" 2>/dev/null; sleep 0.3' 2>/dev/null; done
tone_tx
rx_arm
sleep 2
# pin RX gain at the tone operating point
G=$($W $A_IP 'cat /sys/bus/iio/devices/iio:device2/in_voltage0_hardwaregain' 2>/dev/null); GV=$(echo "$G"|grep -oE '^[0-9.]+')
$W $A_IP "echo spi > /sys/bus/iio/devices/iio:device2/in_voltage0_gain_control_mode; echo $GV > /sys/bus/iio/devices/iio:device2/in_voltage0_hardwaregain" 2>/dev/null
echo "  148 rx gain pinned $GV dB"
cap tone_bbdcON  1
cap tone_bbdcOFF 0
$W $A_IP "echo 1 > /sys/bus/iio/devices/iio:device2/in_voltage0_bbdc_rejection_tracking_en" 2>/dev/null
# stop the tone
$W $B_IP 'TXP=/sys/bus/iio/devices/iio:device5; for c in 0 1 2 3; do echo 0 > $TXP/out_altvoltage${c}_*_scale 2>/dev/null; done; echo calibrated > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null
echo "PHASE_B_DONE $OUT"
# FALLBACK if no tick on static tone: emulate a drifting offset by stepping
#   TONEHZ or the TX LO a few Hz/s, or apply slow AM via scale, to give the
#   BBDC a time-varying RX DC to chase.
