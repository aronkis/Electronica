#!/usr/bin/env python3
"""compare_singles.py -- merge the singles_reread chunk runs and cross-reference
the 148 hardware framelog corrupt-single events (forward direction, -M16 DMA
cadence). Netlist: perframe_f1536 (bit-true f1536), capture:
two_jup/r3cap/singles_reread/pair.iq (162 frames, SPF=49332).

Frame mapping: capture frame k = samples [k*SPF,(k+1)*SPF); last delivered word
of slice-frame j lands at clk ~= (j + 2.3)*4*SPF, so k = w0 + round(clk/FP - 2.3).
Scoring rule (prior-art traps): a frame k is scored from a chunk only if
w0+2 <= k <= chunk_end-2 (skip cold-start/warm-up head and undelivered tail);
prefer the payload chunk when two chunks cover k.
"""
import glob
import re
import sys
import zlib

SPF = 49332
FP = SPF * 4
WPF = 191
WARM = 8


def load_chunk(pfx):
    words = []
    with open(pfx + "_rxw.txt") as f:
        for ln in f:
            ln = ln.strip()
            if ln and not ln.startswith("#"):
                w, last, user = ln.split(",")
                words.append((int(w, 16), int(last)))
    clks = {}
    with open(pfx + "_frames.txt") as f:
        for ln in f:
            if not ln.startswith("#") and ln.strip():
                p = ln.split()
                clks[int(p[0])] = int(p[1])
    frames, cur = [], []
    for w, last in words:
        cur.append(w)
        if last:
            frames.append(cur)
            cur = []
    return frames, clks


def verdict(fw):
    buf = b"".join(w.to_bytes(8, "little") for w in fw)
    ok, seq, length = 0, -1, -1
    if len(buf) >= 12 and buf[0] == 0x51 and buf[1] == 0x4B:
        length = buf[2] | (buf[3] << 8)
        seq = buf[4] | (buf[5] << 8) | (buf[6] << 16) | (buf[7] << 24)
        if length <= len(buf) - 12:
            crc_rx = int.from_bytes(buf[8:12], "little")
            tmp = bytearray(buf[: 12 + length])
            tmp[8:12] = b"\x00\x00\x00\x00"
            ok = int((zlib.crc32(bytes(tmp)) & 0xFFFFFFFF) == crc_rx)
    ok = ok and (len(fw) == WPF)
    return int(ok), seq, len(fw)


def main():
    kmap = {}  # k -> (crc_ok, seq, words, chunk, payload?)
    for pfx in sorted(glob.glob("chunk_*_r0_rxw.txt")):
        pfx = pfx[: -len("_rxw.txt")]
        m = re.match(r"chunk_(\d+)_(\d+)_r0", pfx)
        s, e = int(m.group(1)), int(m.group(2))
        w0 = max(s - WARM, 0)
        frames, clks = load_chunk(pfx)
        for i, fw in enumerate(frames):
            clk = clks.get(i, -1)
            if clk < 0:
                continue
            k = w0 + round(clk / FP - 2.3)
            lo = w0 + 2 if w0 > 0 else 0
            if not (lo <= k <= e - 2):
                continue
            payload = s <= k <= e - 2
            if k in kmap and kmap[k][4] and not payload:
                continue
            kmap[k] = (*verdict(fw), pfx, payload)

    ks = sorted(kmap)
    # seq anchor: fit seq = base + k over CRC-good frames
    goods = [(k, kmap[k][1]) for k in ks if kmap[k][0]]
    bases = [s - k for k, s in goods]
    base = max(set(bases), key=bases.count)
    off = sum(1 for b in bases if b != base)
    print(f"scored frames: {len(ks)} (k={ks[0]}..{ks[-1]}), "
          f"crc_good={len(goods)}, seq_base={base} (non-linear seq on {off} good frames)")

    with open("framemap_singles.csv", "w") as f:
        f.write("k,seq_expected,crc_ok,seq_decoded,words,chunk\n")
        for k in ks:
            ok, seq, nw, pfx, _ = kmap[k]
            f.write(f"{k},{base + k},{ok},{seq},{nw},{pfx}\n")

    # gaps in k coverage
    missing = [k for k in range(ks[0], ks[-1] + 1) if k not in kmap]
    if missing:
        print("k not delivered/scored:", missing)

    bad = [k for k in ks if not kmap[k][0]]
    print("netlist CRC-fail frames:", [(k, base + k) for k in bad] or "NONE")

    # hardware corrupt events (from frames.bin, in/near IQ window)
    hw_single = [31999, 32032, 32040, 32065, 32073, 32098, 32139,
                 32163, 32171, 32196, 32229, 32237]
    hw_pair = [32007, 32008, 32106, 32107, 32131, 32132, 32204, 32205]
    print("\nseq  k  netlist_verdict")
    for s in sorted(hw_single + hw_pair):
        k = s - base
        if k in kmap:
            ok, seq, nw, pfx, _ = kmap[k]
            tag = "pair" if s in hw_pair else "single"
            print(f"{s}  k={k}  crc_ok={ok} decoded_seq={seq} words={nw} ({tag}, {pfx})")
        else:
            print(f"{s}  k={k}  NOT COVERED by sim scoring")
    return 0


if __name__ == "__main__":
    sys.exit(main())
