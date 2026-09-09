#!/bin/bash
# capture_window_iq.sh -- capture the demodulator soft constellation (rx2-lpc
# debug tap, iq_debug_mux selectable) DURING the ~1s held-corruption windows of
# the 119.75s beat, on the flashed build-1 image, BIST ROM digital loopback.
# Brackets each 65ms snapshot with a cap_in read so we know in-window (corrupt)
# vs golden-gap. Decides timing/carrier (analog) vs demapper/Serializer (digital).
#
# MUX (0x10C): 1=post symbol-sync, 2=post carrier-sync (decision input), 3=decisions.
# Windows cluster near arm+149..156 (first burst) and arm+269..276 (second).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=${BOARD:-10.0.0.148}
MUX=${MUX:-2}
NS=${NS:-4000000}   # 4M complex @61.44M = ~65ms snapshot
OUT=$D/evmcap/winiq_$(date +%Y%m%d_%H%M%S)_m${MUX}; mkdir -p "$OUT"
echo "=== window-IQ capture mux=$MUX -> $OUT ==="

arm_bist(){ $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
  awk "{print \$1}" /proc/uptime > /dev/shm/arm_t0
  echo "ARMED t0=$(cat /dev/shm/arm_t0)"' 2>/dev/null | tail -1; }
fsync(){ $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo "$1">$DRA;cat $DRA; }; a=$(($(rd 0x104)));sleep 3;b=$(($(rd 0x104)));echo $(((b-a)/3))' 2>/dev/null|tail -1; }

echo "--- quiesce + arm ---"
$W $B 'PF=/dev/shm/watchdog.pid;[ -f $PF ]&&kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null;pkill -x qpsk_tun 2>/dev/null;pkill -x iio_readdev 2>/dev/null;sleep 1;echo q' 2>/dev/null|tail -1
ATT=0;OK=0
while [ $ATT -lt 3 ]; do ATT=$((ATT+1)); arm_bist; sleep 65; F=$(fsync); echo "  arm-health=$F f/s"
  [ "${F:-0}" -ge 1000 ] 2>/dev/null && { OK=1; break; }
  bash "$D/restore_known_good.sh" >"$OUT/restore_pre$ATT.log" 2>&1
  $W $B 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null;pkill -x qpsk_tun 2>/dev/null;sleep 1' 2>/dev/null; done
[ $OK -eq 1 ] || { echo "ABORT: no healthy arm"; bash "$D/restore_known_good.sh">"$OUT/restore.log" 2>&1; exit 2; }

echo "--- set mux=$MUX; snapshot loop across the first burst window cluster (~arm+148..156) ---"
# on-board: set mux, wait to ~arm+148 (we're now ~arm+68), loop snapshots w/ cap_in brackets
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled>/sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo \"\$1\">\$DRA;cat \$DRA; }
  echo '0x10C 0x$MUX'>\$DRA
  T0=\$(cat /dev/shm/arm_t0)
  # beat law: first clean burst at arm+34.75+119.75=arm+154.5; windows span arm+149..156.
  waituntil(){ while :; do N=\$(awk '{print \$1}' /proc/uptime); awk -v n=\$N -v t=\$1 'BEGIN{exit !(n>=t)}' && break; sleep 0.02; done; }
  START=\$(awk -v t=\$T0 'BEGIN{print t+148.5}')
  echo \"T0=\$T0 wait-until=\$START (arm+148.5)\"
  waituntil \$START
  : > /dev/shm/winbrackets.txt
  for i in \$(seq 1 28); do
    pre=\$(rd 0x13C)
    iio_readdev -u local: -b 65536 -s $NS axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /dev/shm/win_\$i.bin 2>/dev/null
    post=\$(rd 0x13C)
    up=\$(awk '{print \$1}' /proc/uptime)
    sz=\$(stat -c %s /dev/shm/win_\$i.bin 2>/dev/null)
    echo \"i=\$i up=\$up pre=\$pre post=\$post bytes=\$sz\" | tee -a /dev/shm/winbrackets.txt
    sleep 0.15
  done
  echo SNAP_DONE" 2>/dev/null | tee "$OUT/brackets.txt"

echo "--- pull brackets + the in-window and a gap snapshot ---"
$W $B 'cat /dev/shm/winbrackets.txt' 2>/dev/null > "$OUT/winbrackets.txt"
# choose one corrupt-bracket (in-window) and one golden-bracket (gap) capture to pull
# line fmt: i=<idx> up=<t> pre=<cap> post=<cap> bytes=<n>  (split on '='/' ' -> pre=$6 post=$8 idx=$2)
INW=$(awk -F'[= ]' '$6!="0x5216F3E2"&&$8!="0x5216F3E2"{print $2; exit}' "$OUT/winbrackets.txt")
GAP=$(awk -F'[= ]' '$6=="0x5216F3E2"&&$8=="0x5216F3E2"{print $2; exit}' "$OUT/winbrackets.txt")
echo "  in-window snapshot idx=$INW ; gap snapshot idx=$GAP"
for tag in "inwin:$INW" "gap:$GAP"; do
  nm=${tag%%:*}; ix=${tag##*:}
  [ -n "$ix" ] && SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
    -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    root@$B:/dev/shm/win_$ix.bin "$OUT/${nm}_m${MUX}.bin" </dev/null 2>/dev/null && echo "  pulled $nm (idx $ix)"
done

echo "--- restore ---"
$W $B 'echo "0x10C 0x0">/sys/kernel/debug/iio/iio:device0/direct_reg_access 2>/dev/null; pkill -x iio_readdev 2>/dev/null' 2>/dev/null
bash "$D/restore_known_good.sh" > "$OUT/restore_post.log" 2>&1
F=$(fsync); echo "  post-restore fsync=$F"; [ "${F:-0}" -lt 1000 ] 2>/dev/null && { bash "$D/restore_known_good.sh">>"$OUT/restore_post.log" 2>&1; F=$(fsync); echo "  post-restore(2)=$F"; }
echo "WINIQ_DONE out=$OUT"