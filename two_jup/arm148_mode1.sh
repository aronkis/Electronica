#!/bin/bash
# arm148_mode1.sh -- arm 148 ALONE in mode-1 internal digital loopback.
#
# 148-only by construction: mode 1 is an FPGA-internal loopback and needs nothing
# from 146. Use this instead of bringup_r2r3.sh for 148-only work -- r3 is a
# TWO-BOARD bring-up and arms 146 as well (that is how 146 hung on 2026-09-01).
#
# The profile is DISCOVERED at runtime and a miss is FATAL. The previous inline
# arm cat'd /root/jupiter_240k5.{bin,json} with 2>/dev/null; neither file exists,
# so both loads failed silently on every run and the arm merely inherited
# whatever profile happened to be loaded -- which silently changed the link rate
# from 1246 f/s to 312 f/s after a cold boot (§49).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; B=${B:-10.0.0.148}
PROF=${PROF:-lvds_61p44_fdd_jupiter}
GOLD=${GOLD:-BCF94856}

echo "=== discovering profile '$PROF' on $B (a miss is fatal, not silent)"
HAVE=$($W $B "ls /root/${PROF}.bin /root/${PROF}.json 2>/dev/null | tr '\\n' ' '" 2>/dev/null | tr -d '\r')
if [ "$(printf %s "$HAVE" | wc -w)" -ne 2 ]; then
  echo "ARM_FATAL: need BOTH /root/${PROF}.bin and .json on $B; found: [$HAVE]. Available:"
  $W $B 'ls /root/*.bin 2>/dev/null' 2>/dev/null | sed 's/^/    /'
  echo "ARM_FATAL: refusing to arm with an unknown profile -- that is how the rate silently changed."
  exit 2
fi
echo "  found: $HAVE"

$W $B "set -e
P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
# A profile is TWO files and BOTH are required: the .bin is the stream processor
# image, the .json carries the rate configuration. Writing only the .bin leaves
# the previous rate in place -- that is how the link sat at 15.36 MHz (311 f/s)
# instead of 61.44 MHz (1245 f/s), exactly a factor of 4, for the whole morning.
# When I found jupiter_240k5.json missing I deleted the profile_config write
# instead of correcting the filename: I fixed the symptom and removed the step.
cat /root/${PROF}.bin  > \$P/stream_config
cat /root/${PROF}.json > \$P/profile_config
sleep 2
echo calibrated > \$P/out_voltage1_ensm_mode 2>/dev/null || true
echo calibrated > \$P/in_voltage1_ensm_mode  2>/dev/null || true
for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done
echo tx_a > \$P/out_voltage0_port_select
echo 2000000000 > \$P/out_altvoltage2_TX1_LO_frequency
echo 0 > \$P/out_voltage0_hardwaregain
echo rf_enabled > \$P/out_voltage0_ensm_mode
echo 2000000000 > \$P/out_altvoltage0_RX1_LO_frequency
echo rf_enabled > \$P/in_voltage0_ensm_mode
echo automatic > \$P/in_voltage0_gain_control_mode
echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
echo '0x208 0x0' > \$DRA
echo '0x000 0x1' > \$DRA; sleep 0.5; echo '0x000 0x0' > \$DRA
echo '0x158 0x0' > \$DRA; echo '0x118 0x0' > \$DRA; echo '0x114 0x0' > \$DRA
echo '0x110 0x1' > \$DRA; sleep 0.3; echo '0x110 0x0' > \$DRA
echo '  armed, waiting 70 s for the transient'" || { echo "ARM_FATAL: arm sequence returned non-zero"; exit 3; }

sleep 70
R=$($W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 echo '0x10C 0x60003' > \$DRA; sleep 2
 p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108))); sleep 4; p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
 echo \"\$(( (p1-p0)/4 )) \$(( (e1-e0)/4 )) \$(rd 0x20C)\"" 2>/dev/null | tr -d '\r' | tail -1)
read -r FPS ERR CAP <<<"$R"
CN=$(printf %s "${CAP:-}" | sed -E 's/^0[xX]//' | tr 'a-f' 'A-F')
echo "  post-arm: fps=$FPS errps=$ERR capTAP=$CAP"
# fps is NOT a health criterion on its own (§49): the rate depends on the profile.
# The criterion is the golden digest plus a non-zero, stable rate.
if [ "$CN" != "$GOLD" ]; then echo "ARM_FAIL: capTAP [$CN] != golden [$GOLD]"; exit 4; fi
if [ "${FPS:-0}" -lt 100 ]; then echo "ARM_FAIL: fps=$FPS -- link not running"; exit 5; fi
echo "ARM_OK profile=$PROF fps=$FPS capTAP=$CAP"
