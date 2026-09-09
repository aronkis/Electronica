#!/bin/bash
# =============================================================================
# loopback_s_test.sh -- has -S EVER framed on this hardware?
#
# WHY THIS EXISTS. Six air-link runs and four dead hypotheses (under-feed, missing
# pacing, mux drop, byte-FIFO underrun) all assumed -S works and something on the
# link was breaking it. Nobody established that -S has ever framed on hardware at
# all -- Layer B was "code-complete and sim-tested but never ran on hardware". Six
# runs debugging toward a state never shown to be reachable produced zero numbers.
#
# THE BISECT. Run on ONE board with rx_input_select=0 (internal loopback): no air,
# no peer, no RF, no arm-gate lottery. The daemon's own TX loops back into its RX.
#   -S frames in loopback     -> the fault is in the AIR path under -S
#   -S does NOT frame         -> the fault is entirely host/mode-side, reproducible
#                                with no link at all and debuggable off hardware
#
# MANDATORY POSITIVE CONTROL (arm A). -G is run in the SAME loopback configuration
# first. If -G does not frame either, the loopback CONFIG is wrong and this test
# discriminates NOTHING -- it is then VOID and must not be reported as a -S result.
# This campaign has already produced one confident verdict off unreadable registers
# (mux_test) and several off structurally-blind counters; the control is not
# optional.
#
# REGISTERS. 0x114=0 selects the in-FPGA loopback (=1 is air); 0x118=0 is in-FPGA
# Tx; 0x158=1 is byte-DMA tx_data_source. 0x114/0x118/0x158 are ALL WRITE-ONLY --
# they are set, never read back, and nothing here verifies them by readback.
#
# ORDER. Stream-first (bringup_r2r3.sh:128, R2FINISH): start the daemon so its TX
# stream is pumping, THEN flip to byte source. Flipping first starts the modulator
# on an underrunning FIFO and is demod-hostile.
#
# DRA is a single address latch -- the watchdog is stopped so this is the only
# reader/writer, and restarted at the end.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=${BOARD:-10.0.0.146}
M=${M:-32}
DUR=${DUR:-40}
# FRAMELOG=1 adds the per-frame telemetry logger to ARM B so singles_cadence.py can
# score host_seq/crc_ok. Default 0 -> the daemon command line is unchanged and every
# logger hook in qpsk_tun.c is a no-op (byte-identical behaviour to prior runs).
FRAMELOG=${FRAMELOG:-0}
FLENV=""; [ "$FRAMELOG" = 1 ] && FLENV="QPSK_FRAMELOG=/dev/shm/frames.bin"
# ARMB_FLAG/ARMB_GREP let a caller swap ARM B's daemon mode (default -S, this
# script's whole reason to exist) for -B, the ONLY mode QPSK_FRAMELOG populates
# crc_ok/host_seq correctly in (see qpsk_tun.c framelog_record call sites; -S
# logs every record crc_ok=0/host_seq unset and is unscorable by singles_cadence.py).
# Defaults preserve the original -S behaviour byte-for-byte when unset.
ARMB_FLAG=${ARMB_FLAG:--S}
ARMB_GREP=${ARMB_GREP:-"^seq: t="}
OUT=$D/r3cap/loopback_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"

echo "=== loopback_s_test on $B (no air, no peer) -> $OUT ==="
echo "--- stopping watchdog (single DRA writer; it would also re-arm 0x114 to AIR) ---"
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; sleep 1
  pgrep -f "[l]ock_watchdog" >/dev/null && echo "  watchdog STILL UP" || echo "  watchdog stopped"' 2>/dev/null

# arm the fabric into LOOPBACK with the byte source live (stream already pumping)
arm_loopback(){ $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x1">$DRA        # tx_data_source = byte DMA
  echo "0x118 0x0">$DRA        # tx_source_select = in-FPGA Tx
  echo "0x114 0x0">$DRA        # rx_input_select = LOOPBACK (not air)
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
  echo "  loopback armed (0x114=0)"' 2>/dev/null; }

# framesync rate straight off 0x104 -- independent of any host-side counter
fsync_rate(){ $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  rd(){ echo "$1" > $DRA; cat $DRA; }
  p0=$(rd 0x104); sleep 3; p1=$(rd 0x104)
  echo "  0x104 framesync/s = $(( ( $(( $p1 )) - $(( $p0 )) ) / 3 ))"' 2>/dev/null; }

run_arm(){ # $1 label  $2 launch-cmd  $3 progress-grep
  echo
  echo "##### $1 #####"
  $W $B "pkill -x qpsk_tun 2>/dev/null; sleep 1; cd /root/host_app_k5; rm -f /dev/shm/lb.log
    $2 > /dev/shm/lb.log 2>&1 &
    exit 0" >/dev/null 2>&1
  sleep 6                       # let the TX stream pump BEFORE the source flip
  arm_loopback
  sleep 6
  fsync_rate
  # WAIT FOR THE DAEMON TO EXIT ON ITS OWN. The first version pkill'd at DUR while
  # the daemon had -d DUR+20, so it never reached its end-of-run summary and the
  # SEQRX/SEQDMA classification -- the actual Layer B number -- was destroyed. Wait
  # out the full -d, then collect.
  echo "  --- running ${DUR}s (waiting for the daemon to print its summary) ---"
  sleep $((DUR + 26))
  $W $B 'cat /dev/shm/lb.log' 2>/dev/null > "$OUT/$1.log"
  echo "  --- last daemon stat ---"
  grep -E "$3" "$OUT/$1.log" | tail -2 | sed 's/^/    /'
  echo "  --- end-of-run summary ---"
  grep -E "^SEQRX|^SEQDMA" "$OUT/$1.log" | sed 's/^/    /' || echo "    (none printed)"
  $W $B 'pkill -x qpsk_tun 2>/dev/null; exit 0' >/dev/null 2>&1
}

# ---- ARM A: POSITIVE CONTROL. -G in the identical loopback config. -------------
run_arm "A_G_loopback" \
  "QPSK_FRAME=f1536 QPSK_RX_QUEUED=1 setsid chrt -f 50 ./qpsk_tun -G -M $M -r 15360 -i tun0 -s 5 -d $((DUR+20))" \
  "qpsk_tun stats"

# ---- ARM B: the actual question. -S in the identical loopback config. ----------
# framelog opens O_APPEND ("ab" in qpsk_tun.c) so a stale file from a prior run
# (e.g. a previous -M sweep point) would silently concatenate into this one.
[ "$FRAMELOG" = 1 ] && $W $B 'rm -f /dev/shm/frames.bin' 2>/dev/null
# QPSK_FRAME=f1536 and QPSK_SEQ_KEEPM=1 are -S-specific: -B sets k5_mode=1
# itself (qpsk_tun.c case 'B'), which is flatly incompatible with
# QPSK_FRAME=f1536 ("-F (K5) and -G/QPSK_FRAME=f1536 are mutually exclusive"
# -- the daemon refuses to start and frames.bin stays empty), and
# QPSK_SEQ_KEEPM is meaningless outside -S. Only the -S path (the default,
# unchanged) carries them.
if [ "$ARMB_FLAG" = "-S" ]; then
  ARMB_ENV="QPSK_FRAME=f1536 QPSK_SEQ_KEEPM=1 QPSK_RX_QUEUED=1"
else
  ARMB_ENV="QPSK_RX_QUEUED=1"
fi
run_arm "B_S_loopback" \
  "$FLENV $ARMB_ENV setsid chrt -f 50 ./qpsk_tun $ARMB_FLAG -M $M -r 15360 -d $((DUR+20))" \
  "$ARMB_GREP"

if [ "$FRAMELOG" = 1 ]; then
  $W $B 'cat /dev/shm/frames.bin' 2>/dev/null > "$OUT/frames.bin"
  echo "  frames.bin: $(stat -c %s "$OUT/frames.bin" 2>/dev/null || echo 0) bytes"
fi

echo
echo "=== VERDICT ==="
python3 - "$OUT" "$ARMB_FLAG" <<'PY'
import os, re, sys
o = sys.argv[1]
armb_flag = sys.argv[2] if len(sys.argv) > 2 else "-S"

def g_frames(p):
    # idle_rx, NOT dma_rx_ok. -G with no tun traffic and no peer transmits ONLY idle
    # frames (tunB_tx=0, idle_tx=68509), so dma_rx_ok -- which counts DATA frames --
    # is structurally zero and cannot indicate whether the loopback is framing. The
    # first version of this control used it and declared a working config VOID.
    if not os.path.exists(p): return None
    v = None
    for ln in open(p):
        m = re.search(r"idle_rx=(\d+)", ln)
        if m: v = int(m.group(1))
    return v

def s_ok(p):
    if not os.path.exists(p): return None, None
    ok = junk = None
    for ln in open(p):
        m = re.search(r"^seq: t=\d+s .* ok=(\d+) .* junk=(\d+)", ln)
        if m: ok, junk = int(m.group(1)), int(m.group(2))
    return ok, junk

gv = g_frames(os.path.join(o, "A_G_loopback.log"))
print(f"  ARM A  -G loopback : idle_rx = {gv}  (control: >0 means the loopback frames)")

# The -S-specific ok=/junk= parsing, wedge-time check, and interpretation below
# are ONLY valid when ARM B actually ran -S. When it ran something else (e.g.
# -B), printing them anyway would be a confident, false conclusion about a
# mode that never executed -- exactly the failure this project is trying to
# stop making. Gate the entire block on armb_flag instead.
if armb_flag != "-S":
    print(f"  ARM B ran {armb_flag}, not -S -- the ok=/junk=/SEQRX/SEQDMA parsing")
    print("      and interpretation below are for -S only and DO NOT APPLY here.")
    print("      See B_S_loopback.log and this run's own scorer output for what")
    print(f"      {armb_flag} actually did.")
    print()
    if gv is None or gv == 0:
        print("  >>> VOID. The POSITIVE CONTROL failed: -G did not frame in loopback either,")
        print("      so the loopback CONFIG is wrong (or 0x114=0 is not the loopback select).")
        print(f"      This run says NOTHING about {armb_flag}. Do not report it as a result.")
    else:
        print(f"  >>> Positive control OK (idle_rx={gv}). {armb_flag} arm ran under a")
        print("      DIFFERENT interpretation than -S; consult the scorer output, not")
        print("      the (suppressed) -S-specific text above.")
    raise SystemExit(0)

ok, junk = s_ok(os.path.join(o, "B_S_loopback.log"))
print(f"  ARM B  -S loopback : ok = {ok}   junk = {junk}")
# TIME-TO-WEDGE on the -S arm: ok rose then froze while tx kept climbing.
sp = os.path.join(o, "B_S_loopback.log")
if os.path.exists(sp):
    prog = []
    for ln in open(sp):
        m = re.search(r"^seq: t=(\d+)s tx=(\d+) ok=(\d+)", ln)
        if m: prog.append(tuple(int(x) for x in m.groups()))
    last = 0
    for i in range(1, len(prog)):
        if prog[i][2] > prog[i-1][2]: last = prog[i][0]
    if prog and last < prog[-1][0]:
        print(f"  *** -S WEDGED IN LOOPBACK at t~{last}s "
              f"(ok frozen at {prog[-1][2]} while tx climbed to {prog[-1][1]}) ***")
        print(f"      No air, no peer, no RF -- the wedge is NOT an RF/channel effect.")
    elif prog:
        print(f"  -S ok still advancing at t={prog[-1][0]}s -- no wedge in this window.")
print()
if gv is None or gv == 0:
    print("  >>> VOID. The POSITIVE CONTROL failed: -G did not frame in loopback either,")
    print("      so the loopback CONFIG is wrong (or 0x114=0 is not the loopback select).")
    print("      This run says NOTHING about -S. Do not report it as a -S result.")
    print("      Fix the control first: find the setting under which -G frames in")
    print("      loopback, then re-run.")
elif ok:
    print("  >>> -S FRAMES IN LOOPBACK. The host/mode side is sound; the fault is in the")
    print("      AIR path under -S. Air-link debugging was the right half after all.")
else:
    print("  >>> -S DOES NOT FRAME IN LOOPBACK while -G DOES, in the identical config.")
    print("      The fault is entirely HOST/MODE-SIDE and reproduces with no link, no")
    print("      peer and no RF. Stop spending air-link cycles: bisect -G vs -S in the")
    print("      daemon (tx_send_batch at F1536 is the leading difference -- -G never")
    print("      exercises it).")
PY

echo
echo "--- restoring: air select + watchdog ---"
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x114 0x1">$DRA; exit 0' >/dev/null 2>&1
$W $B 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; exit 0' >/dev/null 2>&1
$W $B ': > /dev/shm/watchdog.log; exit 0' >/dev/null 2>&1
$W $B 'nohup setsid /root/lock_watchdog.sh </dev/null >/dev/shm/watchdog.log 2>&1 & disown; exit 0' >/dev/null 2>&1
sleep 2
$W $B 'pgrep -f "[l]ock_watchdog" >/dev/null && echo "  watchdog VERIFIED up" || echo "  watchdog FAILED TO START"' 2>/dev/null
echo "=== artifacts in $OUT ==="
