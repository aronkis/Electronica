#!/usr/bin/env python3
"""capTAP golden-constancy per RX stage.  CSV: tap t frames err capTAP capIn capDeint capOut

K1 coverage : <99 % golden in QUIET => tap UNCOVERED, burst number void.
K2 localise : first covered tap in chain order whose golden fraction DROPS in
              bursts is where the error first appears.
K3          : all covered taps hold while cap_in drops => error enters at or
              after the demodulator's slice/serialise path.
"""
import sys, collections
BURST = 200
NAME = {0: "0 AGC out", 1: "1 postSymbolSync", 2: "2 postCarrierSync",
        3: "3 QPSKConstellation (demod IN)"}

rows = []
for l in open(sys.argv[1]):
    p = l.split()
    if len(p) >= 8:
        rows.append((int(p[0]), int(p[1]), int(p[2]), int(p[3]),
                     int(p[4], 16), int(p[5], 16), int(p[6], 16), int(p[7], 16)))
taps = sorted(set(r[0] for r in rows))
print(f"=== {sys.argv[1]}: {len(rows)} rows, taps {taps} ===\n")
print(f"{'stage':34s} {'n_q':>5s} {'n_b':>4s} {'quiet %gold':>12s} {'burst %gold':>12s}  K1        golden")
summary = {}
for t in taps:
    sub = [r for r in rows if r[0] == t]
    q = [r for r in sub if r[3] <= BURST]
    b = [r for r in sub if r[3] > BURST]
    if not q:
        continue
    gold = collections.Counter(r[4] for r in q).most_common(1)[0][0]
    qg = 100 * sum(1 for r in q if r[4] == gold) / len(q)
    bg = 100 * sum(1 for r in b if r[4] == gold) / len(b) if b else float('nan')
    ok = qg >= 99.0
    summary[t] = (ok, qg, bg, len(b))
    print(f"{NAME.get(t,str(t)):34s} {len(q):5d} {len(b):4d} {qg:11.1f}% {bg:11.1f}%  "
          f"{'PASS' if ok else 'UNCOVERED':9s} 0x{gold:08X}")

# cap_in as the reference point, pooled across the whole file
q = [r for r in rows if r[3] <= BURST]; b = [r for r in rows if r[3] > BURST]
for idx, lab in ((5, "cap_in (demod OUT / FEC in)"), (6, "cap_deint"), (7, "cap_out (post-Viterbi)")):
    gold = collections.Counter(r[idx] for r in q).most_common(1)[0][0]
    qg = 100 * sum(1 for r in q if r[idx] == gold) / len(q)
    bg = 100 * sum(1 for r in b if r[idx] == gold) / len(b) if b else float('nan')
    print(f"{lab:34s} {len(q):5d} {len(b):4d} {qg:11.1f}% {bg:11.1f}%  "
          f"{'PASS' if qg>=99 else 'UNCOVERED':9s} 0x{gold:08X}")

print("\n--- VERDICT (pre-registered K1/K2/K3) ---")
covered = [t for t in taps if summary.get(t, (False,))[0]]
if not covered:
    print("  No tap passes K1 -- nothing to localise; report and do not interpret bursts.")
else:
    moved = [t for t in sorted(covered) if summary[t][2] < 99.0]
    if moved:
        t = moved[0]
        print(f"  FIRST COVERED STAGE THAT DEVIATES IN BURSTS: {NAME.get(t)} "
              f"({summary[t][1]:.1f}% -> {summary[t][2]:.1f}% golden)")
        print("  => the error is present at or before this stage.")
    else:
        print("  Every covered tap holds golden through bursts.")
        print("  => the error enters at or AFTER the demodulator's slice/serialise path (K3).")
    unc = [t for t in taps if not summary.get(t, (False,))[0]]
    if unc:
        print(f"  UNCOVERED (not frame-invariant when clean, burst numbers void): "
              f"{', '.join(NAME.get(t,str(t)) for t in unc)}")
