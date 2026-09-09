#!/bin/bash
# =============================================================================
# prewedge_trigger.sh [watch_s] -- TRIGGERED capture of the pre-wedge window.
#
# WHY TRIGGERED. The blind version grabs 1.4 s of IQ at arm and hopes it straddles the
# onset. Measured: time-to-wedge is 0.4 s .. 150 s depending on rig state, and two blind
# reps both landed entirely inside healthy stretches (98% golden). /dev/shm caps a single
# grab at ~3.9 s, still shorter than the phenomenon. So stop guessing and trigger.
#
# The campaign already learned this once: CAP_SETTLE exists because the IQ grab was
# landing in the wrong window relative to the metric, and the fix was to MOVE the grab,
# not enlarge it. Same fix, made conditional.
#
# TRIGGER. Sample biterr on-board. Establish a running baseline rate over the first
# BASE_N samples, then fire iio_readdev the moment the short-term rate exceeds
# TRIG_MULT x baseline (and at least TRIG_MIN/s, so a near-zero baseline cannot make any
# blip look like a trigger). The grab then spans the degrading window by construction.
#
# ONE DRA READER ONLY: iio_readdev does not touch direct_reg_access, and the sampler is
# the sole DRA user, so the single-address-latch corruption that voided an earlier run
# cannot recur. Register sampling PAUSES during the grab for the same reason it must not
# overlap -- the trigger has already fired by then, so nothing is lost.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.146
WATCH=${1:-1800}
NSAMP=${NSAMP:-80000000}
BASE_N=${BASE_N:-60}
TRIG_MULT=${TRIG_MULT:-4}
TRIG_MIN=${TRIG_MIN:-3000}
OUT=$D/prewedge/trig_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"

echo "=== prewedge_trigger: watch ${WATCH}s, fire at >${TRIG_MULT}x baseline (min ${TRIG_MIN}/s) -> $OUT ==="
"$D/reverse_rom_soak.sh" 1 > "$OUT/arm.log" 2>&1 || true
grep -qE "LOCKED GOLDEN" "$OUT/arm.log" && echo "  armed, locked golden" || echo "  WARNING: did not lock golden"

$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  rd(){ echo \"\$1\" > \$DRA; cat \$DRA; }
  : > /dev/shm/pwt_regs.log; rm -f /dev/shm/pwt.iq
  end=\$(( \$(date +%s) + $WATCH ))
  n=0; base=0; sum=0; prev=\$(( \$(rd 0x108) )); pt=\$(date +%s%N)
  fired=0
  while [ \$(date +%s) -lt \$end ]; do
    cur=\$(( \$(rd 0x108) )); ct=\$(date +%s%N)
    cap=\$(rd 0x144)
    dt=\$(( (ct - pt) / 1000000 )); [ \$dt -le 0 ] && dt=1
    rate=\$(( (cur - prev) * 1000 / dt ))
    echo \"t=\$(date +%s.%N) cap=\$cap biterr=\$cur rate=\$rate\" >> /dev/shm/pwt_regs.log
    prev=\$cur; pt=\$ct; n=\$((n+1))
    if [ \$n -le $BASE_N ]; then
      sum=\$(( sum + rate ))
      [ \$n -eq $BASE_N ] && { base=\$(( sum / $BASE_N )); echo \"BASELINE rate=\${base}/s over $BASE_N samples\"; }
      continue
    fi
    thr=\$(( base * $TRIG_MULT )); [ \$thr -lt $TRIG_MIN ] && thr=$TRIG_MIN
    if [ \$rate -gt \$thr ]; then
      echo \"TRIGGER rate=\${rate}/s > thr=\${thr}/s at t=\$(date +%s.%N)\"
      iio_readdev -u local: -b 32768 -s $NSAMP axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/pwt.iq 2>/dev/null
      echo \"GRAB_DONE t=\$(date +%s.%N) bytes=\$(stat -c%s /dev/shm/pwt.iq 2>/dev/null)\"
      fired=1; break
    fi
  done
  [ \$fired -eq 0 ] && echo NO_TRIGGER_IN_WINDOW
  echo \"samples=\$n\"" 2>&1 | tee "$OUT/trigger.log"

if grep -q GRAB_DONE "$OUT/trigger.log"; then
  for f in pwt.iq pwt_regs.log; do
    SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
      -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      root@$B:/dev/shm/$f "$OUT/$f" </dev/null 2>/dev/null
  done
  $W $B 'rm -f /dev/shm/pwt.iq' 2>/dev/null
  echo "--- EVM across the triggered window ---"
  /mnt/onetb/MATLAB/R2025b/bin/matlab -batch \
    "cd('$D'); prewedge_evm('$OUT/pwt.iq','$OUT/pwt_regs.log','$OUT/trigger.log')" 2>&1 | tail -22
else
  echo "no trigger fired -- the link stayed healthy for the whole window"
  SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
    -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    root@$B:/dev/shm/pwt_regs.log "$OUT/pwt_regs.log" </dev/null 2>/dev/null
fi
echo "=== artifacts: $OUT ==="
