#!/usr/bin/env python3
"""Score dbgcap CSV: t frames err mmTX mm0 mm1 mm2 mm3 capIn capDeint capOut

H1 coverage gate : a witness with NONZERO mismatch delta in quiet seconds is
                   UNCOVERED on hardware -- never interpret its burst numbers.
H2 localisation  : among H1-passing witnesses, the FIRST along the chain whose
                   delta rises in bursts is where the error first appears.
H3 TX verdict    : TXCAP flat through a burst => TX exonerated on silicon.
Chain: TXCAP -> AGC -> postSymSync -> postCarrierSync -> constellation
       -> cap_in -> cap_deint -> cap_out
"""
import sys, collections
BURST = 200
MM = [("TXCAP (transmitter, TX-anchored)", 3), ("AGC out", 4),
      ("postSymbolSync", 5), ("postCarrierSync", 6), ("QPSKConstellation (demod in)", 7)]
CAPS = [("cap_in (demod out / FEC in)", 8), ("cap_deint", 9), ("cap_out (post-Viterbi)", 10)]

def norm(v):
    v = v.strip()
    try: return int(v, 16) if v.lower().startswith('0x') else int(v)
    except ValueError: return None

def main(path, have_tx):
    rows = []
    for l in open(path):
        p = l.split()
        if len(p) >= 11:
            rows.append([int(p[0]), int(p[1]), int(p[2])] + [int(x) for x in p[3:8]] + [norm(x) for x in p[8:11]])
    if len(rows) < 3:
        print("NO DATA"); return
    print(f"=== {path}: {len(rows)} samples ===")
    d = []
    for a, b in zip(rows, rows[1:]):
        d.append({'err': b[2], 'mm': [(b[i] - a[i]) & 0xFFFFFFFF for i in range(3, 8)],
                  'cap': b[8:11]})
    quiet = [x for x in d if x['err'] <= BURST]
    burst = [x for x in d if x['err'] > BURST]
    print(f"quiet={len(quiet)}s burst={len(burst)}s burst_errors={sum(x['err'] for x in burst)}\n")

    print(f"{'witness':38s} {'quiet mm/s':>11s} {'burst mm/s':>11s}  H1")
    passing = []
    for name, col in MM:
        i = col - 3
        if name.startswith("TXCAP") and not have_tx:
            print(f"{name:38s} {'--':>11s} {'--':>11s}  n/a (image has no TXCAP)"); continue
        q = sum(x['mm'][i] for x in quiet) / max(1, len(quiet))
        b = sum(x['mm'][i] for x in burst) / max(1, len(burst))
        ok = q <= 0.01
        print(f"{name:38s} {q:11.2f} {b:11.2f}  {'PASS' if ok else 'UNCOVERED'}")
        if ok: passing.append((name, q, b))

    print(f"\n{'capture (golden-constancy)':38s} {'quiet %gold':>11s} {'burst %gold':>11s}  H1")
    for name, col in CAPS:
        vals = [r[col] for r in rows if r[col] is not None]
        if not vals: continue
        g = collections.Counter(v for v, x in zip(vals, d + [d[-1]]) if x['err'] <= BURST).most_common(1)
        if not g: continue
        gold = g[0][0]
        qs = [x for x, r in zip(d, rows[1:]) if x['err'] <= BURST]
        bs = [x for x, r in zip(d, rows[1:]) if x['err'] > BURST]
        qg = 100 * sum(1 for x in qs if x['cap'][col - 8] == gold) / max(1, len(qs))
        bg = 100 * sum(1 for x in bs if x['cap'][col - 8] == gold) / max(1, len(bs))
        print(f"{name:38s} {qg:10.1f}% {bg:10.1f}%  {'PASS' if qg >= 99 else 'UNCOVERED'}  golden=0x{gold:08X}")

    print("\n--- H2/H3 VERDICT ---")
    if not passing:
        print("  NO witness passes H1. The measurement approach is not working on hardware;")
        print("  write it up rather than iterating."); return
    if not burst:
        print("  No burst captured -- inconclusive."); return
    if have_tx:
        tx = [p for p in passing if p[0].startswith("TXCAP")]
        if tx:
            _, q, b = tx[0]
            if b > 0.5:
                print(f"  TX IS THE SOURCE: TXCAP {q:.2f}/s quiet -> {b:.2f}/s in burst.")
            else:
                print(f"  TX EXONERATED ON SILICON: TXCAP flat ({b:.2f}/s) through bursts totalling "
                      f"{sum(x['err'] for x in burst)} bit errors.")
    moved = [p for p in passing if p[2] > 0.5 and not p[0].startswith("TXCAP")]
    if moved:
        print(f"  FIRST COVERED RX STAGE THAT MOVES: {moved[0][0]} "
              f"({moved[0][2]:.2f}/s burst vs {moved[0][1]:.2f}/s quiet)")
        print(f"  => the error first appears at or before this stage.")
    else:
        print("  No covered RX stage moves. If cap_in still deviates in bursts, the damage is")
        print("  outside the 16 symbols these captures see -- report that, do not force a stage.")

main(sys.argv[1], len(sys.argv) > 2 and sys.argv[2] == '1')
