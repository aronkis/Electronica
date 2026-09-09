#!/bin/bash
# [sim] Task 12b: score every gate leg.  Run ONCE, after all t12b_* units have exited.
# Everything lands in t12b_score.txt; the gate table in the report is filled from it.
cd "$(dirname "$0")"
exec > t12b_score.txt 2>&1
echo "=== t12b scoring $(date -Is) ==="
echo
echo "########## G16 wrapper provenance (every leg) ##########"
for f in t12b_*.log; do
  echo "-- $f"; grep -E 'WRAP4B_FILE|WRAP4B_DEFINE|SRO_RX' "$f" | sed 's/^/   /'
done
echo
echo "########## unit exit status ##########"
systemctl --user list-units --all 't12b_*' --no-legend | sed 's/^/   /'
echo
echo "########## G1 content identity (n_p000 ONLY -- this is the gate row) ##########"
python3 t12_ident.py r4b_p000 b_p000
echo
echo "########## DIAGNOSTIC ONLY, NOT A GATE ROW: t12_ident on the SRO legs ##########"
echo "## The baseline LOSES frames on these legs by design (b_m10 loses 46), so"
echo "## 'same_seq_set=False' and 'T12_IDENT FAIL' are EXPECTED here and must not be"
echo "## carried into the gate table.  G1 is n_p000 only."
for pair in "r4b_m10 b_m10" "r4b_m40 b_m40" "r4b_m10c b_m10c" "r4b_p10 b_p10"; do
  set -- $pair; echo "---- DIAGNOSTIC $1 vs $2"; python3 t12_ident.py "$1" "$2"
done
echo
echo "########## G4 PRE-ARM STRUCTURAL IDENTITY (every paired leg) ##########"
echo "## Before the first skip R4B's pop IS the baseline expression, so every frame"
echo "## delivered before it must match the baseline INCLUDING sidx."
python3 t12b_prearm.py r4b_p000 b_p000 r4b_m10 b_m10 r4b_m40 b_m40 \
                       r4b_m10c b_m10c r4b_p10 b_p10
echo
echo "########## LOSS on the seq-scored (non-repeating) legs ##########"
python3 score_t7.py r4b_p000 r4b_m10 r4b_m40 r4b_m10c b_m10c r4b_p10 b_p10
echo
echo "########## the tiled control (G11) and the loss-of-lock leg (G15) ##########"
python3 score_sro2.py tb_p000 tb_m10 r4b_tm10
echo "---- lol: R4B against task 6's banked baseline t_lol"
python3 score_sro2.py tb_p000 t_lol r4b_lol
echo
echo "########## G8/G10/G12 skip-position histograms ##########"
python3 t12b_window.py r4b_p000 r4b_m10 r4b_m40 r4b_tm10 r4b_m10c r4b_p10 r4b_lol
echo
echo "########## G15 loss-of-lock RE-ACQUISITION window (frames 195-220) ##########"
echo "## The outage deletes 4.05 air frames at frame 200.  A false sync is most likely"
echo "## during re-acquisition, and a mid-payload skip THERE would be the most"
echo "## silicon-relevant finding in the gate -- so the skips are listed with their tref."
python3 t12b_window.py --frames r4b_lol 195 220
python3 t12b_window.py --frames r4b_lol 198 206
echo
echo "########## hole / skip / loss alignment (falsifier 2) ##########"
python3 t11_align.py b_m10 r4b_m10 r4b_m40 r4b_m10c
echo
echo "########## witnesses and ring state, per leg ##########"
for p in r4b_p000 r4b_m10 r4b_m40 r4b_tm10 r4b_m10c r4b_p10 r4b_lol b_m10c b_p10; do
  [ -f "${p}_res.txt" ] || continue
  echo "-- $p"; grep -E '^r3_skips|^rh_pop_on_empty|^packets|^t7_ok' "${p}_res.txt" | sed 's/^/   /'
  echo "   occupancy oMin/oMax by air frame (first 24, then every 32nd):"
  awk -F, '$1<24 || $1%32==0 {printf "     f%-3s oS=%-2s oE=%-2s oMin=%-2s oMax=%-2s pe=%-3s pf=%s\n",$1,$21,$22,$23,$24,$25,$26}' "${p}_frames.txt" | head -40
done
echo
echo "=== t12b scoring done $(date -Is) ==="
