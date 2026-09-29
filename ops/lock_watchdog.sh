#!/bin/sh
# lock_watchdog.sh -- ON-BOARD modem acquisition watchdog (busybox ash).
#
# Fixes the "armed-before-signal never locks" wedge: the RX AGC winds up/wraps on
# noise, firing rstCS continuously so the carrier loop is pinned; a bare 0x110
# rstCS pulse cannot clear it (AGC re-pins on the next cycle). Only a full 0x000
# soft-reset re-arm clears the AGC accumulator -- and only recovers if a signal is
# present at the reset instant. So: detect CYCLING-WITH-SIGNAL and issue a full
# re-arm; wait (don't re-arm) on noise.
#
# Runs independently of qpsk_tun: the daemon owns only the byte DMAs (0x9D1/2/3..)
# via /dev/mem; this watchdog owns only the modem regfile (0x9D000000) via debugfs.
# Disjoint -> zero contention. A 0x000 re-arm does NOT clear byte_ctrl_gpio, so the
# daemon rides out the brief RX gap on its -F keepalive.
#
# Launch (per board):  setsid nohup /root/lock_watchdog.sh > /dev/shm/watchdog.log 2>&1 &
# Env overrides: PERIOD RSTCS_THRESH LEVEL_THRESH HOLDOFF DAEMON_CMD VERBOSE
set -u
# --- per-board persistent overrides (2026-09-23) -----------------------------
# Sourced FIRST, before every knob below, and with UNCONDITIONAL assignment, so a
# board-local file beats the launch environment. That precedence is deliberate:
# bringup_r2r3.sh hardcodes the watchdog's launch env, so an env-only override is
# silently lost on the next bring-up -- which is how 146 kept coming back up with
# a knob it must not have. /root/watchdog.conf survives bring-ups.
# 146 needs BYTE_WD=0 here: its pre-fsv2 bitstream does not implement 0x1C0.
# RXPIN="clk i q strobe" (task-GLITCH, 2026-09-23): every rearm_once does a 0x000
# soft reset, which re-runs the driver's rx0 SSI auto-tune and silently reverts
# any RXPIN override apply_146_ssi_fix.sh applied at bring-up time (146's
# auto-tune lands on clk=0, a bad eye position -> PAYLOAD-WEDGE loop that never
# clears because every recovery attempt re-introduces the fault it's recovering
# from). Set RXPIN here so pin_rx0 (below) re-asserts it after every re-arm, the
# same way /root/watchdog.conf already survives bring-ups for BYTE_WD.
RXPIN=${RXPIN:-}
[ -r /root/watchdog.conf ] && . /root/watchdog.conf
LOGFILE=${LOGFILE:-/dev/shm/watchdog.log}
exec >>"$LOGFILE" 2>&1        # capture EVERYTHING (incl. errors) so a background launch is debuggable
echo "[wd] === STARTING $(date +%H:%M:%S) pid=$$ ==="
PERIOD=${PERIOD:-5}            # measurement window (s): rstcs delta measured across this
PKT_MIN=${PKT_MIN:-50}        # 0x104 packets/window >= this => the link is DECODING (locked/working)
RSTCS_THRESH=${RSTCS_THRESH:-8} # 0x150 delta (logged for diagnosis; NOT a lock gate -- a marginal
                                # link cycles rstcs yet still decodes, and re-arming it would disrupt it)
STORM_THRESH=${STORM_THRESH:-100} # 0x150 delta/window >= this => reset STORM: the demod is re-firing
                                # ~2x per frame and 0x104 counts CRC-FAILING framesyncs, so dpkt alone
                                # lies "locked" while nothing decodes (DEPLOY-A2 finding). A working
                                # marginal link cycles rstcs at ~order-10/window; storms measure 160-360.
BIST_GATE=${BIST_GATE:-0}       # 1 = ROM/BIST mode: also gate on cap_out/biterr quality
GOLDEN=${GOLDEN:-0x04922282}    # ROM/BIST cap_out (0x144) when decoding correctly
BITERR_MAX=${BITERR_MAX:-8000}  # 0x108 delta/window tolerated in ROM mode. Measured:
                                # healthy 400-900/window at PERIOD=5, wedged ~34600.
LEVEL_THRESH=${LEVEL_THRESH:-12} # 0x15C levelLog >= this => a lockable signal is present
HOLDOFF=${HOLDOFF:-10}        # settle seconds after a re-arm before the next decision
FAIL_N=${FAIL_N:-2}           # re-arm only after this many CONSECUTIVE not-locked windows (debounce peer-blips)
# --- CARRIER-WEDGE (byte-flip / sync-at-rate) detector, 2026-09-23 -----------------
# The wedge this catches: 0x104 frames at 76-79% of nominal while 0x150 cycles steadily
# and EVERY payload slice fails CRC (crc_drop == slices, exactly). dpkt stays far above
# PKT_MIN and drst stays under STORM_THRESH, so both existing gates read it as LOCKED.
# Measured on 146 over 8798 windows / 16.4 h (2026-09-22/23), the two populations are
# disjoint on BOTH axes -- this is the calibration, do not retune without re-measuring:
#     healthy  18 windows : drstcs = 0 exactly       dpkts 6108..6250
#     wedged 8780 windows : drstcs 10..92 (med 40)   dpkts 4067..4969
# Thresholds sit in the 4969..6108 gap and just above healthy's flat 0.
# The CONJUNCTION is what makes this safe: a marginal-but-working link also cycles
# rstcs (~order-10/window per STORM_THRESH's note) but keeps framing at full rate, so
# it fails the dpkts half and is never re-armed. Neither half alone is specific.
WEDGE_WD=${WEDGE_WD:-1}         # 0 = disable this detector entirely
WEDGE_RSTCS=${WEDGE_RSTCS:-10}  # 0x150 delta/window >= this (healthy is a flat 0; wedge min was 10)
WEDGE_PKT=${WEDGE_PKT:-5500}    # AND 0x104 delta/window < this (wedge max 4969, healthy min 6108)
WEDGE_FAIL_N=${WEDGE_FAIL_N:-4} # consecutive wedge windows before re-arming (~19 s of confirmation).
                                # PERSISTENCE is the real discriminator, not the thresholds. Replayed over
                                # the same 16.4 h on BOTH boards: 146's wedge ran 8780 consecutive flagged
                                # windows; healthy 148 threw isolated transients (dpkts 1641-2345, drstcs
                                # 39-89) whose longest run was 2 and which self-cleared in one window.
                                # N=3 already gives 0 false re-arms on 148; 4 leaves two windows of margin
                                # because a false re-arm is not merely wasted -- per the double-tap note at
                                # :77-82 a 0x000 taken while the peer is mid-recovery can LATCH the very
                                # wedge we are trying to cure. Detection latency is 19 s vs a 2-min bring-up.
WEDGE_MAX_TRY=${WEDGE_MAX_TRY:-3}    # consecutive re-arms that fail to clear it -> stop and back off
WEDGE_BACKOFF=${WEDGE_BACKOFF:-300}  # ... for this long, rather than thrash and blip the peer

# --- STORM path anti-thrash, 2026-09-23 --------------------------------------
# MEASURED FAILURE this is for: on 148, 2026-09-23 11:56 onward, the NOT-LOCKED
# branch below fired FULL RE-ARM 13 times in ~5 min with a STATIONARY result
# (drstcs pinned 142..355, dpkts pinned 2336..2549 across every attempt). The
# branch had no cap and no backoff, so it re-armed forever. That is not merely
# wasted: 0x000 is a WHOLE-MODEM soft reset, so each attempt also blips THIS
# board's TX -- which is the peer's receive signal. Per the double-tap note in
# full_rearm(), a demod reset taken while the peer's TX is mid-recovery latches
# a false state in the peer. Two coupled watchdogs can therefore hold each other
# down indefinitely, which is exactly what 146 (100% CRC, zero payload) showed
# while 148 was in this loop. The cure for a storm is LOCAL-RX only; if three
# tries have not taken, the fault is not on this side and the useful action is
# to HOLD STILL and let the peer acquire against a steady carrier.
STORM_MAX_TRY=${STORM_MAX_TRY:-3}    # consecutive NOT-LOCKED re-arms before backing off
STORM_BACKOFF=${STORM_BACKOFF:-120}  # hold-still window (s). Long enough for the peer to
                                     # acquire (bring-up acquires in seconds), short enough
                                     # that a genuinely recoverable storm retries promptly.

# --- PAYLOAD-WEDGE detector, 2026-09-23 --------------------------------------
# The ground-truth "no video" signal, and the ONLY detector here that catches both
# known presentations of the byte-flip wedge:
#   (a) 2026-09-22 on 146: drstcs 10..92, dpkts 4067..4969  -> CARRIER-WEDGE sees it
#   (b) 2026-09-23 on 146: drstcs = 0,    dpkts = 6244      -> CARRIER-WEDGE is BLIND.
#       Both register-plane gates read (b) as perfectly healthy and printed LOCKED
#       while dma_rx_ok=0, idle_rx=0 and crc_drop climbed to 235280. Framing counters
#       cannot see this: 0x104 counts framesyncs that then fail CRC.
# So score the PAYLOAD plane, where "no video" is defined: crc_drop ADVANCING while
# idle_rx AND dma_rx_ok are both frozen == every slice carved is failing CRC.
# crc_drop advancing is the load-bearing half -- it is what distinguishes a wedge
# from a quiet/just-started link (all three frozen), which is the case the old
# DELIVERY-WEDGE guard [ "$irx" -gt 0 ] was reaching for and got wrong.
# Costs nothing: reads /dev/shm/qpsk_tun.log, never direct_reg_access.
PAYLOAD_WD=${PAYLOAD_WD:-1}
PAYLOAD_FAIL_N=${PAYLOAD_FAIL_N:-3}    # consecutive windows (~19 s) before acting
PAYLOAD_MAX_TRY=${PAYLOAD_MAX_TRY:-3}
PAYLOAD_BACKOFF=${PAYLOAD_BACKOFF:-120}
# task-CHAIN (2026-09-24): a re-arm that only PARTIALLY recovers lets the payload
# counters advance for one poll, which used to zero pfails/parms via the PAYLOAD-OK
# veto below -- so the next wedge restarted the PAYLOAD_FAIL_N detection from scratch
# and `parms` never reached 2. Measured on 146: 3 of 10 re-arms came back DIRTY
# (drstcs 795/837/1401, dpkts ~3500, vs drstcs=0 dpkts~6240 when cured), and all three
# chained into a second full detect+re-arm round -- 94 s and 105 s outages against
# ~15-20 s when a re-arm cures first try. Every re-arm in that log read "attempt 1/3",
# so PAYLOAD_MAX_TRY/PAYLOAD_BACKOFF ("suspect the PEER TX") were unreachable.
# Fix: keep the veto, but only forget the re-arm history once the link is GENUINELY
# clean. drstcs separates the two states cleanly -- 189 of 202 LOCKED samples read
# exactly 0, lowest dirty reading 55 -- so 32 is a safe floor with headroom.
PAYLOAD_CLEAN_DRSTCS=${PAYLOAD_CLEAN_DRSTCS:-32}  # <= this => the link really is clean
PAYLOAD_CLEAN_N=${PAYLOAD_CLEAN_N:-3}             # or this many advancing polls in a row
PAYLOAD_FASTRETRY=${PAYLOAD_FASTRETRY:-0}          # 1 = re-arm at once when a re-arm lands half-rate
# task-ONSET (measured 2026-09-24 on 146, n=5 blackouts): at the ONSET poll the register
# plane already reads drstcs 1647-1844 with dpkts 3122-3237 (exactly half of 6250) while
# the payload counters advance for ONE last poll. The PAYLOAD-OK veto below hands that
# poll a free pass, so the wedge is only confirmed two polls later and ~8 s of the
# measured 18.5 s detect is latency rather than fault. That reading is 6x worse than the
# drstcs=274 / dpkts=2444 false positive on 148 that the veto exists to prevent, so a
# CATASTROPHIC register reading counts a strike instead of a free pass. The threshold
# sits 2.9x above that false positive and below all four clean onsets; the fifth
# (drstcs=632 dpkts=5114) is deliberately NOT caught -- margin over the FP wins.
PAYLOAD_ONSET_WD=${PAYLOAD_ONSET_WD:-1}            # 0 = disable, restoring the old free pass
PAYLOAD_ONSET_DRSTCS=${PAYLOAD_ONSET_DRSTCS:-800}  # drstcs >= this AND dpkts < PAYLOAD_ONSET_PKT
PAYLOAD_ONSET_PKT=${PAYLOAD_ONSET_PKT:-5500}       # ... == the half-rate onset signature
# PAYLOAD_LIGHT_FIRST (2026-09-24): try light_rearm before full_rearm on a
# PAYLOAD-WEDGE.  DEFAULT NOW 0 (was unconditionally on).  Measured on 146 from
# this watchdog's own log:
#     13:30:29 LIGHT RE-ARM  -> PAYLOAD-WEDGE #1/3 again 14 s later (no effect)
#     13:30:59 FULL RE-ARM   -> 13:31:58 PAYLOAD-OK, counters advancing (cleared)
# A bare 0x110 rstCS pulse cannot clear this fault because the fault is a byte
# -phase displacement in the host RX drain, not a carrier-sync problem; only the
# 0x000 soft reset restarts the byte pipeline.  Trying it first burned a whole
# PAYLOAD_FAIL_N confirmation cycle (~25 s) per stall, which is why stall runs
# measured 60 s (light cycle wasted + full cycle) instead of ~30 s.
# Set PAYLOAD_LIGHT_FIRST=1 to restore the 2026-09-23 behaviour for the periodic
# ~100 s RX glitch it was originally written for.

# --- tun0 re-addressing after a daemon relaunch, 2026-09-23 ------------------
# Every qpsk_tun relaunch from DAEMON_CMD recreates tun0 UNADDRESSED: DAEMON_CMD
# carries only the daemon invocation, while bringup_r2r3.sh:183 follows its own
# launch with "ip addr replace <local> peer <peer> dev tun0 / ip link set up mtu
# 1516 / ip route replace". So any DELIVERY-WEDGE fire or dead-daemon relaunch
# silently drops the board off the tunnel -- observed on 146 on 2026-09-23 (tun0
# with no IPv4 after a single DELIVERY fire). Set these and the addressing is
# restored with the relaunch. Empty = disabled, so behaviour is unchanged for any
# caller that does not set them.
TUN_IF=${TUN_IF:-tun0}
TUN_LOCAL=${TUN_LOCAL:-}      # e.g. 10.66.0.1   (this board)
TUN_PEER=${TUN_PEER:-}        # e.g. 10.66.0.2   (the other board)
TUN_MTU=${TUN_MTU:-1516}
DAEMON_LOG=${DAEMON_LOG:-/dev/shm/qpsk_tun.log}
DAEMON_CMD=${DAEMON_CMD:-}    # if set, relaunched when qpsk_tun dies (else daemon left to its own supervisor)
VERBOSE=${VERBOSE:-1}

# --- locate the modem regfile (mwipcore*, fallback iio:device0) and the tx-lpc DAC mux ---
MW=""
for d in /sys/bus/iio/devices/iio:device*; do
  case "$(cat "$d/name" 2>/dev/null)" in mwipcore*) MW=${d##*/}; break;; esac
done
[ -n "$MW" ] || MW=iio:device0
echo enabled > /sys/bus/iio/devices/$MW/reg_access 2>/dev/null
DRA=/sys/kernel/debug/iio/$MW/direct_reg_access
TXD=""
for d in /sys/bus/iio/devices/iio:device*; do
  [ "$(cat "$d/name" 2>/dev/null)" = axi-adrv9002-tx-lpc ] && TXD=${d##*/}
done
T=/sys/kernel/debug/iio/$TXD/direct_reg_access
[ -e "$DRA" ] || { echo "[wd] FATAL: no modem direct_reg_access at $DRA"; exit 1; }

rd(){ echo "$1" > "$DRA"; cat "$DRA"; }            # read a modem reg -> "0x...."
# stats_line: the LAST "qpsk_tun stats" line. NEVER tail -1 the raw log: the daemon
# interleaves "qpsk_tun nakstat:" lines after every stats line, so tail -1 returns a
# line with no idle_rx/dma_rx_ok fields, the awk sums to 0, and the >0 guard disarms
# the detector PERMANENTLY. This exact bug made the host-wedge backstop structurally
# inert through seven live delivery wedges (2026-08-24/25, #48 class).
stats_line(){ grep "qpsk_tun stats" "$DAEMON_LOG" 2>/dev/null | tail -1; }
h2d(){ echo $(( $1 )); }                            # "0x2F" -> 47 (ash parses 0x)
log(){ echo "[wd $(date +%H:%M:%S)] $*"; }   # stdout is exec-redirected to $LOGFILE

# AGC/RSSI snapshot (task-GLITCH Option 2, 2026-09-23): 0x15C's "lvl" field goes
# to 0 during a payload wedge (it's fed by the same demod fabric that's stuck),
# so it can't tell a real signal dropout from a digital/framing wedge with a
# perfectly healthy front end. The analog AGC loop (in_voltage0_rssi/hardwaregain
# on the phy, iio:device2) runs independently of the wedged fabric and keeps
# reporting real numbers throughout -- read-only, no register writes. Logged on
# every LOCKED/WEDGE line to build a timeline correlating AGC state with wedge
# onset/duration, to find what (if anything) precedes/causes the freeze.
AGC_P=/sys/bus/iio/devices/iio:device2
agc(){
  [ -r "$AGC_P/in_voltage0_rssi" ] || { echo "agc=n/a"; return 0; }
  echo "rssi=$(cat "$AGC_P/in_voltage0_rssi" 2>/dev/null) gain=$(cat "$AGC_P/in_voltage0_hardwaregain" 2>/dev/null) mode=$(cat "$AGC_P/in_voltage0_gain_control_mode" 2>/dev/null)"
}

# Re-apply tun0 addressing after a relaunch. Mirrors bringup_r2r3.sh:182-183
# exactly (same wait loop, same addr/link/route triple) so a watchdog-relaunched
# daemon lands in the same network state as a bring-up-launched one.
# "ip addr replace" is idempotent, so this is safe to call unconditionally.
restore_tun(){
  [ -n "$TUN_LOCAL" ] && [ -n "$TUN_PEER" ] || return 0
  n=0
  while [ "$n" -lt 20 ]; do ip link show "$TUN_IF" >/dev/null 2>&1 && break; n=$(( n + 1 )); sleep 0.5; done
  if ! ip link show "$TUN_IF" >/dev/null 2>&1; then
    log "  -> $TUN_IF never appeared; cannot restore addressing"; return 1
  fi
  ip addr replace "$TUN_LOCAL" peer "$TUN_PEER" dev "$TUN_IF"
  ip link set "$TUN_IF" up mtu "$TUN_MTU"
  ip route replace "$TUN_PEER" dev "$TUN_IF" advmss 1476 rto_min 25ms 2>/dev/null
  if ip -4 addr show dev "$TUN_IF" 2>/dev/null | grep -q "inet "; then
    log "  -> restored $TUN_IF ($TUN_LOCAL peer $TUN_PEER mtu $TUN_MTU)"
  else
    log "  -> WARNING: $TUN_IF still has no IPv4 after restore attempt"
  fi
}

# PIN-LAST rx0 (task-GLITCH, mirrors apply_146_ssi_fix.sh step (f) exactly): the
# per-field debugfs files are a WRITE CACHE never synced from hardware, so the
# whole rx0/rx1/tx0/tx1 struct must be re-populated from a FRESH live read before
# overriding rx0, or every untouched field gets silently zeroed. Must run LAST,
# after every register write in rearm_once -- a 0x000/0x110 write taken behind
# this pin reverts it (Task 61).
SSI_B=/sys/kernel/debug/iio/iio:device2
pin_rx0(){
  [ -n "$RXPIN" ] || return 0
  [ -e "$SSI_B/ssi_delays" ] || return 0
  set -- $RXPIN; RC=$1; RI=$2; RQ=$3; RS=$4
  LIVE=$(cat "$SSI_B/ssi_delays")
  g(){ echo "$LIVE" | awk -F": " -v k="$1" "\$1==k{print \$2}"; }
  for ch in rx0 rx1 tx0 tx1; do
    echo "$(g ${ch}_ClkDelay)"     > "$SSI_B/${ch}_ssi_clk_delay"
    echo "$(g ${ch}_StrobeDelay)"  > "$SSI_B/${ch}_ssi_strobe_delay"
    echo "$(g ${ch}_rxIDataDelay)" > "$SSI_B/${ch}_ssi_i_data_delay"
    echo "$(g ${ch}_rxQDataDelay)" > "$SSI_B/${ch}_ssi_q_data_delay"
  done
  echo "$(g tx0_RefClkDelay)" > "$SSI_B/tx0_ssi_refclk_delay"
  echo "$(g tx1_RefClkDelay)" > "$SSI_B/tx1_ssi_refclk_delay"
  echo "$RC" > "$SSI_B/rx0_ssi_clk_delay"
  echo "$RI" > "$SSI_B/rx0_ssi_i_data_delay"
  echo "$RQ" > "$SSI_B/rx0_ssi_q_data_delay"
  echo "$RS" > "$SSI_B/rx0_ssi_strobe_delay"
  echo 1 > "$SSI_B/ssi_delays"
  NOW=$(cat "$SSI_B/ssi_delays" | awk -F": " '$1=="rx0_ClkDelay"{print $2}')
  [ "$NOW" = "$RC" ] && log "  -> rx0 re-pinned $RC/$RI/$RQ/$RS" \
                     || log "  -> RXPIN-FAIL: rx0_ClkDelay live=$NOW want=$RC"
}
rearm_once(){
  echo "0x000 0x1" > "$DRA"; sleep 0.5; echo "0x000 0x0" > "$DRA"
  echo "0x158 0x1" > "$DRA"                          # tx_data_source = byte DMA (regfile reverted by 0x000)
  echo "0x118 0x0" > "$DRA"                          # tx_source_select = in-FPGA Tx
  echo "0x114 0x1" > "$DRA"                          # rx_input_select = air
  if [ -n "$TXD" ]; then echo "0x418 0x2" > "$T"; echo "0x458 0x2" > "$T"; echo "0x044 0x1" > "$T"; fi
  echo "0x110 0x1" > "$DRA"; sleep 0.3; echo "0x110 0x0" > "$DRA"   # carrier-sync reset
  pin_rx0                                            # LAST: nothing writes a register after this
}
# LIGHT RE-ARM (task-GLITCH, 2026-09-23): a single rstCS pulse, no 0x000 soft
# reset. For PAYLOAD-WEDGE specifically -- NOT CARRIER-WEDGE, see the AGC note
# above full_rearm -- the carrier is often still locked or near-locked (drstcs
# staying under a few hundred, dpkts still nonzero before freezing) and only the
# byte/payload plane needs a nudge. 0x000 is a whole-modem soft reset (blips the
# peer, and on 146 re-runs the SSI auto-tune that pin_rx0 then has to undo); a
# bare 0x110 rstCS pulse does neither. Tried first on the periodic ~100s 146 RX
# glitch (2026-09-23) that full_rearm always cleared but at a 20-40s cost.
light_rearm(){
  log "LIGHT RE-ARM (0x110 rstCS pulse only, no soft reset)"
  echo "0x110 0x1" > "$DRA"; sleep 0.3; echo "0x110 0x0" > "$DRA"
}
full_rearm(){                                       # 0x000 soft reset clears the wound AGC
  log "FULL RE-ARM (0x000 soft reset + re-select + rstCS, double-tap)"
  rearm_once
  # DOUBLE-TAP (task-ARMCAUSE): a demod reset taken while the peer's TX is
  # garbage/mid-recovery LATCHES a false FTS state (sync ~40%, cfc dither,
  # rstcs calm) that only another 0x000 clears. Second pulse ~3 s later
  # re-rolls acquisition once this side's own TX (and typically the peer's
  # recovery) is continuous again -- makes coupled-watchdog recovery
  # convergent instead of thrash-prone.
  if [ "${DOUBLETAP:-1}" = 1 ]; then sleep 3; rearm_once; fi
}

log "watchdog up: MW=$MW TXD=${TXD:-none} PERIOD=${PERIOD}s PKT_MIN=$PKT_MIN FAIL_N=$FAIL_N HOLDOFF=${HOLDOFF}s BIST_GATE=$BIST_GATE"
fails=0
wfails=0
warms=0
sarms=0
pfails=0
parms=0
pokrun=0
while :; do
  # (1) daemon dead -> relaunch (re-arming the modem won't fix a dead daemon)
  if [ -n "$DAEMON_CMD" ] && ! pgrep -x qpsk_tun >/dev/null 2>&1; then
    log "qpsk_tun dead -> relaunch: $DAEMON_CMD"
    (cd /root/host_app_k5 2>/dev/null; setsid nohup sh -c "$DAEMON_CMD" >"$DAEMON_LOG" 2>&1 &)
    restore_tun
    sleep "$HOLDOFF"; continue
  fi

  # (2) measure lock over the window
  r0=$(h2d "$(rd 0x150)"); p0=$(h2d "$(rd 0x104)"); be0=$(h2d "$(rd 0x108)")
  sleep "$PERIOD"
  r1=$(h2d "$(rd 0x150)"); p1=$(h2d "$(rd 0x104)"); lvl=$(( ( $(rd 0x15C) >> 24 ) & 255 ))
  drst=$(( r1 - r0 )); dpkt=$(( p1 - p0 ))
  # LOCKED = the modem is DECODING packets (0x104 advancing >= PKT_MIN) AND not in a
  # reset STORM. 0x104 counts framesyncs even when every frame fails CRC, so dpkt alone
  # is fooled by a storm (drst >= STORM_THRESH: ~2 resets/frame, nothing decodes --
  # DEPLOY-A2). Small rstcs cycling is still NOT gated on: a marginal link cycles
  # rstcs yet keeps decoding, and re-arming it (0x000) would break a working link AND
  # blip the peer. The armed-on-noise wedge is dpkt=0 -> caught here.
  # levelLog is not used either (the analog Rx AGC amplifies noise to the same rail).
  locked=0; [ "$dpkt" -ge "$PKT_MIN" ] && [ "$drst" -lt "$STORM_THRESH" ] && locked=1

  # BIST QUALITY GATE (2026-08-11) -- OPT-IN, default OFF.
  # dpkt counts framesyncs, not correct frames, so a carrier wedge still emitting
  # ~630 pkt/s reads 12x over PKT_MIN and passes. The HOST-WEDGE check below is the
  # existing quality test but is guarded on qpsk_tun running, and ROM/BIST bring-up
  # deliberately kills the daemon -- so in that mode nothing checked quality at all.
  # Measured 2026-08-10: 149/149 wedged windows, never once NOT-LOCKED.
  #
  # WHY OPT-IN AND NOT MODE-DETECTED: 0x144/0x108 are BIST quantities scored against the
  # ROM pattern and are only meaningful when the TX source IS the ROM. The obvious test
  # -- read tx_data_source (0x158) -- DOES NOT WORK: 0x158 is WRITE-ONLY. Verified by
  # writing 1 then 0 and reading 0x0 both times, while 0x144 returned live values. A
  # mode-detecting version of this gate was therefore always-true and would have re-armed
  # a HEALTHY byte-mode link every window (cap_out is legitimately != golden there),
  # which is far worse than the blindness it replaces -- a re-arm disrupts the link and
  # blips the peer. So the caller states the mode explicitly.
  #   BIST_GATE=1  -> ROM/BIST soaks (reverse_rom_soak, carrier work)
  #   unset        -> production byte mode; gate inert, behaviour identical to before
  if [ "$locked" = 1 ] && [ "${BIST_GATE:-0}" = 1 ]; then
    cap=$(( $(rd 0x144) )); dbe=$(( $(h2d "$(rd 0x108)") - be0 ))
    if [ "$cap" -ne "$(( GOLDEN ))" ]; then
      log "BIST-WEDGE (cap_out=$(printf 0x%08x "$cap") != golden, dpkts=$dpkt)"
      locked=0
    elif [ "$dbe" -ge "$BITERR_MAX" ]; then
      log "BIST-WEDGE (biterr +$dbe/window >= $BITERR_MAX, dpkts=$dpkt)"
      locked=0
    fi
  fi

  # HOST-WEDGE detector (R2 caveat): the demod can wedge into sync-but-CRC-fail
  # (dpkt at rate, NO storm) where the host decodes NOTHING -- invisible to the
  # two gates above. If qpsk_tun is running and its stats show idle_rx+dma_rx_ok
  # FROZEN across a whole window while dpkt says frames are syncing, that is the
  # wedge: mark not-locked (a full re-arm recovers it -- proven).
  # BYTE-PLANE WEDGE (2026-08-15, caught live on 148): the modem decodes at FULL
  # line rate (0x104 +1240/s, fsync 1251, ZERO rstcs) while the byte-word counter
  # 0x1C0 is completely frozen and the host gets nothing (dma_rx_ok=2). Register-
  # based, so it does not depend on the daemon log format. This is the primary
  # detector; the daemon-log one below is the backstop.
  # Recovery order matters: a qpsk_tun restart alone was PROVEN to clear it
  # (0x1C0 resumed, no fabric reset), so prefer that over a 0x000 re-arm, which
  # disrupts the link and blips the peer.
  if [ "$locked" = 1 ] && [ "${BYTE_WD:-1}" = 1 ]; then
    w1=$(rd 0x1C0)
    if [ -n "${prev_w:-}" ] && [ "$w1" = "$prev_w" ] && [ "$dpkt" -ge "$PKT_MIN" ]; then
      log "BYTE-PLANE WEDGE (0x1C0 frozen at $w1 while dpkt=$dpkt at rate)"
      if [ -n "$DAEMON_CMD" ] && pgrep -x qpsk_tun >/dev/null 2>&1; then
        log "  -> restarting qpsk_tun (proven recovery, less disruptive than 0x000)"
        pkill -x qpsk_tun; sleep 2; ( eval "$DAEMON_CMD" ) >/dev/null 2>&1 &
        restore_tun
        sleep "$HOLDOFF"
      else
        locked=0    # no daemon cmd available -> fall through to the full re-arm path
      fi
    fi
    prev_w=$w1
  fi

  # DELIVERY-WEDGE backstop (2026-08-25, #48 class -- REPLACES the dma_rx_ok-only
  # host-wedge backstop). Signature caught 7x live: idle_rx FROZEN across a window
  # while the modem decodes at rate (dpkt >= PKT_MIN). On a healthy locked link the
  # peer streams idle frames continuously, so idle_rx always advances; frozen idle_rx
  # with framesyncs at rate = host DMA delivery dead. (The old dma_rx_ok-only key was
  # unsound: dma_rx_ok is legitimately static on an idle link, so with working
  # parsing it would have re-arm-thrashed a healthy link. The 08-15 class -- idle_rx
  # advancing, delivery dead -- is covered by the register-based 0x1C0 BYTE-PLANE
  # detector above, which needs no log parsing at all.)
  # Recovery: daemon restart is the proven, least-disruptive fix for host-side DMA
  # wedges; fall through to full re-arm only when no DAEMON_CMD is available.
  # ---- PAYLOAD PLANE: the only source of truth for "is video actually moving?" ----
  # Read once per window, then use it to ADJUDICATE the register verdict in BOTH
  # directions. Grounded in two measurements taken minutes apart on 2026-09-23:
  #
  #   148: drstcs=274 (>= STORM_THRESH) dpkts=2444  BUT idle_rx=95043 and CLIMBING.
  #        Registers screamed "storm"; frames were reaching the host the whole time.
  #        The watchdog re-armed 13 times on a LINK THAT WAS WORKING. 0x000 is a
  #        whole-modem reset, so each attempt also blipped 148's TX -- which is 146's
  #        receive signal -- and 146 could never hold sync against it.
  #   146: drstcs=0 dpkts=6244 (both nominal)       BUT dma_rx_ok=0, idle_rx=0,
  #        crc_drop=235280 climbing. Registers said perfect; zero video.
  #
  # Neither direction of the register verdict stands on its own: 0x104 counts
  # framesyncs that then fail CRC, and 0x150 counts carrier-sync resets that a working
  # marginal link legitimately cycles. idle_rx/dma_rx_ok advancing means frames arrived
  # AND passed CRC AND reached the host -- that is what "working" means, so it wins.
  pwedge=0; pok=0; dwedge=0; pdirty=0
  if pgrep -x qpsk_tun >/dev/null 2>&1 && [ -r "$DAEMON_LOG" ]; then
    sl=$(stats_line)
    irx=$(echo "$sl" | tr " " "\n" | awk -F= '$1=="idle_rx"{print $2+0}')
    orx=$(echo "$sl" | tr " " "\n" | awk -F= '$1=="dma_rx_ok"{print $2+0}')
    cdr=$(echo "$sl" | tr " " "\n" | awk -F= '$1=="crc_drop"{print $2+0}')
    if [ -n "$irx" ] && [ -n "$orx" ] && [ -n "$cdr" ] && [ -n "${pv_irx:-}" ]; then
      if [ "$irx" -gt "$pv_irx" ] || [ "$orx" -gt "${pv_orx:-0}" ]; then
        pok=1                       # frames reaching the host -> it works, whatever 0x150 says
      elif [ "${PAYLOAD_WD:-1}" = 1 ] && [ "$cdr" -gt "${pv_cdr:-0}" ]; then
        pwedge=1                    # slices carved and EVERY one fails CRC -> PHY wedge
      elif [ "$irx" -gt 0 ]; then
        dwedge=1                    # was delivering, now nothing moves at all -> host stall
      fi
    fi
    pv_irx=$irx; pv_orx=$orx; pv_cdr=$cdr
  fi

  # Adjudicate: payload overrides the register plane in both directions.
  if [ "$pok" = 1 ]; then
    if [ "$pokrun" -lt "$PAYLOAD_CLEAN_N" ]; then pokrun=$(( pokrun + 1 )); fi
    # task-CHAIN: advancing counters alone do NOT mean recovered -- a half-cured
    # re-arm advances for one poll with drstcs still in the hundreds. Keep the veto
    # (never re-arm a link that is delivering), but hold the re-arm history until the
    # link is clean, so a chained wedge escalates instead of paying full detection again.
    # task-ONSET part 2 (2026-09-24, found by DEPLOYING part 1): the pokrun escape
    # declared the link clean after PAYLOAD_CLEAN_N advancing polls REGARDLESS of drstcs.
    # Live at 19:19:51 that wiped a PAYLOAD-ONSET strike taken at drstcs=2936 dpkts=3424
    # and sent the following wedge back to #1/2, costing the poll the strike had bought.
    # Deny the escape while the register plane is catastrophic. The drstcs<=CLEAN_DRSTCS
    # arm is untouched, so a genuinely clean link still resets on the first poll, and
    # PAYLOAD_ONSET_WD=0 restores the old unconditional behaviour.
    pokesc=0
    if [ "$pokrun" -ge "$PAYLOAD_CLEAN_N" ]; then
      pokesc=1
      if [ "${PAYLOAD_ONSET_WD:-1}" = 1 ] && [ "${drst:-0}" -ge "$PAYLOAD_ONSET_DRSTCS" ]; then pokesc=0; fi
    fi
    if [ "${drst:-999999}" -le "$PAYLOAD_CLEAN_DRSTCS" ] || [ "$pokesc" = 1 ]; then
      pfails=0; parms=0
    elif [ "$parms" -gt 0 ]; then
      # task-HALFRATE (measured 2026-09-24, n=34 re-arms): a re-arm lands in exactly one
      # of two states -- clean (drstcs=0, dpkts~6200, 28/34) or HALF-RATE (drstcs 795-1401,
      # dpkts 3288-3688 ~= 56% of rate, 6/34). Which one is a coin flip: no discriminator in
      # drstcs/dpkts/rssi/gain at the trigger, no RXPIN-FAIL in 892 lines, double-tap gap
      # identical (4 s) for both. A half-rate landing emits ONE poll of payload burst
      # (idle_rx +1817..7788) and then freezes at exactly that value -- which sets pok=1 and
      # blinds BOTH planes: this veto, and the CARRIER-WEDGE clause below via its pok=0 guard
      # (drstcs/dpkts are squarely inside WEDGE_RSTCS/WEDGE_PKT, it just never gets to look).
      # Cost of re-detecting through 3 fresh strikes: ~21 s per failed round, ~129 s/38 min.
      # We already KNOW a re-arm just completed and left the link dirty, so there is nothing
      # left to debounce -- retry now. Gated off by default: a retry at ~20 s instead of ~41 s
      # is the one thing here that is NOT measured, so prove the cure rate holds before trusting it.
      if [ "${PAYLOAD_FASTRETRY:-0}" = 1 ]; then
        pdirty=1; locked=0
        log "  -> HALF-RATE landing (parms=$parms): payload burst but drstcs=$drst dpkts=$dpkt still dirty (pokrun=$pokrun/$PAYLOAD_CLEAN_N) -- re-arming now, skipping re-detection"
      else
        log "  -> holding re-arm history (parms=$parms pfails=$pfails): payload advanced but drstcs=$drst still dirty (pokrun=$pokrun/$PAYLOAD_CLEAN_N)"
      fi
    elif [ "${PAYLOAD_ONSET_WD:-1}" = 1 ] && [ "${drst:-0}" -ge "$PAYLOAD_ONSET_DRSTCS" ] \
         && [ "${dpkt:-999999}" -lt "$PAYLOAD_ONSET_PKT" ]; then
      # task-ONSET: payload advanced this poll, but the register plane is catastrophic
      # (see the threshold note above). Count a strike rather than grant the free pass.
      pfails=$(( pfails + 1 ))
      log "  -> PAYLOAD-ONSET #$pfails/$PAYLOAD_FAIL_N (payload still advancing but drstcs=$drst dpkts=$dpkt at half rate)"
      if [ "$pfails" -ge "$PAYLOAD_FAIL_N" ]; then pdirty=1; locked=0; fi
    fi
    if [ "$locked" = 0 ] && [ "$pdirty" = 0 ]; then
      locked=1
      log "PAYLOAD-OK veto (drstcs=$drst dpkts=$dpkt read as not-locked, but idle_rx=$irx dma_rx_ok=$orx are ADVANCING -- not re-arming a working link)"
    fi
  else
    pokrun=0
    if [ "$pwedge" = 1 ]; then
      locked=0
    fi
  fi

  # DELIVERY-WEDGE keeps its original job, now scoped to the case it was written for:
  # the PHY is fine and the HOST stopped delivering, so crc_drop is static too. The
  # split matters -- on 146 (2026-09-23) a PHY wedge was misread as this and "cured"
  # with a qpsk_tun restart, which does not clear it (proven twice, 2026-09-22) and
  # dropped tun0's IPv4 as a side effect. Strictly worse than doing nothing.
  if [ "$dwedge" = 1 ] && [ "$locked" = 1 ] && [ "$dpkt" -ge "$PKT_MIN" ]; then
    log "DELIVERY-WEDGE (idle_rx frozen at $irx, crc_drop static, dpkt=$dpkt at rate)"
    if [ -n "$DAEMON_CMD" ]; then
      log "  -> restarting qpsk_tun (proven recovery, less disruptive than 0x000)"
      pkill -x qpsk_tun; sleep 2
      # a SIGSTOPped (or hung) daemon never sees SIGTERM -- escalate so the relaunch
      # can't race a zombie holding the DMA
      pgrep -x qpsk_tun >/dev/null 2>&1 && { pkill -9 -x qpsk_tun; sleep 1; }
      (cd /root/host_app_k5 2>/dev/null; setsid nohup sh -c "$DAEMON_CMD" >"$DAEMON_LOG" 2>&1 &)
      restore_tun
      sleep "$HOLDOFF"
    else
      locked=0    # no daemon cmd -> fall through to the full re-arm path
    fi
    pv_irx=""     # stats restart from zero after a relaunch; re-baseline before judging again
  fi

  # CARRIER-WEDGE detector. Scoped to production byte mode (BIST_GATE=0): in ROM/BIST
  # mode the BIST gate above already scores quality against the golden pattern, and the
  # framing rate there is not this calibration. Uses ONLY drst/dpkt, both already read
  # this window -- it adds ZERO extra direct_reg_access traffic.
  wedge=0
  # [ "$pok" = 0 ] is REQUIRED, not belt-and-braces: 148 on 2026-09-23 satisfied this
  # detector's register conditions (drstcs=274, dpkts=2444) while delivering payload
  # normally. Without this clause it re-arms straight through the PAYLOAD-OK veto and
  # the thrash continues. This detector is now the register-only FALLBACK for when the
  # daemon log is unreadable -- when payload is visible, payload decides.
  if [ "$locked" = 1 ] && [ "$pok" = 0 ] && [ "${WEDGE_WD:-1}" = 1 ] && [ "${BIST_GATE:-0}" = 0 ] \
     && [ "$drst" -ge "$WEDGE_RSTCS" ] && [ "$dpkt" -lt "$WEDGE_PKT" ]; then
    wedge=1; locked=0
  elif [ "$drst" -lt "$WEDGE_RSTCS" ] && [ "$dpkt" -ge "$WEDGE_PKT" ]; then
    wfails=0; warms=0                                                    # a clean window clears the escalation
  fi

  if [ "$locked" = 1 ]; then
    fails=0; sarms=0
    log "LOCKED (drstcs=$drst dpkts=$dpkt lvl=$lvl $(agc))"                     # decoding + settled -> nothing
  elif [ "$pwedge" = 1 ] || [ "$pdirty" = 1 ]; then
    # Ground truth beats the register plane: no payload is no video, whatever 0x104 says.
    fails=0
    if [ "$pdirty" = 1 ]; then
      pfails=$PAYLOAD_FAIL_N      # a completed re-arm already proved it dirty -- no debounce left to pay
    else
    pfails=$(( pfails + 1 ))
    log "PAYLOAD-WEDGE #$pfails/$PAYLOAD_FAIL_N (crc_drop $pv_cdr advancing, idle_rx=$irx dma_rx_ok=$orx both frozen; drstcs=$drst dpkts=$dpkt $(agc))"
    fi
    if [ "$pfails" -ge "$PAYLOAD_FAIL_N" ]; then
      pfails=0; parms=$(( parms + 1 ))
      if [ "$parms" -gt "$PAYLOAD_MAX_TRY" ]; then
        log "  -> $PAYLOAD_MAX_TRY re-arms did not restore payload; holding still ${PAYLOAD_BACKOFF}s (suspect the PEER TX)"
        parms=0; sleep "$PAYLOAD_BACKOFF"
      elif [ "${PAYLOAD_LIGHT_FIRST:-0}" = 1 ] && [ "$parms" = 1 ]; then
        # LIGHT re-arm tried first (task-GLITCH, 2026-09-23): rstCS pulse only, no
        # 0x000. Cheaper than full_rearm and doesn't disturb rx0 or the peer -- try
        # it before paying the full soft-reset cost. Escalates to full_rearm below
        # if this doesn't clear the wedge by the next poll.
        log "  -> light re-arm (attempt $parms/$PAYLOAD_MAX_TRY, rstCS only)"
        light_rearm
        sleep "${LIGHT_HOLDOFF:-5}"
      else
        # Byte re-arm, NOT a daemon restart -- see the note in the detector above.
        log "  -> canonical byte re-arm (attempt $parms/$PAYLOAD_MAX_TRY)"
        full_rearm
        sleep "$HOLDOFF"
      fi
    fi
  elif [ "$wedge" = 1 ]; then
    # Deliberately does NOT touch $fails: that counter drives the armed-on-noise path,
    # and letting both fire would double re-arm.
    fails=0
    wfails=$(( wfails + 1 ))
    log "CARRIER-WEDGE #$wfails/$WEDGE_FAIL_N (drstcs=$drst >= $WEDGE_RSTCS AND dpkts=$dpkt < $WEDGE_PKT, lvl=$lvl $(agc))"
    if [ "$wfails" -ge "$WEDGE_FAIL_N" ]; then
      wfails=0; warms=$(( warms + 1 ))
      if [ "$warms" -gt "$WEDGE_MAX_TRY" ]; then
        # The cure is LOCAL-RX only. If it keeps not taking, the fault is not here --
        # most likely the peer's TX. Thrashing 0x000 blips the peer and makes it worse.
        log "  -> $WEDGE_MAX_TRY re-arms did not clear it; backing off ${WEDGE_BACKOFF}s (suspect the PEER TX, not this RX)"
        warms=0; sleep "$WEDGE_BACKOFF"
      else
        # Straight to full_rearm -- NOT a qpsk_tun restart. A daemon restart was proven
        # twice (2026-09-22) not to cure this: the wedge is in the PHY carrier-sync
        # plane and the host is downstream, faithfully copying garbage (CP2/CP3
        # mismatch=0 over 70.5 MB). full_rearm/rearm_once is byte-for-byte the canonical
        # byte re-arm from bringup_r2r3.sh:186-190 that took 148 from 0% to 97.5% yield.
        log "  -> canonical byte re-arm (attempt $warms/$WEDGE_MAX_TRY)"
        full_rearm
        sleep "$HOLDOFF"
      fi
    fi
  else
    fails=$(( fails + 1 ))
    log "NOT-LOCKED #$fails/$FAIL_N (drstcs=$drst dpkts=$dpkt lvl=$lvl $(agc))"
    if [ "$fails" -ge "$FAIL_N" ]; then                                  # sustained -> full 0x000 re-arm
      fails=0; sarms=$(( sarms + 1 ))
      if [ "$sarms" -gt "$STORM_MAX_TRY" ]; then
        # Measured 2026-09-23: 13 consecutive re-arms here moved nothing. Holding still
        # is the only move left that can help -- it gives the peer a steady carrier to
        # acquire against instead of one this board resets every ~25 s.
        log "  -> $STORM_MAX_TRY re-arms did not clear it; holding still ${STORM_BACKOFF}s (suspect the PEER TX, not this RX)"
        sarms=0; sleep "$STORM_BACKOFF"
      else
        log "  -> full re-arm (attempt $sarms/$STORM_MAX_TRY)"
        full_rearm
        sleep "$HOLDOFF"                                                 # anti-thrash hold-off
      fi
    fi
  fi

  # small random per-board jitter so two coupled watchdogs don't lock-step and thrash
  sleep $(( $(od -An -N1 -tu1 /dev/urandom 2>/dev/null || echo 1) % 4 ))
done
