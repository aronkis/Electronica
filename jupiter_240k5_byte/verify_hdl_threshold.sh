#!/bin/bash
# verify_hdl_threshold.sh -- confirm the CFC-jump reset-gating fix is in the
# GENERATED HDL: the CFO-step-change detector's Compare-To-Constant threshold
# must be 0.0125 cyc/sym, NOT the old 0.0015625. In the fixed-point sfix22_En21
# format: 0.0125 * 2^21 = 26214 (0x6666); 0.0015625 * 2^21 = 3277 (0x0CCD).
HDLDIR=/mnt/onetb/scratch/qpsk_variants/fec_jupiter_rxfix/hdl_prj_jupiter_composite
echo "=== searching generated Verilog for the CFO-step threshold constant ==="
# 0.0125 * 2^21 = 26214 ; -0.0125 => two's-comp 22-bit = 4194304-26214 = 4168090
# 0.0015625 * 2^21 = 3277 (OLD)
NEW_POS=26214; NEW_NEG=$((4194304-26214)); OLD_POS=3277; OLD_NEG=$((4194304-3277))
echo "expected NEW: +${NEW_POS} / -${NEW_NEG} (0.0125) ; OLD (must be ABSENT): +${OLD_POS} / -${OLD_NEG} (0.0015625)"
# find the CFO step change detector generated module(s)
FILES=$(grep -rIl -iE "CFO|StepChange|CoarseFrequency|Compare_To_Constant" "$HDLDIR" --include="*.v" 2>/dev/null)
echo "--- candidate HDL files ---"; echo "$FILES" | head
echo "--- occurrences of NEW constant 26214 (0.0125) ---"
grep -rIn "\b${NEW_POS}\b" "$HDLDIR" --include="*.v" 2>/dev/null | head
grep -rIn "\b${NEW_NEG}\b" "$HDLDIR" --include="*.v" 2>/dev/null | head
echo "--- occurrences of OLD constant 3277 (0.0015625) -- should be NONE in the CFO detector ---"
grep -rIn "\b${OLD_POS}\b" "$HDLDIR" --include="*.v" 2>/dev/null | head
echo "--- hex forms: NEW +0x6666 / -0x3F999A (0.0125) ; OLD +0x0CCD / -0x3FF333 (0.0015625) ---"
echo "[NEW present -> PASS]"
grep -rIn -iE "22'[hs]*h?0*6666|22'[hs]*h?3F999A|22'd(26214|4168090)" "$HDLDIR" --include="*.v" 2>/dev/null | head
echo "[OLD absent -> PASS if empty]"
grep -rIn -iE "22'[hs]*h?0*0ccd|22'[hs]*h?3FF333|22'd(3277|4191027)" "$HDLDIR" --include="*.v" 2>/dev/null | head
echo "=== done ==="
