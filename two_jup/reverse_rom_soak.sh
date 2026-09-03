#!/bin/bash
# =============================================================================
# reverse_rom_soak.sh [secs] -- REVERSE-link source discriminator.
#
# Runs the reverse link (148 TX -> 146 RX) in ROM/BIST mode (tx_data_source=0)
# and soaks 146's modem registers. ROM/BIST checks decoded bits IN FABRIC (the
# 0x108 bit_errors / 0x144 cap_out BIST), BYPASSING the byte plane, DMA and host
# CRC. So:
#   * reverse WEDGES in ROM (bit_errors bursts / cap_out drops golden)
#         -> the fault is PHY / modem / axi_adrv9001-interface (NOT DMA/byte-plane)
#         -> then 0x15C adc_forensic splits it:
#              maxGap/maxBurst glitch at errors -> axi_adrv9001 SSI delivery
#              adc clean + cfc(0x154) dither     -> modem carrier/timing loop
#   * reverse STAYS CLEAN in ROM over a long soak
#         -> the fault needs the byte/DMA/host path -> DMA / byte-plane.
#
#   reverse_rom_soak.sh 180
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146            # A=148 (reverse TX), B=146 (reverse RX = soak target)
PROF=lvds_61p44_fdd_jupiter
SECS=${1:-180}
LO_A_TX=1900000000; LO_A_RX=2000000000        # 148: Tx rev 1.9G
LO_B_TX=2000000000; LO_B_RX=${LO_B_RX:-1900002500}  # 146 Rx rev; override to test off-null (dead-zone)
OUT=$D/revrom/$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

arm_rom(){ # $1 ip $2 txlo $3 rxlo
  $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 pkill -x qpsk_tun 2>/dev/null; pkill -9 -f '[l]ock_watchdog' 2>/dev/null; sleep 0.5
 cat /root/$PROF.bin > \$P/stream_config 2>/dev/null; cat /root/$PROF.json > \$P/profile_config 2>/dev/null; sleep 2
 echo calibrated > \$P/out_voltage1_ensm_mode 2>/dev/null; echo calibrated > \$P/in_voltage1_ensm_mode 2>/dev/null
 for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
 echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
 echo calibrated > \$P/in_voltage0_ensm_mode 2>/dev/null; echo $3 > \$P/out_altvoltage0_RX1_LO_frequency
 echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x0'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
 TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
 echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
 echo '$1 armed ROM'" 2>/dev/null
}
rearm_rom(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }

echo "=== reverse_rom_soak: 148 TX ROM -> 146 RX, BIST soak ${SECS}s -> $OUT ==="
arm_rom $B $LO_B_TX $LO_B_RX & arm_rom $A $LO_A_TX $LO_A_RX & wait
echo "146: $($D/apply_146_ssi_fix.sh $B 3 4 2>&1 | tail -1)"
echo "148: $(FORCE=1 $D/apply_146_ssi_fix.sh $A 5 3 2>&1 | tail -1)"
rearm_rom $B; rearm_rom $A; sleep 3; rearm_rom $B; rearm_rom $A    # double-tap (ARMCAUSE)
# arm-quality GATE: require 146 cap_out GOLDEN (clean lock, not the CFO-dither
# false-lock), re-arm up to GMAX times. If it never locks golden, that IS the
# finding (146 RX cannot cleanly decode the reverse link even in ROM).
GTRY=1; GMAX=${GMAX:-8}; LOCKED=0
while [ $GTRY -le $GMAX ]; do
  sleep 2
  R=$($W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA;cat $DRA; }
   c=$(rd 0x144); p0=$(rd 0x104); sleep 3; p1=$(rd 0x104); echo "$c $((p1-p0))"' 2>/dev/null)
  cap=$(echo $R | cut -d" " -f1); dpk=$(echo $R | cut -d" " -f2)
  echo "gate try $GTRY: 146 cap=$cap dpkts/3s=${dpk:-0}"
  # numeric compare -- direct_reg_access returns cap UNPADDED (0x4922282), so a
  # string compare to the padded 0x04922282 gives a false negative.
  if [ "$(( ${cap:-0} ))" -eq "$(( 0x04922282 ))" ] && [ "${dpk:-0}" -gt 3000 ]; then LOCKED=1; echo "146 LOCKED GOLDEN"; break; fi
  rearm_rom $B; rearm_rom $A; sleep 3; rearm_rom $B; rearm_rom $A
  GTRY=$(( GTRY + 1 ))
done
{ echo "146 gate: LOCKED=$LOCKED tries=$GTRY cap=$cap dpkts3s=${dpk:-0}"; } | tee "$OUT/arm.txt"
[ $LOCKED = 1 ] || echo "NOTE: 146 RX did NOT lock golden in reverse ROM after $GMAX re-arms -- soaking the degraded state for the record"

# 10 Hz soak of the reverse RX (146) registers, on-board
N=$(( SECS * 10 ))
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; rd(){ echo \"\$1\">\$DRA;cat \$DRA; }
 : > /dev/shm/revrom.log
 for i in \$(seq $N); do
   echo \"t=\$(date +%s.%N) pkts=\$(rd 0x104) biterr=\$(rd 0x108) cap=\$(rd 0x144) rstcs=\$(rd 0x150) cfc=\$(rd 0x154) fx=\$(rd 0x15C)\" >> /dev/shm/revrom.log
   sleep 0.1
 done; echo SOAK_DONE" 2>/dev/null
scpput root@$B:/dev/shm/revrom.log "$OUT/revrom.log" || echo "WARN: fetch failed"

# quiesce both
for ip in $B $A; do $W $ip 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access
 busybox devmem 0x9D000000 32 0 2>/dev/null; echo "'$ip' quiesced"' 2>/dev/null; done

python3 "$D/revrom_analyze.py" "$OUT/revrom.log" | tee "$OUT/verdict.txt"
echo "REVERSE_ROM_SOAK_DONE $OUT"
