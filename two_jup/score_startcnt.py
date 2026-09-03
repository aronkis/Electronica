#!/usr/bin/env python3
"""Score a mode2_startcnt CSV against the PRE-REGISTERED prediction/falsifier.

CSV columns: t frames err startIn vitrst decbits startOut   (per-second deltas)

S1 self-test : healthy => startIn/frames == 1.00. Any other constant => STOP.
S2 prediction: during a burst the ratio rises to ~2 starts/frame.
S3 falsifier : ratio stays 1.00 through a full-magnitude burst => MODEL DEAD.
Boundary discrimination (Travis's question):
  startIn->2 & vitrst->2 : spurious start from the demod side, restarts trellis (UPSTREAM)
  startIn =1 & vitrst->2 : restart generated INSIDE the decoder
  startIn->2 & vitrst =1 : extra start absorbed; damage elsewhere
"""
import sys
BURST = 200  # err/s threshold, same as every prior burst analysis

def main(path):
    rows = []
    for l in open(path):
        p = l.split()
        if len(p) >= 7:
            rows.append([int(x) for x in p[:7]])
    if not rows:
        print(f"{path}: NO DATA"); return
    print(f"=== {path}: {len(rows)} samples ===")

    quiet = [r for r in rows if r[2] <= BURST]
    burst = [r for r in rows if r[2] > BURST]

    def ratios(rs, lab):
        if not rs: 
            print(f"  {lab}: none"); return None
        f  = sum(r[1] for r in rs)
        si = sum(r[3] for r in rs); vr = sum(r[4] for r in rs); so = sum(r[6] for r in rs)
        e  = sum(r[2] for r in rs)
        print(f"  {lab}: {len(rs)}s  frames={f}  err={e} ({e/len(rs):.1f}/s)")
        print(f"      startIn/frame={si/f:.4f}  vitReset/frame={vr/f:.4f}  startOut/frame={so/f:.4f}")
        return si/f, vr/f, so/f

    q = ratios(quiet, "QUIET ")
    b = ratios(burst, "BURST ")

    # S1
    print("\n--- S1 counter self-test (healthy must be 1.00) ---")
    if q and abs(q[0]-1.0) < 0.01:
        print(f"  PASS: startIn/frame = {q[0]:.4f}")
    elif q:
        print(f"  *** STOP: startIn/frame = {q[0]:.4f}, not 1.00. Characterise the counter "
              f"before interpreting burst data. ***"); return

    # 51-quantisation of the quiet floor
    qm = [r[2] for r in quiet if r[2] % 51 == 0]
    print(f"  quiet seconds that are exact multiples of 51: {len(qm)}/{len(quiet)} "
          f"= {100*len(qm)/max(1,len(quiet)):.1f}%")

    # bursts
    print("\n--- bursts ---")
    seq=[];inb=False
    for i,r in enumerate(rows):
        if r[2] > BURST:
            if not inb: st=i; inb=True
            en=i
        elif inb:
            seq.append((st,en)); inb=False
    if inb: seq.append((st,en))
    prev=None
    for (st,en) in seq:
        sub=rows[st:en+1]
        f=sum(r[1] for r in sub); si=sum(r[3] for r in sub); vr=sum(r[4] for r in sub); so=sum(r[6] for r in sub)
        e=sum(r[2] for r in sub)
        g=f"  start-to-start={rows[st][0]-prev}s" if prev else ""
        print(f"  t={rows[st][0]}..{rows[en][0]} dur={en-st+1}s err={e}"
              f"  startIn/f={si/f:.3f} vitRst/f={vr/f:.3f} startOut/f={so/f:.3f}{g}")
        prev=rows[st][0]
    if not seq:
        print("  none seen in this window")

    # verdict
    print("\n--- VERDICT (pre-registered) ---")
    if not seq:
        print("  NO BURST CAPTURED -- neither confirms nor falsifies. Re-run over a longer window.")
        return
    si_b, vr_b = b[0], b[1]
    if si_b >= 1.5 and vr_b >= 1.5:
        print(f"  CONFIRMED + LOCALISED UPSTREAM: startIn/frame {q[0]:.3f}->{si_b:.3f}, "
              f"vitReset/frame {q[1]:.3f}->{vr_b:.3f}.\n"
              f"  A spurious start arrives from the demod side and restarts the trellis.")
    elif si_b < 1.1 and vr_b >= 1.5:
        print(f"  START PATH INNOCENT, RESTART IS INTERNAL: startIn stays {si_b:.3f} while "
              f"vitReset goes to {vr_b:.3f}.\n  The trellis is being reset from inside the decoder.")
    elif si_b >= 1.5 and vr_b < 1.1:
        print(f"  EXTRA START ABSORBED: startIn {si_b:.3f} but vitReset {vr_b:.3f} -- the decoder "
              f"does not act on it; damage is elsewhere.")
    elif si_b < 1.1 and vr_b < 1.1:
        print(f"  *** MODEL DEAD (S3 falsifier fired) ***\n"
              f"  startIn/frame = {si_b:.4f} and vitReset/frame = {vr_b:.4f} straight through a "
              f"burst of {sum(r[2] for r in burst)} bit errors.\n"
              f"  Hardware shows exactly one start per frame through the burst. The spurious-start\n"
              f"  model is WRONG and is reported dead, as pre-registered. Do not reinterpret.")
    else:
        print(f"  AMBIGUOUS: startIn/frame={si_b:.3f}, vitReset/frame={vr_b:.3f}. "
              f"Neither clause fires cleanly; report the numbers, do not force a verdict.")

for p in sys.argv[1:]:
    main(p); print()
