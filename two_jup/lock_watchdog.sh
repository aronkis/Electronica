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
h2d(){ echo $(( $1 )); }                            # "0x2F" -> 47 (ash parses 0x)
log(){ echo "[wd $(date +%H:%M:%S)] $*"; }   # stdout is exec-redirected to $LOGFILE

full_rearm(){                                       # 0x000 soft reset clears the wound AGC
  log "FULL RE-ARM (0x000 soft reset + re-select + rstCS)"
  echo "0x000 0x1" > "$DRA"; sleep 0.5; echo "0x000 0x0" > "$DRA"
  echo "0x158 0x1" > "$DRA"                          # tx_data_source = byte DMA (regfile reverted by 0x000)
  echo "0x118 0x0" > "$DRA"                          # tx_source_select = in-FPGA Tx
  echo "0x114 0x1" > "$DRA"                          # rx_input_select = air
  if [ -n "$TXD" ]; then echo "0x418 0x2" > "$T"; echo "0x458 0x2" > "$T"; echo "0x044 0x1" > "$T"; fi
  echo "0x110 0x1" > "$DRA"; sleep 0.3; echo "0x110 0x0" > "$DRA"   # carrier-sync reset
}

log "watchdog up: MW=$MW TXD=${TXD:-none} PERIOD=${PERIOD}s PKT_MIN=$PKT_MIN FAIL_N=$FAIL_N HOLDOFF=${HOLDOFF}s"
fails=0
while :; do
  # (1) daemon dead -> relaunch (re-arming the modem won't fix a dead daemon)
  if [ -n "$DAEMON_CMD" ] && ! pgrep -x qpsk_tun >/dev/null 2>&1; then
    log "qpsk_tun dead -> relaunch: $DAEMON_CMD"
    (cd /root/host_app_k5 2>/dev/null; setsid nohup sh -c "$DAEMON_CMD" >"$DAEMON_LOG" 2>&1 &)
    sleep "$HOLDOFF"; continue
  fi

  # (2) measure lock over the window
  r0=$(h2d "$(rd 0x150)"); p0=$(h2d "$(rd 0x104)")
  sleep "$PERIOD"
  r1=$(h2d "$(rd 0x150)"); p1=$(h2d "$(rd 0x104)"); lvl=$(( ( $(rd 0x15C) >> 24 ) & 255 ))
  drst=$(( r1 - r0 )); dpkt=$(( p1 - p0 ))
  # LOCKED = the modem is DECODING packets (0x104 advancing >= PKT_MIN). That is the
  # only thing that means "the link delivers frames". rstcs is NOT gated on: a marginal
  # link cycles rstcs yet keeps decoding, and re-arming it (0x000) would break a working
  # link AND blip the peer. The armed-on-noise wedge is dpkt=0 -> caught here.
  # levelLog is not used either (the analog Rx AGC amplifies noise to the same rail).
  locked=0; [ "$dpkt" -ge "$PKT_MIN" ] && locked=1

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
