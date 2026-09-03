#!/usr/bin/env python3
"""t87_inject_verdict.py -- injection-anchored T8.7 per-event verdict.

Cold-sim register comparison is fundamentally unusable: quantized loops
started from different initial state sustain persistent LSB-scale limit-cycle
differences, so live and cold-sim registers never match bit-exactly at ANY
time offset (measured: <=3/200 anchors across +-95k). The completeness proof
says the fix: inject the live state and the sim tracks bit-exactly.

Per event:
  1. COARSE align: numpy L1 valley of live AGC-integrator series (telemetry
     slot 18/19) vs the cold-sim per-beat AGC trace (realcmp2 *_traj.txt).
     AGC forgets initial state, so cold-sim AGC ~= live AGC in VALUE (LSBs
     differ; L1 tolerates that) -- valid alignment signal.
  2. EXACT align: sweep candidate offsets around coarse. For each: slice the
     input ring from (w_T0' + d), inject the T0' telemetry image state at
     sample 0 (rstcs_end=0 -- must not wipe injected carrier state), run ~4
     frames, score exact register matches vs the following live images.
     Correct offset -> near-total match after the skew transient (the 24-slot
     image is sampled across 22 beats, so injected state is slightly skewed;
     the contractive loops re-lock within ~2 frames).
  3. VERDICT run: slice from w_T0' + d* through trig + POST frames, inject,
     per-beat trace, compare EVERY following live image through the episode.
     First sustained divergence (register, beat) = the live corruption
     signature; no divergence = monitored state bit-clean through the errors.

Usage: t87_inject_verdict.py <huntdir> <event> [--sweep-only]
"""
import sys, os, struct, subprocess
import numpy as np

K5 = os.path.dirname(os.path.abspath(__file__))
R  = os.path.join(K5, '..', 'jupiter_240k5_byte', 'rtl_sim')
sys.path.insert(0, R)
sys.path.insert(0, K5)
import tel_parse as tp
from t87_compare import REGS, FRAME, TRIG, SS, CS, AGC

HARNESS = os.path.join(R, 'obj_byte_inject', 'Vwrap_byte_taps')

def load_sim_traj(path, ncol):
    idx = []; rows = []
    for l in open(path):
        p = l.split()
        idx.append(int(p[0])); rows.append(p[1:])
    return idx, rows

def slice_input(iq_path, start, count, out):
    with open(iq_path, 'rb') as f:
        f.seek(4 * start)
        data = f.read(4 * count)
    open(out, 'wb').write(data)
    return len(data) // 4

def run_sim(iqfile, nsamp, inject, pfx, subset, traj, tracewin):
    cmd = [HARNESS, iqfile, str(nsamp), '0', '2', '0', '0', pfx,
           '--inject', inject, '0',
           '--trace', subset, traj, '1',
           '--tracewin', str(tracewin[0]), str(tracewin[1])]
    subprocess.run(cmd, check=True, capture_output=True)

def score(imgs_sel, w0, sim, col, skip_imgs, nimgs):
    """exact-match fraction over live images [skip_imgs, skip_imgs+nimgs)"""
    tot = hit = 0
    for s, ws in imgs_sel:
        i = (s - w0) // 24
        if i < skip_imgs or i >= skip_imgs + nimgs:
            continue
        for name, parts in REGS:
            ci = col.get(name)
            if ci is None: continue
            live = simv = 0; ok = True
            for slot, wsh, lsb, mask in parts:
                r = sim.get(s - w0 + slot)
                if r is None: ok = False; break
                live |= ((ws[slot] >> wsh) & mask) << lsb
                simv |= ((int(r[ci], 16) >> lsb) & mask) << lsb
            if not ok: continue
            tot += 1
            if live == simv: hit += 1
    return hit, tot

def main():
    hunt, ev = sys.argv[1], sys.argv[2]
    d_meas = None
    if '--d' in sys.argv:
        d_meas = int(sys.argv[sys.argv.index('--d') + 1])
    tap  = f'{hunt}/{ev}_tap.iq'
    iqf  = f'{hunt}/{ev}.iq'
    subset = f'{hunt}/telnames.txt'
    coldtraj = f'{hunt}/simcmp/{ev}_traj.txt'
    names = [l.strip() for l in open(subset) if l.strip()]
    col = {n: i for i, n in enumerate(names)}
    work = f'{hunt}/simcmp/{ev}_inj'
    os.makedirs(work, exist_ok=True)

    words = tp.load_words(tap)
    imgs = tp.find_images(words)
    # T0' image: 2 frames before the trigger IN TAP COORDINATES. The two ring
    # saves are sequential copies displaced by ~1.3 s, so the tap-ring word at
    # the trigger is TRIG - d (d measured by CS-integrator FFT correlation).
    w_trig = TRIG - d_meas if d_meas is not None else TRIG
    tgt = w_trig - 2 * FRAME
    i0 = min(range(len(imgs)), key=lambda i: abs(imgs[i][0] - tgt))
    w0 = imgs[i0][0]
    print(f'{ev}: T0\' image {i0} at word {w0} (trig{w0-TRIG:+d})')
    # regenerate inject file (marker-fixed tel_parse)
    inj = f'{work}/inject.txt'
    subprocess.run(['python3', os.path.join(R, 'tel_parse.py'), 'inject',
                    tap, str(i0), inj], check=True, capture_output=True)

    # ---- 1. coarse align ----
    if d_meas is not None:
        d_c = d_meas
        print(f'using measured d={d_c} (FFT CS-integrator lock)')
    else:
        _unused = None
    # legacy AGC L1 coarse (featureless-envelope caveat) --
    ci_agc = col[AGC+'u_Loop_Filter__DOT__Delay1_out1_re'] if d_meas is None else None
    if d_meas is None:
        sidx, srows = load_sim_traj(coldtraj, len(names))
    if d_meas is None:
        s0 = sidx[0]
        sim_agc = np.array([int(r[ci_agc], 16) & 0xFFFFFFFFF for r in srows],
                           dtype=np.float64)
        anchors = [(s, ws) for s, ws, c in imgs
                   if w0 - 200 * 24 <= s <= w0 + 200 * 24]
        lw = np.array([s + 18 for s, ws in anchors])
        lv = np.array([(ws[18] | (ws[19] << 32)) for s, ws in anchors],
                      dtype=np.float64)
        lo = s0 - lw.min() + 1
        hi = s0 + len(sim_agc) - lw.max() - 2
        deltas = np.arange(lo, hi, 4)
        costs = np.empty(len(deltas))
        for k, d in enumerate(deltas):
            sv = sim_agc[lw + d - s0]
            costs[k] = np.abs(sv - lv).mean()
        d_c = int(deltas[costs.argmin()])
        fine = np.arange(max(lo, d_c - 8), min(hi, d_c + 9))
        fc = [np.abs(sim_agc[lw + d - s0] - lv).mean() for d in fine]
        d_c = int(fine[int(np.argmin(fc))])
        print(f'coarse AGC align: d={d_c} cost={min(fc):.1f}')

    # ---- 2. exact align: injection sweep ----
    SWEEP = range(d_c - 24, d_c + 25)
    NS_SW = 4 * FRAME + 200
    best = (-1.0, None)
    for d in SWEEP:
        start = w0 + d
        if start < 0: continue
        iqw = f'{work}/win.iq'
        n = slice_input(iqf, start, NS_SW, iqw)
        try:
            run_sim(iqw, n, inj, f'{work}/sw', subset,
                    f'{work}/sw_traj.txt', (0, NS_SW))
        except subprocess.CalledProcessError:
            continue
        sim = {}
        for l in open(f'{work}/sw_traj.txt'):
            p = l.split(); sim[int(p[0])] = p[1:]
        sel = [(s, ws) for s, ws, c in imgs if w0 <= s < w0 + 3 * FRAME]
        hit, tot = score(sel, w0, sim, col, skip_imgs=190, nimgs=160)
        frac = hit / tot if tot else 0
        if frac > best[0]:
            best = (frac, d)
        print(f'  d={d}: {hit}/{tot} = {frac:.3f}')
    frac, d_x = best
    print(f'EXACT ALIGN: d={d_x} match={frac:.3f}')
    if frac < 0.85:
        print('INJ_ALIGN_FAIL: no offset yields bit-exact tracking')
        return
    if '--sweep-only' in sys.argv:
        return

    # ---- 3. verdict run through the episode ----
    start = w0 + d_x
    NS_V = (w_trig - w0) + 16 * FRAME + 400
    iqv = f'{work}/verdict.iq'
    n = slice_input(iqf, start, NS_V, iqv)
    run_sim(iqv, n, inj, f'{work}/vd', subset,
            f'{work}/vd_traj.txt', (0, NS_V))
    sim = {}
    for l in open(f'{work}/vd_traj.txt'):
        p = l.split(); sim[int(p[0])] = p[1:]
    sel = [(s, ws) for s, ws, c in imgs if w0 <= s <= w_trig + 15 * FRAME]
    total = mism = 0
    divs = []
    per_reg = {}
    for s, ws in sel:
        i = (s - w0) // 24
        if i < 190:                      # skew transient margin (~1/2 frame)
            continue
        for name, parts in REGS:
            ci = col.get(name)
            if ci is None: continue
            live = simv = 0; ok = True
            for slot, wsh, lsb, mask in parts:
                r = sim.get(s - w0 + slot)
                if r is None: ok = False; break
                live |= ((ws[slot] >> wsh) & mask) << lsb
                simv |= ((int(r[ci], 16) >> lsb) & mask) << lsb
            if not ok: continue
            total += 1
            if live != simv:
                mism += 1
                short = name.split('__DOT__')[-1]
                per_reg[short] = per_reg.get(short, 0) + 1
                if len(divs) < 30:
                    divs.append((s, s - w_trig, short, hex(live), hex(simv)))
    print(f'VERDICT compare: {total} register-samples, {mism} mismatches')
    if per_reg:
        print('per-register mismatch counts:', sorted(per_reg.items(),
              key=lambda kv: -kv[1]))
        print('first divergences (word, rel-to-trig, reg, live, sim):')
        for v in divs:
            print('  ', v)
    else:
        print(f'{ev}: NO DIVERGENCE -- injected sim tracks every monitored '
              'register bit-exactly through the episode span.')

if __name__ == '__main__':
    main()
