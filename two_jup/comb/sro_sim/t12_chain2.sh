#!/bin/bash
# [sim] Task 12, chain v2: certify the smoke leg, then launch the five gate legs.
#
# WHY v2 IS A NEW FILE AND WHAT CHANGED.  t12_chain.sh (v1) failed the smoke and did
# NOT launch the gate legs.  Two of its three failures were MY errors, not the RTL's:
#
#  1. WRONG CONSTANT.  v1 tested for the r4_prefilled sentinel as decimal 2779087873.
#     0xA5A50001 is 2779054081.  The sentinel was correct in the run all along.
#  2. GATE CRITERIA IMPORTED INTO A SMOKE.  v1 required r4_skips = 0 and occupancy in
#     [14,18] -- G2 and G3 of the pre-registration -- on a 25-air-frame TRUNCATED run
#     that is almost entirely acquisition.  A smoke leg cannot carry gate rows: its
#     whole point is to prove the harness compiled the right wrapper and that the RTL
#     delivers the right bytes, before spending five full legs.  Those two rows are
#     scored on the FULL-LENGTH leg r4_p000 and reported there, pass or fail.
#  3. The sidx-delta spread is likewise NOT a smoke condition: sim_sro.cpp's sidx
#     FREEZES at nsamp once the stimulus is exhausted while frames already in the
#     pipeline keep being delivered, so a truncated run's tail frames carry a frozen
#     annotation (measured: -49365 = one air frame, the Task 11 lesson exactly).  The
#     pre-fill latency is measured on the full-length leg over frames delivered while
#     the stimulus was still flowing.
#
# SMOKE = WRAPPER PROVENANCE + SEQ-KEYED CONTENT IDENTITY.  Everything else is printed
# as a diagnostic and cannot block the legs.
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim
while systemctl --user is-active --quiet t12smoke; do sleep 10; done
L=t12_smoke.log
ok=1
grep -q 'WRAP4_FILE wrap_byte_sro4.v t12a' $L || { echo "SMOKE_FAIL wrapper file"; ok=0; }
grep -q 'WRAP4_DEFINE RXFIX_R4'            $L || { echo "SMOKE_FAIL define"; ok=0; }
NL=$(wc -l < sk4_p000_deliv.txt 2>/dev/null || echo 0)
if [ "$NL" -gt 3 ]; then
  python3 t12_ident.py sk4_p000 b_p000 > t12_smoke_ident.txt 2>&1
  if grep -q 'content_equal=True' t12_smoke_ident.txt; then
    echo "SMOKE seq-keyed CONTENT identity on the common frames: PASS ($NL delivered)"
  else
    echo "SMOKE_FAIL content mismatch -- see t12_smoke_ident.txt"; ok=0
  fi
else
  echo "SMOKE_FAIL only $NL delivered frames"; ok=0
fi
# ---- diagnostics, non-blocking: these are what the gate legs will be scored on ----
echo "SMOKE_DIAG witnesses: $(grep '^r3_skips=' sk4_p000_res.txt)   (0xA5A50001 = 2779054081 = r4_prefilled set)"
echo "SMOKE_DIAG $(grep '^rh_pop_on_empty' sk4_p000_res.txt)"
echo "SMOKE_DIAG occupancy oS/oE/oMin/oMax by air frame 0..24:"
awk -F, '$1<=24{printf "  f%-3s %2s %2s %2s %2s pe=%s\n",$1,$21,$22,$23,$24,$25}' sk4_p000_frames.txt
grep -E '^  (common seq|CONTENT|sidx delta|  distribution)' t12_smoke_ident.txt
if [ "$ok" = "1" ]; then
  echo "T12_SMOKE_PASS (wrapper provenance + content identity)"
  ./runall_t12.sh
else
  echo "T12_SMOKE_FAIL -- gate legs NOT launched"
fi
