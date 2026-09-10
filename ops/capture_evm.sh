#!/bin/bash
# =============================================================================
# capture_evm.sh {A|B} [-m "0 2 3"] [-n NSAMP] [-o outdir] -- EVM CAPTURE RECIPE
# (task C1): per-mode debug-tap (0x10C) captures for evm_from_tap, plus one
# raw rx-lpc passthrough capture for evm_ideal_ref, on ONE board.
#
#   A : tap board 148 (forward quiet-pair link 146 TX@2.00 GHz -> 148 RX)
#   B : tap board 146 (reverse quiet-pair link 148 TX@1.90 GHz -> 146 RX)
#
# Clones the session discipline of ops/capture_paired.sh / tap_smoke.sh:
#   anyssh.sh for all remote commands (one ssh per board), /dev/shm scratch,
#   arm BOTH boards (quiet pair, nominal LOs), watchdogs during acquisition
#   only (a mid-capture re-arm pulses reset and corrupts the record), verified
#   lock before capturing, register snapshots bracketing every read.
#
# Options:
#   -m "0 2 3"   space-separated tap modes to sweep (default "0 1 2 3")
#   -n NSAMP     complex samples per mode capture (default 2000000).
#                NOTE (forward-direction): BBDC calibration ticks are an
#                intermittent artifact -- use NSAMP >= 4000000 to reliably span
#                a tick window when characterizing tick-related EVM excursions.
#   -o outdir    output dir (default ops/evmcap/<ts>_<A|B>)
#
# Per mode: write 0x10C=<mode> via direct_reg_access (same poke mechanism as
# tap_smoke.sh/capture_paired.sh), settle 0.5s, iio_readdev the debug-tap
# stream (axi-adrv9002-rx2-lpc voltage0_i voltage0_q) to /dev/shm, bracket
# with register snapshots (0x104,0x108,0x150,0x154,0x15C) into regs_m$m.txt.
# ALSO one raw rx-lpc passthrough capture (0x10C=0, receiver input, same
# NSAMP) for evm_ideal_ref -- separate ADI DMA, never the byte S2MM path.
# 0x10C is restored to 0 at exit (trap, incl. on error/interrupt).
#
# Output: ops/evmcap/<ts>_<A|B>/
#   tap_m<mode>.bin   -- rx2-lpc debug-tap capture, mode <mode>
#   regs_m<mode>.txt  -- pre/post register snapshot for that mode's capture
#   raw.iq            -- rx-lpc passthrough capture (0x10C=0), evm_ideal_ref input
#   regs_raw.txt      -- pre/post register snapshot for the raw capture
#   meta.txt          -- direction, mode list, nsamp, image id (if readable)
#
# NEVER touches the byte S2MM path or exceeds 512KB S2MM -- this script only
# ever reads the rx2-lpc / rx-lpc IIO streams (iio_readdev), matching
# capture_paired.sh's "never the 512KB-wedge S2MM path" discipline.
#
# Task C1 constraint: this script is NOT run against real boards in this task
# -- syntax/`bash -n` check only.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A_IP=10.0.0.148; B_IP=10.0.0.146
FWD_HZ=2000000000   # 146 TX -> 148 RX (quiet-pair forward)
REV_HZ=1900000000   # 148 TX -> 146 RX (dodges 148's 2.10 GHz Tx-LO leakage)

TGT=${1:?usage: capture_evm.sh A-or-B [-m modes] [-n NSAMP] [-o outdir]}
shift
MODES="0 1 2 3"; NSAMP=2000000; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m) MODES=$2; shift 2;;
    -n) NSAMP=$2; shift 2;;
    -o) OUT=$2; shift 2;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
case "$TGT" in
  A) T_IP=$A_IP; DIRN=fwd;;
  B) T_IP=$B_IP; DIRN=rev;;
  *) echo "target must be A (tap board 148) or B (tap board 146)" >&2; exit 2;;
esac
[ -n "$OUT" ] || OUT=$D/evmcap/$(date +%Y%m%d_%H%M%S)_${TGT}
mkdir -p "$OUT"

scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
snap(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA;cat $DRA; }
   echo "t=$(date +%s.%N) pkts=$(rd 0x104) biterr=$(rd 0x108) rstcs=$(rd 0x150) cfc=$(rd 0x154) fx=$(rd 0x15C)"' 2>/dev/null; }
setmode(){ $W $1 "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; echo '0x10C 0x$2' > \$DRA" 2>/dev/null; }

# ---- restore 0x10C=0 on ANY exit (normal, error, or interrupt) ------------
cleanup(){
  setmode "$T_IP" 0 >/dev/null 2>&1
  echo "cleanup: 0x10C restored to 0 on $T_IP"
}
trap cleanup EXIT INT TERM

echo "=== capture_evm $TGT ($DIRN): modes=[$MODES] nsamp=$NSAMP -> $OUT ==="

# 1. quiesce both boards (per capture_paired.sh / tap_smoke.sh discipline)
for ip in $B_IP $A_IP; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; pkill -x iio_readdev 2>/dev/null; sleep 0.4' 2>/dev/null
done

# 2. quiet-pair arm on both (verbatim capture_paired.sh / tap_smoke.sh arm; nominal LOs)
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

# 3. watchdogs (acquisition-verification only) + qpsk_tun -S on both, verify lock
for ip in $B_IP $A_IP; do
  $W $ip 'rm -f /dev/shm/acc.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
  $W $ip "cd /root/host_app_k5; setsid sh -c './qpsk_tun -S -d 600 > /dev/shm/acc.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
done
echo "  acquiring (watchdogs live) 12s ..."; sleep 12
for ip in $B_IP $A_IP; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null' 2>/dev/null; done
sleep 2

S1=$(snap "$T_IP"); sleep 3; S2=$(snap "$T_IP")
echo "  lock check: $S1"; echo "              $S2"
p1=$(echo "$S1"|grep -o 'pkts=0x[0-9a-fA-F]*'|cut -d= -f2); p2=$(echo "$S2"|grep -o 'pkts=0x[0-9a-fA-F]*'|cut -d= -f2)
[ $((p2)) -gt $((p1)) ] || echo "WARN: packets not climbing on $T_IP -- capturing anyway, flag it in meta.txt"

# 4. per-mode debug-tap captures ---------------------------------------------
for m in $MODES; do
  echo "--- mode $m ---"
  R1=$(snap "$T_IP")
  setmode "$T_IP" "$m"
  sleep 0.5   # settle after the mode-mux switch
  $W "$T_IP" "rm -f /dev/shm/tap_m$m.bin
    iio_readdev -u local: -b 65536 -s $NSAMP axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /dev/shm/tap_m$m.bin 2>/tmp/iio_m$m.err \
      || cat /tmp/iio_m$m.err
    ls -l /dev/shm/tap_m$m.bin" 2>/dev/null
  R2=$(snap "$T_IP")
  { echo "$R1"; echo "$R2"; } > "$OUT/regs_m$m.txt"
  scpput root@"$T_IP":/dev/shm/tap_m$m.bin "$OUT/tap_m$m.bin" || { echo "capture_evm FAIL: pull tap_m$m.bin"; exit 1; }
  [ "$(stat -c %s "$OUT/tap_m$m.bin" 2>/dev/null || echo 0)" -gt 0 ] || { echo "capture_evm FAIL: tap_m$m.bin empty"; exit 1; }
done

# 5. one raw rx-lpc passthrough capture (0x10C=0 / whatever passthrough mode is) --
echo "--- raw rx-lpc passthrough capture ---"
R1=$(snap "$T_IP")
setmode "$T_IP" 0
sleep 0.5
$W "$T_IP" "rm -f /dev/shm/raw.iq
  iio_readdev -u local: -b 65536 -s $NSAMP axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/raw.iq 2>/tmp/iio_raw.err \
    || cat /tmp/iio_raw.err
  ls -l /dev/shm/raw.iq" 2>/dev/null
R2=$(snap "$T_IP")
{ echo "$R1"; echo "$R2"; } > "$OUT/regs_raw.txt"
scpput root@"$T_IP":/dev/shm/raw.iq "$OUT/raw.iq" || { echo "capture_evm FAIL: pull raw.iq"; exit 1; }
[ "$(stat -c %s "$OUT/raw.iq" 2>/dev/null || echo 0)" -gt 0 ] || { echo "capture_evm FAIL: raw.iq empty"; exit 1; }

# 6. cleanup remote scratch + stop host tools --------------------------------
$W "$T_IP" "rm -f /dev/shm/tap_m*.bin /dev/shm/raw.iq /tmp/iio_*.err" 2>/dev/null
for ip in $B_IP $A_IP; do $W $ip 'pkill -x qpsk_tun 2>/dev/null' 2>/dev/null; done

# 7. meta.txt (direction, mode list, nsamp, image id if readable) -----------
IMGID=$($W "$T_IP" 'md5sum /boot/BOOT.BIN 2>/dev/null | cut -d" " -f1' 2>/dev/null)
{
  echo "target=$TGT dir=$DIRN tap_ip=$T_IP modes=[$MODES] nsamp=$NSAMP"
  echo "fwd=$FWD_HZ rev=$REV_HZ ts=$(date -Is)"
  echo "image_md5=${IMGID:-unreadable}"
} > "$OUT/meta.txt"

echo "CAPTURE_EVM_DONE $OUT"
