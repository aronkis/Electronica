#!/usr/bin/env python3
"""score_qtick.py -- QUICK-LOOK verdict: drift-vs-lock for the gated byte-plane
tick. Reads q_<s>_<e>_{rxw,frames,ticks}.txt shards; scores k in
[max(w0+2,s), e-2]; attribution by TICK TAG: a CRC-fail frame counts as an
INJECTED event iff it (or a +/-1 neighbor) has eaten>0; other CRC fails are
baseline-coincident. Reports tagged count, within-shard interval CV, k mod 8
histogram, gated-tick census.
"""
import glob
import re
import statistics as st
import zlib

SPF = 49332
FP = SPF * 4
WARM = 8


def verdict(fw):
    buf = b"".join(w.to_bytes(8, "little") for w in fw)
    ok = 0
    if len(buf) >= 12 and buf[0] == 0x51 and buf[1] == 0x4B:
        length = buf[2] | (buf[3] << 8)
        if length <= len(buf) - 12:
            crc_rx = int.from_bytes(buf[8:12], "little")
            tmp = bytearray(buf[: 12 + length])
            tmp[8:12] = b"\x00\x00\x00\x00"
            ok = int((zlib.crc32(bytes(tmp)) & 0xFFFFFFFF) == crc_rx)
    return int(ok and len(fw) == 191)


def main():
    all_tagged_k = []          # (shard_s, k)
    all_base_k = []
    intervals = []
    mod8 = [0] * 8
    tot_scored = tot_ticks = tot_gated = tot_eatframes = 0
    for fn in sorted(glob.glob("q_*_frames.txt"),
                     key=lambda x: int(x.split("_")[1])):
        m = re.match(r"q_(\d+)_(\d+)_frames", fn)
        s, e = int(m.group(1)), int(m.group(2))
        w0 = max(s - WARM, 0)
        pfx = f"q_{s}_{e}"
        frames, cur = [], []
        for ln in open(pfx + "_rxw.txt"):
            w, last, user = ln.strip().split(",")
            cur.append(int(w, 16))
            if int(last):
                frames.append(cur)
                cur = []
        meta = []
        for ln in open(pfx + "_frames.txt"):
            if ln.startswith("#") or not ln.strip():
                continue
            p = ln.split()
            meta.append((int(p[1]), int(p[2]), int(p[5])))  # clk nwords eaten
        n = min(len(frames), len(meta))
        rows = []
        for i in range(n):
            clk, nw, eaten = meta[i]
            k = w0 + round(clk / FP - 2.3)
            rows.append((k, verdict(frames[i]), eaten))
        lo = max(w0 + 2, s)
        sc = [(k, ok, ea) for k, ok, ea in rows if lo <= k <= e - 2]
        tot_scored += len(sc)
        eat_ks = set(k for k, ok, ea in sc if ea > 0)
        tot_eatframes += len(eat_ks)
        bad = [k for k, ok, ea in sc if not ok]
        tagged = sorted(k for k in bad
                        if any((k + d) in eat_ks for d in (-1, 0, 1)))
        basec = sorted(set(bad) - set(tagged))
        # collapse tagged into events
        ev = []
        for k in tagged:
            if ev and k == ev[-1][-1] + 1:
                ev[-1].append(k)
            else:
                ev.append([k])
        starts = [x[0] for x in ev]
        iv = [b - a for a, b in zip(starts, starts[1:])]
        intervals += iv
        for k in starts:
            mod8[k % 8] += 1
        all_tagged_k += [(s, k) for k in tagged]
        all_base_k += [(s, k) for k in basec]
        ticks = [ln.split() for ln in open(pfx + "_ticks.txt")
                 if not ln.startswith("#")]
        ng = sum(1 for t in ticks if t[1] == "1")
        tot_ticks += len(ticks)
        tot_gated += ng
        print(f"shard {s:3d}-{e}: scored={len(sc)} ticks={len(ticks)} "
              f"gated={ng} eat_frames={len(eat_ks)} tagged_bad={tagged} "
              f"basec_bad={basec} iv={iv}")
    print()
    nev = len([1 for _ in all_tagged_k])
    print(f"TOTAL scored={tot_scored} ticks={tot_ticks} gated={tot_gated} "
          f"frames_with_eaten_words={tot_eatframes}")
    print(f"tagged (injected-attributed) bad frames: {len(all_tagged_k)}")
    print(f"baseline-coincident bad frames: {len(all_base_k)} "
          f"{[k for _, k in all_base_k]}")
    if len(intervals) >= 2:
        cv = st.pstdev(intervals) / st.mean(intervals)
        print(f"within-shard event intervals (n={len(intervals)}): "
              f"{sorted(intervals)}")
        print(f"interval mean={st.mean(intervals):.2f} CV={cv:.2f}")
    else:
        print(f"intervals: too few ({intervals})")
    print(f"k mod 8 of tagged event starts: {mod8}")


if __name__ == "__main__":
    main()
