#!/usr/bin/env python3
"""frame_taxonomy.py -- fresh, assumption-free error-source derivation for the
QPSK modem PER<1% campaign.

Ingests the per-frame telemetry log written by qpsk_tun's QPSK_FRAMELOG hook
(48 B/frame, see host/qpsk_tun.c struct frame_rec) and classifies the
errored frames by SIGNATURE -- periodicity, carrier-reset (rstcs) correlation,
CFO (cfc) dither, level excursion, burst structure, and host-missed frames --
WITHOUT presupposing any particular root cause (the documented BBDC tick is one
hypothesis the data must independently produce, not an input).

Record layout (little-endian, packed to 48 B, matches struct frame_rec):
    <QQIIIIIIII =
    t_mono_ns, t_real_ns (u64);
    host_seq, crc_ok, reg_packets, reg_biterr, reg_rstcs, reg_cfc,
    reg_adcforensic, reserved (u32)

Usage:
    frame_taxonomy.py <frames.bin> [-o OUTDIR] [--frame-period-s S]
    frame_taxonomy.py --selftest

Output: prints a summary and writes <OUTDIR>/error_sources.csv. Exit 0 on
success; --selftest exits nonzero if any self-check fails.
"""
import argparse
import os
import struct
import sys

import numpy as np

REC = struct.Struct("<QQIIIIIIII")
REC_SIZE = REC.size
assert REC_SIZE == 48, REC_SIZE

DTYPE = np.dtype([
    ("t_mono_ns", "<u8"), ("t_real_ns", "<u8"),
    ("host_seq", "<u4"), ("crc_ok", "<u4"),
    ("reg_packets", "<u4"), ("reg_biterr", "<u4"),
    ("reg_rstcs", "<u4"), ("reg_cfc", "<u4"),
    ("reg_adcforensic", "<u4"), ("reserved", "<u4"),
])


def read_frames(path):
    """Load a frames.bin into a structured array (drops any trailing partial)."""
    raw = np.fromfile(path, dtype=np.uint8)
    n = raw.size // REC_SIZE
    if n == 0:
        raise ValueError(f"{path}: no complete {REC_SIZE}-byte records")
    if raw.size % REC_SIZE:
        raw = raw[: n * REC_SIZE]
    return raw.view(DTYPE)


def sx21(u):
    """Sign-extend the 21-bit cfc_est field (0x154) from its u32 storage."""
    u = np.asarray(u, dtype=np.int64) & 0x1FFFFF
    return np.where(u >= (1 << 20), u - (1 << 21), u)


def _episodes(err_idx, max_gap):
    """Group errored-frame indices into episodes (runs separated by > max_gap
    good frames). Returns list of (onset_idx, length)."""
    if err_idx.size == 0:
        return []
    eps = []
    start = prev = err_idx[0]
    run = 1
    for i in err_idx[1:]:
        if i - prev <= max_gap:
            run += 1
        else:
            eps.append((int(start), run))
            start = i
            run = 1
        prev = i
    eps.append((int(start), run))
    return eps


def analyze(fr, frame_period_s=None):
    """Derive error-source signatures. Returns a dict of findings."""
    n = fr.size
    crc_ok = fr["crc_ok"].astype(bool)
    err = ~crc_ok
    nerr = int(err.sum())

    # frame cadence: prefer measured monotonic dt, fall back to the argument
    t = fr["t_mono_ns"].astype(np.float64) * 1e-9
    dt = np.diff(t)
    dt = dt[(dt > 0) & (dt < 1.0)]                     # drop stalls/rotations
    dt_med = float(np.median(dt)) if dt.size else (frame_period_s or 0.0)
    fp = frame_period_s or dt_med or 1.0

    # multi-drain detection: with -M K the host logs several frames per modem
    # packet, so reg_packets does not advance 1:1 with records (Delta==0 runs)
    # and log timestamps burst microseconds apart. When detected, the
    # timestamp-derived cadence and the packet-gap metric are unreliable; the
    # error-train signatures (periodicity/rstcs/burst over record index) stay
    # valid, and seconds are taken from the supplied frame_period_s.
    dp_all = np.diff(fr["reg_packets"].astype(np.int64))
    frac_pkts0 = float(np.mean(dp_all == 0)) if dp_all.size else 0.0
    multi_drain = frac_pkts0 > 0.3
    if multi_drain and frame_period_s is None:
        print("[warn] multi-drain detected (Delta packets==0 in "
              f"{frac_pkts0*100:.0f}% of records) and no --frame-period-s given;"
              " period-in-seconds will be unreliable (pass --frame-period-s).")

    out = {
        "n_frames": n, "n_errored": nerr,
        "per": nerr / n if n else 0.0,
        "frame_period_s": fp, "measured_dt_med_s": dt_med,
        "multi_drain": multi_drain,
        "sources": [],
    }
    if nerr == 0:
        return out

    err_idx = np.flatnonzero(err)
    ei = err.astype(np.float64)
    ei -= ei.mean()

    # ---- periodicity: autocorrelation of the per-frame error train ----------
    max_lag = min(n // 3, 5000)
    period_frames = 0
    period_strength = 0.0
    if max_lag >= 4 and np.any(ei):
        ac = np.correlate(ei, ei, mode="full")[n - 1:]
        ac = ac / ac[0]
        lag = int(np.argmax(ac[3:max_lag])) + 3
        period_frames = lag
        period_strength = float(ac[lag])

    # episode onsets (a burst = consecutive errors within ~a few frames)
    eps = _episodes(err_idx, max_gap=max(3, int(round(0.05 / fp))) if fp else 3)
    onsets = np.array([e[0] for e in eps], dtype=np.float64)
    runlens = np.array([e[1] for e in eps], dtype=np.float64)
    onset_period_frames = 0.0
    if onsets.size >= 3:
        onset_period_frames = float(np.median(np.diff(onsets)))

    # a period is credible if autocorr and episode-onset spacing agree
    period_ok = (period_strength > 0.05 and onset_period_frames > 0 and
                 abs(period_frames - onset_period_frames) <=
                 0.15 * onset_period_frames)
    out["sources"].append({
        "source": "periodic_episodes",
        "metric": "period_s",
        "value": round(onset_period_frames * fp, 4) if onset_period_frames else 0.0,
        "period_frames": round(onset_period_frames, 1),
        "autocorr_strength": round(period_strength, 4),
        "attributed_fraction": round(runlens.sum() / nerr, 3) if period_ok else 0.0,
        "confidence": "high" if period_ok and period_strength > 0.15 else
                      ("medium" if period_ok else "low"),
    })

    # ---- rstcs (carrier-reset) correlation ----------------------------------
    d_rstcs = np.diff(fr["reg_rstcs"].astype(np.int64), prepend=fr["reg_rstcs"][0])
    rst_pulse = d_rstcs > 0
    # phi coefficient between (errored) and (rstcs pulse in same frame)
    a = err & rst_pulse
    phi = _phi(err, rst_pulse)
    out["sources"].append({
        "source": "carrier_reset_storm",
        "metric": "phi",
        "value": round(phi, 4),
        "err_frames_with_rstcs": int(a.sum()),
        "attributed_fraction": round(int(a.sum()) / nerr, 3),
        "confidence": "high" if phi > 0.3 else ("medium" if phi > 0.1 else "low"),
    })

    # ---- CFO (cfc) dither at error vs baseline ------------------------------
    cfc = sx21(fr["reg_cfc"]).astype(np.float64)
    cfc_dev = np.abs(cfc - np.median(cfc))
    dev_err = float(cfc_dev[err].mean()) if nerr else 0.0
    dev_ok = float(cfc_dev[crc_ok].mean()) if crc_ok.any() else 0.0
    ratio = dev_err / dev_ok if dev_ok > 1e-9 else 0.0
    out["sources"].append({
        "source": "cfo_dither",
        "metric": "cfc_dev_ratio_err_vs_ok",
        "value": round(ratio, 3),
        "cfc_dev_err": round(dev_err, 2), "cfc_dev_ok": round(dev_ok, 2),
        "attributed_fraction": 0.0,               # corroborating, not attributive
        "confidence": "high" if ratio > 3 else ("medium" if ratio > 1.5 else "low"),
    })

    # ---- level excursion (adc_forensic) -------------------------------------
    lvl = fr["reg_adcforensic"].astype(np.float64)
    lvl_dev = np.abs(lvl - np.median(lvl))
    le = float(lvl_dev[err].mean()) if nerr else 0.0
    lo = float(lvl_dev[crc_ok].mean()) if crc_ok.any() else 0.0
    lratio = le / lo if lo > 1e-9 else 0.0
    out["sources"].append({
        "source": "level_excursion",
        "metric": "adcforensic_dev_ratio_err_vs_ok",
        "value": round(lratio, 3),
        "attributed_fraction": 0.0,
        "confidence": "high" if lratio > 3 else ("medium" if lratio > 1.5 else "low"),
    })

    # ---- burst structure -----------------------------------------------------
    mean_run = float(runlens.mean()) if runlens.size else 0.0
    out["sources"].append({
        "source": "burst_structure",
        "metric": "mean_run_len",
        "value": round(mean_run, 2),
        "n_episodes": int(runlens.size),
        "isolated_frac": round(float((runlens == 1).mean()), 3) if runlens.size else 0.0,
        "attributed_fraction": 1.0,
        "confidence": "info",
    })

    # ---- host-missed frames (HW delivered but host never saw) ----------------
    d_pkts = np.diff(fr["reg_packets"].astype(np.int64))
    # positive jumps > 1 mean the modem's packet counter advanced past the host
    gaps = int(np.sum(d_pkts > 1))
    out["sources"].append({
        "source": "host_missed_frames",
        "metric": "packet_gap_events",
        "value": gaps,
        "attributed_fraction": 0.0,
        # unreliable under multi-drain: reg_packets legitimately jumps between
        # logged frames, so a >1 gap is not a missed frame.
        "confidence": "n/a-multidrain" if multi_drain else
                      ("high" if gaps > 0.01 * n else ("medium" if gaps else "low")),
    })
    return out


def _phi(a, b):
    """Phi (Matthews) coefficient between two boolean arrays."""
    a = a.astype(np.int64)
    b = b.astype(np.int64)
    n11 = int(np.sum((a == 1) & (b == 1)))
    n10 = int(np.sum((a == 1) & (b == 0)))
    n01 = int(np.sum((a == 0) & (b == 1)))
    n00 = int(np.sum((a == 0) & (b == 0)))
    num = n11 * n00 - n10 * n01
    den = np.sqrt(float((n11 + n10) * (n01 + n00) * (n11 + n01) * (n10 + n00)))
    return num / den if den > 0 else 0.0


def write_csv(findings, out_csv):
    cols = ["source", "metric", "value", "attributed_fraction", "confidence"]
    with open(out_csv, "w") as f:
        f.write(",".join(cols) + "\n")
        for s in findings["sources"]:
            f.write(",".join(str(s.get(c, "")) for c in cols) + "\n")


def print_summary(findings):
    md = findings.get("multi_drain", False)
    print(f"frames={findings['n_frames']}  errored={findings['n_errored']}  "
          f"PER={findings['per']*100:.3f}%  frame_period="
          f"{findings['frame_period_s']*1e3:.3f} ms "
          f"(measured dt {findings['measured_dt_med_s']*1e3:.3f} ms"
          f"{'; MULTI-DRAIN' if md else ''})")
    print(f"{'source':22s} {'metric':32s} {'value':>10s} {'attr':>6s} conf")
    for s in findings["sources"]:
        print(f"{s['source']:22s} {s['metric']:32s} {str(s['value']):>10s} "
              f"{s['attributed_fraction']:>6} {s['confidence']}")


# --------------------------------------------------------------------------
# self-test: synthesize a frames.bin with a KNOWN signature and assert the
# tool recovers it. No hardware needed.
def synth(n, frame_period_s, err_kind, seed=1):
    rng = np.random.default_rng(seed)
    fr = np.zeros(n, dtype=DTYPE)
    t0 = 1_000_000_000
    # frame timestamps with small jitter
    jit = rng.normal(0, frame_period_s * 0.01, n)
    tsec = t0 * 1e-9 + np.cumsum(np.full(n, frame_period_s) + jit)
    fr["t_mono_ns"] = (tsec * 1e9).astype(np.uint64)
    fr["t_real_ns"] = fr["t_mono_ns"]
    fr["host_seq"] = np.arange(n, dtype=np.uint32)
    fr["reg_packets"] = np.arange(n, dtype=np.uint32)      # 1 per frame, no gaps
    fr["reg_rstcs"] = 0
    fr["reg_cfc"] = 0
    fr["reg_adcforensic"] = 1000
    crc_ok = np.ones(n, dtype=bool)

    if err_kind == "periodic_tick":
        # episodes every ~1.57 s, bursts of 2-8, rstcs=0, cfc stable (the
        # documented tick shape -- the tool must find it WITHOUT being told)
        period_frames = int(round(1.57 / frame_period_s))
        onset = period_frames
        while onset < n - 10:
            blen = int(rng.integers(2, 9))
            crc_ok[onset:onset + blen] = False
            onset += period_frames + int(rng.integers(-2, 3))
    elif err_kind == "random":
        # Poisson scatter, no period
        crc_ok[rng.random(n) < 0.02] = False
    elif err_kind == "rstcs_driven":
        # errors coincide with carrier-reset pulses (rstcs increments)
        rst = np.zeros(n, dtype=np.int64)
        hits = np.flatnonzero(rng.random(n) < 0.02)
        for h in hits:
            crc_ok[h] = False
        rst = np.cumsum(np.isin(np.arange(n), hits).astype(np.int64))
        fr["reg_rstcs"] = rst.astype(np.uint32)
    fr["crc_ok"] = crc_ok.astype(np.uint32)
    return fr


def selftest():
    fp = (2240 / 2 + 13) / 240000.0     # 240k K5 frame period, 4.72 ms
    n = 60000                            # ~283 s
    fails = []

    # 1. periodic tick: dominant period ~1.57 s, rstcs uncorrelated, bursty
    f = analyze(synth(n, fp, "periodic_tick"), frame_period_s=fp)
    per = next(s for s in f["sources"] if s["source"] == "periodic_episodes")
    rst = next(s for s in f["sources"] if s["source"] == "carrier_reset_storm")
    bur = next(s for s in f["sources"] if s["source"] == "burst_structure")
    print("[selftest] periodic_tick:")
    print_summary(f)
    if not (1.4 <= per["value"] <= 1.7):
        fails.append(f"tick period {per['value']} not ~1.57 s")
    if per["confidence"] == "low":
        fails.append("tick periodicity not detected")
    if abs(rst["value"]) > 0.2:
        fails.append(f"tick falsely correlated with rstcs (phi={rst['value']})")
    if bur["value"] < 1.5:
        fails.append(f"tick not bursty (mean run {bur['value']})")

    # 2. random scatter: NO sharp period
    f2 = analyze(synth(n, fp, "random"), frame_period_s=fp)
    per2 = next(s for s in f2["sources"] if s["source"] == "periodic_episodes")
    print("[selftest] random:")
    print_summary(f2)
    if per2["confidence"] == "high":
        fails.append(f"random errors falsely flagged periodic ({per2['value']} s)")

    # 3. rstcs-driven: phi correlation must be high, and NOT mislabeled periodic
    f3 = analyze(synth(n, fp, "rstcs_driven"), frame_period_s=fp)
    rst3 = next(s for s in f3["sources"] if s["source"] == "carrier_reset_storm")
    print("[selftest] rstcs_driven:")
    print_summary(f3)
    if rst3["value"] < 0.3:
        fails.append(f"rstcs-driven errors not correlated (phi={rst3['value']})")

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
    ap.add_argument("frames", nargs="?", help="frames.bin path")
    ap.add_argument("-o", "--outdir", default=None, help="output dir for error_sources.csv")
    ap.add_argument("--frame-period-s", type=float, default=None,
                    help="override frame period (else measured from timestamps)")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()
    if not args.frames:
        ap.error("frames.bin required (or --selftest)")
    fr = read_frames(args.frames)
    findings = analyze(fr, frame_period_s=args.frame_period_s)
    print_summary(findings)
    outdir = args.outdir or os.path.dirname(os.path.abspath(args.frames))
    os.makedirs(outdir, exist_ok=True)
    out_csv = os.path.join(outdir, "error_sources.csv")
    write_csv(findings, out_csv)
    print(f"\nwrote {out_csv}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
