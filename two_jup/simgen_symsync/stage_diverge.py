#!/usr/bin/env python3
"""stage_diverge.py -- first-divergent-stage comparator (Stage 1b).

usage: stage_diverge.py CLEAN_PREFIX INJ_PREFIX

Compares a clean and an injected sim_byte_lock run (dumptaps=1: _ss/_cs/_con
streams + _frames/_rxw) and reports, for each corrupt frame of the injected
run, which stage FIRST shows degradation.

Because a continuous sample-domain dither perturbs every sample, exact
word-level lockstep diffing is dominated by benign symbol-index drift; the
honest divergence instrument is per-frame QUALITY per stage:
  q_ss / q_cs / q_con = per-frame RMS distance of the stage constellation to
  the nearest ideal QPSK point (radial+angular error), computed on each run
  separately, then the injected/clean ratio per frame per stage.
The 'first divergent stage' for a corrupt frame is the earliest stage in chain
order (ss -> cs -> con -> serializer words) whose ratio exceeds THR (3 sigma of
the clean-frame ratio population).

Frame windows: stage streams are symbol-rate; frames.txt gives per-frame
symbol counts (nssv/ncsv) so streams are chopped per frame exactly.
Word-level: cksum16/nwords from frames.txt + CRC verdict give the serializer
verdict per frame.
"""
import sys

import numpy as np

SPF = 49332
FP = SPF * 4


def load_stream(pfx, suf):
    try:
        a = np.loadtxt(pfx + "_" + suf + ".txt", delimiter=",", dtype=np.int32)
        if a.ndim == 1:
            a = a.reshape(-1, 2)
        return a[:, 0] + 1j * a[:, 1]
    except OSError:
        return np.zeros(0, dtype=complex)


def load_frames(pfx):
    rows = []
    with open(pfx + "_frames.txt") as f:
        for ln in f:
            if ln.startswith("#") or not ln.strip():
                continue
            p = ln.split()
            rows.append(dict(outframe=int(p[0]), clk=int(p[1]),
                             nwords=int(p[2]), cksum=int(p[3]),
                             ss_rms=float(p[5]), cs_rms=float(p[6]),
                             nssv=int(p[12]), ncsv=int(p[13]),
                             k=round(int(p[1]) / FP - 2.3)))
    return rows


def qpsk_q(z):
    """RMS distance to nearest ideal QPSK point (scale-normalized)."""
    if z.size == 0:
        return np.nan
    r = np.mean(np.abs(z))
    if r == 0:
        return np.nan
    ideal = r * np.exp(1j * (np.pi / 4 + np.pi / 2 * np.arange(4)))
    d = np.min(np.abs(z[:, None] - ideal[None, :]), axis=1)
    return float(np.sqrt(np.mean(d ** 2)) / r)


def perframe_q(pfx, frames, key):
    """Chop a symbol-rate stream by per-frame symbol counts (cumulative)."""
    z = load_stream(pfx, key)
    # frames.txt counts symbols BETWEEN frame boundaries; streams start before
    # the first boundary -- accumulate from the end backwards is safest, but
    # counts include inter-frame gaps too, so cumulative from start works:
    out = []
    pos_end = 0
    cum = 0
    for fr in frames:
        cnt = fr["nssv"] if key == "ss" else (fr["ncsv"] if key == "cs" else None)
        if cnt is None:
            # con stream: payload symbols only; approximate with equal share
            cnt = 0
        cum += cnt
        out.append((fr["k"], cum))
    q = {}
    prev = 0
    for k, c in out:
        q[k] = qpsk_q(z[prev:c]) if c > prev else np.nan
        prev = c
    return q


def crc_verdicts(pfx):
    import zlib
    frames, cur = [], []
    with open(pfx + "_rxw.txt") as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            w, last, user = ln.split(",")
            cur.append(int(w, 16))
            if int(last):
                frames.append(cur)
                cur = []
    v = []
    for fw in frames:
        buf = b"".join(w.to_bytes(8, "little") for w in fw)
        ok = 0
        if len(buf) >= 12 and buf[0] == 0x51 and buf[1] == 0x4B:
            length = buf[2] | (buf[3] << 8)
            if length <= len(buf) - 12:
                crc_rx = int.from_bytes(buf[8:12], "little")
                tmp = bytearray(buf[: 12 + length])
                tmp[8:12] = b"\x00\x00\x00\x00"
                ok = int((zlib.crc32(bytes(tmp)) & 0xFFFFFFFF) == crc_rx)
        v.append(ok and len(fw) == 191)
    return v


def main():
    cpfx, ipfx = sys.argv[1], sys.argv[2]
    cf, inf = load_frames(cpfx), load_frames(ipfx)
    ck = {f["k"]: f for f in cf}
    crc = crc_verdicts(ipfx)

    stages = ["ss", "cs", "con"]
    qc = {s: perframe_q(cpfx, cf, s) for s in ["ss", "cs"]}
    qi = {s: perframe_q(ipfx, inf, s) for s in ["ss", "cs"]}

    # ratio population over clean (crc-ok) frames of the injected run
    ratios = {s: {} for s in ["ss", "cs"]}
    for i, fr in enumerate(inf):
        k = fr["k"]
        for s in ["ss", "cs"]:
            a, b = qi[s].get(k, np.nan), qc[s].get(k, np.nan)
            if np.isfinite(a) and np.isfinite(b) and b > 0:
                ratios[s][k] = a / b
    for s in ["ss", "cs"]:
        vals = [r for k, r in ratios[s].items()]
        med = np.nanmedian(vals)
        sd = np.nanstd(vals)
        print(f"stage {s}: inj/clean quality ratio median={med:.3f} sd={sd:.3f}")

    print("\ncorrupt frames (injected run) -- per-stage inj/clean ratio, loop stats:")
    print("k  crc  ss_ratio cs_ratio  ss_err_rms(inj/cln) cs_err_rms(inj/cln)")
    for i, fr in enumerate(inf):
        k = fr["k"]
        bad = i < len(crc) and not crc[i]
        if not bad:
            continue
        c = ck.get(k)
        sser = f"{fr['ss_rms']:.0f}/{c['ss_rms']:.0f}" if c else f"{fr['ss_rms']:.0f}/-"
        cser = f"{fr['cs_rms']:.3f}/{c['cs_rms']:.3f}" if c else f"{fr['cs_rms']:.3f}/-"
        rs = ratios["ss"].get(k, np.nan)
        rc = ratios["cs"].get(k, np.nan)
        first = "ss" if (np.isfinite(rs) and rs > 1.5) else \
                ("cs" if (np.isfinite(rc) and rc > 1.5) else "downstream")
        print(f"{k}  BAD  {rs:.3f} {rc:.3f}  {sser} {cser}  first_divergent={first}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
