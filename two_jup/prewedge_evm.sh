#!/bin/bash
# =============================================================================
# prewedge_evm.sh [reps] -- is the PRE-WEDGE bit-error rise a SIGNAL problem or a
# DEMOD problem?
#
# WHERE THIS COMES FROM. Time-resolved ordering at the wedge (wedge_transition.py, post
# reboot, 212-sample baseline) showed:
#     biterr/s   lead -5.34 s      <- the ONLY leading indicator
#     cfc        no sustained pre-cursor    (carrier still tracking)
#     rstcs      none                        (no resets)
#     maxGap     none                        (ADC/SSI delivery clean)
#     agc_level  CONSTANT at 12              (no gain event, input power steady)
# So bits go wrong while every upstream indicator is nominal, and the cfc dither Layer A
# blamed ("MODEM CARRIER LOOP") only appears AFTER. That verdict read the steady-state
# signature, not the causal order -- which is also why a 4x range of loop gains changed
# nothing: we were tuning downstream of the trigger.
#
# THE DISCRIMINATOR. Capture Tap-A IQ across the pre-wedge window and measure EVM:
#   EVM RISES with biterr  -> signal quality: TX-side impairment or channel. (This is the
#                             campaign's old "148-RX-tick vs 146-TX-EVM" question, now
#                             with a time-resolved handle.)
#   EVM FLAT while biterr rises -> the demodulator/slicer, i.e. fixed point. Would be
#                             surprising given the float oracle's 0.0000% ceiling -- but
#                             that oracle ran on HEALTH-GATED captures and so has never
#                             seen this window.
#
# INTERNAL CONTROL. biterr stays at 0 until ~t=0.46 s and rises after, so a single
# capture starting at arm contains both a clean and a degrading stretch of the SAME run,
# on the same hardware, same gain, same LO. EVM is compared within the file -- no
# cross-run normalisation, which is what has burned this campaign repeatedly.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.146
REPS=${1:-3}
NSAMP=${NSAMP:-80000000}          # 80 M complex = 320 MB = ~1.3 s at 61.44 MSPS
OUT=$D/prewedge/$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"

echo "=== prewedge_evm: $REPS reps, ${NSAMP} samples each -> $OUT ==="

for r in $(seq 1 "$REPS"); do
  echo "--- rep $r/$REPS: arm ROM/BIST ---"
  "$D/reverse_rom_soak.sh" 1 > "$OUT/arm_$r.log" 2>&1 || true
  grep -qE "LOCKED GOLDEN" "$OUT/arm_$r.log" || { echo "  did not lock golden -- skipping rep"; continue; }

  # register sampler in the background ON THE BOARD, then the IQ grab, so the two
  # overlap. The pkts anchor in both lets them be aligned afterwards.
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
    rd(){ echo \"\$1\" > \$DRA; cat \$DRA; }
    : > /dev/shm/pw_regs.log
    ( for i in \$(seq 400); do
        echo \"t=\$(date +%s.%N) cap=\$(rd 0x144) cfc=\$(rd 0x154) biterr=\$(rd 0x108) pkts=\$(rd 0x104)\" >> /dev/shm/pw_regs.log
      done ) &
    sleep 0.1
    # NO DRA reads here. The background sampler above already owns
    # direct_reg_access, and DRA is a SINGLE ADDRESS LATCH -- a second concurrent
    # reader silently returns the other reader's register. Observed in rep 1:
    # biterr read back as 0x4922282, which is cap_out's golden constant.
    # Alignment is by wall clock against the sampler's own timestamps instead.
    echo \"IQ_START t=\$(date +%s.%N)\"
    iio_readdev -u local: -b 32768 -s $NSAMP axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/pw.iq 2>/tmp/iio.err || cat /tmp/iio.err
    echo \"IQ_END   t=\$(date +%s.%N)\"
    wait" 2>/dev/null | tee "$OUT/anchor_$r.txt"

  for f in pw.iq pw_regs.log; do
    SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
      -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      root@$B:/dev/shm/$f "$OUT/${f%.*}_$r.${f##*.}" </dev/null 2>/dev/null
  done
  echo "  pulled: $(ls -la "$OUT"/pw_$r.iq 2>/dev/null | awk '{print $5}') bytes"
  $W $B 'rm -f /dev/shm/pw.iq' 2>/dev/null      # 320 MB, do not accumulate
done

echo
echo "=== EVM vs biterr, windowed within each capture ==="
for r in $(seq 1 "$REPS"); do
  [ -f "$OUT/pw_$r.iq" ] || continue
  echo "--- rep $r ---"
  /mnt/onetb/MATLAB/R2025b/bin/matlab -batch \
    "cd('$D'); prewedge_evm('$OUT/pw_$r.iq','$OUT/pw_regs_$r.log','$OUT/anchor_$r.txt')" 2>&1 | tail -20
done
echo "=== artifacts: $OUT ==="
