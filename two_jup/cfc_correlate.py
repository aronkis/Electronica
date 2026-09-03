#!/usr/bin/env python3
"""cfc_correlate.py -- test the CFC step-detector -> rstCS -> error-burst chain.

RTL basis (task #16, traced 2026-08-06 in Coarse_Frequency_Compensator.v):
  the CFC accumulator has NO frame-boundary reset (acquire-once-then-hold; the
  module's only inputs are clk/reset/enb/data/validIn). The frame coupling runs
  the OTHER way: CFO_step_change_detector differences the normalized frequency
  estimate against its own 1-sample delay and fires when |delta| leaves a
  deadband; that becomes the rstCS OUTPUT which resets the CARRIER synchronizer.
      fire = (d > +0x0CCCCC) | (d < -0x199999)   [21-bit signed, En21]
  Hypothesis under test: CFC estimate JUMPS cause carrier resets, and the
  re-acquisition -- not the frequency error itself -- is what costs frames.

Method (all from already-captured frames.bin; no new instrumentation):
  * per-frame cfc_est (0x154, 21-bit signed) -> delta between consecutive frames
  * observed rstcs increments (0x150) mark real carrier resets
  * missing host_seq values mark delivered-frame loss
  Then: (1) do large |dcfc| frames coincide with rstcs increments?
        (2) do losses cluster at/after rstcs events vs a shuffled baseline?
        (3) does the RTL deadband predict the observed resets?

Usage: cfc_correlate.py <frames.bin> [more.bin ...]
"""
import sys, numpy as np
sys.path.insert(0, "/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup")
from frame_taxonomy import read_frames, sx21

# RTL constants from CFO_step_change_detector.v lines 67-69 (sfix22_En21)
THR_HI = 0x0CCCCC          # +0.10000038 in En21
THR_LO = -(1 << 22) + 0x1E66666 if False else -0x199999  # -0.20000076 (as coded)

def analyze(path):
    fr = read_frames(path)
    if fr.size < 500:
        return None
    cfc = sx21(fr["reg_cfc"])
    rst = fr["reg_rstcs"].astype(np.int64)
    seq = fr["host_seq"].astype(np.int64)
    crc = fr["crc_ok"].astype(np.int64)

    d_cfc = np.diff(cfc)
    d_rst = np.diff(rst)
    reset_here = d_rst > 0                      # a carrier reset happened at this step

    # --- (1) coincidence: |dcfc| at reset steps vs elsewhere ---
    a = np.abs(d_cfc)
    at_reset = a[reset_here]
    no_reset = a[~reset_here]

    # --- (3) does the RTL deadband predict the resets? ---
    pred = (d_cfc > THR_HI) | (d_cfc < THR_LO)
    tp = int(np.sum(pred & reset_here)); fp = int(np.sum(pred & ~reset_here))
    fn = int(np.sum(~pred & reset_here))

    # --- (2) do frame losses cluster near resets? ---
    clean = crc != 0
    s = seq[clean]
    order = np.argsort(s, kind="mergesort")
    s_sorted = s[order]
    uniq = np.unique(s_sorted)
    lost_after = np.zeros(fr.size, dtype=bool)
    if uniq.size > 2:
        gaps = np.diff(uniq)
        # index (into the clean/sorted stream) where a gap follows
        gap_at = np.where(gaps > 1)[0]
        # map back to record index of the frame BEFORE each gap
        idx_clean = np.where(clean)[0][order]
        for gi in gap_at:
            if gi < idx_clean.size:
                lost_after[idx_clean[gi]] = True

    # proximity: fraction of loss-events within W frames after a reset
    W = 5
    reset_idx = np.where(reset_here)[0]
    loss_idx = np.where(lost_after)[0]
    near = 0
    for li in loss_idx:
        if reset_idx.size and np.min(np.abs(reset_idx - li)) <= W:
            near += 1
    # shuffled baseline: same number of losses placed uniformly
    rng = np.random.default_rng(0)
    base = []
    for _ in range(200):
        fake = rng.choice(fr.size, size=max(loss_idx.size, 1), replace=False)
        c = sum(1 for f in fake if reset_idx.size and np.min(np.abs(reset_idx - f)) <= W)
        base.append(c)
    base_mean = float(np.mean(base))

    return dict(
        n=fr.size, resets=int(reset_here.sum()), losses=int(loss_idx.size),
        med_dcfc_reset=float(np.median(at_reset)) if at_reset.size else float("nan"),
        med_dcfc_norm=float(np.median(no_reset)) if no_reset.size else float("nan"),
        p95_dcfc_norm=float(np.percentile(no_reset, 95)) if no_reset.size else float("nan"),
        tp=tp, fp=fp, fn=fn,
        near=near, base=base_mean, W=W,
    )

if __name__ == "__main__":
    for p in sys.argv[1:]:
        r = analyze(p)
        name = p.split("/")[-2] if "/" in p else p
        if r is None:
            print(f"{name}: too few records"); continue
        print(f"=== {name}  ({r['n']} frames) ===")
        print(f"  carrier resets observed      : {r['resets']}")
        print(f"  delivered-frame loss events  : {r['losses']}")
        print(f"  |d cfc| median AT reset      : {r['med_dcfc_reset']:.0f}")
        print(f"  |d cfc| median normal / p95  : {r['med_dcfc_norm']:.0f} / {r['p95_dcfc_norm']:.0f}")
        print(f"  RTL deadband predicts resets : TP={r['tp']} FP={r['fp']} FN={r['fn']}")
        print(f"  losses within {r['W']} frames of a reset: {r['near']}/{r['losses']}"
              f"   (shuffled baseline {r['base']:.1f})")
