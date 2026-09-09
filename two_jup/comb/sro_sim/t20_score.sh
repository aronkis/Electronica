#!/bin/bash
# [sim] Task 20: score every S1 (R4D+R1) gate leg.  Run ONCE, after all t20_* units exit.
# Everything lands in t20_score.txt; the gate table in task-20-report.md is filled from it.
# Pre-registration: two_jup/comb/RXFIX_S1_SIM_GATE.md.
cd "$(dirname "$0")"
exec > t20_score.txt 2>&1
echo "=== t20 scoring $(date -Is) ==="
echo
echo "########## S9 provenance (every leg): binary md5, wrapper banner, SRO_RX line ##########"
for f in t20_*.log; do
  echo "-- $f"; grep -E 'T20_BIN|T20_MD5|T20_LEG|WRAP4D_FILE|WRAP4D_DEFINE|SRO_RX' "$f" | sed 's/^/   /'
done
echo
echo "########## unit exit status ##########"
systemctl --user list-units --all 't20_*' --no-legend | sed 's/^/   /'
echo
echo "########## S9 runtime discriminator: pdOcc (R4D leaves it SHORT, R1 PINS it) ##########"
echo "## banked R4D:   r4d_p000 12333 | r4d_m10 12331 | r4d_p10 12332 | r4d_tm10 env 12332..12333"
for p in r4dr1_p000 r4dr1_m10 r4dr1_m40 r4dr1_tm10 r4dr1_m10c r4dr1_p10 r4dr1_lol; do
  [ -f "${p}_res.txt" ] || continue
  echo "-- $p"
  grep -E '^rh_pop_on_empty' "${p}_res.txt" | sed 's/^/   /'
  # pdOccMin/pdOccMax are columns 29/30 of _frames.txt (score_sro2.FC order); the fill
  # transient is skipped by starting at air frame 4, as score_sro2's own envelope does.
  awk -F, '$1>=4 && NF>=30 {if(mn==""||$29<mn){mn=$29} if($30>mx){mx=$30}} \
       END{printf "   pdOcc per-frame envelope (frames >= 4): %s..%s  (12333 = full)\n", mn, mx}' "${p}_frames.txt"
  grep -E '^rh_push_on_full|pdOcc_end' "${p}_res.txt" | sed 's/^/   /'
done
echo
echo "########## S1 / S1b: the p000 identity DISJUNCTION (pre-registration section 4.2) ##########"
echo "## GATE is LOSS, not byte identity: R4D takes 8 skips on p000, so a byte difference"
echo "## would mean R1 is WORKING.  Both branches were pre-interpreted before the run."
for s in _deliv _seq; do
  if cmp -s "r4dr1_p000${s}.txt" "r4d_p000${s}.txt"; then
    echo "   r4dr1_p000${s}.txt == r4d_p000${s}.txt   (byte-identical)"
  else
    echo "   r4dr1_p000${s}.txt DIFFERS from r4d_p000${s}.txt"
    echo "     lines: $(wc -l < r4dr1_p000${s}.txt) vs $(wc -l < r4d_p000${s}.txt); first differing line:"
    diff "r4dr1_p000${s}.txt" "r4d_p000${s}.txt" | head -6 | sed 's/^/       /'
  fi
done
echo "   -- and against the BASELINE b_p000 (task 7), for reference:"
for s in _deliv _seq; do
  cmp -s "r4dr1_p000${s}.txt" "b_p000${s}.txt" \
    && echo "   r4dr1_p000${s}.txt == b_p000${s}.txt" \
    || echo "   r4dr1_p000${s}.txt DIFFERS from b_p000${s}.txt"
done
echo "   -- seq-keyed content identity (t12_ident, the comparator task 12 cut for this):"
python3 t12_ident.py r4dr1_p000 r4d_p000
echo
echo "########## S1/S2/S7: LOSS on the seq-scored legs, DENOMINATOR 1 (seq-keyed) ##########"
echo "## banked: b_p000 0.00 | b_p10 4.99 | r4b_p10 6.65 | r4d_p10 REFUSED"
echo "##         b_m10 10.93 | r4b_m10 0.48 | r4d_m10 REFUSED | b_m40/b_m10c see below"
T7_NAIR=428 python3 score_t7.py r4dr1_p000 r4dr1_m10 r4dr1_m40 r4dr1_m10c r4dr1_p10
echo
echo "########## the SAME legs, DENOMINATOR 2 (t7_ok / 424 air frames fed) ##########"
echo "## This is the denominator task 14 section 2.2 showed cannot be gamed: once framing"
echo "## collapses the delivered frames carry no TGEN magic and VANISH from the seq-keyed"
echo "## denominator instead of counting as losses (a naive bounded rescore then says 0.00 %)."
echo "## The one-frame acquisition floor is real: b_p000 scores 423/424 = 0.24 % here."
printf "   %-14s %-8s %-8s %-9s %-8s %s\n" leg t7_ok t7_bad nomagic "D2_loss%" "(banked comparator)"
for p in r4dr1_p000 r4dr1_m10 r4dr1_m40 r4dr1_m10c r4dr1_p10 \
         b_p000 b_p10 r4b_p10 r4d_p10 b_m10 r4b_m10 r4d_m10 b_m40 r4d_m40 b_m10c r4d_m10c; do
  [ -f "${p}_res.txt" ] || continue
  awk -F'[= ]' -v L="$p" '/^t7_ok=/{ok=$2; bad=$4; nm=$6;
      printf "   %-14s %-8s %-8s %-9s %.2f\n", L, ok, bad, nm, 100.0*(424-ok)/424 }' "${p}_res.txt"
done
echo
echo "########## S3/S4/S5: ring, PD FIFO and extras, per leg ##########"
for p in r4dr1_p000 r4dr1_m10 r4dr1_m40 r4dr1_tm10 r4dr1_m10c r4dr1_p10 r4dr1_lol; do
  [ -f "${p}_res.txt" ] || continue
  echo "-- $p"
  grep -E '^packets|^r3_skips|^rh_pop_on_empty|^t7_ok' "${p}_res.txt" | sed 's/^/   /'
  echo "   ring occupancy oMin/oMax by air frame (first 24, then every 32nd):"
  awk -F, '$1<24 || $1%32==0 {printf "     f%-3s oS=%-2s oE=%-2s oMin=%-2s oMax=%-2s pe=%-3s pf=%s\n",$1,$21,$22,$23,$24,$25,$26}' "${p}_frames.txt" | head -32
  echo "   ring occupancy plateau after lock (oMax histogram, frames >= 24):"
  awk -F, '$1>=24 {h[$24]++} END{n=0; for(k in h){printf "     oMax=%-3s %s\n",k,h[k]; if(++n>12)break}}' "${p}_frames.txt" | sort -t= -k2 -n
done
echo
echo "########## S5: extra-pop census and spacing (ep kind 5), skip census (kind 4) ##########"
for p in r4dr1_p000 r4dr1_m10 r4dr1_m40 r4dr1_tm10 r4dr1_m10c r4dr1_p10 r4dr1_lol; do
  [ -f "${p}_ep.txt" ] || continue
  echo "-- $p"
  awk -F, '{k[$1]++} END{for(x in k) printf "   ep kind %s: %s\n", x, k[x]}' "${p}_ep.txt" | sort
  echo "   extras (kind 5) at air frames:"
  awk -F, '$1==5{printf "%s ",$3}' "${p}_ep.txt" | fold -s -w 100 | sed 's/^/     /'
  echo
  awk -F, '$1==5{f[n++]=$3} END{if(n>1){for(i=1;i<n;i++)d[f[i]-f[i-1]]++;
       printf "   extra spacing histogram:"; for(x in d) printf " %s:%s", x, d[x]; print ""}}' "${p}_ep.txt"
done
echo
echo "########## S6 FALSIFIER: loss alignment to EXTRAS (kind 5) and to holes (kind 0) ##########"
echo "## kind 5 == the extra pop in the R4D/R4DR1 lineage (wrap_byte_sro4d.v header)."
T7_NAIR=428 python3 t11_align.py r4dr1_p10 r4dr1_m10 r4dr1_m40 r4dr1_m10c
echo
echo "## the banked R4D legs, for contrast (both REFUSE the seq scoring -- that IS the result):"
T7_NAIR=428 python3 t11_align.py r4d_p10 r4d_m10
echo
echo "########## S8: the tiled control and the loss-of-lock leg ##########"
python3 score_sro2.py tb_p000 tb_m10 r4b_tm10 r4d_tm10 r4dr1_tm10
echo "---- lol: R4DR1 against task 6's banked baseline t_lol and task 14's r4d_lol"
python3 score_sro2.py tb_p000 t_lol r4d_lol r4dr1_lol
echo
echo "########## S10 diagnostics: does R1 ALONE perturb the skip-only legs? ##########"
echo "## m40/m10c/lol carry 210/60/17 skips and ZERO extras.  Under R4D all three were"
echo "## byte-identical to R4B.  Section 4.1 pre-interprets all three outcomes."
for p in m40 m10c lol; do
  for s in _deliv _seq; do
    if [ -f "r4dr1_${p}${s}.txt" ] && [ -f "r4d_${p}${s}.txt" ]; then
      cmp -s "r4dr1_${p}${s}.txt" "r4d_${p}${s}.txt" \
        && echo "   r4dr1_${p}${s}.txt == r4d_${p}${s}.txt" \
        || echo "   r4dr1_${p}${s}.txt DIFFERS from r4d_${p}${s}.txt ($(wc -l < r4dr1_${p}${s}.txt) vs $(wc -l < r4d_${p}${s}.txt) lines)"
    fi
  done
done
echo "   -- and tm10 (a gate leg, but the same question):"
for s in _deliv _seq; do
  cmp -s "r4dr1_tm10${s}.txt" "r4d_tm10${s}.txt" \
    && echo "   r4dr1_tm10${s}.txt == r4d_tm10${s}.txt" \
    || echo "   r4dr1_tm10${s}.txt DIFFERS from r4d_tm10${s}.txt"
done
echo
echo "########## S5/S9: skip+extra window positions (t12b_window, RTL slot vs recount) ##########"
python3 t12b_window.py r4dr1_p000 r4dr1_m10 r4dr1_m40 r4dr1_tm10 r4dr1_m10c r4dr1_p10 r4dr1_lol
echo
echo "=== t20 scoring done $(date -Is) ==="
