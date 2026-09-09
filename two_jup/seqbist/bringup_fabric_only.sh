#!/bin/bash
# =============================================================================
# bringup_fabric_only.sh -- stage 3 (task 8): bring BOTH boards up on the R3 air
# link with NO host daemon, NO watchdog and NO DMA anywhere, so a SEQ-BIST leg
# measures the fabric + RF chain only.
#
# DERIVED FROM bringup_r2r3.sh r3.  arm_rom(), rearm_rom() and probe() are carried
# VERBATIM (the pokes must not be paraphrased -- the radio wedges), together with:
#   * the R3 profile lvds_61p44_fdd_jupiter and -r 15360 geometry
#   * the CFO policy LOs: 148 Tx 1900000000 / Rx 2000020000 (+20k), 146 Tx
#     2000000000 / Rx 1900040000 (+40k) -- the shipped rig defaults
#   * the SSI delay overrides (146 tx0 "3 4", 148 tx0 "5 3")
#   * the ARMCAUSE double-tap and the ROM arm-quality gate with auto re-arm
#
# WHAT IS DELIBERATELY REMOVED (this is the whole point of the script):
#   * start_daemon()  -- no qpsk_tun, so no DMA, no host, no tun0 on either board
#   * the watchdog block -- WATCHDOG is forced to 0 and never launched
#   * rearm_byte()    -- the boards are LEFT ARMED ROM (0x158=0, 0x114=1).
#
# WHY THE BYTE FLIP IS *NOT* DONE HERE (R2FINISH, bringup_r2r3.sh:~170).  Flipping
# the TX source to the byte plane while the byte FIFO is underrunning starts the
# modulator on a discontinuous stream, which is demod-hostile ON AIR (measured
# 0 %/0 % -> 551/602 f/s purely from fixing the order; loopback does not care).
# With no daemon the only thing that can keep the byte FIFO fed is the fabric TGEN,
# so the correct order for a fabric-only RF leg is: arm ROM -> pass the ROM gate ->
# TGEN ON -> let it pump -> THEN 0x158=1 (double-tapped).  The last two steps belong
# to the leg runner (stage3_leg_go.sh), not here.  Task 7's stage-2 gate did it the
# other way round (arm148_rf_self.sh:215 flips 0x158 before TGEN is on) and every
# byte-plane stream it tried was received at ~half rate.
#
# Usage: DRY=0 bringup_fabric_only.sh        (K=V env, launch_rig_unit.sh convention)
# Env: GATE_FPS (default 1120), GATE_TRIES (default 6), SSI146="3 4", SSI148="5 3"
#      (either may be "skip"), LO_A_RX/LO_B_RX overrides, DRY (default 1).
# Exit 0 = both boards armed ROM and both RX sides decoding >= GATE_FPS.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")/.." && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
PROF=lvds_61p44_fdd_jupiter
GATE_FPS=${GATE_FPS:-1120}
GATE_TRIES=${GATE_TRIES:-6}
DRY=${DRY:-1}
LO_B_TX=2000000000; LO_B_RX=${LO_B_RX:-1900040000}
LO_A_TX=1900000000; LO_A_RX=${LO_A_RX:-2000020000}
SSI146=${SSI146:-3 4}
SSI148=${SSI148:-5 3}
echo "=== bringup_fabric_only: $PROF, gate >= $GATE_FPS f/s, NO daemons, NO watchdog, DRY=$DRY ==="

arm_rom(){ # $1 ip $2 txlo $3 rxlo -- bringup_r2r3.sh:66-81 VERBATIM
  if [ "$DRY" = 1 ]; then echo "[dry] arm_rom $1 txlo=$2 rxlo=$3 profile=$PROF"; return 0; fi
  $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 pkill -x qpsk_tun 2>/dev/null
 pkill -f \"[l]ock_watchdog\" 2>/dev/null; pkill -f \"[s]tallpoll\" 2>/dev/null; sleep 1
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
rearm_rom(){ # bringup_r2r3.sh:83-86 VERBATIM
  if [ "$DRY" = 1 ]; then echo "[dry] rearm_rom $1"; return 0; fi
  $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }
probe(){ # 0x104 pkts/s over 5 s -- bringup_r2r3.sh:88-90 VERBATIM
  if [ "$DRY" = 1 ]; then echo 1245; return 0; fi
  $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo 0x104 > $DRA; p0=$(cat $DRA); sleep 5; echo 0x104 > $DRA; p1=$(cat $DRA); echo $(( (p1 - p0) / 5 ))' 2>/dev/null; }

arm_rom $B $LO_B_TX $LO_B_RX &
arm_rom $A $LO_A_TX $LO_A_RX &
wait

# SSI overrides (safe cache protocol; the helper re-arms with 0x158=1, so ROM is
# re-asserted straight afterwards -- exactly as bringup_r2r3.sh does).
if [ "$SSI146" = skip ]; then echo "146 SSI: SKIPPED"
elif [ "$DRY" = 1 ]; then echo "[dry] apply_146_ssi_fix.sh $B $SSI146"
else set -- $SSI146; echo "146 SSI: $($D/apply_146_ssi_fix.sh $B $1 $2 2>&1 | tail -1)"; fi
if [ "$SSI148" = skip ]; then echo "148 SSI: SKIPPED"
elif [ "$DRY" = 1 ]; then echo "[dry] FORCE=1 apply_146_ssi_fix.sh $A $SSI148"
else set -- $SSI148; echo "148 SSI: $(FORCE=1 $D/apply_146_ssi_fix.sh $A $1 $2 2>&1 | tail -1)"; fi

# ARMCAUSE double-tap: first tap gives both TX streams clean ROM, second re-rolls
# both demods against clean peers.
rearm_rom $B; rearm_rom $A
[ "$DRY" = 1 ] || sleep 3
rearm_rom $B; rearm_rom $A

try=1; PASS=0; FA=0; FB=0
while [ $try -le $GATE_TRIES ]; do
  [ "$DRY" = 1 ] || sleep 4
  FA=$(probe $A); FB=$(probe $B)
  echo "gate try $try: 148 rx=${FA:-0} f/s  146 rx=${FB:-0} f/s (need >= $GATE_FPS both)"
  { [ "${FA:-0}" -ge "$GATE_FPS" ] && [ "${FB:-0}" -ge "$GATE_FPS" ]; } && { PASS=1; break; }
  rearm_rom $B; rearm_rom $A
  [ "$DRY" = 1 ] || sleep 3
  rearm_rom $B; rearm_rom $A
  try=$(( try + 1 ))
done
if [ $PASS != 1 ]; then
  echo "FABRIC_BRINGUP_GATE_FAIL 148=${FA:-0} 146=${FB:-0} after $GATE_TRIES tries -- boards left armed ROM, no daemons started"
  exit 1
fi
echo "FABRIC_BRINGUP_OK gate try $try: 148=${FA} f/s 146=${FB} f/s; both boards ARMED ROM (0x158=0, 0x114=1), no daemon, no watchdog, no DMA"
