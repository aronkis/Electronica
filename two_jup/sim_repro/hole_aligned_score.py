#!/usr/bin/env python3
"""hole_aligned_score.py <chunk_dir> <hw_lost_seqs_csv> [out_csv]

Generalisation of tap_replay_study/singles_replay/compare_singles.py (08-12):
merge perframe_f1536 chunk runs (chunk_<s>_<e>_r0_{rxw,frames}.txt) into a
per-capture-frame verdict (QK header + zlib CRC32 over the 191-word frame),
fit the seq anchor on CRC-good frames, then report the netlist verdict for
every hardware-lost seq (from sim_repro/window_truth.py) and for the
hardware-good controls. Scoring rule as in the original: skip warm-up head
and drain tail of each chunk; prefer the payload chunk.
"""
import glob, os, re, sys, zlib
SPF = 49332; FP = SPF * 4; WPF = 191; WARM = 8

def load_chunk(pfx):
    words = [(int(w, 16), int(l)) for w, l, u in (ln.strip().split(',') for ln in open(pfx + '_rxw.txt') if ln.strip() and not ln.startswith('#'))]
    clks = {int(p[0]): int(p[1]) for p in (ln.split() for ln in open(pfx + '_frames.txt') if ln.strip() and not ln.startswith('#'))}
    frames, cur = [], []
    for w, last in words:
        cur.append(w)
        if last: frames.append(cur); cur = []
    return frames, clks

def verdict(fw):
    buf = b''.join(w.to_bytes(8, 'little') for w in fw)
    ok, seq, length = 0, -1, -1
    if len(buf) >= 12 and buf[0] == 0x51 and buf[1] == 0x4B:
        length = buf[2] | (buf[3] << 8); seq = int.from_bytes(buf[4:8], 'little')
        if length <= len(buf) - 12:
            tmp = bytearray(buf[:12 + length]); crc_rx = int.from_bytes(buf[8:12], 'little'); tmp[8:12] = b'\0\0\0\0'
            ok = int((zlib.crc32(bytes(tmp)) & 0xFFFFFFFF) == crc_rx)
    return int(ok and len(fw) == WPF), seq, len(fw)

def main():
    d = sys.argv[1]; hw = [int(x) for x in sys.argv[2].split(',') if x]
    out = sys.argv[3] if len(sys.argv) > 3 else None
    kmap = {}
    for pfx in sorted(glob.glob(os.path.join(d, 'chunk_*_r0_rxw.txt'))):
        pfx = pfx[:-len('_rxw.txt')]
        m = re.search(r'chunk_(\d+)_(\d+)_r0', pfx); s, e = int(m.group(1)), int(m.group(2)); w0 = max(s - WARM, 0)
        frames, clks = load_chunk(pfx)
        for i, fw in enumerate(frames):
            clk = clks.get(i, -1)
            if clk < 0: continue
            k = w0 + round(clk / FP - 2.3); lo = w0 + 2 if w0 > 0 else 0
            if not (lo <= k <= e - 2): continue
            payload = s <= k <= e - 2
            if k in kmap and kmap[k][4] and not payload: continue
            kmap[k] = (*verdict(fw), os.path.basename(pfx), payload)
    ks = sorted(kmap)
    goods = [(k, kmap[k][1]) for k in ks if kmap[k][0]]
    if not goods:
        print(f"scored frames={len(ks)} crc_good=0 -- NO CRC-GOOD FRAME IN THE NETLIST OUTPUT (all {len(ks)} delivered frames fail header/CRC); no seq anchor possible")
        hdr = sum(1 for k in ks if kmap[k][1] >= 0); print(f"  frames with a valid QK header: {hdr}/{len(ks)}; words per frame: {sorted(set(kmap[k][2] for k in ks))}")
        return
    bases = [s - k for k, s in goods]; base = max(set(bases), key=bases.count)
    nonlin = sum(1 for b in bases if b != base)
    print(f"scored frames={len(ks)} k={ks[0]}..{ks[-1]} crc_good={len(goods)} seq_base={base} nonlinear_seq_on_good={nonlin}")
    bad = [(k, base + k) for k in ks if not kmap[k][0]]
    print("netlist CRC-fail frames (k,seq):", bad or "NONE")
    if out:
        with open(out, 'w') as f:
            f.write('k,seq_expected,crc_ok,seq_decoded,words,chunk,hw_lost\n')
            for k in ks:
                ok, seq, nw, pfx, _ = kmap[k]; f.write(f"{k},{base+k},{ok},{seq},{nw},{pfx},{int(base+k in hw)}\n")
    cov = [s for s in hw if (s - base) in kmap]; clean = [s for s in cov if kmap[s - base][0]]
    print(f"HW-LOST seqs: {len(hw)} total, {len(cov)} inside scored window, {len(clean)} decode CRC-GOOD in netlist, {len(cov)-len(clean)} fail")
    for s in cov:
        ok, seq, nw, pfx, _ = kmap[s - base]; print(f"  hw-lost seq {s} k={s-base}: crc_ok={ok} decoded_seq={seq} words={nw} {pfx}")
    ctrl = [k for k in ks if (base + k) not in hw]; cbad = [k for k in ctrl if not kmap[k][0]]
    print(f"HW-GOOD controls: {len(ctrl)} scored, {len(ctrl)-len(cbad)} clean, fails at (k,seq): {[(k, base+k) for k in cbad] or 'NONE'}")

if __name__ == '__main__': main()
