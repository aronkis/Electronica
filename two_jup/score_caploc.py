#!/usr/bin/env python3
"""Score cap_localise CSV: t frames err capIn capDeint capOut  (caps are raw reg strings).

C1 self-test: in QUIET seconds each cap must be ~100% constant (its golden value).
C2 localisation during bursts -- see the runner header.
"""
import sys, collections
BURST = 200

def norm(v):
    v = v.strip()
    try: return int(v, 16) if v.lower().startswith('0x') else int(v)
    except ValueError: return None

def main(path):
    rows = []
    for l in open(path):
        p = l.split()
        if len(p) >= 6:
            rows.append((int(p[0]), int(p[1]), int(p[2]), norm(p[3]), norm(p[4]), norm(p[5])))
    if not rows:
        print("NO DATA"); return
    print(f"=== {path}: {len(rows)} samples ===")
    quiet = [r for r in rows if r[2] <= BURST]
    burst = [r for r in rows if r[2] > BURST]
    taps = [("cap_in  (demod out, PRE-Viterbi)", 3),
            ("cap_deint (post-deint, PRE-Viterbi)", 4),
            ("cap_out (POST-Viterbi)", 5)]

    print(f"\nquiet seconds={len(quiet)}  burst seconds={len(burst)}"
          f"  burst errors={sum(r[2] for r in burst)}")

    golden = {}
    print("\n--- C1 self-test: each tap must be constant in QUIET ---")
    ok = True
    for lab, i in taps:
        c = collections.Counter(r[i] for r in quiet)
        g, n = c.most_common(1)[0]
        golden[i] = g
        pct = 100*n/len(quiet)
        flag = "PASS" if pct >= 99.0 else "*** NOT CONSTANT ***"
        print(f"  {lab:38s} golden=0x{g:08X}  {pct:6.2f}% of quiet seconds   {flag}")
        if pct < 99.0:
            ok = False
            for v, k in c.most_common(4)[1:]:
                print(f"        also seen: 0x{v:08X} x{k}")
    if not ok:
        print("\n  *** STOP: a tap is not constant on a clean link. The golden assumption is\n"
              "      wrong; do not interpret the burst data. ***")
        return
    if not burst:
        print("\n  NO BURST CAPTURED -- nothing to localise. Re-run over a longer window.")
        return

    print("\n--- C2 localisation: % of BURST seconds matching golden ---")
    dev = {}
    for lab, i in taps:
        m = sum(1 for r in burst if r[i] == golden[i])
        pct = 100*m/len(burst)
        dev[i] = 100-pct
        print(f"  {lab:38s} {pct:6.2f}% golden   -> {100-pct:6.2f}% DEVIATED")

    print("\n--- per-burst detail ---")
    inb=False; seq=[]
    for j,r in enumerate(rows):
        if r[2]>BURST:
            if not inb: st=j; inb=True
            en=j
        elif inb: seq.append((st,en)); inb=False
    if inb: seq.append((st,en))
    for st,en in seq:
        sub=rows[st:en+1]
        d=[sum(1 for r in sub if r[i]!=golden[i]) for _,i in taps]
        print(f"  t={rows[st][0]}..{rows[en][0]} err={sum(r[2] for r in sub)}"
              f"  deviating seconds: in={d[0]}/{len(sub)} deint={d[1]}/{len(sub)} out={d[2]}/{len(sub)}")

    print("\n--- VERDICT (pre-registered C2) ---")
    din, dde, dou = dev[3], dev[4], dev[5]
    T = 50.0
    if din >= T:
        print(f"  ERRORS ARE ALREADY IN THE DEMOD OUTPUT: cap_in deviates in {din:.1f}% of burst\n"
              f"  seconds. The FEC decoder is a victim; the fault is UPSTREAM of it, in the\n"
              f"  symbol/demod path. The Viterbi is exonerated as the origin.")
    elif dde >= T:
        print(f"  DEINTERLEAVER: cap_in stays golden ({100-din:.1f}%) but cap_deint deviates in\n"
              f"  {dde:.1f}% of burst seconds. Corruption between demod output and Viterbi input.")
    elif dou >= T:
        print(f"  VITERBI MISDECODE: cap_in and cap_deint stay golden but cap_out deviates in\n"
              f"  {dou:.1f}% of burst seconds. The decoder is given correct input and produces\n"
              f"  wrong bits.")
    else:
        print(f"  ALL THREE TAPS STAY GOLDEN through the burst (in={din:.1f}% deint={dde:.1f}%\n"
              f"  out={dou:.1f}% deviating). The damage is OUTSIDE the first 32 bits of the frame.\n"
              f"  Report that; do not force a verdict. Note the BIST window is bits 1..120, so a\n"
              f"  burst can score ~33 err/frame while bits 1..32 stay clean.")

for p in sys.argv[1:]:
    main(p)
