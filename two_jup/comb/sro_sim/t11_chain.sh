#!/bin/bash
# [sim] Task 11: certify the smoke leg, then launch the four gate legs.  No foreground polls.
#
# SMOKE COMPARISON, corrected 2026-09-04 after a FALSE FAIL.  The smoke leg is a
# TRUNCATED run (25 air frames of the 428-frame n_p000.iq).  sim_sro.cpp's `sidx` is
# the driver's INPUT-SAMPLE counter and it FREEZES at nsamp once the stimulus is
# exhausted (sim_sro.cpp: `if(sidx<nsamp){...sidx++;} else t->adc_validIn=0;`), while
# frames already in the receive pipeline keep being delivered.  Column 1 of
# <p>_deliv.txt is that frozen sidx, so the LAST frames of a truncated run carry a
# different annotation from the same frames of the full-length b_p000 even when the
# delivered BYTES are identical.  A whole-file md5 of a truncated run against a
# full-length one therefore tests the driver's bookkeeping, not the RTL.
#
# So the smoke checks two things instead:
#   (a) FULL-LINE identity for every frame delivered while the stimulus was still
#       flowing (sidx < nsamp) -- sidx included;
#   (b) CONTENT identity (nwords, FNV hash over the delivered bytes, user flag) for
#       EVERY delivered frame, tail included.
# G1 in the pre-registration is UNCHANGED and needs no such care: the gate leg s_p000
# uses nsamp=21,114,096, byte-for-byte the same as b_p000, so there is no truncation
# skew and the whole-file md5 comparison stands exactly as pre-registered.
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/sro_sim
P=/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/sdd_archive/2026-09-04-rxfix/progress.md
NS=1233300                       # the smoke leg's nsamp (25 air frames)
while systemctl --user is-active --quiet t11smoke; do sleep 10; done
L=t11_smoke.log
ok=1
grep -q 'WRAP3S_FILE wrap_byte_sro3s.v e7c1' $L || { echo "SMOKE_FAIL wrapper file"; ok=0; }
grep -q 'WRAP3S_DEFINE RXFIX_R3S'            $L || { echo "SMOKE_FAIL define"; ok=0; }
R=$(grep '^r3_skips=' sk_p000_res.txt 2>/dev/null)
[ "$R" = "r3_skips=0 r3_extras=0" ] || { echo "SMOKE_FAIL witnesses: $R"; ok=0; }
NL=$(wc -l < sk_p000_deliv.txt 2>/dev/null || echo 0)
if [ "$NL" -gt 3 ]; then
  NF=$(awk -F, -v n=$NS '$1<n' sk_p000_deliv.txt | wc -l)
  if diff -q <(awk -F, -v n=$NS '$1<n' sk_p000_deliv.txt) \
             <(head -n "$NL" b_p000_deliv.txt | awk -F, -v n=$NS '$1<n') >/dev/null; then
    echo "SMOKE full-line identity on the $NF frames delivered with stimulus still flowing: PASS"
  else
    echo "SMOKE_FAIL full-line diff on flowing frames"; ok=0
  fi
  if diff -q <(cut -d, -f2,3,4 sk_p000_deliv.txt) \
             <(head -n "$NL" b_p000_deliv.txt | cut -d, -f2,3,4) >/dev/null; then
    echo "SMOKE content identity (nwords,hash,user) on all $NL delivered frames: PASS"
  else
    echo "SMOKE_FAIL content diff over $NL frames"; ok=0
  fi
else
  echo "SMOKE_FAIL only $NL delivered frames"; ok=0
fi
if [ "$ok" = "1" ]; then
  echo "T11_SMOKE_PASS"
  ./runall_t11.sh
else
  echo "T11_SMOKE_FAIL -- gate legs NOT launched"
fi
