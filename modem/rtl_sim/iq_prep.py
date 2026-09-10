#!/usr/bin/env python3
"""iq_prep.py -- capture preprocessing for the float-vs-fixed replay campaign.

Both decode legs must see the IDENTICAL sample stream (Method rule 2 of the
campaign): the float reference (decode_ref_k5.m) silently strips zero samples,
while the raw Verilator replay (sim_byte_iq) ingests them as fake dropouts that
perturb the timing/carrier loops -- an asymmetry that biases the verdict toward
a false "fixed-point gap". This tool splices zero-runs ONCE, reports what it
removed, and (optionally) rotates the constellation by an exact multiple of 90
degrees so the fixed leg can sweep the cold-start quadrant at the SAMPLE level
(post-FEC bits are not de-rotatable -- scoring-level rotation cannot work).

Usage:
  iq_prep.py IN.iq OUT.iq [--rot {0,90,180,270}] [--dc] [--maxsamp N] [--quiet]

Rotation is exact integer swap/negate (no precision loss):
   90:  I' = -Q, Q' =  I        180: I' = -I, Q' = -Q        270: I' =  Q, Q' = -I
DC removal (--dc) subtracts the rounded mean of the spliced stream (explicit
A/B ablation -- the deployed RTL has no DC block; float scripts subtract mean).
Values are clipped to int16 after negation (-32768 -> 32767 overflow guard).

Prints one machine-greppable line:  IQPREP in=... out=... n=... zeros=... maxzrun=... clip=... rot=... dc=...
"""
import argparse
import sys

import numpy as np


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("infile")
    ap.add_argument("outfile")
    ap.add_argument("--rot", type=int, default=0, choices=[0, 90, 180, 270])
    ap.add_argument("--dc", action="store_true", help="subtract rounded mean (A/B ablation)")
    ap.add_argument("--maxsamp", type=int, default=0, help="truncate to N complex samples (0 = all)")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    raw = np.fromfile(a.infile, dtype=np.int16)
    raw = raw[: 2 * (raw.size // 2)]
    I = raw[0::2].astype(np.int32)
    Q = raw[1::2].astype(np.int32)

    # ---- zero-run splice (parity with decode_ref_k5.m's iq(abs(iq)>0)) ----
    z = (I == 0) & (Q == 0)
    nz = int(z.sum())
    maxrun = 0
    if nz:
        # max run length of consecutive zero samples
        d = np.diff(np.concatenate(([0], z.view(np.int8), [0])))
        starts = np.flatnonzero(d == 1)
        ends = np.flatnonzero(d == -1)
        maxrun = int((ends - starts).max())
        I, Q = I[~z], Q[~z]

    if a.maxsamp > 0:
        I, Q = I[: a.maxsamp], Q[: a.maxsamp]

    # ---- optional DC removal ----
    if a.dc:
        I = I - int(round(I.mean()))
        Q = Q - int(round(Q.mean()))

    # ---- exact 90-degree-multiple rotation ----
    if a.rot == 90:
        I, Q = -Q, I
    elif a.rot == 180:
        I, Q = -I, -Q
    elif a.rot == 270:
        I, Q = Q, -I

    # ---- int16 clip guard ----
    nclip = int(((I > 32767) | (I < -32768) | (Q > 32767) | (Q < -32768)).sum())
    I = np.clip(I, -32768, 32767).astype(np.int16)
    Q = np.clip(Q, -32768, 32767).astype(np.int16)

    out = np.empty(2 * I.size, dtype=np.int16)
    out[0::2] = I
    out[1::2] = Q
    out.tofile(a.outfile)

    if not a.quiet:
        print(
            f"IQPREP in={a.infile} out={a.outfile} n={I.size} zeros={nz} "
            f"maxzrun={maxrun} clip={nclip} rot={a.rot} dc={int(a.dc)}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
