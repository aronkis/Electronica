#!/bin/bash
# =============================================================================
# capture_rom_air.sh -- forward ROM/BIST-on-air IQ capture, for the float and
# fixed replay oracles.
#
# WHY THIS EXISTS. Both offline oracles score against a KNOWN reference:
#   * fixed  (perframe_f1536): per-frame cap_out vs CAPGOLD=0x04922282 -- the
#            SAME golden the v3 netlist gate produced (two_jup/NETLIST_PROVENANCE.md).
#   * float  (float_oracle_r3): front-end bound; no reference needed, but it
#            still needs a real locked signal.
# capture_r3 flips the byte source live, so its captures carry qpsk_perf TUN
# traffic -- arbitrary payload, no reference. Pointing either oracle at that
# produces a meaningless number (capGoldFrames=0/39 is EXPECTED for tun, not
# evidence of corruption). This script keeps the link on the ROM/BIST source so
# every transmitted frame IS the reference.
#
# Forward only: 146 radiates ROM, 148 receives and is tapped. 146's own receiver
# is NOT used, so this works even when the reverse leg is degraded (the #48
# arm-lottery state that blocks a both-directions gate).
#
# Leaves the link ARMED ON ROM. Re-run bringup_r2r3.sh r3 afterwards to restore
# byte-source + daemons.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148   # RX / tap target
B=10.0.0.146   # TX (radiates ROM)
NSAMP=${NSAMP:-4000000}
OUT=${OUT:-$D/r3cap/romair_$(date +%Y%m%d_%H%M%S)}; mkdir -p "$OUT"

echo "=== capture_rom_air: 146 ROM -> 148 RX, ${NSAMP} complex samples -> $OUT ==="

# watchdogs off during the capture: a mid-capture re-arm corrupts the record
for ip in $B $A; do
  $W $ip 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
    pkill -9 -f "[l]ock_watchdog" 2>/dev/null; exit 0' >/dev/null 2>&1
done
echo "  watchdogs stopped"

# daemons off: they would flip the byte source and destroy the ROM reference
for ip in $B $A; do $W $ip 'pkill -x qpsk_tun 2>/dev/null; exit 0' >/dev/null 2>&1; done
sleep 1

# proven rearm_rom sequence (bringup_r2r3.sh): 0x158=0 ROM, 0x118=0 in-FPGA Tx,
# 0x114=1 AIR. These are WRITE-ONLY -- set, never verified by readback; verify
# BY EFFECT via the 0x104 framesync rate below.
rearm_rom(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }

# double-tap (ARMCAUSE): first tap gets both TX streams clean ROM, second
# re-rolls both demods against clean peers.
rearm_rom $B; rearm_rom $A; sleep 3
rearm_rom $B; rearm_rom $A; sleep 4

probe(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo 0x104 > $DRA; p0=$(cat $DRA); sleep 5; echo 0x104 > $DRA; p1=$(cat $DRA)
  echo $(( (p1 - p0) / 5 ))' 2>/dev/null; }

FA=$(probe $A)
echo "  148 ROM framesync = ${FA:-0} f/s  (need >= 1120 -- forward leg only)"
if [ "${FA:-0}" -lt 1120 ]; then
  echo "  ABORT: 148 not receiving ROM at rate; capture would be worthless."
  echo "  (rearm and retry, or the forward leg is genuinely down)"
  exit 1
fi

# the tap, with the same anchor capture_r3 uses
$W $A "rm -f /dev/shm/pair.iq
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
  echo \"CAP_START t=\$(date +%s.%N) pkts=\$(rd 0x104) biterr=\$(rd 0x108) rstcs=\$(rd 0x150) cfc=\$(rd 0x154)\"
  iio_readdev -u local: -b 32768 -s $NSAMP axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/pair.iq 2>/tmp/iio.err || cat /tmp/iio.err
  echo \"CAP_END   t=\$(date +%s.%N) pkts=\$(rd 0x104) biterr=\$(rd 0x108) rstcs=\$(rd 0x150) cfc=\$(rd 0x154)\"
  ls -la /dev/shm/pair.iq" 2>/dev/null | tee "$OUT/regs_cap.txt"

# These boards need SSH_ASKPASS password auth -- plain scp silently produces a
# 0-byte file (hit 2026-08-24: the capture succeeded on the board, 16 MB written,
# and the local copy was empty). Same form capture_r3.sh's scpput() uses.
SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
  -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no root@$A:/dev/shm/pair.iq "$OUT/pair.iq" </dev/null 2>>/tmp/romair_scp_err.txt
if [ ! -s "$OUT/pair.iq" ]; then
  echo "  FATAL: pair.iq fetch produced an empty file (see /tmp/romair_scp_err.txt)"; exit 1
fi
echo "  pair.iq: $(stat -c %s "$OUT/pair.iq" 2>/dev/null || echo 0) bytes"
# CAPTURE-PATH HEALTH GATE (added 2026-08-24) -- see check_capture_health.py.
if ! python3 "$D/check_capture_health.py" "$OUT/pair.iq"; then
  echo "  *** CAPTURE HEALTH FAILED -- pair.iq is DEGENERATE, do NOT score it. ***"
fi
echo "ROMAIR_CAPTURE_DONE $OUT"
echo "  fixed leg : CAP=$OUT/pair.iq jupiter_240k5_byte/rtl_sim/tap_replay_study/run_region.sh 0 <N> 0 4"
echo "  NOTE       that harness links the cadence-4 Jul-25 archive -- NOT the flashed generation."
echo "  restore   : ./bringup_r2r3.sh r3   (byte source + daemons + watchdogs)"
