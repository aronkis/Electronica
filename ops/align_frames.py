#!/usr/bin/env python3
"""align_frames.py -- map errored frames in a QPSK_FRAMELOG capture to sample
windows in the concurrent pair.iq, for the reproduction harness (Workstream R).

The anchor is the modem packet counter (0x104), NOT a timestamp and NOT the
host seq (-B radiates one fixed reference frame, so seq is constant). The
capture script (capture_paired.sh) records `CAP_START ... pkts=0x104` at the
instant the Tap-A iio_readdev begins, so:

    capture-relative frame index k = record.reg_packets - pkts_at_CAP_START
    sample offset of frame k in pair.iq = k * samples_per_frame

Errored frames (crc_ok==0) inside the captured window are emitted as sample
windows [k*SPF - pre, k*SPF + SPF + guard] that reproduce_frame.sh slices out
of pair.iq and feeds to both replay legs.

Optionally cross-correlates the host good/bad train against a replay per-frame
good/bad train (integer-slip search) and REPORTS the residual slip -- an
unclosable slip means frames the host never saw (upstream loss), a finding in
its own right, not something to force-fit.

Usage:
    align_frames.py FRAMES.bin REGS_CAP.txt [--spf 9064] [-o OUTDIR]
                    [--pair PAIR.iq]
    align_frames.py --selftest
"""
import argparse
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from frame_taxonomy import read_frames, DTYPE          # noqa: E402

SPF_240K = 9064          # 1133 sym * 8 sps, the 240k geometry (replay_capture.sh)


def parse_cap_anchor(regs_cap_path):
    """Return (pkts_start, pkts_end, t_start, t_end) from a regs_cap.txt with
    CAP_START/CAP_END lines (pkts in hex)."""
    p0 = p1 = None
    t0 = t1 = None
    with open(regs_cap_path) as f:
        for line in f:
            m = re.search(r"CAP_START.*t=([\d.]+).*pkts=0x([0-9a-fA-F]+)", line)
            if m:
                t0 = float(m.group(1)); p0 = int(m.group(2), 16)
            m = re.search(r"CAP_END.*t=([\d.]+).*pkts=0x([0-9a-fA-F]+)", line)
            if m:
                t1 = float(m.group(1)); p1 = int(m.group(2), 16)
    if p0 is None:
        raise ValueError(f"{regs_cap_path}: no CAP_START pkts anchor found")
    return p0, p1, t0, t1


def windows_for_errors(fr, pkts_start, pkts_end=None, spf=SPF_240K,
                       pre=256, guard=256):
    """Map errored frames within [pkts_start, pkts_end) to pair.iq windows.
    Returns a list of dicts."""
    k = fr["reg_packets"].astype(np.int64) - int(pkts_start)   # capture-relative
    in_win = k >= 0
    if pkts_end is not None:
        in_win &= (fr["reg_packets"].astype(np.int64) < int(pkts_end))
    err = (fr["crc_ok"] == 0) & in_win
    d_rstcs = np.diff(fr["reg_rstcs"].astype(np.int64), prepend=fr["reg_rstcs"][0])
    wins = []
    for i in np.flatnonzero(err):
        s0 = int(k[i]) * spf
        wins.append({
            "frame_idx": int(k[i]),
            "sample_start": max(0, s0 - pre),
            "sample_end": s0 + spf + guard,
            "reg_cfc": int(fr["reg_cfc"][i]),
            "rstcs_delta": int(d_rstcs[i]),
            "host_seq": int(fr["host_seq"][i]),
        })
    return wins


def residual_slip(host_bad, replay_bad, max_slip=8):
    """Integer-slip cross-correlation between two per-frame bad masks. Returns
    (best_slip, agreement_fraction). A large residual (low agreement at best
    slip) => host/replay disagree on frame count (upstream loss)."""
    host = np.asarray(host_bad, dtype=np.int8)
    rep = np.asarray(replay_bad, dtype=np.int8)
    best_slip, best_agree = 0, -1.0
    for s in range(-max_slip, max_slip + 1):
        if s >= 0:
            a, b = host[s:], rep[: len(host) - s] if s else rep[: len(host)]
        else:
            a, b = host[: len(host) + s], rep[-s: -s + (len(host) + s)]
        n = min(len(a), len(b))
        if n == 0:
            continue
        agree = float(np.mean(a[:n] == b[:n]))
        if agree > best_agree:
            best_agree, best_slip = agree, s
    return best_slip, best_agree


def write_csv(wins, out_csv):
    cols = ["frame_idx", "sample_start", "sample_end", "reg_cfc",
            "rstcs_delta", "host_seq"]
    with open(out_csv, "w") as f:
        f.write(",".join(cols) + "\n")
        for w in wins:
            f.write(",".join(str(w[c]) for c in cols) + "\n")


def selftest():
    from frame_taxonomy import synth
    fails = []
    fp = (2240 / 2 + 13) / 240000.0
    n = 20000
    fr = synth(n, fp, "periodic_tick")
    # reg_packets is 0..n-1 in synth; simulate a capture that starts at pkts=5000
    p0 = 5000
    fr2 = fr.copy()
    fr2["reg_packets"] = fr["reg_packets"] + 0        # already 0..n-1
    wins = windows_for_errors(fr2, pkts_start=p0, pkts_end=p0 + 3000, spf=SPF_240K)
    # every window must be for an errored frame with capture-relative idx in [0,3000)
    errset = set(int(i) - p0 for i in np.flatnonzero(fr2["crc_ok"] == 0)
                 if p0 <= int(i) < p0 + 3000)
    got = set(w["frame_idx"] for w in wins)
    print(f"[selftest] windows: {len(wins)} errored frames in [{p0},{p0+3000}); "
          f"idx range {min(got) if got else '-'}..{max(got) if got else '-'}")
    if got != errset:
        fails.append("windowed error set mismatch")
    # sample offset must equal frame_idx * SPF (minus pre, clamped)
    for w in wins[:5]:
        exp = max(0, w["frame_idx"] * SPF_240K - 256)
        if w["sample_start"] != exp:
            fails.append(f"sample_start {w['sample_start']} != {exp}")
            break

    # regs_cap.txt parse
    import tempfile
    tf = tempfile.mktemp(suffix=".txt")
    with open(tf, "w") as f:
        f.write("CAP_START t=1000.5 pkts=0x1388 biterr=0x0 rstcs=0x0 cfc=0x0\n")
        f.write("some iio line\n")
        f.write("CAP_END   t=1060.5 pkts=0x2710 biterr=0x0 rstcs=0x0 cfc=0x0\n")
    a = parse_cap_anchor(tf)
    os.unlink(tf)
    print(f"[selftest] anchor parse: pkts_start={a[0]} pkts_end={a[1]} "
          f"(want 5000, 10000)")
    if a[0] != 0x1388 or a[1] != 0x2710:
        fails.append(f"anchor parse wrong: {a}")

    # residual slip: shift a bad mask by a known lag, recover it
    rng = np.random.default_rng(3)
    host_bad = (rng.random(2000) < 0.05).astype(np.int8)
    lag = 3
    replay_bad = np.zeros_like(host_bad)
    replay_bad[: len(host_bad) - lag] = host_bad[lag:]
    s, agree = residual_slip(host_bad, replay_bad, max_slip=8)
    print(f"[selftest] residual_slip: recovered slip={s} agree={agree:.3f} (want 3, ~1.0)")
    if s != lag or agree < 0.95:
        fails.append(f"slip recovery wrong: slip={s} agree={agree}")

    if fails:
        print("\nSELFTEST FAILED:")
        for x in fails:
            print("  -", x)
        return 1
    print("\nSELFTEST OK")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("frames", nargs="?")
    ap.add_argument("regs_cap", nargs="?")
    ap.add_argument("--spf", type=int, default=SPF_240K, help="samples per frame")
    ap.add_argument("--pre", type=int, default=256)
    ap.add_argument("--guard", type=int, default=256)
    ap.add_argument("--pair", default=None, help="pair.iq (for range sanity only)")
    ap.add_argument("-o", "--outdir", default=None)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()
    if not args.frames or not args.regs_cap:
        ap.error("FRAMES.bin and REGS_CAP.txt required (or --selftest)")
    fr = read_frames(args.frames)
    p0, p1, t0, t1 = parse_cap_anchor(args.regs_cap)
    wins = windows_for_errors(fr, p0, p1, spf=args.spf, pre=args.pre, guard=args.guard)
    if args.pair and os.path.exists(args.pair):
        nsamp = os.path.getsize(args.pair) // 4
        clipped = [w for w in wins if w["sample_end"] <= nsamp]
        print(f"pair.iq has {nsamp} samples; {len(wins)-len(clipped)} windows "
              f"extend past end (dropped)")
        wins = clipped
    print(f"CAP_START pkts=0x{p0:x} -> {len(wins)} errored-frame windows "
          f"(spf={args.spf})")
    outdir = args.outdir or os.path.dirname(os.path.abspath(args.frames))
    os.makedirs(outdir, exist_ok=True)
    out_csv = os.path.join(outdir, "errored_windows.csv")
    write_csv(wins, out_csv)
    print(f"wrote {out_csv}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
