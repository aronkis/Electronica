#!/usr/bin/env python3
"""Score a stagesig CSV: t frames err mm0 mm1 mm2 mm3 mm4 mm5 mm6
mm* are ACCUMULATING per-stage mismatch counters, so what matters is the DELTA
across quiet vs burst seconds.

Coverage depends on which image produced the data:
  build 1 (0ce3caa2d00b, unbounded)   -> stages 0,1 valid; 2-6 UNCOVERED
  build 2 (bounded)                   -> 0,1,2,3 valid
  build 3 (bounded + sign bits)       -> 0,1,2,3,5,6 valid; 4 UNCOVERED

G1 gate: stage 0 mismatch delta must be 0 across quiet seconds.
G2      : stage 0 delta during bursts -> TX is the source; flat -> TX exonerated.
"""
import sys
BURST = 200
NAMES = ["0 dataIn (TX modulator out)", "1 AGC out", "2 RRC out", "3 postSymbolSync",
         "4 postCarrierSync", "5 QPSKConstellation (demod in)", "6 demod bits"]

def main(path, covered):
    rows = []
    for l in open(path):
        p = l.split()
        if len(p) >= 10:
            rows.append([int(x) for x in p[:10]])
    if len(rows) < 3:
        print("NO DATA"); return
    print(f"=== {path}: {len(rows)} samples; covered stages: {covered} ===")
    # per-second deltas of the accumulating counters
    d = []
    for a, b in zip(rows, rows[1:]):
        d.append({'t': b[0], 'fr': b[1], 'err': b[2],
                  'mm': [(b[3+i] - a[3+i]) & 0xFFFFFFFF for i in range(7)]})
    quiet = [x for x in d if x['err'] <= BURST]
    burst = [x for x in d if x['err'] > BURST]
    print(f"quiet={len(quiet)}s  burst={len(burst)}s  burst_errors={sum(x['err'] for x in burst)}")

    print(f"\n{'stage':34s} {'quiet mm/s':>12s} {'burst mm/s':>12s}   verdict")
    res = {}
    for i in range(7):
        q = sum(x['mm'][i] for x in quiet) / max(1, len(quiet))
        b = sum(x['mm'][i] for x in burst) / max(1, len(burst))
        res[i] = (q, b)
        tag = "" if i in covered else "   (UNCOVERED - ignore)"
        print(f"{NAMES[i]:34s} {q:12.2f} {b:12.2f}{tag}")

    print("\n--- G1 instrument gate (stage 0 quiet delta must be 0) ---")
    q0, b0 = res[0]
    if q0 > 0.01:
        print(f"  *** STOP: stage 0 shows {q0:.2f} mismatches/s on a CLEAN link. The reference frame\n"
              f"      (latched at frame 8, possibly mid-acquisition) is bad. Do not interpret bursts. ***")
        return
    print(f"  PASS: stage 0 = {q0:.2f} mismatches/s in quiet")

    if not burst:
        print("\n  NO BURST CAPTURED -- neither confirms nor falsifies."); return
    print("\n--- G2 VERDICT: TX vs RX ---")
    if b0 > 0.5:
        print(f"  TX IS THE SOURCE: stage 0 (the transmitter's own output) mismatches at {b0:.2f}/s\n"
              f"  during bursts vs {q0:.2f}/s quiet. The modulator output is NOT bit-identical frame to\n"
              f"  frame, and mode-1 loopback puts the TX inside the loop, so this indicts the TX.")
    else:
        print(f"  TX EXONERATED ON SILICON: stage 0 stays flat ({b0:.2f}/s) straight through bursts\n"
              f"  totalling {sum(x['err'] for x in burst)} bit errors. The modulator output is\n"
              f"  bit-identical every frame; the fault is DOWNSTREAM, in the RX chain.")
        for i in sorted(covered):
            if i == 0: continue
            qq, bb = res[i]
            if bb > 0.5:
                print(f"  FIRST COVERED STAGE THAT MOVES: {NAMES[i]} ({bb:.2f}/s in burst,"
                      f" {qq:.2f}/s quiet)")
                break
        else:
            print("  No covered stage downstream of 0 moves either -- the damage is outside what")
            print("  these taps see (window/tap width). Report that; do not force a localisation.")

cov = set(int(c) for c in sys.argv[2].split(',')) if len(sys.argv) > 2 else {0, 1}
main(sys.argv[1], cov)
