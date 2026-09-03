#!/bin/bash
# =============================================================================
# arm_telemetry.sh <r2|r3> <n_arms> [outdir] -- instrumented-arm campaign to
# root-cause the degraded-arm lottery (task ARMCAUSE).
#
# Per arm cycle:
#   * odd cycles  = FULL arm  (profile reload -> fresh SSI tuner pick + init
#                   cals + LO retune; the real-world cold-arm path)
#   * even cycles = REARM only (modem 0x000/0x110 re-arm, radio untouched)
#     -> discriminates transceiver-stage causes (cal/tuner/PLL) from
#        modem/acquisition-stage causes (CFC dead zone, CS lottery, grid).
#   1. one-time snapshot per board: pll_status, LIVE ssi_delays (tuner picks +
#      overrides), ensm modes, cals_internal_path_delay_ns, temps, rssi/gain
#   2. 12 s ROM window @1 Hz on-board sampling: pkts 0x104, biterr 0x108,
#      rstcs 0x150, cfc 0x154, level 0x15C, deint counters 0x120/0x124/0x12C,
#      rssi, hwgain  (single ssh per board, both boards in parallel)
#   3. PRBS15 spot-check at the OPERATING delay point, tx0 (chip checker) and
#      rx0 (rx-lpc pseudorandom_err_check, double-read) -- NO delay writes at
#      all, test-mode toggles only => the STOCKSSI write-cache trap cannot
#      trigger. Link is disturbed during the check; a re-arm follows anyway.
#   4. byte phase: stream-first daemon start (R2FINISH ordering), byte re-arm,
#      stats at +5 s and +20 s (crc%, rx f/s, dma_tx exactness), daemons killed
# Ends with full quiesce of both boards. All output tagged in armtel.log for
# arm_telemetry_classify.py.
#
# RAILS: no dd on /dev/mem (devmem/DRA only -- this script uses DRA + sysfs
# exclusively); 0x114 re-asserted after every reset; detached-run friendly
# (writes DONE_MARKER at end).
# Env: WHITEN=0, ROMSECS=12, BYTESECS=20
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146; TA=10.66.0.2; TB=10.66.0.1
RUNG=${1:?usage: arm_telemetry.sh r2|r3 n_arms [outdir]}
N=${2:?n_arms}
case "$RUNG" in
  r2) PROF=lvds_30p72_fdd_jupiter; KSYM=7680;  FPS=623;  SSI148="";    ;;
  r3) PROF=lvds_61p44_fdd_jupiter; KSYM=15360; FPS=1245; SSI148="5 3"; ;;
  *) echo "unknown rung '$RUNG'" >&2; exit 2;;
esac
OUT=${3:-/tmp/armtel_${RUNG}_$(date +%m%d_%H%M)}
mkdir -p "$OUT"; LOG=$OUT/armtel.log
ROMSECS=${ROMSECS:-12}; BYTESECS=${BYTESECS:-20}; WHITEN=${WHITEN:-0}
# CFO policy (TXCHAR2 / bringup_r2r3.sh): offsets, never the null at R2/R3.
# LO_B_RX overridable for the ARMCAUSE dead-zone A/B (e.g. 1899994861 = +10 kHz)
LO_B_TX=2000000000; LO_B_RX=${LO_B_RX:-1900002500}
LO_A_TX=1900000000; LO_A_RX=${LO_A_RX:-2000000000}
say(){ echo "@@ $*" >> "$LOG"; }

# ---------- arm/rearm (verbatim from bringup_r2r3.sh) ------------------------
arm_rom(){ # $1 ip $2 txlo $3 rxlo
  $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 pkill -x qpsk_tun 2>/dev/null; sleep 0.5
 cat /root/$PROF.bin > \$P/stream_config 2>/dev/null; cat /root/$PROF.json > \$P/profile_config 2>/dev/null; sleep 2
 echo calibrated > \$P/out_voltage1_ensm_mode 2>/dev/null; echo calibrated > \$P/in_voltage1_ensm_mode 2>/dev/null
 for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
 echo $2 > \$P/out_altvoltage2_TX1_LO_frequency 2>&1; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
 echo calibrated > \$P/in_voltage0_ensm_mode 2>/dev/null; echo $3 > \$P/out_altvoltage0_RX1_LO_frequency 2>&1
 echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x0'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
 TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
 echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
 echo '$1 armed ROM ($PROF)'" 2>/dev/null
}
rearm_rom(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }
# CS-reset-only recovery probe (candidate C5 discriminator): 0x110 pulse alone
csreset_only(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }

# ---------- telemetry --------------------------------------------------------
onetime(){ # $1 ip $2 tag -> tagged static snapshot
  $W $1 'P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 echo "pll: $(cat $DB/pll_status 2>/dev/null | tr "\n" ";")"
 echo "ssi: $(cat $DB/ssi_delays 2>/dev/null | tr "\n" ";")"
 echo "ensm: tx0=$(cat $P/out_voltage0_ensm_mode) rx0=$(cat $P/in_voltage0_ensm_mode)"
 echo "caldelay: tx0=$(cat $DB/tx0_cals_internal_path_delay_ns 2>/dev/null) rx0=$(cat $DB/rx0_cals_internal_path_delay_ns 2>/dev/null)"
 echo "temp: phy=$(cat $P/in_temp0_input 2>/dev/null) ams=$(cat /sys/bus/iio/devices/iio:device1/in_temp0_ps_temp_raw 2>/dev/null)$(cat /sys/bus/iio/devices/iio:device1/in_temp7_raw 2>/dev/null)"
 echo "gain: hw=$(cat $P/in_voltage0_hardwaregain) rssi=$(cat $P/in_voltage0_rssi) txatten=$(cat $P/out_voltage0_hardwaregain)"' 2>/dev/null \
  | sed "s/^/@@ $2 /" >> "$LOG"
}
window(){ # $1 ip $2 tag $3 secs -> 1 Hz samples, single ssh, on-board loop
  $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 P=/sys/bus/iio/devices/iio:device2
 rd(){ echo "$1">$DRA; cat $DRA; }
 for s in $(seq 0 '"$3"'); do
  echo "s=$s t=$(date +%s.%N) pkts=$(rd 0x104) biterr=$(rd 0x108) rstcs=$(rd 0x150) cfc=$(rd 0x154) lvl=$(rd 0x15C) c120=$(rd 0x120) c124=$(rd 0x124) c12C=$(rd 0x12C) rssi=$(cat $P/in_voltage0_rssi 2>/dev/null|cut -d" " -f1) hwg=$(cat $P/in_voltage0_hardwaregain 2>/dev/null|cut -d" " -f1)"
  sleep 1
 done' 2>/dev/null | sed "s/^/@@ $2 /" >> "$LOG"
}
prbs_spot(){ # $1 ip $2 tag : PRBS15 at OPERATING delays; test-mode toggles only
  $W $1 'DB=/sys/kernel/debug/iio/iio:device2
 RXLPC=""; for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-rx-lpc ] && RXLPC=$d; done
 R=/sys/kernel/debug/iio/$(basename $RXLPC)
 # tx0: FPGA->chip PRBS, chip-side checker
 echo TESTMODE_DATA_PRBS15 > $DB/tx0_ssi_test_mode_data
 echo 1 > $DB/tx0_ssi_test_mode_configure 2>/dev/null; sleep 0.1
 echo 1 > $DB/tx0_ssi_test_mode_configure 2>/dev/null; sleep 2.5
 echo "tx0_prbs: $(cat $DB/tx0_ssi_test_mode_status 2>/dev/null | tr "\n" ";")"
 echo TESTMODE_DATA_NORMAL > $DB/tx0_ssi_test_mode_data
 echo 1 > $DB/tx0_ssi_test_mode_configure 2>/dev/null
 # rx0: chip->FPGA PRBS, FPGA-side checker (1st read clears, 2nd scores)
 echo TESTMODE_DATA_PRBS15 > $DB/rx0_ssi_test_mode_data
 echo 1 > $DB/rx0_ssi_test_mode_configure 2>/dev/null; sleep 0.2
 cat $R/pseudorandom_err_check > /dev/null 2>&1; sleep 2.5
 echo "rx0_prbs: $(cat $R/pseudorandom_err_check 2>/dev/null | tr "\n" ";")"
 echo TESTMODE_DATA_NORMAL > $DB/rx0_ssi_test_mode_data
 echo 1 > $DB/rx0_ssi_test_mode_configure 2>/dev/null' 2>/dev/null \
  | sed "s/^/@@ $2 /" >> "$LOG"
}
# ---------- byte phase (stream-first ordering, R2FINISH) ---------------------
start_daemon(){ # $1 ip $2 tunaddr $3 peer
  $W $1 "cd /root/host_app_k5; QPSK_WHITEN=$WHITEN setsid chrt -f 50 ./qpsk_tun -G -M 32 -r $KSYM -i tun0 -s 5 </dev/null >/dev/shm/qpsk_tun.log 2>&1 &
 n=0; while [ \$n -lt 15 ]; do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; n=\$((n+1)); done
 ip addr replace $2 peer $3 dev tun0; ip link set tun0 up mtu 1516; echo daemon-up" 2>/dev/null
}
rearm_byte(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }
bytestats(){ # $1 ip $2 tag
  $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 rd(){ echo "$1">$DRA; cat $DRA; }
 echo "t=$(date +%s.%N) rstcs=$(rd 0x150) pkts=$(rd 0x104) cfc=$(rd 0x154) $(grep "qpsk_tun stats" /dev/shm/qpsk_tun.log | tail -1)"' 2>/dev/null \
  | sed "s/^/@@ $2 /" >> "$LOG"
}
kill_daemons(){ $W $1 'pkill -x qpsk_tun 2>/dev/null; sleep 0.5; ip link del tun0 2>/dev/null; echo killed' 2>/dev/null; }

quiesce(){ # $1 ip
  $W $1 'pkill -x qpsk_tun 2>/dev/null; pkill -x iio_readdev 2>/dev/null; ip link del tun0 2>/dev/null
 P=/sys/bus/iio/devices/iio:device2; echo 0 > $P/out_voltage0_hardwaregain
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.3; echo "0x000 0x0">$DRA; echo "0x114 0x0">$DRA
 echo "quiesced: qpsk=$(pgrep -c -x qpsk_tun || echo 0)"' 2>/dev/null | sed "s/^/@@ QUIESCE $1 /" >> "$LOG"
}
trap 'quiesce $B; quiesce $A; say "DONE_MARKER (trap)"' EXIT INT TERM

say "ARMCAUSE telemetry start rung=$RUNG prof=$PROF n=$N romsecs=$ROMSECS bytesecs=$BYTESECS $(date -Is)"
# ARMCAUSE causality knobs:
#   ALLREARM=1    -> arm 1 FULL (profile), all others REARM-only
#   REARM_MODE    -> BA (default, B first) | AB (A first) | DOUBLE (both, wait,
#                    both again -- second pulse lands with both peers clean ROM)
do_rearms(){
  case "${REARM_MODE:-BA}" in
    AB)     rearm_rom $A; rearm_rom $B;;
    DOUBLE) rearm_rom $B; rearm_rom $A; sleep 3; rearm_rom $B; rearm_rom $A;;
    *)      rearm_rom $B; rearm_rom $A;;
  esac
}
for i in $(seq 1 $N); do
  if [ "${ALLREARM:-0}" = 1 ]; then
    TYPE=REARM; [ $i = 1 ] && TYPE=FULL
  else
    if [ $(( i % 2 )) = 1 ]; then TYPE=FULL; else TYPE=REARM; fi
  fi
  say "ARM $i TYPE=$TYPE REARM_MODE=${REARM_MODE:-BA} t=$(date -Is)"
  if [ $TYPE = FULL ]; then
    arm_rom $B $LO_B_TX $LO_B_RX >> "$LOG" 2>&1 &
    arm_rom $A $LO_A_TX $LO_A_RX >> "$LOG" 2>&1 &
    wait
    S146="$($D/apply_146_ssi_fix.sh $B 3 4 2>&1 | tail -1)"; say "ARM $i ssi146: $S146"
    if [ -n "$SSI148" ]; then
      set -- $SSI148
      S148="$(FORCE=1 $D/apply_146_ssi_fix.sh $A $1 $2 2>&1 | tail -1)"; say "ARM $i ssi148: $S148"
    fi
    rearm_rom $B; rearm_rom $A
  else
    do_rearms
  fi
  onetime $B "SNAP $i B"; onetime $A "SNAP $i A"
  window $B "WIN $i B" $ROMSECS & WB=$!
  window $A "WIN $i A" $ROMSECS & WA=$!
  wait $WB $WA
  # C5 probe: if either side is well below rate on ROM, try a CS-reset-only
  # recovery + 6 s re-window (0x110 alone fixing it = acquisition-lottery C5)
  romdelta(){ # $1 tag -> decimal pkts delta first..last sample (hex-safe)
    local vals f l
    vals=$(grep "@@ $1 " "$LOG" | grep -o 'pkts=0x[0-9A-Fa-f]*' | cut -d= -f2)
    f=$(echo "$vals" | head -1); l=$(echo "$vals" | tail -1)
    if [ -n "$f" ] && [ -n "$l" ]; then echo $(( l - f )); else echo 0; fi
  }
  DB_=$(romdelta "WIN $i B"); DA_=$(romdelta "WIN $i A")
  thresh=$(( FPS * ROMSECS * 60 / 100 ))   # <60% of rate over the window
  for side in "B $DB_ $B" "A $DA_ $A"; do
    set -- $side
    if [ "$2" -lt $thresh ]; then
      say "ARM $i CSPROBE $1 (rom pkts delta $2 < $thresh): 0x110-only pulse"
      csreset_only $3
      window $3 "CSWIN $i $1" 6
    fi
  done
  prbs_spot $B "PRBS $i B"; prbs_spot $A "PRBS $i A"
  # byte phase (stream-first)
  rearm_rom $B; rearm_rom $A
  start_daemon $B $TB $TA >> "$LOG" 2>&1
  start_daemon $A $TA $TB >> "$LOG" 2>&1
  sleep 4
  rearm_byte $B; rearm_byte $A
  sleep 5
  bytestats $B "BYTE0 $i B"; bytestats $A "BYTE0 $i A"
  sleep $BYTESECS
  bytestats $B "BYTE1 $i B"; bytestats $A "BYTE1 $i A"
  kill_daemons $B >/dev/null; kill_daemons $A >/dev/null
  say "ARM $i END t=$(date -Is)"
done
say "campaign complete $(date -Is)"
