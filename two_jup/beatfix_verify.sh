#!/bin/bash
# beatfix_verify.sh -- BEATFIX on-air verification per BEATFIX_DESIGN.md.
# Legs (each with its own arm-health-gated BIST arm; scheduled slots at
# arm+34.75+n*119.75): A fixctl=0 (positive control: bursts MUST appear,
# counter watches the real trigger); B fixctl=3 (contract+serializer);
# C fixctl=4 (grid-pace comparison arm). 340s polls catch slots ~153/273.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.148
OUT=$D/r3cap/beatfixver_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
echo "=== BEATFIX verification -> $OUT ==="
SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
  -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  "$D/stage_poll.c" root@$B:/root/ </dev/null 2>/dev/null
$W $B 'gcc -O2 -o /root/stage_poll /root/stage_poll.c && echo POLLER_OK' 2>/dev/null | tail -1

arm_bist(){ $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; echo ARMED' 2>/dev/null | tail -1; }
fsync(){ $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access;echo enabled>/sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo "$1">$DRA;cat $DRA; };a=$(($(rd 0x104)));sleep 3;b=$(($(rd 0x104)));echo $(((b-a)/3))' 2>/dev/null|tail -1; }
setfix(){ $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access;echo enabled>/sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  echo '0x208 0x$1'>\$DRA; echo FIXCTL_$1" 2>/dev/null | tail -1; }

$W $B 'PF=/dev/shm/watchdog.pid;[ -f $PF ]&&kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null;pkill -x qpsk_tun 2>/dev/null;sleep 1;echo q' 2>/dev/null|tail -1

leg(){ # $1=name $2=fixctl-hex
  echo "--- LEG $1 (fixctl=0x$2) ---"
  A=0; while [ $A -lt 3 ]; do A=$((A+1))
    arm_bist; setfix $2; sleep 65
    F=$(fsync); echo "  arm-health=$F"
    [ "${F:-0}" -ge 1000 ] 2>/dev/null && break
    bash "$D/restore_known_good.sh" >"$OUT/${1}_restore$A.log" 2>&1
    $W $B 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null;pkill -x qpsk_tun 2>/dev/null;sleep 1' 2>/dev/null
  done
  [ "${F:-0}" -ge 1000 ] || { echo "LEG_${1}_ABORT arm lottery"; return 1; }
  $W $B "/root/stage_poll 100 340" 2>/dev/null > "$OUT/${1}.csv"
  echo "  $(wc -l < "$OUT/${1}.csv") samples"
}
leg A_fixoff 0
leg B_fixon3 3
leg B2_fixon3 3
leg C_grid 4
echo "--- restore ---"
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access;echo enabled>/sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null;echo "0x208 0x0">$DRA' 2>/dev/null
bash "$D/restore_known_good.sh" > "$OUT/restore_post.log" 2>&1
F=$(fsync); [ "${F:-0}" -lt 1000 ] 2>/dev/null && bash "$D/restore_known_good.sh" >> "$OUT/restore_post.log" 2>&1
echo "BEATFIXVER_DONE out=$OUT fsync=$(fsync)"
