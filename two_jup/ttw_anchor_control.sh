#!/bin/bash
# =============================================================================
# ttw_anchor_control.sh -- is the ~20.3 s time-to-wedge anchored to the ARM, or to my
# own sampler starting?
#
# WHY THIS CONTROL EXISTS. Four independent arm cycles across both LO offsets gave
# 20.3 / 20.2 / 20.3 / 20.2 s -- reproducible to +/-0.05 s. That looks like a
# deterministic, time-triggered hardware event (a periodic tracking calibration would fit;
# this campaign already documented a ~1.5 s BBDC cadence). But a mundane alternative
# produces IDENTICAL numbers: if something in the MEASUREMENT path terminates at a fixed
# offset, TTW is constant and says nothing about the hardware.
#
# Tonight already produced five instrument defects of exactly that shape -- a measurement
# that looks plausible and is wrong for a reason invisible in its own output (engine_gaps
# unable to fire, crc_health a ratio, the stall watchdog skipped under 20 s, batch_m never
# set, two DRA readers on one latch). So the determinism gets a control before it gets an
# interpretation.
#
# THE TEST. Arm, wait DELAY seconds, then start the watch loop.
#   TTW falls by ~DELAY  -> anchored to ARM  -> real deterministic hardware event
#   TTW stays ~20.3 s     -> anchored to MY SAMPLER -> the determinism is my artifact
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.146
GOLDEN=0x04922282
MAXW=${MAXW:-90}
OUT=$D/looffset/anchor_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
CSV=$OUT/results.csv
echo "delay_s,ttw_s,predicted_if_arm_anchored,verdict_hint" > "$CSV"

run_one() { # $1 delay
  local delay=$1
  echo "--- arm, wait ${delay}s, then watch ---"
  "$D/reverse_rom_soak.sh" 1 > "$OUT/arm_$delay.log" 2>&1 || true
  grep -qE "LOCKED GOLDEN" "$OUT/arm_$delay.log" || { echo "    no golden lock, skipping"; return; }
  [ "$delay" -gt 0 ] && sleep "$delay"
  local r
  r=$($W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
    rd(){ echo \"\$1\" > \$DRA; cat \$DRA; }
    t0=\$(date +%s%N); bad=0; n=0
    end=\$(( \$(date +%s) + $MAXW ))
    while [ \$(date +%s) -lt \$end ]; do
      c=\$(rd 0x144); n=\$((n+1))
      if [ \$(( \$c )) -eq \$(( $GOLDEN )) ]; then bad=0; else bad=\$((bad+1)); fi
      [ \$bad -ge 40 ] && { echo \"TTW=\$(( (\$(date +%s%N) - t0) / 1000000 )) N=\$n\"; exit 0; }
    done
    echo \"TTW=NONE N=\$n\"" 2>/dev/null | grep -o 'TTW=[^ ]*' | tail -1 | cut -d= -f2)
  local tts pred
  if [ "$r" = "NONE" ]; then tts=NONE; else tts=$(awk -v m="$r" 'BEGIN{printf "%.1f", m/1000}'); fi
  pred=$(awk -v d="$delay" 'BEGIN{printf "%.1f", 20.3-d}')
  echo "    delay=${delay}s -> TTW=${tts}s   (arm-anchored would predict ~${pred}s)"
  echo "$delay,$tts,$pred," >> "$CSV"
}

echo "=== ttw_anchor_control: does TTW track the arm or the sampler? ==="
for d in 0 8 15; do run_one "$d"; done

echo; echo "=== VERDICT ==="
python3 - "$CSV" <<'PY'
import csv,sys
rows=[r for r in csv.DictReader(open(sys.argv[1])) if r['ttw_s'] not in ('NONE','')]
if len(rows)<2: sys.exit("  too few usable runs")
for r in rows: print(f"  delay={r['delay_s']:>2}s  TTW={r['ttw_s']:>6}s  arm-anchored predicts {r['predicted_if_arm_anchored']}s")
t=[float(r['ttw_s']) for r in rows]; d=[float(r['delay_s']) for r in rows]
spread=max(t)-min(t); dspread=max(d)-min(d)
print()
# FLOOR CHECK FIRST. If every TTW is at the detector floor (40 bad samples at the
# sampler rate, ~0.3 s), the link was already wedging instantly and TTW is constant
# because it is FLOORED, not because it is anchored to anything. Without this the
# verdict below happily reports "anchored to my sampler" off data that discriminates
# nothing -- which is exactly what it did on the first run.
if max(t) < 1.0:
    print("  >>> INCONCLUSIVE: every TTW is at the detector floor (~0.3 s), i.e. the link")
    print("      wedged immediately in all arms. A floored value is constant regardless of")
    print("      what it is anchored to, so this run discriminates NOTHING. Re-run when the")
    print("      link is exhibiting a long TTW (reboot first -- that restored ~20 s before).")
elif spread < 0.25*dspread:
    print("  >>> TTW is CONSTANT across delays -> anchored to MY SAMPLER.")
    print("      The determinism is a measurement artifact, NOT a hardware event.")
elif abs((max(t)-min(t)) - dspread) < 0.4*dspread:
    print("  >>> TTW FALLS with delay, ~1:1 -> anchored to the ARM.")
    print("      A real deterministic, time-triggered event ~20.3 s after arm.")
    print("      Next: periodic tracking calibration is the leading candidate.")
else:
    print("  >>> mixed/partial tracking -- neither explanation is clean; inspect raw runs")
PY
echo "=== $CSV ==="
