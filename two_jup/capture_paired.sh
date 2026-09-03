#!/bin/bash
# =============================================================================
# capture_paired.sh {A|B} [opts] -- THE PAIRED CAPTURE: Tap-A raw ADC I/Q
# recorded DURING a live scored -B window on the same board, so the offline
# float/fixed replay can be compared against the CONCURRENT live BER slice
# (not an adjacent window -- the flaw in every earlier floorcap capture).
#
#   A : capture on 148, forward quiet-pair link  146 TX@2.00 GHz -> 148 RX
#   B : capture on 146, reverse quiet-pair link  148 TX@1.90 GHz -> 146 RX
#
# Sequence (board-safety per campaign plan):
#   quiesce -> deploy host tool -> arm BOTH (quiet pair, nominal LOs) ->
#   watchdogs + -B on both -> acquisition sleep -> KILL WATCHDOGS (a re-arm
#   mid-capture pulses reset and corrupts both records) -> verify lock ->
#   PRE regs -> Tap-A iio_readdev (separate ADI DMA; never the 512KB-wedge
#   S2MM path) -> POST regs -> wait -B end -> pkill + pgrep-confirm ->
#   scp results -> health check.
#
# Options: -d DUR(-B secs, def 60)  -n NSAMP(complex, def 2000000)
#          -s SEED (QBER_SEED both ends)  -o OUTDIR (def paired/<ts>_<dir>)
# Output:  pair.iq (int16 I,Q @1.92 Msps), ber.log (full -B report incl.
#          per-offset map), frames.bin (per-frame telemetry, 48 B/frame, via
#          QPSK_FRAMELOG -- correlate to pair.iq by the CAP_START pkts=0x104
#          anchor), regs_{pre,cap,post}.txt, meta.txt
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=$(cd "$D/.." && pwd)/host_app_k5
A_IP=10.0.0.148; B_IP=10.0.0.146
FWD_HZ=2000000000   # 146 TX -> 148 RX (quiet-pair forward)
REV_HZ=1900000000   # 148 TX -> 146 RX (dodges 148's 2.10 GHz Tx-LO leakage)

TGT=${1:?usage: capture_paired.sh A-or-B -d dur -n nsamp -s seed -o outdir}
shift
DUR=60; NSAMP=2000000; SEED=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d) DUR=$2; shift 2;;
    -n) NSAMP=$2; shift 2;;
    -s) SEED=$2; shift 2;;
    -o) OUT=$2; shift 2;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
case "$TGT" in
  A) RX_IP=$A_IP; DIRN=fwd;;
  B) RX_IP=$B_IP; DIRN=rev;;
  *) echo "target must be A (capture on 148) or B (capture on 146)" >&2; exit 2;;
esac
[ -n "$OUT" ] || OUT=$D/paired/$(date +%Y%m%d_%H%M%S)_${DIRN}
mkdir -p "$OUT"
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
snap(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA;cat $DRA; }
   echo "t=$(date +%s.%N) pkts=$(rd 0x104) biterr=$(rd 0x108) cap=$(rd 0x144) rstcs=$(rd 0x150) cfc=$(rd 0x154) fx=$(rd 0x15C)"' 2>/dev/null; }

echo "=== capture_paired $TGT ($DIRN): -B ${DUR}s on both, Tap-A ${NSAMP} samp on $RX_IP -> $OUT ==="

# 1. quiesce + deploy host tool on both
for ip in $B_IP $A_IP; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4; echo "'$ip' quiesced"' 2>/dev/null
  $W $ip 'mkdir -p /root/host_app_k5' 2>/dev/null
  scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" \
         "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" root@$ip:/root/host_app_k5/ || { echo "scp $ip FAIL"; exit 1; }
  R=$($W $ip 'cd /root/host_app_k5 && gcc -O2 -Wall -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c 2>/tmp/gcc.err && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }' 2>/dev/null)
  echo "  $ip build: $(echo "$R" | tail -1)"; echo "$R" | grep -q BUILD_OK || exit 1
done

# 2. quiet-pair arm on both (verbatim ber_ota.sh arm; nominal LOs)
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
arm $B_IP $FWD_HZ $REV_HZ
arm $A_IP $REV_HZ $FWD_HZ

# 3. watchdogs (acquisition only) + -B on both
for ip in $B_IP $A_IP; do
  $W $ip 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
  $W $ip "cd /root/host_app_k5; rm -f /dev/shm/pair_ber.log /dev/shm/frames.bin; setsid sh -c 'QBER_SEED=$SEED QPSK_FRAMELOG=/dev/shm/frames.bin ./qpsk_tun -B -d $DUR > /dev/shm/pair_ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
done
echo "  acquiring (watchdogs live) 12s ..."; sleep 12

# 4. kill watchdogs BOTH (a mid-capture re-arm corrupts capture + BER slice)
for ip in $B_IP $A_IP; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; echo "'$ip' wd stopped"' 2>/dev/null; done
sleep 2

# 5. lock check on target: packets must be climbing, rstcs stable
S1=$(snap $RX_IP); sleep 3; S2=$(snap $RX_IP)
echo "  lock check: $S1"; echo "              $S2"
p1=$(echo "$S1"|grep -o 'pkts=0x[0-9a-fA-F]*'|cut -d= -f2); p2=$(echo "$S2"|grep -o 'pkts=0x[0-9a-fA-F]*'|cut -d= -f2)
[ $((p2)) -gt $((p1)) ] || { echo "WARN: packets not climbing on $RX_IP -- capture proceeds but flag it"; }
echo "$S1" > "$OUT/regs_pre.txt"; echo "$S2" >> "$OUT/regs_pre.txt"

# 6. THE PAIRED WINDOW: Tap-A capture during the live -B (single ssh session)
$W $RX_IP "rm -f /dev/shm/pair.iq
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; rd(){ echo \"\$1\">\$DRA;cat \$DRA; }
  echo \"CAP_START t=\$(date +%s.%N) pkts=\$(rd 0x104) biterr=\$(rd 0x108) rstcs=\$(rd 0x150) cfc=\$(rd 0x154)\"
  iio_readdev -u local: -b 32768 -s $NSAMP axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/pair.iq 2>/tmp/iio.err || cat /tmp/iio.err
  echo \"CAP_END   t=\$(date +%s.%N) pkts=\$(rd 0x104) biterr=\$(rd 0x108) rstcs=\$(rd 0x150) cfc=\$(rd 0x154)\"
  ls -la /dev/shm/pair.iq" 2>/dev/null | tee "$OUT/regs_cap.txt"

# 7. wait out the -B window, confirm clean exit
LEFT=$((DUR - 20)); [ $LEFT -gt 0 ] && { echo "  waiting ${LEFT}s for -B to finish ..."; sleep $((LEFT + 6)); }
for ip in $B_IP $A_IP; do
  $W $ip 'pkill -x qpsk_tun 2>/dev/null; sleep 0.5; pgrep -x qpsk_tun >/dev/null && echo "'$ip' qpsk_tun STILL RUNNING" || echo "'$ip' qpsk_tun stopped"' 2>/dev/null
done
snap $RX_IP > "$OUT/regs_post.txt"; cat "$OUT/regs_post.txt"

# 8. pull artifacts + health check
scpput root@$RX_IP:/dev/shm/pair.iq "$OUT/pair.iq" || { echo "scp pair.iq FAIL"; exit 1; }
scpput root@$RX_IP:/dev/shm/pair_ber.log "$OUT/ber.log" || echo "WARN: ber.log fetch failed"
# per-frame telemetry log (QPSK_FRAMELOG): 48 B/frame, correlated to pair.iq via
# the pkts=0x104 anchor in regs_cap.txt (CAP_START). Analyzed by
# two_jup/frame_taxonomy.py + align_frames.py.
scpput root@$RX_IP:/dev/shm/frames.bin "$OUT/frames.bin" || echo "WARN: frames.bin fetch failed"
PEER=$([ "$RX_IP" = "$A_IP" ] && echo $B_IP || echo $A_IP)
scpput root@$PEER:/dev/shm/pair_ber.log "$OUT/ber_peer.log" 2>/dev/null || true
scpput root@$PEER:/dev/shm/frames.bin "$OUT/frames_peer.bin" 2>/dev/null || true
{ echo "target=$TGT dir=$DIRN rx=$RX_IP dur=$DUR nsamp=$NSAMP seed=${SEED:-default}"
  echo "fwd=$FWD_HZ rev=$REV_HZ ts=$(date -Is)"; } > "$OUT/meta.txt"
for ip in $B_IP $A_IP; do $W $ip 'echo "'$ip' health: up $(cat /proc/uptime | cut -d" " -f1)s"' 2>/dev/null; done
echo "--- concurrent -B slice (target) ---"
grep -E 'ber: t=|frames_scored|buckets' "$OUT/ber.log" 2>/dev/null | tail -18
echo "PAIRED_CAPTURE_DONE $OUT"
