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

rearm_once(){
  echo "0x000 0x1" > "$DRA"; sleep 0.5; echo "0x000 0x0" > "$DRA"
  echo "0x158 0x1" > "$DRA"                          # tx_data_source = byte DMA (regfile reverted by 0x000)
  echo "0x118 0x0" > "$DRA"                          # tx_source_select = in-FPGA Tx
  echo "0x114 0x1" > "$DRA"                          # rx_input_select = air
  if [ -n "$TXD" ]; then echo "0x418 0x2" > "$T"; echo "0x458 0x2" > "$T"; echo "0x044 0x1" > "$T"; fi
  echo "0x110 0x1" > "$DRA"; sleep 0.3; echo "0x110 0x0" > "$DRA"   # carrier-sync reset
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
while :; do
  # (1) daemon dead -> relaunch (re-arming the modem won't fix a dead daemon)
  if [ -n "$DAEMON_CMD" ] && ! pgrep -x qpsk_tun >/dev/null 2>&1; then
    log "qpsk_tun dead -> relaunch: $DAEMON_CMD"
    (cd /root/host_app_k5 2>/dev/null; setsid nohup sh -c "$DAEMON_CMD" >"$DAEMON_LOG" 2>&1 &)
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
  if [ "$locked" = 1 ] && pgrep -x qpsk_tun >/dev/null 2>&1 && [ -r "$DAEMON_LOG" ]; then
    irx=$(stats_line | tr " " "\n" | awk -F= '$1=="idle_rx"{print $2+0}')
    if [ -n "${prev_irx:-}" ] && [ -n "$irx" ] && [ "$irx" = "$prev_irx" ] && [ "$irx" -gt 0 ]; then
      log "DELIVERY-WEDGE (idle_rx frozen at $irx while dpkt=$dpkt at rate)"
      if [ -n "$DAEMON_CMD" ]; then
        log "  -> restarting qpsk_tun (proven recovery, less disruptive than 0x000)"
        pkill -x qpsk_tun; sleep 2
        # a SIGSTOPped (or hung) daemon never sees SIGTERM -- escalate so the
        # relaunch can't race a zombie holding the DMA
        pgrep -x qpsk_tun >/dev/null 2>&1 && { pkill -9 -x qpsk_tun; sleep 1; }
        (cd /root/host_app_k5 2>/dev/null; setsid nohup sh -c "$DAEMON_CMD" >"$DAEMON_LOG" 2>&1 &)
        sleep "$HOLDOFF"
      else
        locked=0    # no daemon cmd -> fall through to the full re-arm path
      fi
      prev_irx=""
    else
      prev_irx=$irx
    fi
  fi

  if [ "$locked" = 1 ]; then
    fails=0
    log "LOCKED (drstcs=$drst dpkts=$dpkt lvl=$lvl)"                     # decoding + settled -> nothing
  else
    fails=$(( fails + 1 ))
    log "NOT-LOCKED #$fails/$FAIL_N (drstcs=$drst dpkts=$dpkt lvl=$lvl)"
    if [ "$fails" -ge "$FAIL_N" ]; then                                  # sustained -> full 0x000 re-arm
      full_rearm; fails=0
      sleep "$HOLDOFF"                                                   # anti-thrash hold-off
    fi
  fi

  # small random per-board jitter so two coupled watchdogs don't lock-step and thrash
  sleep $(( $(od -An -N1 -tu1 /dev/urandom 2>/dev/null || echo 1) % 4 ))
done
