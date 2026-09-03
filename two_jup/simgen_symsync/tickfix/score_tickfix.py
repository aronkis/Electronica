#!/usr/bin/env python3
"""score_tickfix.py -- A/B verdict for the TICK-FIX campaign.

Reads tf_<s>_<e>_m{0,1,2}_{rxw,frames,hits}.txt shards. Per mode:
  - CRC verdict per delivered frame (QK header + crc32, AND len==191 words);
  - corrupt-frame rate over scored frames (warmup + edge frames excluded);
  - morphology of the m1 positive control: frame lengths of corrupt frames,
    event run lengths (self-heal), start-to-start intervals in frame units
    (expect the 8 / 24 alternation, 16 absent), attribution (sw>0 tag),
    stale-content check (corrupt words == words delivered 1536 beats earlier);
  - m2 vs m0: delivered-stream equality (bitwise), frame-count parity;
  - throughput and guard counters (nrepair, noverflow, mingap) from _res.txt.
"""
import glob, re, statistics as st, sys, zlib

WARM = 8  # shard warmup frames (excluded, matches run_qtick discipline)
EDGE = 2  # scored range: [w0+WARM+EDGE-w0 .. n-EDGE] in shard-local frames


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


def load(pfx):
    words, frames, cur = [], [], []
    for ln in open(pfx + "_rxw.txt"):
        w, last, user = ln.strip().split(",")
        words.append(int(w, 16))
        cur.append(int(w, 16))
        if int(last):
            frames.append(cur)
            cur = []
    meta = []
    for ln in open(pfx + "_frames.txt"):
        if ln.startswith("#") or not ln.strip():
            continue
        p = ln.split()
        # outframe clk nwords cksum16 cfc_est sw stale rep
        meta.append(dict(clk=int(p[1]), nw=int(p[2]), cks=int(p[3]),
                         sw=int(p[5]), stale=int(p[6]), rep=int(p[7])))
    res = {}
    for ln in open(pfx + "_res.txt"):
        for tok in ln.split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                res[k] = v
    return words, frames, meta, res


def main():
    shards = sorted(set(re.match(r"(tf_\d+_\d+)_m0_frames", f).group(1)
                        for f in glob.glob("tf_*_m0_frames.txt")),
                    key=lambda x: int(x.split("_")[1]))
    agg = {m: dict(scored=0, bad=0, frames=0, nrxw=0, badlens=[], runs=[],
                   ivs=[], tagged=0, untagged_bad=0, stale_ok=0, stale_tot=0,
                   nrepair=0, noverflow=0, mingap=1 << 60)
           for m in (0, 1, 2)}
    m2_eq_m0 = True
    m2_neq_detail = []
    for sh in shards:
        per = {}
        for m in (0, 1, 2):
            pfx = f"{sh}_m{m}"
            words, frames, meta, res = load(pfx)
            n = min(len(frames), len(meta))
            lo, hi = WARM + EDGE, n - EDGE
            a = agg[m]
            a["frames"] += n
            a["nrxw"] += len(words)
            a["nrepair"] += int(res.get("nrepair", 0))
            a["noverflow"] += int(res.get("noverflow", 0))
            mg = int(res.get("mingap", -1))
            if mg > 0:
                a["mingap"] = min(a["mingap"], mg)
            bad_idx = []
            for i in range(lo, hi):
                ok = verdict(frames[i])
                a["scored"] += 1
                if not ok:
                    a["bad"] += 1
                    bad_idx.append(i)
                    a["badlens"].append(len(frames[i]))
                    if meta[i]["sw"] > 0:
                        a["tagged"] += 1
                    else:
                        a["untagged_bad"] += 1
            # event runs + intervals
            ev = []
            for k in bad_idx:
                if ev and k == ev[-1][-1] + 1:
                    ev[-1].append(k)
                else:
                    ev.append([k])
            a["runs"] += [len(x) for x in ev]
            starts = [x[0] for x in ev]
            a["ivs"] += [b - c for c, b in zip(starts, starts[1:])]
            per[m] = (words, frames, meta, bad_idx)
        # stale-content check on m1: corrupt-frame words that differ from m0
        # must equal the m0 stream 1536 words earlier (ring stale fingerprint)
        w0, f0 = per[0][0], per[0][1]
        w1, f1 = per[1][0], per[1][1]
        base = 0
        for i, fr in enumerate(f1):
            if i < len(f0) and fr != f0[i]:
                for j, wv in enumerate(fr):
                    gi = base + j
                    if gi < len(w0) and wv != w0[gi]:
                        agg[1]["stale_tot"] += 1
                        if gi >= 1536 and wv == w1[gi - 1536]:
                            agg[1]["stale_ok"] += 1
            base += len(fr)
        # m2 == m0 bitwise?
        if per[2][0] != per[0][0]:
            m2_eq_m0 = False
            d = sum(1 for x, y in zip(per[2][0], per[0][0]) if x != y)
            m2_neq_detail.append((sh, d, len(per[2][0]) - len(per[0][0])))

    names = {0: "m0 clean", 1: "m1 inject+UNGUARDED", 2: "m2 inject+GUARDED"}
    for m in (0, 1, 2):
        a = agg[m]
        rate = 100.0 * a["bad"] / a["scored"] if a["scored"] else 0.0
        print(f"{names[m]}: frames={a['frames']} nrxw={a['nrxw']} "
              f"scored={a['scored']} corrupt={a['bad']} rate={rate:.2f}% "
              f"tagged={a['tagged']} untagged={a['untagged_bad']} "
              f"repairs={a['nrepair']} skid_ovf={a['noverflow']} "
              f"mingap={a['mingap'] if a['mingap'] < 1<<59 else '-'}")
        if m == 1 and a["bad"]:
            lens = sorted(set(a["badlens"]))
            runh = {r: a["runs"].count(r) for r in sorted(set(a["runs"]))}
            ivh = {v: a["ivs"].count(v) for v in sorted(set(a["ivs"]))}
            cv = (st.pstdev(a["ivs"]) / st.mean(a["ivs"])) if len(a["ivs"]) > 1 else 0
            print(f"  positive-control morphology:")
            print(f"    corrupt frame lengths (words): {lens}  (191 = full delivery)")
            print(f"    event run lengths: {runh}  (1 = self-heal <=1 frame)")
            print(f"    start-to-start intervals: {ivh}  CV={cv:.2f}")
            print(f"    c8={ivh.get(8,0)} c16={ivh.get(16,0)} "
                  f"c24={ivh.get(24,0)} c25={ivh.get(25,0)}")
            print(f"    stale-content fingerprint: {a['stale_ok']}/{a['stale_tot']} "
                  f"corrupt words == stream[-1536] (8.04 frames earlier)")
    print(f"m2 delivered stream bitwise == m0 clean: {m2_eq_m0}"
          + ("" if m2_eq_m0 else f"  DIFFS {m2_neq_detail}"))


if __name__ == "__main__":
    main()
