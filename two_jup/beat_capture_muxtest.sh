#!/bin/bash
# beat_capture.sh -- scheduled ILA capture of the 119.75s burst on the beat-ILA image.
# Law: bursts start at arm+34.75s + n*119.75s (10ms-exact). err_cnt is tied 0 in
# build 1 (BEATILA_ERRSRC NONE), so trigger = arm|soft_force (0x9D430000 = 0x3)
# scheduled on-board: run1 forced at arm+34.90s (raw 133us shot inside onset),
# run2 forced at arm+154.65s (capture-qualified ~17ms symbol-rate context).
# iq_debug_mux (DUT 0x10C) = 1 -> probes 10/11 = post-symbol-sync IQ (timing loop).
set -u
D=$(cd "$(dirname "$0")" && pwd); R=$(dirname "$D"); W=$D/anyssh.sh
B=10.0.0.148
LTX=$R/jupiter_byte_beatila_build/hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.runs/impl_1/debug_nets.ltx
OUT=$D/r3cap/beatcap_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
export PATH=/tools/Xilinx/2025.1/Vivado/bin:$PATH

echo "=== beat ILA capture -> $OUT ==="
echo "--- [1] board: build + start xvc daemon (0x9D440000:2542) ---"
SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
  -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  "$R/host_app_k5/xvc_server.c" root@$B:/root/ </dev/null 2>>/tmp/beatcap_scp.txt
$W $B 'pkill -x xvc_server 2>/dev/null; gcc -Wall -O2 -o /root/xvc_server /root/xvc_server.c \
  && { setsid /root/xvc_server 0x9D440000 2542 > /dev/shm/xvc.log 2>&1 & sleep 1; }
  pgrep -x xvc_server >/dev/null && echo XVCD_UP || { echo XVCD_FAIL; cat /dev/shm/xvc.log; }' 2>/dev/null | tail -3

echo "--- [2] quiesce (adc_1_clk stays up: profile already loaded post-bringup) ---"
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1; echo quiesced' 2>/dev/null

echo "--- [3] vivado XVC session (background; waits for triggers) ---"
pkill -x hw_server 2>/dev/null; pkill -x cs_server 2>/dev/null; sleep 1
rm -f "$OUT/armed_1" "$OUT/armed_2"
( cd "$OUT" && timeout 900 vivado -mode batch -notrace -source "$D/beat_capture.tcl" \
    -tclargs "$LTX" "$OUT" "$B:2542" ) > "$OUT/vivado.log" 2>&1 &
VPID=$!
for i in $(seq 1 120); do [ -f "$OUT/armed_1" ] && break; sleep 1; done
[ -f "$OUT/armed_1" ] || { echo "BEATCAP_FATAL: ILA never armed (see $OUT/vivado.log)"; tail -20 "$OUT/vivado.log"; exit 1; }
echo "  ILA run1 armed"

echo "--- [4] board: arm loopback, force at +34.90s and +154.65s (single session, ms-precision) ---"
$W $B 'DM=$(command -v devmem || echo "busybox devmem")
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
  # mux set per-force below (mux-take control test)
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9001-tx-lpc ] && echo ${d##*/}; done)
  TL=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$TL; echo "0x458 0x2">$TL; echo "0x044 0x1">$TL
  T0=$(awk "{print \$1}" /proc/uptime)
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
  echo "BOARD_ARM_UPTIME $T0"
  waituntil(){ while :; do N=$(awk "{print \$1}" /proc/uptime)
      awk -v n=$N -v t=$1 "BEGIN{exit !(n>=t)}" && break; sleep 0.05; done; }
  waituntil $(awk -v t=$T0 "BEGIN{print t+40.0}"); echo "0x10C 0x0">$DRA
  CAP1=$(echo 0x13C>$DRA; cat $DRA); $DM 0x9D430000 32 3; echo "FORCE1(mux0-AGC) $(awk "{print \$1}" /proc/uptime) cap_in=$CAP1 status=$($DM 0x9D430008)"
  sleep 1; $DM 0x9D430000 32 0
  waituntil $(awk -v t=$T0 "BEGIN{print t+42.0}"); echo "0x10C 0x2">$DRA
  CAP2=$(echo 0x13C>$DRA; cat $DRA); $DM 0x9D430000 32 3; echo "FORCE2(mux2-carrier) $(awk "{print \$1}" /proc/uptime) cap_in=$CAP2 status=$($DM 0x9D430008)"
  sleep 1; $DM 0x9D430000 32 0
  echo BOARD_SEQ_DONE' 2>/dev/null | tee "$OUT/board_seq.txt"

echo "--- [5] wait for vivado to finish ---"
wait $VPID; VEXIT=$?
grep -E "BEATCAP_|BEATCAP_WARN" "$OUT/vivado.log" | tail -8
ls -la "$OUT"/*.csv 2>/dev/null

echo "--- [6] stop daemon + restore rig ---"
$W $B 'pkill -x xvc_server 2>/dev/null; exit 0' >/dev/null 2>&1
bash "$D/restore_known_good.sh" > /tmp/beatcap_restore.log 2>&1
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo "$1">$DRA; cat $DRA; }
  p0=$(($(rd 0x104))); sleep 3; p1=$(($(rd 0x104))); echo "RIG: fsync/s=$(( (p1-p0)/3 ))"' 2>/dev/null
echo "BEATCAP_SESSION_DONE vexit=$VEXIT out=$OUT"
