#!/bin/bash
# =============================================================================
# lo_offset_test.sh [reps] -- does the wedge rate depend on the RX LO offset?
#
# WHY. Every measurement today ran at LO_B_RX=1900020000, i.e. +20 kHz off-null, which
# the carrier loop must continuously track. If time-to-wedge depends on that offset, the
# offset is a contributing cause and the mitigation is trivial (retune the LO). If it
# does not, the offset is exonerated and attention stays on the demod path, where the
# pre-wedge EVM evidence points (bits err with EVM flat to 0.08 pp).
#
# METRIC = TIME-TO-WEDGE, not steady-state quality. Steady-state quality is ~98-99%
# golden in BOTH regimes when healthy, so it cannot discriminate; what has actually moved
# all day is how long the link survives (0.4 s .. 150 s). Measuring the wrong quantity is
# how the loop-gain sweep produced an unrankable table.
#
# INTERLEAVED across reps: the rig drifts over tens of minutes, so all-of-A-then-all-of-B
# would confound offset with time. Time-to-wedge is also recorded per rep so drift is
# visible rather than assumed away.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.146
REPS=${1:-3}
MAXW=${MAXW:-120}                 # cap the wait; a link that survives this long is "no wedge"
GOLDEN=0x04922282
OUT=$D/looffset/$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
CSV=$OUT/results.csv
echo "rep,offset_hz,time_to_wedge_s,golden_pct,biterr_per_s" > "$CSV"

# null and +20 kHz; LO_A_TX is 1.9 GHz so null = exactly 1900000000
OFFSETS=${OFFSETS:-"1900000000 1900020000"}

measure_ttw() { # $1 rep  $2 rxlo
  local rep=$1 rxlo=$2 lbl
  lbl=$(( rxlo - 1900000000 ))
  echo "--- rep $rep  RX LO $rxlo (offset ${lbl} Hz) ---"
  LO_B_RX=$rxlo "$D/reverse_rom_soak.sh" 1 > "$OUT/arm_${rep}_${lbl}.log" 2>&1 || true
  if ! grep -qE "LOCKED GOLDEN" "$OUT/arm_${rep}_${lbl}.log"; then
    echo "    did not lock golden -- recording as no-lock"
    echo "$rep,$lbl,NOLOCK,0,0" >> "$CSV"; return
  fi
  # watch until golden collapses (40 consecutive non-golden) or MAXW elapses
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
    rd(){ echo \"\$1\" > \$DRA; cat \$DRA; }
    t0=\$(date +%s%N); bad=0; n=0; g=0
    b0=\$(( \$(rd 0x108) ))
    end=\$(( \$(date +%s) + $MAXW ))
    while [ \$(date +%s) -lt \$end ]; do
      c=\$(rd 0x144); n=\$((n+1))
      if [ \$(( \$c )) -eq \$(( $GOLDEN )) ]; then g=\$((g+1)); bad=0; else bad=\$((bad+1)); fi
      if [ \$bad -ge 40 ]; then
        echo \"TTW=\$(( (\$(date +%s%N) - t0) / 1000000 )) GOLD=\$g N=\$n BE=\$(( \$(rd 0x108) - b0 ))\"
        exit 0
      fi
    done
    echo \"TTW=NONE GOLD=\$g N=\$n BE=\$(( \$(rd 0x108) - b0 ))\"" 2>/dev/null | tee "$OUT/ttw_${rep}_${lbl}.txt"

  local line ttw gold n be
  line=$(grep -o 'TTW=[^ ]* GOLD=[0-9]* N=[0-9]* BE=[0-9-]*' "$OUT/ttw_${rep}_${lbl}.txt" | tail -1)
  ttw=$(echo "$line" | sed -n 's/.*TTW=\([^ ]*\).*/\1/p')
  gold=$(echo "$line" | sed -n 's/.*GOLD=\([0-9]*\).*/\1/p')
  n=$(echo "$line"    | sed -n 's/.*N=\([0-9]*\).*/\1/p')
  be=$(echo "$line"   | sed -n 's/.*BE=\([0-9-]*\).*/\1/p')
  local gp=0; [ "${n:-0}" -gt 0 ] && gp=$(awk -v g="${gold:-0}" -v n="$n" 'BEGIN{printf "%.1f",100*g/n}')
  local tts="NONE"; [ "$ttw" != "NONE" ] && tts=$(awk -v m="$ttw" 'BEGIN{printf "%.1f", m/1000}')
  echo "    time-to-wedge=${tts}s golden=${gp}% biterr_total=${be:-0}"
  echo "$rep,$lbl,$tts,$gp,${be:-0}" >> "$CSV"
}

echo "=== lo_offset_test: $REPS reps, offsets [$OFFSETS], cap ${MAXW}s -> $CSV ==="
for r in $(seq 1 "$REPS"); do
  for o in $OFFSETS; do measure_ttw "$r" "$o"; done
done

echo; echo "=== SUMMARY ==="
python3 - "$CSV" <<'PY'
import csv,sys,statistics as st
from collections import defaultdict
d=defaultdict(list)
for r in csv.DictReader(open(sys.argv[1])):
    d[r['offset_hz']].append(r)
print(f"{'offset':>10} {'n':>3} {'median TTW':>12} {'no-wedge':>9} {'median golden':>14}")
for k,v in sorted(d.items(), key=lambda x:int(x[0])):
    tt=[float(r['time_to_wedge_s']) for r in v if r['time_to_wedge_s'] not in ('NONE','NOLOCK')]
    nw=sum(1 for r in v if r['time_to_wedge_s']=='NONE')
    gp=[float(r['golden_pct']) for r in v if r['golden_pct'].replace('.','').isdigit()]
    m=f"{st.median(tt):.1f}s" if tt else "n/a"
    print(f"{k:>10} {len(v):>3} {m:>12} {nw:>6}/{len(v)} {(st.median(gp) if gp else 0):>13.1f}%")
print("\n  If median TTW differs materially between offsets, the LO offset contributes and")
print("  retuning is a cheap mitigation. If not, the offset is exonerated and the demod")
print("  path stays the primary suspect (pre-wedge EVM: bits err with EVM flat 0.08 pp).")
PY
