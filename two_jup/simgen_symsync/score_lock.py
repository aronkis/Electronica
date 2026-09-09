#!/usr/bin/env python3
"""score_lock.py -- per-frame CRC verdict + fingerprint for a sim_byte_lock run.

usage: score_lock.py PREFIX [PREFIX...]

For each PREFIX (files PREFIX_rxw.txt, PREFIX_frames.txt):
  - per-frame CRC verdict (QK header + crc32, 191-word rule -- same as
    singles_replay/compare_singles.py)
  - capture-frame index k = round(clk/FP - 2.3)   (FP = 4*49332 clk/frame)
  - writes PREFIX_verdict.csv: k,crc_ok,seq,nwords,cksum16,cfc_est,
    ss_err_rms,cs_err_rms,ssIntP,ssIntI,csIntP,csIntI,pdsync
  - fingerprint over the scored region (k >= KMIN, default 6, to skip
    cold-start): event collapse (consecutive bad k -> one event), event rate,
    single:double ratio, inter-arrival intervals of collapsed events
    (start-to-start), interval histogram, k mod 8 distribution, CV.
"""
import sys
import zlib

SPF = 49332
FP = SPF * 4
WPF = 191
KMIN = 6


def verdict(fw):
    buf = b"".join(w.to_bytes(8, "little") for w in fw)
    ok, seq = 0, -1
    if len(buf) >= 12 and buf[0] == 0x51 and buf[1] == 0x4B:
        length = buf[2] | (buf[3] << 8)
        seq = int.from_bytes(buf[4:8], "little")
        if length <= len(buf) - 12:
            crc_rx = int.from_bytes(buf[8:12], "little")
            tmp = bytearray(buf[: 12 + length])
            tmp[8:12] = b"\x00\x00\x00\x00"
            ok = int((zlib.crc32(bytes(tmp)) & 0xFFFFFFFF) == crc_rx)
    ok = ok and (len(fw) == WPF)
    return int(ok), seq


def score(pfx):
    frames, cur = [], []
    with open(pfx + "_rxw.txt") as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            w, last, user = ln.split(",")
            cur.append(int(w, 16))
            if int(last):
                frames.append(cur)
                cur = []
    stats = {}
    with open(pfx + "_frames.txt") as f:
        for ln in f:
            if ln.startswith("#") or not ln.strip():
                continue
            p = ln.split()
            stats[int(p[0])] = p    # outframe -> fields
    rows = []
    for i, fw in enumerate(frames):
        if i not in stats:
            continue
        p = stats[i]
        clk = int(p[1])
        k = round(clk / FP - 2.3)
        ok, seq = verdict(fw)
        rows.append((k, ok, seq, int(p[2]), p[3], p[4], p[5], p[6],
                     p[7], p[8], p[9], p[10], p[11]))
    with open(pfx + "_verdict.csv", "w") as f:
        f.write("k,crc_ok,seq,nwords,cksum16,cfc_est,ss_err_rms,cs_err_rms,"
                "ssIntP,ssIntI,csIntP,csIntI,pdsync\n")
        for r in rows:
            f.write(",".join(str(x) for x in r) + "\n")
    return rows


def fingerprint(pfx, rows):
    sc = [(k, ok) for k, ok, *_ in rows if k >= KMIN]
    ks = [k for k, _ in sc]
    bad = sorted(k for k, ok in sc if not ok)
    nf = len(sc)
    # delivered-k gaps also count as corrupt-ish (undelivered) -- report only
    missing = [k for k in range(min(ks), max(ks) + 1) if k not in set(ks)] if ks else []
    # collapse consecutive-k bad frames into events
    events = []
    for k in bad:
        if events and k == events[-1][-1] + 1:
            events[-1].append(k)
        else:
            events.append([k])
    singles = sum(1 for e in events if len(e) == 1)
    doubles = sum(1 for e in events if len(e) == 2)
    longer = sum(1 for e in events if len(e) > 2)
    starts = [e[0] for e in events]
    iv = [b - a for a, b in zip(starts, starts[1:])]
    hist = {}
    for x in iv:
        hist[x] = hist.get(x, 0) + 1
    mod8 = [0] * 8
    for k in bad:
        mod8[k % 8] += 1
    import statistics as st
    cv = (st.pstdev(iv) / st.mean(iv)) if len(iv) >= 2 and st.mean(iv) else float("nan")
    print(f"== {pfx}: scored={nf} bad_frames={len(bad)} "
          f"({100*len(bad)/max(nf,1):.1f}%) events={len(events)} "
          f"S:D:L={singles}:{doubles}:{longer} missing_k={missing}")
    print(f"   bad k: {bad}")
    print(f"   intervals: {sorted(iv)}  hist={dict(sorted(hist.items()))}  "
          f"CV={cv:.2f}" if iv else "   intervals: none")
    print(f"   k mod 8: {mod8}")
    return dict(pfx=pfx, scored=nf, bad=len(bad), events=len(events),
                singles=singles, doubles=doubles, longer=longer,
                intervals=iv, mod8=mod8, cv=cv, badk=bad)


def main():
    out = []
    for pfx in sys.argv[1:]:
        rows = score(pfx)
        out.append(fingerprint(pfx, rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
