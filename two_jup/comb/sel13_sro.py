#!/usr/bin/env python3
"""sel13_sro.py FILE.bin [--json OUT.json] -- T3 scoring (b): SRO / interpolator
sawtooth test on a DDRCAP-v2 sel13 capture.

Field map (task-4-report.md sec"IMPORTANT 2", ddrcap2_pc.py:86-89): I[10:0]=countReg,
I[15]=underflow sticky, Q=muReg.  DESK FACT (archived 09-02 sel13.bin, 67.1 M records):
Q == 4*(countReg mod 256) exactly -- muReg is the low 8 bits of countReg scaled by 4,
NOT an independent field.  countReg is a BOUNDED loop count (477..545 on 09-02), so the
pre-registered "wrap/sawtooth" is scored three ways, all on a tref-built time base
(record index is not a time base: the rx2 DMA drops 20-40% of records in bursts):

  1. THE SAWTOOTH.  countReg is a symbol-phase NCO: it steps -256 per record and wraps
     mod 1024 once per symbol (silicon: slot0~765, slot1~509, slot2~255, slot3 spans
     0..1023; 4 records = 4 samples = 1 symbol, so 256 counts == ONE SAMPLE interval and
     Q == 4*(countReg mod 256) is the sub-sample fractional phase).  Sampling countReg at
     slot 1 (once per symbol) and phase-unwrapping (countReg mod 256) mod 256 gives the
     accumulated fractional timing phase; ONE FULL 256-CYCLE IS ONE WHOLE-SAMPLE SLIP.
     The SRO prediction is exactly 1 cycle per 25.72 ms (38.9 cycles/s, 0.63 ppm of
     61.44 MSPS).  This test needs no time alignment at all.
  2. periodogram of countReg on a uniform symbol grid -> is there a line at
     f = 1/25.72 ms = 38.88 Hz (32 frames)?  Frame line at 1245.5 Hz is the built-in
     positive control that the time base and grid are right.
  3. explicit modular wraps of countReg (mod 2048) and of muReg (mod 1024), reported
     even when zero.

Frame index inside the capture comes from tref wraps (tref is mod 12333 = one frame of
symbols), so wrap events can be placed on the same transmitted-frame axis the comb
autocorrelation uses.
"""
import argparse, json, sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from ddrcap2_decode import load, decode

P = 12333            # frame period in symbols
FS_SYM = 15360000.0  # symbol rate (61.44 MSPS / 4)
F_TARGET = FS_SYM / (32.0 * P)   # 38.88 Hz == 25.72 ms == 32 frames


def build(path):
    a = load(path)
    d = decode(a)
    tr = d['tref']
    vp = np.flatnonzero(tr >= 0)
    trv = tr[vp].astype(np.int64)
    dt = np.mod(np.diff(trv), P)
    vals, cnts = np.unique(dt, return_counts=True)
    modal = int(vals[cnts.argmax()])
    sym = np.concatenate([[0], np.cumsum(dt)]).astype(np.int64)
    cnt = (a[vp, 0].astype(np.uint16) & 0x7FF).astype(np.int64)
    uf_all = ((a[:, 0].astype(np.uint16) >> 15) & 1).astype(np.int64)   # all records (pc.py rule)
    mu = a[vp, 1].astype(np.uint16).astype(np.int64)
    phase = (cnt % 256).astype(np.float64)                              # sub-sample phase, 256 = 1 sample
    uph = np.unwrap(phase * 2 * np.pi / 256.0) / (2 * np.pi) * 256.0    # unwrapped, units of counts
    frame = np.cumsum(np.concatenate([[0], (np.diff(trv) < 0).astype(np.int64)]))
    return dict(a=a, d=d, vp=vp, trv=trv, dt=dt, modal=modal, frac_modal=float(cnts.max() / len(dt)),
                sym=sym, cnt=cnt, uf_all=uf_all, mu=mu, phase=phase, uph=uph,
                frame=frame, n_records=len(a))


def grid(sym, y, B=256):
    """average y onto a uniform symbol grid of B symbols/bin; linear-fill empty bins."""
    nb = int(sym[-1] // B)
    acc = np.zeros(nb); num = np.zeros(nb)
    idx = sym // B; ok = idx < nb
    np.add.at(acc, idx[ok], y[ok]); np.add.at(num, idx[ok], 1)
    good = num > 0
    out = np.where(good, acc / np.maximum(num, 1), 0.0)
    bad = np.flatnonzero(~good)
    if len(bad):
        out[bad] = np.interp(bad, np.flatnonzero(good), out[good])
    return out, FS_SYM / B, int(len(bad))


def spectrum(y, fsb, fmax=2000.0):
    y = y - y.mean()
    w = np.hanning(len(y))
    Y = np.fft.rfft(y * w)
    f = np.fft.rfftfreq(len(y), 1.0 / fsb)
    pw = np.abs(Y) ** 2
    return f, pw


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('src'); ap.add_argument('--json')
    ap.add_argument('--bin-symbols', type=int, default=256)
    x = ap.parse_args()
    s = build(x.src)
    R = {}
    span = int(s['sym'][-1])
    R['records'] = s['n_records']; R['valid_tref'] = int(len(s['vp']))
    R['modal_tref_delta'] = s['modal']; R['frac_at_modal'] = s['frac_modal']
    R['drop_frac_gt2x_modal'] = float((s['dt'] > 2 * s['modal']).mean())
    R['symbol_span'] = span
    R['span_ms'] = span / FS_SYM * 1e3
    R['span_frames'] = span / P
    R['frames_by_tref_wrap'] = int(s['frame'][-1])
    c = s['cnt']
    R['countReg'] = dict(min=int(c.min()), max=int(c.max()), mean=float(c.mean()),
                         std=float(c.std()), distinct=int(len(np.unique(c))))
    R['underflow_mean_all_records'] = float(s['uf_all'].mean())  # pc.py rule: 0.25 +/- 0.03
    R['muReg_is_low8_of_countReg_x4'] = bool(np.array_equal(s['mu'], 4 * (c % 256)))
    # (1) explicit modular wraps
    for nm, v, mod in (('countReg', c, 2048), ('muReg', s['mu'], 1024)):
        dv = np.diff(v)
        R[f'{nm}_down_wraps'] = int((dv < -mod / 2).sum())
        R[f'{nm}_up_wraps'] = int((dv > mod / 2).sum())
    # (2) THE SAWTOOTH: unwrapped sub-sample phase; 256 counts == one whole sample
    uph = s['uph']; sym = s['sym']
    total = float(uph[-1] - uph[0])
    R['unwrapped_phase_total_counts'] = total
    R['whole_sample_slips'] = total / 256.0
    sl = float(np.polyfit(sym, uph, 1)[0])          # counts per symbol
    R['phase_slope_counts_per_symbol'] = sl
    if sl != 0:
        per_sym = 256.0 / abs(sl)
        R['sawtooth_period_symbols'] = per_sym
        R['sawtooth_period_ms'] = per_sym / FS_SYM * 1e3
        R['sawtooth_period_frames'] = per_sym / P
        R['sro_ppm'] = abs(sl) / 256.0 * 1e6 / 4.0   # counts/symbol -> samples/symbol -> ppm of the 4x sample clock
    else:
        R['sawtooth_period_symbols'] = None; R['sawtooth_period_ms'] = None
        R['sawtooth_period_frames'] = None; R['sro_ppm'] = 0.0
    # per-cycle periods (uncertainty), from successive 256-count crossings of the unwrapped phase
    if abs(total) >= 256:
        sgn = 1.0 if total > 0 else -1.0
        lvls = np.arange(1, int(abs(total) // 256) + 1) * 256.0 * sgn + uph[0]
        idx = np.searchsorted(uph * sgn, lvls * sgn)
        idx = idx[idx < len(sym)]
        ts = sym[idx]
        g = np.diff(ts)
        R['n_slip_events'] = int(len(ts))
        R['slip_period_symbols_median'] = float(np.median(g)) if len(g) else None
        R['slip_period_ms_median'] = float(np.median(g) / FS_SYM * 1e3) if len(g) else None
        R['slip_period_frames_median'] = float(np.median(g) / P) if len(g) else None
        R['slip_period_frames_mean'] = float(g.mean() / P) if len(g) else None
        R['slip_period_frames_sd'] = float(g.std() / P) if len(g) else None
        R['slip_period_frames_sem'] = float(g.std() / np.sqrt(len(g)) / P) if len(g) else None
        R['slip_frames_in_capture'] = (s['frame'][idx]).tolist()[:4000]
    else:
        R['n_slip_events'] = 0
        for k in ('slip_period_symbols_median','slip_period_ms_median','slip_period_frames_median',
                  'slip_period_frames_mean','slip_period_frames_sd','slip_period_frames_sem'):
            R[k] = None
        R['slip_frames_in_capture'] = []
    # (3) periodogram
    y, fsb, nfill = grid(s['sym'], s['phase'], x.bin_symbols)
    R['grid_bins'] = int(len(y)); R['grid_bin_rate_hz'] = fsb; R['grid_filled_bins'] = nfill
    f, pw = spectrum(y, fsb)
    band = (f > 1) & (f < 2000)
    med_pw = float(np.median(pw[band]))
    order = np.argsort(pw[band])[::-1][:12]
    R['spectrum_median_power_1_2000Hz'] = med_pw
    R['top_peaks'] = [dict(f_hz=float(f[band][i]), power=float(pw[band][i]),
                           period_ms=float(1000.0 / f[band][i]),
                           frames=float(FS_SYM / f[band][i] / P),
                           snr_vs_median=float(pw[band][i] / med_pw)) for i in order]
    # targeted: 38.88 Hz +/- 5%
    lo, hi = F_TARGET * 0.95, F_TARGET * 1.05
    m = (f >= lo) & (f <= hi)
    R['f_target_hz'] = F_TARGET
    R['target_band'] = [lo, hi]
    R['target_band_max_power'] = float(pw[m].max()) if m.any() else 0.0
    R['target_band_max_f'] = float(f[m][pw[m].argmax()]) if m.any() else None
    R['target_snr_vs_median'] = R['target_band_max_power'] / med_pw if med_pw else None
    # frame-rate line as the positive control on the time base
    mf = (f > 1200) & (f < 1300)
    R['frame_line_f_hz'] = float(f[mf][pw[mf].argmax()]) if mf.any() else None
    R['frame_line_snr_vs_median'] = float(pw[mf].max() / med_pw) if mf.any() and med_pw else None
    for k, v in R.items():
        if k == 'slip_frames_in_capture':
            print(f"slip_frames_in_capture = {len(v)} events (first 10: {v[:10]})")
        elif k == 'top_peaks':
            print('top_peaks:')
            for p in v:
                print(f"   f={p['f_hz']:9.3f} Hz  period={p['period_ms']:8.3f} ms  "
                      f"frames={p['frames']:8.3f}  snr={p['snr_vs_median']:8.1f}")
        else:
            print(f"{k} = {v}")
    if x.json:
        with open(x.json, 'w') as fh:
            json.dump(R, fh, indent=1)
    return 0


if __name__ == '__main__':
    sys.exit(main())
