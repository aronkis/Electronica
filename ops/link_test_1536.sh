#!/bin/bash
# =============================================================================
# link_test.sh -- OPERATOR entry point for the two-Jupiter QPSK RF link.
#
# One script to bring up / measure / tear down the FDD "quiet pair" link between
# two ADRV9002 "Jupiter" boards that are ALREADY FLASHED with the rxfix BOOT.BIN
# (CFOChangeDetectThreshold = 0.0125, the CFO-step reset-storm fix).
#
#   Board A = 10.0.0.148   Board B = 10.0.0.146   (wired management LAN)
#   FDD "quiet pair" (dodges 148's 2.10 GHz Tx-LO leakage):
#       FORWARD  146 -> 148  @ 2.00 GHz
#       REVERSE  148 -> 146  @ 1.90 GHz
#   => 146 Tx@2.00 Rx@1.90 ;  148 Tx@1.90 Rx@2.00
#
# Usage:  ./link_test.sh <subcommand> [options]     (see usage() / -h)
#
# ALL board access goes through the proven password-auth wrapper anyssh.sh,
# resolved next to this script:  W="$DIR/anyssh.sh" ;  "$W <ip> '<remote cmd>'".
#
# The modem/radio arm register sequences and the -B / tun0 / ssh remote command
# strings below are copied VERBATIM from the proven ground-truth scripts
# (test_quietband.sh, fdd_tun_quiet.sh, tun_ssh_key.sh). Do NOT paraphrase the
# register writes -- the radio wedges if the sequence is wrong.
#
# ---------------------------------------------------------------------------
# HARDWARE SAFETY CONSTRAINTS (this script honors all five):
#   1. Jupiter has NO remote power. A wedge = physical reflash+reboot only.
#      => nothing here can wedge a board (no giant DMA capture, no half-arm).
#   2. Uses the EXISTING boot files. This script NEVER flashes or touches
#      /boot/BOOT.BIN. (grep this file for "BOOT.BIN": only in comments.)
#   3. An Rx S2MM DMA capture > 512 KB WEDGES the board. This script does NO
#      such capture -- the -B BER test needs none; there is no iio_readdev here.
#   4. Never run two concurrent ssh sessions to the SAME board during
#      arm/profile-reload. Each board's arm is ONE anyssh call (arm_ber /
#      coldstart_tun). The two DIFFERENT boards arm in parallel ("& & wait"),
#      exactly as the proven scripts do. One profile reload per bring-up.
#   5. Any scratch/capture files on the board go to /dev/shm, never /tmp.
# ---------------------------------------------------------------------------
set -u

# ---------------- config block (all overridable via env or options) ----------
A_IP=${A_IP:-10.0.0.148}          # Board A management IP (-A)
B_IP=${B_IP:-10.0.0.146}          # Board B management IP (-B)
FWD_HZ=${FWD_HZ:-2000000000}      # forward  146->148 LO, Hz (-f <MHz>)
REV_HZ=${REV_HZ:-1900000000}      # reverse  148->146 LO, Hz (-r <MHz>)
DUR=${DUR:-60}                    # -B BER run duration, seconds (-d). Window starts
                                  # at arm, so it includes the lock transient; use
                                  # -d 90 for a steadier steady-state figure.
WHITEN=${WHITEN:-0}               # host whitener QPSK_WHITEN (-w sets 1); MUST
                                  # match on BOTH ends or every frame fails CRC.
TEARDOWN=0                        # -k: tear the link down after tun/ssh

# tun0 point-to-point addresses are FIXED constants tied to board role (not
# overridable): B(146)=10.66.0.1  A(148)=10.66.0.2. Kept identical to the
# proven coldstart calls so the ping/ssh remote strings stay byte-verbatim.
TUN_A=10.66.0.2                   # A_IP (148) tun0 address
TUN_B=10.66.0.1                   # B_IP (146) tun0 address

# resolve anyssh.sh relative to THIS script's own directory
DIR=$(cd "$(dirname "$0")" && pwd)
W="$DIR/anyssh.sh"
scpput(){ SSH_ASKPASS=$DIR/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

GOLDEN_CAP=0x4922282              # 0x144 cap_out golden readback for the rxfix image

# ============================================================================
usage(){
cat <<'EOF'
link_test.sh -- operator entry point for the two-Jupiter QPSK RF link (rxfix build).
Usage: ./link_test.sh <subcommand> [options]

Subcommands:
  preflight   verify BOTH boards are ready (reachable; /root/host_app_k5/qpsk_tun
              executable; /root/lvds_15p36_jupiter.{bin,json} present; lock_watchdog.sh
              present; modem reg access works). NO arm. Prints cap_out/rstcs/level.
              PASS/FAIL per board; exits nonzero if any FAIL.
  ber         THE MAIN LINK TEST. Quiesce -> arm the quiet pair -> watchdogs ->
              qpsk_tun -B both ways -> report frames_scored / bucket % / BER per
              direction + rstcs delta -> quiesce. Read-only-safe quality metric.
  tun         Bring up qpsk_tun -F on tun0 both ways, ping both directions,
              LEAVE THE LINK UP (use -k to tear down after).
  ssh         Like tun, plus: ed25519 pubkey out-of-band (B=client, A=server) and
              ssh B->A over tun0 (minimal-KEX). LEAVE UP (use -k to tear down).
  status      Read modem regs on both boards WITHOUT arming.
  down|clean  Quiesce both: kill lock_watchdog + qpsk_tun, flush tun0.

Options:
  -A <ip>     Board A management IP  (default 10.0.0.148)
  -B <ip>     Board B management IP  (default 10.0.0.146)
  -d <secs>   BER duration for 'ber'  (default 60; window includes lock transient,
              use -d 90 for a steadier figure). No effect on tun/ssh lock wait.
  -f <mhz>    forward LO 146->148, MHz (default 2000)
  -r <mhz>    reverse LO 148->146, MHz (default 1900)
  -w          enable host whitener QPSK_WHITEN=1 (tun/ssh only -- affects the IP
              payload; NO effect on 'ber' which uses a fixed reference). Both ends match.
  -k          tear the link down after tun/ssh (default: leave up)
  -h          this help

Note: the <subcommand> must come FIRST, before any options
      (e.g. './link_test.sh ber -d 90', not './link_test.sh -d 90 ber').

SAFETY: never flashes BOOT.BIN; never does an Rx S2MM capture (>512KB wedges the
        board); board scratch -> /dev/shm; each board's arm is a single anyssh call.
        A wedge = physical reflash+reboot (no remote power). Judge link quality by
        'ber' or 'ssh' -- NOT by ping (ping payloads are low-entropy and lossy).
EOF
}

hr(){ echo; echo "=============================================================="; echo "== $*"; echo "=============================================================="; }

# ---------------------------------------------------------------------------
# quiesce -- kill the on-board watchdog + qpsk_tun and flush tun0 on both boards.
# Read-safe: pkill + address flush can never wedge a board. (VERBATIM remote
# string from fdd_tun_quiet.sh / tun_ssh_key.sh.)
# ---------------------------------------------------------------------------
quiesce(){
  local ip
  for ip in "$B_IP" "$A_IP"; do
    $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; ip addr flush dev tun0 2>/dev/null; sleep 0.3; echo "'$ip' cleared"' 2>/dev/null
  done
}

# ---------------------------------------------------------------------------
# arm_ber -- BER-mode arm.  $1 ip  $2 tx_lo_hz  $3 rx_lo_hz
# VERBATIM copy of arm() from test_quietband.sh (register pokes UNMODIFIED).
# NOTE: the LAST line is the byte-DMA arm ("busybox devmem 0x9D300000 32 0x1")
#       that -B mode needs -- it lives INSIDE this single anyssh call (safety
#       constraint #4: one anyssh per board arm). A watchdog 0x000 re-arm does
#       NOT clear byte_ctrl_gpio, so this byte-DMA arm survives re-arms.
# ---------------------------------------------------------------------------
arm_ber(){ $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_15p36_jupiter.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_15p36_jupiter.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
   for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
   echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
   echo $3 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
   if grep -qi '9d300000-' /proc/iomem 2>/dev/null; then busybox devmem 0x9D300000 32 0x1; else echo 'skip byte-dma arm: no 9d300000 in /proc/iomem'; fi; echo armed" 2>/dev/null; }

# ---------------------------------------------------------------------------
# coldstart_tun -- tun-mode arm.  $1 ip $2 tx_lo_hz $3 rx_lo_hz $4 tunaddr $5 peer
# VERBATIM copy of coldstart() from tun_ssh_key.sh (same register pokes as
# arm_ber, but instead of the devmem byte-DMA arm it launches "qpsk_tun -F"
# (which owns the byte DMAs) + lock_watchdog + configures tun0). QPSK_WHITEN is
# the local $WHITEN and MUST be identical on both ends. Single anyssh per board.
# ---------------------------------------------------------------------------
coldstart_tun(){ # $1 ip $2 txlo $3 rxlo $4 tunaddr $5 peer
  $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_15p36_jupiter.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_15p36_jupiter.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
   for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
   echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
   echo $3 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
   cd /root/host_app_k5; QPSK_WHITEN=$WHITEN setsid ./qpsk_tun -F -i tun0 -s 30 </dev/null >/dev/shm/qpsk_tun.log 2>&1 &
   rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &
   n=0; while [ \$n -lt 15 ]; do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; n=\$((n+1)); done
   ip addr replace $4 peer $5 dev tun0; ip link set tun0 up mtu 116; ip route replace $5 dev tun0 advmss 56 rto_min 25ms 2>/dev/null
   echo '$1 cold-started (quiet 2.00/1.90, WHITEN=$WHITEN), tun0 set'" 2>/dev/null
}

# ---------------------------------------------------------------------------
# rstcs_read -- read modem reg 0x150 (rstcs, carrier-reset firing counter) on a
# board. Read-only debugfs access; never arms. Prints "0x....".
# ---------------------------------------------------------------------------
rstcs_read(){
  $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo 0x150 > $DRA 2>/dev/null; cat $DRA 2>/dev/null' 2>/dev/null
}

# ---------------------------------------------------------------------------
# launch_watchdogs -- start /root/lock_watchdog.sh on both boards (fire & forget).
# Runs AFTER arm has returned (no arm concurrency). VERBATIM launch from
# test_quietband.sh.
# ---------------------------------------------------------------------------
launch_watchdogs(){
  local ip
  for ip in "$B_IP" "$A_IP"; do
    $W $ip 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
  done
}

# ---------------------------------------------------------------------------
# link_snapshot -- print watchdog tail + tun0 addr for both boards (after tun/ssh
# bring-up). Read-only.
# ---------------------------------------------------------------------------
link_snapshot(){
  local ip
  for ip in "$B_IP" "$A_IP"; do
    echo "--- $ip ---"
    $W $ip 'echo "  wd: $(tail -1 /dev/shm/watchdog.log 2>/dev/null)"; echo "  tun0: $(ip -o addr show tun0 2>/dev/null | grep -oE "inet [0-9.]+")"' 2>/dev/null
  done
}

# ============================================================================
# SUBCOMMAND: preflight -- verify BOTH boards are ready. NO arm (fully read-safe).
# ============================================================================
cmd_preflight(){
  hr "PREFLIGHT (no arm; read-only) -- A=$A_IP  B=$B_IP"
  local overall=0 ip label
  for ip in "$A_IP" "$B_IP"; do
    [ "$ip" = "$A_IP" ] && label="A" || label="B"
    echo
    echo "---- Board $label = $ip ----"
    # ONE read-only anyssh call gathers every check + the reg readbacks.
    local out
    out=$($W $ip '
      echo reach=OK
      [ -x /root/host_app_k5/qpsk_tun ] && echo qpsk_tun=OK || echo qpsk_tun=FAIL
      [ -f /root/lvds_15p36_jupiter.bin ]    && echo lvds_bin=OK  || echo lvds_bin=FAIL
      [ -f /root/lvds_15p36_jupiter.json ]   && echo lvds_json=OK || echo lvds_json=FAIL
      [ -f /root/lock_watchdog.sh ]     && echo watchdog=OK  || echo watchdog=FAIL
      DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
      echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
      rd(){ echo "$1" > $DRA 2>/dev/null; cat $DRA 2>/dev/null; }
      CAP=$(rd 0x144); RST=$(rd 0x150); LVL=$(rd 0x15C)
      [ -n "$CAP" ] && echo regaccess=OK || echo regaccess=FAIL
      echo "regs cap=$CAP rstcs=$RST level=$LVL"
    ' 2>/dev/null)

    local fail=0
    if ! printf '%s\n' "$out" | grep -q '^reach=OK'; then
      echo "  [FAIL] unreachable via anyssh.sh"
      overall=1
      echo "  ==> Board $label: FAIL"
      continue
    fi
    local chk
    for chk in qpsk_tun lvds_bin lvds_json watchdog regaccess; do
      if printf '%s\n' "$out" | grep -q "^${chk}=OK"; then
        echo "  [ ok ] $chk"
      else
        echo "  [FAIL] $chk"
        fail=1
      fi
    done
    # print cap_out / rstcs / level (advisory only -- not PASS/FAIL gates)
    local regline cap rst lvl
    regline=$(printf '%s\n' "$out" | grep '^regs ')
    cap=$(printf '%s' "$regline" | sed -n 's/.*cap=\([^ ]*\).*/\1/p')
    rst=$(printf '%s' "$regline" | sed -n 's/.*rstcs=\([^ ]*\).*/\1/p')
    lvl=$(printf '%s' "$regline" | sed -n 's/.*level=\([^ ]*\).*/\1/p')
    local capnote="?"
    if printf '%s' "$cap" | grep -qiE '^0x[0-9a-f]+$'; then
      if [ $((cap)) -eq $((GOLDEN_CAP)) ]; then capnote="OK (== golden $GOLDEN_CAP)"; else capnote="MISMATCH (golden $GOLDEN_CAP -> wrong/broken image?)"; fi
    fi
    echo "  cap_out(0x144) = ${cap:-?}   $capnote"
    echo "  rstcs (0x150)  = ${rst:-?}   (expect low/stable with rxfix; large/growing => reset storm)"
    echo "  level (0x15C)  = ${lvl:-?}"
    if [ "$fail" = 0 ]; then
      echo "  ==> Board $label: PASS"
    else
      echo "  ==> Board $label: FAIL"
      overall=1
    fi
  done
  echo
  if [ "$overall" = 0 ]; then echo "PREFLIGHT: PASS (both boards ready)"; else echo "PREFLIGHT: FAIL (see above)"; fi
  return $overall
}

# ============================================================================
# SUBCOMMAND: ber -- THE MAIN LINK TEST (read-only-safe quality metric).
#   quiesce -> arm both on the quiet pair -> watchdogs -> qpsk_tun -B both ways
#   -> report frames_scored / bucket % / BER per direction + rstcs delta -> quiesce.
# Each board radiates its OWN fixed 128-byte reference and scores what IT
# receives: A(148) scores the FORWARD link (146->148), B(146) scores the REVERSE
# link (148->146). ~211.8 frames/s. NO S2MM capture anywhere.
# ============================================================================
cmd_ber(){
  hr "BER LINK TEST -- fwd 146->148 @${FWD_HZ}Hz / rev 148->146 @${REV_HZ}Hz, dur=${DUR}s"
  echo "-- quiesce both --"; quiesce
  echo "-- arm both on the quiet pair (parallel; DIFFERENT boards; one anyssh each) --"
  # arm_ber's last line is the byte-DMA arm (devmem 0x9D300000) that -B needs.
  arm_ber $B_IP $FWD_HZ $REV_HZ &   # B=146: Tx@FWD(2.00) Rx@REV(1.90)
  arm_ber $A_IP $REV_HZ $FWD_HZ &   # A=148: Tx@REV(1.90) Rx@FWD(2.00)
  wait
  # baseline rstcs right after arm, before the watchdog runs (read-only)
  local rb0 ra0
  ra0=$(rstcs_read $A_IP); rb0=$(rstcs_read $B_IP)
  echo "-- launch on-board lock watchdogs --"; launch_watchdogs
  echo "-- start qpsk_tun -B -d $DUR on BOTH boards (scratch -> /dev/shm/ber.log) --"
  $W $B_IP "cd /root/host_app_k5; setsid sh -c './qpsk_tun -B -d $DUR >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
  $W $A_IP "cd /root/host_app_k5; setsid sh -c './qpsk_tun -B -d $DUR >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
  # The -d window starts at arm, so the reported BER INCLUDES the lock-acquisition
  # transient. Raise -d (e.g. -d 90) for a more steady-state figure. Wait the run
  # duration + a small flush margin so the final qpsk_ber_report is written.
  local waits=$(( DUR + 10 ))
  echo "-- running (~${waits}s; -B scores the initial lock transient too) --"
  sleep "$waits"
  hr "BER RESULT"
  echo "--- FORWARD 146->148  (scored by A=$A_IP, Rx@${FWD_HZ}Hz) ---"
  $W $A_IP 'cat /dev/shm/ber.log' 2>/dev/null | grep -E 'full-packet report|frames_scored=|buckets:|^ber:' | tail -4
  echo
  echo "--- REVERSE 148->146  (scored by B=$B_IP, Rx@${REV_HZ}Hz) ---"
  $W $B_IP 'cat /dev/shm/ber.log' 2>/dev/null | grep -E 'full-packet report|frames_scored=|buckets:|^ber:' | tail -4
  echo
  local rb1 ra1
  ra1=$(rstcs_read $A_IP); rb1=$(rstcs_read $B_IP)
  echo "--- rstcs(0x150) delta over run (rxfix keeps this ~0; a big delta => reset storm / wrong image) ---"
  echo "  A=$A_IP : ${ra0:-?} -> ${ra1:-?}"
  echo "  B=$B_IP : ${rb0:-?} -> ${rb1:-?}"
  echo "-- quiesce --"; quiesce
  echo "=== BER DONE ==="
}

# ============================================================================
# SUBCOMMAND: tun -- bring up qpsk_tun -F on tun0 both ways + ping both dirs.
#   quiesce -> coldstart both (launches qpsk_tun -F + watchdog + sets tun0)
#   -> wait for lock -> ping both directions -> LEAVE UP (unless -k).
# ============================================================================
cmd_tun(){
  hr "TUN0 IP LINK -- quiet pair 2.00/1.90, WHITEN=$WHITEN"
  echo "-- quiesce both --"; quiesce
  echo "-- cold start both (parallel; each: qpsk_tun -F + watchdog + tun0 config) --"
  coldstart_tun $B_IP $FWD_HZ $REV_HZ $TUN_B $TUN_A &   # B=146 -> tun0 10.66.0.1
  coldstart_tun $A_IP $REV_HZ $FWD_HZ $TUN_A $TUN_B &   # A=148 -> tun0 10.66.0.2
  wait
  echo "-- waiting ~40s for watchdogs to lock + tun0 traffic --"; sleep 40
  link_snapshot
  hr "PING both directions"
  echo "NOTE: ping payloads are LOW-ENTROPY and will show loss even on a healthy"
  echo "      link. Judge link quality by 'ber' or 'ssh', NOT by ping."
  echo "=== PING 146->148 (B->A over RF) ==="; $W $B_IP 'ping -c 10 -W 3 10.66.0.2 2>&1 | tail -4' 2>/dev/null
  echo "=== PING 148->146 (A->B over RF) ==="; $W $A_IP 'ping -c 10 -W 3 10.66.0.1 2>&1 | tail -4' 2>/dev/null
  if [ "$TEARDOWN" = 1 ]; then
    echo "-- -k: tearing the link down --"; quiesce
  else
    echo "=== link left UP (tear down with -k, or './link_test.sh down') ==="
  fi
}

# ============================================================================
# SUBCOMMAND: ssh -- like tun, plus ed25519 pubkey (B=client, A=server) + ssh
# B->A over tun0 with minimal-KEX/robust options. LEAVE UP (unless -k).
# Pubkey setup + ssh invocation copied VERBATIM from tun_ssh_key.sh.
# ============================================================================
cmd_ssh(){
  hr "SSH OVER tun0 -- B=$B_IP client -> A=$A_IP server, quiet pair, WHITEN=$WHITEN"
  echo "-- quiesce both --"; quiesce

  # ---- Phase 1: ed25519 pubkey install OUT-OF-BAND over the wired LAN (no RF) --
  echo "-- Phase 1: SSH pubkey setup (out-of-band, wired LAN) --"
  $W $B_IP 'mkdir -p /root/.ssh; chmod 700 /root/.ssh; [ -f /root/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -q; echo "'$B_IP' keypair ready"' 2>/dev/null
  local PUB PUB_B64
  PUB=$($W $B_IP 'cat /root/.ssh/id_ed25519.pub' 2>/dev/null | tr -d '\r')
  echo "  client ($B_IP) pubkey: $PUB"
  PUB_B64=$(printf '%s' "$PUB" | base64 -w0)     # base64-safe transport of the key line
  $W $A_IP "mkdir -p /root/.ssh; chmod 700 /root/.ssh; touch /root/.ssh/authorized_keys
 K=\$(echo $PUB_B64 | base64 -d)
 grep -qF \"\$K\" /root/.ssh/authorized_keys || echo \"\$K\" >> /root/.ssh/authorized_keys
 chmod 600 /root/.ssh/authorized_keys
 echo \"  server authorized_keys lines: \$(wc -l < /root/.ssh/authorized_keys)\"
 echo \"  server PermitRootLogin: \$(sshd -T 2>/dev/null | grep -i '^permitrootlogin' || echo unknown)\"
 echo \"  server PubkeyAuthentication: \$(sshd -T 2>/dev/null | grep -i '^pubkeyauthentication' || echo unknown)\"
 [ -f /etc/ssh/ssh_host_ed25519_key.pub ] && echo '  server ed25519 hostkey present'" 2>/dev/null

  # ---- Phase 2: bring up the RF link (WHITEN=$WHITEN, same on both ends) ----
  echo "-- Phase 2: cold start both (parallel) --"
  coldstart_tun $B_IP $FWD_HZ $REV_HZ $TUN_B $TUN_A &
  coldstart_tun $A_IP $REV_HZ $FWD_HZ $TUN_A $TUN_B &
  wait
  echo "-- waiting ~40s for watchdogs to lock --"; sleep 40
  link_snapshot

  # ---- Phase 3: SSH client(B) -> server(A) over tun0 (10.66.0.2) ----
  hr "SSH $B_IP -> $A_IP over tun0 (root@10.66.0.2)  pubkey + minimal-KEX + robust"
  # Capture the transcript, then judge success by the RF-SSH-OK token the remote
  # login echoes -- NOT by exit status. (The remote shell's rc reflects the whole
  # pipeline, not ssh's own exit, so rc is a meaningless success signal here.)
  local sshout
  sshout=$($W $B_IP 'timeout 150 ssh -i /root/.ssh/id_ed25519 \
     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o PubkeyAuthentication=yes \
     -o HostKeyAlgorithms=ssh-ed25519 -o KexAlgorithms=curve25519-sha256 \
     -o Ciphers=chacha20-poly1305@openssh.com \
     -o ConnectTimeout=120 -o ConnectionAttempts=2 \
     -o ServerAliveInterval=5 -o ServerAliveCountMax=30 -o TCPKeepAlive=yes \
     -o LogLevel=ERROR -n \
     root@10.66.0.2 "echo RF-SSH-OK; hostname; uname -sr; uptime; cat /proc/loadavg" 2>&1' 2>/dev/null)
  printf '%s\n' "$sshout" | sed 's/^/  ssh> /'
  if printf '%s\n' "$sshout" | grep -q 'RF-SSH-OK'; then
    echo "=== SSH over RF: PASS (RF-SSH-OK received -- login succeeded over tun0) ==="
  else
    echo "=== SSH over RF: FAIL (no RF-SSH-OK -- key exchange likely timed out on the lossy link) ==="
    echo "    hint: retry, try -w (whitener on BOTH ends), or check 'ber' quality first"
  fi
  if [ "$TEARDOWN" = 1 ]; then
    echo "-- -k: tearing the link down --"; quiesce
  else
    echo "=== link left UP (tear down with -k, or './link_test.sh down') ==="
  fi
}

# ============================================================================
# Link characterization (perf / lat / mtu). All reuse quiesce + coldstart_tun
# + link_snapshot VERBATIM (no new register writes). Results bundle into
# hunt/<ts>_linkchar/. iperf3 is native on both boards; qpsk_perf is pushed +
# built on-board (control-free UDP -- results harvested over the wired LAN).
# ============================================================================
linkchar_bundle(){ OUT="$DIR/hunt/$(date +%Y%m%d_%H%M%S)_linkchar"; mkdir -p "$OUT"; echo "$OUT"; }

# push + build qpsk_perf on both boards (idempotent; sources over wired LAN)
provision_perf(){
  local ip
  for ip in "$A_IP" "$B_IP"; do
    scpput "$DIR/../host/qpsk_perf.c" root@$ip:/root/host_app_k5/qpsk_perf.c 2>/dev/null
    $W $ip 'cd /root/host_app_k5 && gcc -O2 -Wall -o qpsk_perf qpsk_perf.c 2>&1 | head -3; ./qpsk_perf --selftest 2>&1 | tail -1' 2>/dev/null | sed "s/^/  $ip: /"
  done
}

# one UDP rung: receiver runs -s -e (background), sender runs -c; harvest both.
# $1 rx_ip $2 tx_ip $3 rx_tun $4 rate_bps $5 dur $6 tag $7 outdir
udp_rung(){
  local rxip=$1 txip=$2 rxtun=$3 rate=$4 dur=$5 tag=$6 out=$7
  $W $rxip "setsid sh -c '/root/host_app_k5/qpsk_perf -s -e -p 5001 > /dev/shm/perf_srv.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
  sleep 1
  $W $txip "/root/host_app_k5/qpsk_perf -c $rxtun -e -b $rate -l 88 -t $dur -p 5001 2>&1 | tail -3" 2>/dev/null | sed "s/^/  [$tag] /"
  $W $rxip 'pkill -f "[q]psk_perf -s"' 2>/dev/null
  $W $rxip 'cat /dev/shm/perf_srv.log' 2>/dev/null > "$out/udp_${tag}_srv.log"
  grep -m1 rstcs "$out/../.." >/dev/null 2>&1 || true
}

cmd_perf(){
  hr "UDP THROUGHPUT LADDER -- quiet pair, WHITEN=$WHITEN"
  local OUT; OUT=$(linkchar_bundle); echo "bundle: $OUT"
  echo "-- quiesce + provision qpsk_perf --"; quiesce; provision_perf
  coldstart_tun $B_IP $FWD_HZ $REV_HZ $TUN_B $TUN_A &
  coldstart_tun $A_IP $REV_HZ $FWD_HZ $TUN_A $TUN_B &
  wait
  echo "-- lock settle 40s --"; sleep 40; link_snapshot | tee "$OUT/snapshot_pre.txt"
  local dur=${PERF_DUR:-60}
  for rate in 25000 50000 75000 100000 125000 145000 160000 180000; do
    hr "rung ${rate} bps ($dur s each dir)"
    udp_rung $A_IP $B_IP $TUN_A $rate $dur "fwd_${rate}" "$OUT"   # B->A forward
    udp_rung $B_IP $A_IP $TUN_B $rate $dur "rev_${rate}" "$OUT"   # A->B reverse
  done
  echo "-- iperf3 TCP characterization (native, expected-fragile, not a gate) --"
  $W $A_IP "setsid sh -c 'iperf3 -s -1 -p 5201 >/dev/shm/iperf_srv.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null; sleep 1
  $W $B_IP "iperf3 -c $TUN_A -p 5201 -t 30 -J 2>/dev/null" 2>/dev/null > "$OUT/tcp_fwd.json" || echo "  TCP-CONTROL-FAIL fwd"
  link_snapshot | tee "$OUT/snapshot_post.txt"
  [ "$TEARDOWN" = 1 ] && quiesce
  echo "PERF_DONE $OUT"
}

cmd_lat(){
  hr "LATENCY MATRIX -- quiet pair, WHITEN=$WHITEN"
  local OUT; OUT=$(linkchar_bundle); echo "bundle: $OUT"
  echo "-- quiesce + provision --"; quiesce; provision_perf
  coldstart_tun $B_IP $FWD_HZ $REV_HZ $TUN_B $TUN_A &
  coldstart_tun $A_IP $REV_HZ $FWD_HZ $TUN_A $TUN_B &
  wait
  echo "-- lock settle 40s --"; sleep 40; link_snapshot | tee "$OUT/snapshot_pre.txt"
  local N=${LAT_N:-200}
  for s in 8 16 32 56 88 120 200; do
    echo "=== payload -s $s (fwd B->A) ==="
    $W $B_IP "ping -c $N -i 0.2 -s $s -W 2 10.66.0.2 2>&1 | tail -3" 2>/dev/null | tee "$OUT/ping_fwd_s${s}.log"
    $W $A_IP "ping -c $N -i 0.2 -s $s -W 2 10.66.0.1 2>&1 | tail -3" 2>/dev/null > "$OUT/ping_rev_s${s}.log"
  done
  for iv in 1.0 0.2 0.05; do
    echo "=== interval -i $iv -s32 (fwd) ==="
    $W $B_IP "ping -c $N -i $iv -s 32 -W 2 10.66.0.2 2>&1 | tail -3" 2>/dev/null | tee "$OUT/ping_fwd_i${iv}.log"
  done
  echo "=== app-level qpsk_perf -e RTT (fwd, 200 echoes @ 100kbps) ==="
  udp_rung $A_IP $B_IP $TUN_A 100000 10 "rtt_fwd" "$OUT"
  link_snapshot | tee "$OUT/snapshot_post.txt"
  [ "$TEARDOWN" = 1 ] && quiesce
  echo "LAT_DONE $OUT"
}

cmd_mtu(){
  hr "MTU EDGE FRAMES -- quiet pair, WHITEN=$WHITEN"
  local OUT; OUT=$(linkchar_bundle); echo "bundle: $OUT"
  echo "-- quiesce --"; quiesce
  coldstart_tun $B_IP $FWD_HZ $REV_HZ $TUN_B $TUN_A &
  coldstart_tun $A_IP $REV_HZ $FWD_HZ $TUN_A $TUN_B &
  wait
  echo "-- lock settle 40s --"; sleep 40; link_snapshot | tee "$OUT/snapshot_pre.txt"
  # -s 88 = 1 frame (88+28=116=MTU); -s 200 fragments; -M do -s 200 rejects
  for spec in "88 one-frame" "89 two-frame" "200 fragmented" "-M do -s 200 dont-frag"; do
    set -- $spec
    if [ "$1" = "-M" ]; then
      echo "=== ping -M do -s 200 (expect frag-needed reject) ==="
      $W $B_IP "ping -c 5 -M do -s 200 -W 2 10.66.0.2 2>&1 | tail -4" 2>/dev/null | tee "$OUT/mtu_dontfrag.log"
    else
      local sz=$1; shift; local label="$*"
      echo "=== ping -s $sz ($label) ==="
      $W $B_IP "ping -c 10 -s $sz -W 2 10.66.0.2 2>&1 | tail -3" 2>/dev/null | tee "$OUT/mtu_s${sz}.log"
    fi
  done
  [ "$TEARDOWN" = 1 ] && quiesce
  echo "MTU_DONE $OUT"
}

# ============================================================================
# SUBCOMMAND: status -- read modem regs on both boards WITHOUT arming.
# ============================================================================
cmd_status(){
  hr "MODEM STATUS (no arm) -- A=$A_IP  B=$B_IP"
  local ip label
  for ip in "$A_IP" "$B_IP"; do
    [ "$ip" = "$A_IP" ] && label="A" || label="B"
    echo "--- Board $label = $ip ---"
    $W $ip '
      DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
      echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
      rd(){ echo "$1" > $DRA 2>/dev/null; cat $DRA 2>/dev/null; }
      RSSI=$(cat /sys/bus/iio/devices/iio:device2/in_voltage0_rssi 2>/dev/null | cut -d" " -f1)
      echo "  cap_out(0x144)=$(rd 0x144)  packets_out(0x104)=$(rd 0x104)  rstcs(0x150)=$(rd 0x150)"
      echo "  cfc(0x154)=$(rd 0x154)  level(0x15C)=$(rd 0x15C)  rssi=$RSSI"
    ' 2>/dev/null
  done
}

# ============================================================================
# argument parsing
# ============================================================================
SUB=${1:-}
[ -n "$SUB" ] && shift || true

while getopts "A:B:d:f:r:wkh" opt; do
  case "$opt" in
    A) A_IP=$OPTARG ;;
    B) B_IP=$OPTARG ;;
    d) DUR=$OPTARG ;;
    f) FWD_HZ=$(( OPTARG * 1000000 )) ;;   # MHz -> Hz
    r) REV_HZ=$(( OPTARG * 1000000 )) ;;   # MHz -> Hz
    w) WHITEN=1 ;;
    k) TEARDOWN=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

# SAFETY GUARD (constraint #4): the two boards arm IN PARALLEL. If A_IP and B_IP
# collide (fat-fingered override), that would open TWO concurrent profile-reload +
# register-poke sessions to the SAME board -> can wedge it (physical reflash only).
if [ "$A_IP" = "$B_IP" ]; then
  echo "FATAL: A_IP and B_IP are both '$A_IP' -- they MUST differ." >&2
  echo "       (parallel arm would open two concurrent sessions to one board and can wedge it)" >&2
  exit 2
fi

case "$SUB" in
  preflight) cmd_preflight ;;
  ber)       cmd_ber ;;
  tun)       cmd_tun ;;
  ssh)       cmd_ssh ;;
  perf)      cmd_perf ;;
  lat)       cmd_lat ;;
  mtu)       cmd_mtu ;;
  status)    cmd_status ;;
  down|clean) hr "TEAR DOWN"; quiesce; echo "=== down ===" ;;
  -h|--help|"") usage; exit 0 ;;
  *) echo "unknown subcommand: '$SUB'" >&2; usage; exit 2 ;;
esac
