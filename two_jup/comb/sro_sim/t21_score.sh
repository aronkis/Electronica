#!/bin/bash
# [sim] Task 21: score every R4E gate leg.  Run ONCE, after all t21_* units have exited.
# Everything lands in t21_score.txt; the gate table in the report is filled from it.
#
# T7_NAIR IS EXPORTED HERE AND THAT IS NOT A PREFERENCE.  score_t7.py reads
# nair = int(os.environ.get('T7_NAIR','0')) or None; UNSET, its "SEQ RANGE IMPLAUSIBLE"
# refusal never runs and a leg whose framing collapsed scores as a plausible number --
# the trap task 14 section 2.2 named.  428 air frames are fed on every full-length leg.
cd "$(dirname "$0")"
export T7_NAIR=428
exec > t21_score.txt 2>&1
echo "=== t21 scoring $(date -Is)  T7_NAIR=$T7_NAIR ==="
echo
echo "########## K9 wrapper provenance (every leg) ##########"
for f in t21_*.log; do
  echo "-- $f"; grep -E 'WRAP4E_FILE|WRAP4E_DEFINE|SRO_RX' "$f" | sed 's/^/   /'
done
echo
echo "########## unit exit status ##########"
systemctl --user list-units --all 't21_*' --no-legend | sed 's/^/   /'
echo
echo "########## K1 content identity vs R4B (n_p000) and vs the baseline ##########"
for p in deliv seq; do
  for l in p000 m40 tm10 m10c lol m10 p10; do
    a=r4e_${l}_${p}.txt; b=r4b_${l}_${p}.txt
    [ -f "$a" ] && [ -f "$b" ] || continue
    if cmp -s "$a" "$b"; then echo "   IDENTICAL   $a == $b  ($(wc -l < "$a") lines)"
    else echo "   DIFFERS     $a vs $b  ($(wc -l < "$a") vs $(wc -l < "$b") lines)"; fi
  done
done
echo
echo "-- t12_ident r4e_p000 vs b_p000 (the baseline row)"
python3 t12_ident.py r4e_p000 b_p000
echo
echo "########## K13 pre-arm structural identity ##########"
## t12b_prearm.py keys the pre-arm boundary on <pfx>_skipwin.txt (task 12b's name).  R4E
## writes <pfx>_win.txt with a kind column, so the compatibility view is regenerated here
## and the boundary is the FIRST STEERING ACTION OF EITHER KIND -- a drop perturbs the
## delivered stream exactly as a skip does, so keying on skips alone would compare
## post-drop frames as if they were pre-arm and report a false failure.
python3 - <<'PYEOF'
import glob
for f in sorted(glob.glob('r4e_*_win.txt')):
    p = f[:-len('_win.txt')]
    rows = [l for l in open(f) if not l.startswith('#')]
    with open(p + '_skipwin.txt', 'w') as g:
        g.write('# n,sidx,beat,slot_rtl,slot_harness,dt_enb,occ,tref,locked,opens,kind\n')
        for l in rows:
            g.write(','.join(l.strip().split(',')[:11]) + '\n')
    print(f'   {p}: {len(rows)} steering events -> {p}_skipwin.txt')
PYEOF
python3 t12b_prearm.py r4e_p000 b_p000 r4e_m10 b_m10 r4e_m40 b_m40 \
                       r4e_m10c b_m10c r4e_p10 b_p10
echo
echo "########## K2/K6 LOSS on the seq-scored legs (T7_NAIR bounded) ##########"
python3 score_t7.py r4e_p000 r4e_m10 r4e_m40 r4e_m10c r4e_p10 b_m10c b_p10
echo
echo "########## the tiled control and the loss-of-lock leg ##########"
python3 score_sro2.py tb_p000 tb_m10 r4e_tm10
echo "---- lol: R4E against task 6's banked baseline t_lol"
python3 score_sro2.py tb_p000 t_lol r4e_lol
echo
echo "########## K2 AIR-FRAMES-FED denominator, raw counts, every leg ##########"
echo "## t7_ok of 428 fed.  Reported beside the seq-keyed number, never instead of it."
for p in r4e_p000 r4e_m10 r4e_m40 r4e_m10c r4e_p10 r4e_lol b_p10 b_m10 b_m10c r4b_p10 r4b_m10; do
  [ -f "${p}_res.txt" ] || continue
  printf "   %-10s %s\n" "$p" "$(grep -E '^t7_ok|^packets' "${p}_res.txt" | tr '\n' ' ')"
done
echo
echo "########## K4/K7/K10 event + LANDING-SLOT histograms, and the period precondition ##########"
python3 t21_window.py r4e_p000 r4e_m10 r4e_m40 r4e_tm10 r4e_m10c r4e_p10 r4e_lol
echo
echo "########## K5 the Preamble_Detector realignment FIFO -- the row Task 14 sec 3 turns on ##########"
echo "## pdPof (kind-6 records do not exist; pdPof shows up in <p>_res.txt and in the"
echo "## per-frame columns) and pdOcc must be 0 and flat at 12333 on EVERY leg."
for p in r4e_p000 r4e_m10 r4e_m40 r4e_tm10 r4e_m10c r4e_p10 r4e_lol; do
  [ -f "${p}_res.txt" ] || continue
  echo "-- $p"; grep -E 'pd_push_on_full|pd_pop_on_empty|pdPof|pdOcc' "${p}_res.txt" | sed 's/^/   /'
done
echo
echo "########## K8 hole / event / loss alignment (the falsifier) ##########"
python3 t11_align.py b_m10 r4e_m10 r4e_m40 r4e_m10c
echo
echo "########## witnesses and ring state, per leg ##########"
for p in r4e_p000 r4e_m10 r4e_m40 r4e_tm10 r4e_m10c r4e_p10 r4e_lol; do
  [ -f "${p}_res.txt" ] || continue
  echo "-- $p"; grep -E '^r3_skips|^rh_pop_on_empty|^packets|^t7_ok' "${p}_res.txt" | sed 's/^/   /'
  echo "   occupancy oMin/oMax by air frame (first 24, then every 32nd):"
  awk -F, '$1<24 || $1%32==0 {printf "     f%-3s oS=%-2s oE=%-2s oMin=%-2s oMax=%-2s pe=%-3s pf=%s\n",$1,$21,$22,$23,$24,$25,$26}' "${p}_frames.txt" | head -40
  echo "   push_on_full per frame (nonzero only):"
  awk -F, '$26>0 {printf "     f%s pf=%s\n",$1,$26}' "${p}_frames.txt" | head -20
  echo "   push_on_full TOTAL: $(awk -F, '{s+=$26} END{print s+0}' "${p}_frames.txt")"
done
echo
echo "=== t21 scoring done $(date -Is) ==="
