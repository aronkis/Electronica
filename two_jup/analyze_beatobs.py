#!/usr/bin/env python3
"""Decode a BEATOBS beat-ILA capture CSV (probes 8/9 = packed state vector from
beatobs_overlay) and apply the BEATILA3_DESIGN.md binary readout rule.

Packing (int16 pair, one sample per adc_1_clk):
  probe8 (debugI1): [0] dataOut  [1] startOut  [2] validOut
                    [4:3] decision pair  [6:5] RateHandle mod-4 counter
                    [15:8] FIFO fill proxy (push-pop, low 8)
  probe9 (debugQ1): [7:0] push counter low-8   [15:8] pop counter low-8

Readout (pre-stated): compare against a golden-gap capture of the same session.
  A: decision seq + rh counter + fill all golden-consistent, dataOut seq wrong
     -> implementation divergence between decision and serial output.
  B: any state stream deviates (decision seq wrong / rh phase step / fill jump)
     -> named-element fault (rate-boundary slip shows as rh/fill step with
        decision seq shifted -- Travis mechanism).
  C: void (window not corrupt at force / probes constant).
usage: analyze_beatobs.py <run_csv> [golden_csv]
"""
import sys, csv
import numpy as np

def load(fn):
    rows = list(csv.reader(open(fn)))
    hdr = rows[0]
    def col(tag):
        return [i for i, h in enumerate(hdr) if tag in h][0]
    i8, i9 = col('probe8['), col('probe9[')
    I8, I9 = [], []
    for r in rows[2:]:  # skip header + Radix
        try:
            I8.append(int(r[i8], 16)); I9.append(int(r[i9], 16))
        except (ValueError, IndexError):
            pass
    return np.array(I8, np.uint32), np.array(I9, np.uint32)

def fields(I8, I9):
    return dict(
        dataOut=(I8 >> 0) & 1, startOut=(I8 >> 1) & 1, validOut=(I8 >> 2) & 1,
        decis=(I8 >> 3) & 3, rhctr=(I8 >> 5) & 3, fill=(I8 >> 8) & 0xFF,
        push=I9 & 0xFF, pop=(I9 >> 8) & 0xFF)

def describe(f, tag):
    n = len(f['dataOut'])
    starts = np.where(np.diff(f['startOut'].astype(int)) == 1)[0]
    # rh counter should cycle 0..3; report distinct phase alignments vs sample idx%4
    rh = f['rhctr']
    ph = (rh.astype(int) - (np.arange(n) % 4)) % 4
    phc = np.bincount(ph, minlength=4)
    fill = f['fill']
    print(f"[{tag}] N={n} frame_starts={len(starts)}")
    print(f"  rh-phase hist (ctr - idx%4 mod 4): {phc.tolist()}  (steady = one dominant bin)")
    print(f"  fill: min={fill.min()} max={fill.max()} uniq={sorted(set(fill.tolist()))[:8]}")
    print(f"  decis uniq={sorted(set(f['decis'].tolist()))} dataOut ones={int(f['dataOut'].sum())}/{n}")
    return dict(starts=starts, ph=ph, fill=fill)

def main():
    run = sys.argv[1]
    f = fields(*load(run))
    r = describe(f, 'RUN')
    if len(sys.argv) > 2:
        g = fields(*load(sys.argv[2]))
        gg = describe(g, 'GOLDEN')
        # sequence compare aligned at first frame start
        if len(r['starts']) and len(gg['starts']):
            a, b = r['starts'][0], gg['starts'][0]
            m = min(len(f['dataOut']) - a, len(g['dataOut']) - b)
            for k in ('dataOut', 'decis', 'rhctr', 'fill'):
                d = int(np.sum(f[k][a:a+m] != g[k][b:b+m]))
                print(f"  seq-diff {k}: {d}/{m} samples differ")
            print("READOUT hint: decis/rhctr/fill match + dataOut differs => A;")
            print("  decis or rhctr/fill differ => B (rate-boundary slip if rh/fill stepped);")
            print("  everything matches => capture likely landed in a golden gap (C).")

if __name__ == '__main__':
    main()
