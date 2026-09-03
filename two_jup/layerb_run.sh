#!/bin/bash
# =============================================================================
# layerb_run.sh [dur] -- LAYER B: the DMA-boundary PN bisect at R3.
#
# WHAT IT PROVES. The float oracle showed the algorithmic ceiling on real field
# samples is 0.0000% (161/161 frames recoverable, EVM ~14% against a 45 deg decision
# margin), and today's netlist gate decoded 27/27 ROM frames bit-exact with PI_GATE
# passing. So neither the channel nor the fixed-point receiver is losing frames. The
# measured 0.7-1.4% has to be entering somewhere after the demod -- the host DMA path.
#
# This run makes that concrete instead of inferred. Both boards stream the xorshift32 PN
# (-S), so every received frame is bit-comparable to expected(seq), and every seq in the
# span lands in exactly one bucket. The scorer then names the DMA failure mode:
#   TORN_ZERO  good prefix, tail all zero at an 8-byte boundary -> slice never completed
#   TORN_STALE good prefix, tail = a DIFFERENT seq -> half-old/half-new slice
#   SCATTERED  no aligned split -> decode-side, NOT the DMA
#   BATCH_DROP a LOST run that is an exact multiple of M -> whole batch dropped
#
# CRITICAL: QPSK_SEQ_KEEPM=1. Without it -S sets rx_multi=0 and runs the legacy
# single-packet RX -- i.e. it bypasses the batched DMA under test and would return a
# clean result for entirely the wrong reason. That wiring bug is why this mode had never
# implicated the DMA before.
#
# Rails: host-side only. No FPGA is touched. 148's AXR counter is verified either side.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
DUR=${1:-90}
M=${M:-32}
STAMP=$(date +%Y%m%d_%H%M%S)
OUT=$D/r3cap/layerb_$STAMP; mkdir -p "$OUT"

echo "=== LAYER B: PN through the batched DMA, -M $M, ${DUR}s -> $OUT ==="
echo "--- 148 AXR counter BEFORE ---"
$W $A 'echo "  nakstat=$(strings /root/host_app_k5/qpsk_tun|grep -c nakstat) app=$(md5sum /root/host_app_k5/qpsk_tun|cut -c1-8) BOOT=$(md5sum /boot/BOOT.BIN|cut -c1-12)"' 2>/dev/null

# =============================================================================
# DEPLOY + BUILD. layerb_run.sh used to run against whatever binary happened to be
# on the boards, so a source fix could sit uncompiled while the run "succeeded".
# Mirrors capture_r3.sh's build, INCLUDING its NAK-stat preservation guard: that
# rebuild silently strips -DQPSK_ARQ_NAKSTAT unless the flag is carried over, which
# would destroy 148's AXR counter. Detected from the deployed binary, preserved,
# and verified afterwards rather than assumed.
# =============================================================================
SRC=$(cd "$D/../host_app_k5" && pwd)
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
  -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
echo "--- deploying + building qpsk_tun on both boards ---"
for ip in $B $A; do
  scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" \
         "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" \
         "$SRC/qpsk_uio.c" "$SRC/qpsk_uio.h" "$SRC/qpsk_perf.c" root@$ip:/root/host_app_k5/ \
         || { echo "scp $ip FAIL"; exit 1; }
  NAKKEEP=$($W $ip 'strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -q "nakstat:" \
         && echo "-DQPSK_ARQ_NAKSTAT" || echo ""' 2>/dev/null)
  [ -n "$NAKKEEP" ] && echo "  $ip: preserving deployed NAK-stat instrumentation ($NAKKEEP)"
  R=$($W $ip "cd /root/host_app_k5 && gcc -O2 -Wall -DQPSK_CARVE_2MB $NAKKEEP -o qpsk_tun \
        qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c qpsk_uio.c 2>/tmp/gcc.err \
        && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }" 2>/dev/null)
  echo "  $ip build: $(echo "$R" | tail -1)"; echo "$R" | grep -q BUILD_OK || exit 1
  if [ -n "$NAKKEEP" ]; then
    $W $ip 'strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -q "nakstat:" \
      && echo "  '"$ip"': NAK-stat counter VERIFIED present after rebuild" \
      || { echo "  '"$ip"': WARNING NAK-stat counter LOST in rebuild"; }' 2>/dev/null
  fi
done

# =============================================================================
# FRAMING GATE (added 2026-08-11). The previous run banked 90 s of data on a link
# that was NOT FRAMING: 32640/32640 slices scored junk, and the four DMA buckets
# read all-zero because nothing was ever classified -- which reads as "the DMA is
# clean" unless you check the span. Analysis of the banked slices settled it: they
# were 1528 B (right geometry), 200/200 distinct (not stale), and carried 'QK'
# magic in 5/200 at scattered offsets -- pure chance. No frame structure at all.
#
# The ARM gate and the banner check both PASSED on that run. They verify RF
# acquisition and daemon wiring; neither verifies that framed data is arriving.
# So this gate is in-band: after the -S swap, require the scorer's own ok counter
# to ADVANCE before the run is allowed to count. Retries the whole bring-up if it
# does not -- and on give-up, says so loudly instead of banking junk.
#
# Same defect class as crc_health-is-a-ratio and the skipped stall watchdog: the
# harness must be able to detect its own no-op.
# =============================================================================
TRIES=${TRIES:-3}
FRAMEGATE_S=${FRAMEGATE_S:-25}      # allow this long for ok to start advancing
attempt=0; gated=0
while [ $attempt -lt $TRIES ]; do
  attempt=$((attempt + 1))
  echo
  echo "########## ATTEMPT $attempt/$TRIES ##########"
  echo "--- R3 bring-up (RF/profile), then swap the daemons to -S ---"
  "$D/bringup_r2r3.sh" r3 > "$OUT/bringup_$attempt.log" 2>&1 || { echo "BRINGUP FAILED"; continue; }
  grep -E "ARM GATE|BRING-UP COMPLETE" "$OUT/bringup_$attempt.log" | tail -2

  # bring-up leaves -G daemons running; Layer B needs -S on both ends.
  # The watchdogs stay down for the whole measurement ON PURPOSE: a re-arm
  # mid-run would perturb the very wedge we are trying to time. They are
  # restarted unconditionally at the end.
  for ip in $B $A; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.5' 2>/dev/null; done

  echo "--- launching -S (PN) on both boards, f1536 geometry, batched RX kept ---"
  for ip in $A $B; do
    $W $ip "cd /root/host_app_k5; rm -f /dev/shm/acc.log /dev/shm/seq_events.log /dev/shm/seq_raw.log
      QPSK_FRAME=f1536 QPSK_SEQ_KEEPM=1 QPSK_RX_QUEUED=1 setsid chrt -f 50 \
        ./qpsk_tun -S -M $M -r 15360 -d $DUR > /dev/shm/acc.log 2>&1 &
      exit 0" >/dev/null 2>&1
    echo "  $ip: -S launched"
  done

  echo "--- confirming both daemons took the Layer B wiring (not the legacy path) ---"
  sleep 8
  for ip in $A $B; do
    $W $ip 'p=$(pgrep -x qpsk_tun|head -1)
      echo "  '"$ip"': $( [ -n "$p" ] && tr "\0" " " < /proc/$p/cmdline || echo DOWN )"
      grep -m1 "LAYER B" /dev/shm/acc.log 2>/dev/null || echo "    !! no LAYER B banner -- rx_multi was zeroed, run is INVALID"' 2>/dev/null
  done

  # ===========================================================================
  # BYTE RE-ARM AFTER THE -S SWAP -- the fix for five failed runs.
  #
  # bringup_r2r3.sh:128 (R2FINISH finding), verbatim: "flipping 0x158=1 before the
  # daemon's TX stream is flowing starts the modulator on an underrunning byte FIFO
  # -> the discontinuous stream is demod-hostile at R2 (both dirs 0% while ROM is
  # clean). Start the daemon under ROM, let it pump, then full re-arm to byte with
  # the stream already continuous: measured flip from 0%/0% to 551/602 f/s."
  #
  # This script VIOLATED that. Bring-up arms the byte source correctly around the -G
  # daemons, and then we kill those daemons -- stopping the byte stream and
  # underrunning the FIFO -- start -S, and never re-arm. That leaves the modulator in
  # exactly the 0%/0% state the finding describes, which is why feed rate (tested at
  # 28%, 95% and 242% of air) and pacing both turned out to be irrelevant: none of
  # them touch the FIFO-underrun state.
  #
  # So: let -S pump first (the sleep 8 above), THEN re-arm, in bring-up's order --
  # B then A, double-tapped, because A's flip otherwise lands while B is
  # mid-transition (~8% of flips latch a false state, ARMCAUSE).
  # ===========================================================================
  rearm_byte(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
 echo "  byte re-arm done"' 2>/dev/null; }
  echo "--- byte re-arm with the -S stream already pumping (stream-first order) ---"
  rearm_byte $B; rearm_byte $A
  sleep 3
  rearm_byte $B; rearm_byte $A        # double-tap, as bring-up does
  sleep 3

  echo "--- FRAMING GATE: requiring the scorer's ok counter to advance (<= ${FRAMEGATE_S}s) ---"
  ok_seen=0; waited=8
  while [ $waited -lt $FRAMEGATE_S ]; do
    sleep 4; waited=$((waited + 4))
    line=$($W $B 'grep -E "^seq: t=" /dev/shm/acc.log 2>/dev/null | tail -1' 2>/dev/null)
    okv=$(echo "$line" | sed -n 's/.* ok=\([0-9]*\) .*/\1/p')
    jkv=$(echo "$line" | sed -n 's/.* junk=\([0-9]*\) .*/\1/p')
    echo "    t~${waited}s  ok=${okv:-?} junk=${jkv:-?}"
    if [ -n "${okv:-}" ] && [ "$okv" -gt 0 ]; then ok_seen=1; break; fi
  done
  if [ "$ok_seen" = 1 ]; then
    echo "  FRAMING GATE PASS (ok advancing) -- this run counts"
    gated=1; break
  fi

  # ==========================================================================
  # SECOND DISCRIMINATOR: raw-slice 'QK' hit rate at offset 0.
  #
  # "ok never advanced" has TWO very different causes and the ok counter alone
  # cannot tell them apart:
  #   (a) NOT FRAMING     -- the slices carry no frame structure at all
  #   (b) FRAMING, PN BAD -- slices are properly framed but the payload never
  #                          matches expected(seq)
  # These need opposite fixes, and calling (b) "the link is not framing" would
  # send the next session chasing the modem when the fault is in the scorer or
  # the PN generation.
  #
  # The discriminator is the frame magic at offset 0 of the RAW slice, before any
  # CRC or PN comparison. Baseline established on real data (run 145820): with no
  # framing, 'QK' appeared ANYWHERE in only 5/200 slices at scattered offsets --
  # chance, since 2 bytes over 1528 positions predicts ~4.7. A framing link puts
  # it at offset 0 on essentially every slice.
  # ==========================================================================
  echo "  --- second discriminator: raw-slice 'QK' magic at offset 0 ---"
  $W $B 'head -400 /dev/shm/seq_raw.log 2>/dev/null' 2>/dev/null > "$OUT/seqraw_gate_$attempt.log"
  python3 - "$OUT/seqraw_gate_$attempt.log" <<'PY'
import re, sys
tot = hit0 = anywhere = 0
for ln in open(sys.argv[1], errors="ignore"):
    m = re.search(r"hex=([0-9a-f]+)", ln)
    if not m: continue
    h = m.group(1); tot += 1
    if h[:4] == "514b": hit0 += 1
    elif "514b" in h:   anywhere += 1
if not tot:
    print("    no raw slices dumped -- discriminator unavailable"); raise SystemExit
p0 = 100.0 * hit0 / tot
print(f"    slices={tot}  'QK'@offset0={hit0} ({p0:.1f}%)  elsewhere={anywhere}")
if p0 > 50:
    print("    >>> FRAMING, PN MISMATCH: slices ARE framed (magic at offset 0) but the")
    print("        payload never matches expected(seq). The modem is fine -- the fault is")
    print("        in the PN generation or the scorer, and is debuggable OFF hardware.")
else:
    print("    >>> NOT FRAMING: no frame magic at offset 0. Consistent with chance")
    print("        (~2.3%/slice for a 2-byte pattern over 1528 positions). The fault is")
    print("        upstream of the host -- the modem is not producing framed output.")
PY

  echo "  !! FRAMING GATE FAIL: ok never advanced in ${FRAMEGATE_S}s."
  echo "     NOT counting this run; recovering and retrying."
  for ip in $B $A; do $W $ip 'pkill -x qpsk_tun 2>/dev/null; exit 0' >/dev/null 2>&1; done
done

if [ "$gated" != 1 ]; then
  echo
  echo "=== LAYER B ABORTED: framing gate failed on all $TRIES attempts ==="
  echo "    No DMA number produced. The link would not frame; this is NOT a"
  echo "    statement about the DMA. Restarting watchdogs and exiting."
  for ip in $B $A; do
    $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; exit 0' >/dev/null 2>&1
    $W $ip ': > /dev/shm/watchdog.log; exit 0' >/dev/null 2>&1
    $W $ip 'nohup setsid /root/lock_watchdog.sh </dev/null >/dev/shm/watchdog.log 2>&1 & disown; exit 0' >/dev/null 2>&1
    sleep 2
    $W $ip 'pgrep -f "[l]ock_watchdog" >/dev/null && echo "  '"$ip"' watchdog VERIFIED up" || echo "  '"$ip"' watchdog FAILED TO START"' 2>/dev/null
  done
  exit 3
fi

echo "--- running ${DUR}s ---"
sleep $((DUR + 12))

echo
echo "=== RESULTS (146 = RX under test) ==="
$W $B 'grep -E "^SEQRX|^SEQDMA" /dev/shm/acc.log | tail -4' 2>/dev/null | tee "$OUT/seqrx_146.txt"
echo
echo "=== peer (148) for comparison ==="
$W $A 'grep -E "^SEQRX|^SEQDMA" /dev/shm/acc.log | tail -4' 2>/dev/null | tee "$OUT/seqrx_148.txt"

for ip in $B $A; do
  n=$( [ "$ip" = "$B" ] && echo 146 || echo 148 )
  $W $ip 'cat /dev/shm/acc.log' 2>/dev/null > "$OUT/acc_$n.log"
  $W $ip 'cat /dev/shm/seq_raw.log 2>/dev/null | head -200' 2>/dev/null > "$OUT/seqraw_$n.log"
done

echo
echo "=== TIME-TO-WEDGE (146) ==="
# The run passed the framing gate, so ok WAS advancing. If it stops, that is a
# mid-run wedge and the interesting number is WHEN, not merely that the run is
# short. Reported rather than silently absorbed into a bad PER.
python3 - "$OUT/acc_146.log" <<'PY'
import re, sys
stats, evts = [], []
try:
    txt = open(sys.argv[1]).read().splitlines()
except OSError:
    sys.exit("  no acc_146.log")
for ln in txt:
    m = re.search(r"^seq: t=(\d+)s .* ok=(\d+) .* junk=(\d+)", ln)
    if m:
        stats.append((int(m.group(1)), int(m.group(2)), int(m.group(3))))
    m = re.search(r"^EVT t=([\d.]+) .* type=(\w+)", ln)
    if m:
        evts.append((float(m.group(1)), m.group(2)))
if not stats:
    sys.exit("  no per-interval stats -- cannot time a wedge")
last_prog = 0
for i in range(1, len(stats)):
    if stats[i][1] > stats[i - 1][1]:
        last_prog = stats[i][0]
end_t, end_ok, end_junk = stats[-1]
print(f"  intervals: {len(stats)}  final ok={end_ok} junk={end_junk} at t={end_t}s")
if last_prog >= end_t:
    print(f"  NO WEDGE: ok still advancing at the last interval (t={end_t}s).")
else:
    # sub-second anchor: the junkstart that opens the terminal junk run
    cands = [t for t, ty in evts if ty == "junkstart" and t >= last_prog - 5]
    ttw = min(cands) if cands else float(last_prog)
    src = "junkstart event" if cands else "5 s stat granularity"
    print(f"  *** WEDGED MID-RUN ***")
    print(f"  last ok progress at t={last_prog}s; TIME-TO-WEDGE = {ttw:.3f}s ({src})")
    print(f"  ran {end_t - last_prog}s wedged out of {end_t}s total "
          f"({100.0 * (end_t - last_prog) / end_t:.0f}% of the run)")
    print(f"  -> the scored number below covers only the pre-wedge window; treat")
    print(f"     any bucket total as sampled over ~{last_prog}s, not {end_t}s.")
PY

echo
echo "--- 148 AXR counter AFTER ---"
$W $A 'echo "  nakstat=$(strings /root/host_app_k5/qpsk_tun|grep -c nakstat) BOOT=$(md5sum /boot/BOOT.BIN|cut -c1-12)"' 2>/dev/null

echo
echo "=== restarting lock_watchdog on BOTH boards (kept down for the measurement) ==="
# ISOLATED ssh calls then VERIFY -- a detached launch bundled with other commands
# in one ssh block does not survive; that footgun has bitten twice.
for ip in $B $A; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; exit 0' >/dev/null 2>&1
  $W $ip ': > /dev/shm/watchdog.log; exit 0' >/dev/null 2>&1
  $W $ip 'nohup setsid /root/lock_watchdog.sh </dev/null >/dev/shm/watchdog.log 2>&1 & disown; exit 0' >/dev/null 2>&1
  sleep 2
  $W $ip 'pgrep -f "[l]ock_watchdog" >/dev/null && echo "  '"$ip"' watchdog VERIFIED up" || echo "  '"$ip"' watchdog FAILED TO START"' 2>/dev/null
done

echo "=== artifacts in $OUT ==="
