#!/bin/bash
# [sim] Task 12: certify the smoke leg, then launch the five gate legs.  No foreground polls.
#
# The smoke is a TRUNCATED run (25 air frames of the 428-frame n_p000.iq).  Two
# consequences, both handled here rather than discovered later:
#   (a) sim_sro.cpp's `sidx` FREEZES at nsamp once the stimulus is exhausted while
#       frames already in the pipeline keep being delivered, so the sidx DELTA against
#       the full-length baseline is not constant over the tail.  The pre-fill latency
#       is therefore measured on the GATE leg r4_p000, not here; the smoke checks
#       CONTENT only (t12_ident.py's content_equal, which is seq-keyed).
#   (b) the truncated run delivers far fewer frames, so `same_seq_set` is expected to
#       be false here and is NOT a smoke condition.
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim
while systemctl --user is-active --quiet t12smoke; do sleep 10; done
L=t12_smoke.log
ok=1
grep -q 'WRAP4_FILE wrap_byte_sro4.v t12a' $L || { echo "SMOKE_FAIL wrapper file"; ok=0; }
grep -q 'WRAP4_DEFINE RXFIX_R4'            $L || { echo "SMOKE_FAIL define"; ok=0; }
R=$(grep '^r3_skips=' sk4_p000_res.txt 2>/dev/null)
# r3_skips IS r4_skips; r3_extras IS the r4_prefilled SENTINEL 0xA5A50001 = 2779087873
[ "$R" = "r3_skips=0 r3_extras=2779087873" ] || { echo "SMOKE_FAIL witnesses: $R"; ok=0; }
# the ring must actually have pre-filled: occupancy (frames.txt col 24 = oMax) >= 14
OM=$(awk -F, '$1>=3 && $1<=20 {print $24}' sk4_p000_frames.txt 2>/dev/null | sort -n | tail -1)
OMIN=$(awk -F, '$1>=3 && $1<=20 {print $23}' sk4_p000_frames.txt 2>/dev/null | sort -n | head -1)
echo "SMOKE occupancy over air frames 3..20: min=$OMIN max=$OM"
[ -n "$OM" ] && [ "$OM" -ge 14 ] && [ "$OM" -le 18 ] || { echo "SMOKE_FAIL occupancy $OMIN..$OM not in [14,18]"; ok=0; }
NL=$(wc -l < sk4_p000_deliv.txt 2>/dev/null || echo 0)
if [ "$NL" -gt 3 ]; then
  python3 t12_ident.py sk4_p000 b_p000 > t12_smoke_ident.txt 2>&1
  if grep -q 'content_equal=True' t12_smoke_ident.txt; then
    echo "SMOKE seq-keyed CONTENT identity on the common frames: PASS ($NL delivered)"
  else
    echo "SMOKE_FAIL content mismatch -- see t12_smoke_ident.txt"; ok=0
  fi
  grep -E '^  (common seq|CONTENT|sidx delta)' t12_smoke_ident.txt
else
  echo "SMOKE_FAIL only $NL delivered frames"; ok=0
fi
if [ "$ok" = "1" ]; then
  echo "T12_SMOKE_PASS"
  ./runall_t12.sh
else
  echo "T12_SMOKE_FAIL -- gate legs NOT launched"
fi
