#!/usr/bin/env python3
"""none_state_analysis.py -- controller analysis (2026-09-02 night, coordinator directive):
what IS the "None" state content at the demod-input tap (sel6), i.e. the payload that follows
the two stall transitions whose predicted post-stall offset (6490 for onset.bin frame 4166,
6548 for mid.bin frame 3278) is not present in the injective offset map
(offsetmap/tap3_word_to_offset.tsv)?

Method, per the coordinator's four tests (§88 write-up references this docstring):
1. Bit-level cyclic cross-correlation. Build the 24,640-bit frame bitstream from hard decisions
   (sign(I), sign(Q)) for a representative frame, in both bit pairings (I-then-Q, Q-then-I) and
   under all 8 elements of the QPSK symmetry group (4 rotations x optional conjugation), and
   cyclically cross-correlate (FFT) against a golden (offset==0, i.e. quiet) frame of the SAME
   capture. Positive controls: golden-vs-golden (different frame instances) must peak at shift 0
   with near-full magnitude; a rung-state frame (known nonzero data offset) must peak at an
   EVEN bit shift equal to 2x its known symbol offset (or 2x(12320-offset)).
2. If test 1 finds no clean peak for the None-state frame: is the None-state frame bit-exact
   periodic frame-to-frame within one episode? Bit-exact identical between the two captures'
   None episodes (onset vs mid)? Equal to the golden frame XORed with a constant (whitening/
   scrambler phase)? Inspect the XOR of None vs golden (at the best-correlation shift) for
   low entropy / periodicity.
3. Folded into test 1 (a whole-frame bit correlation subsumes the earlier 16-symbol-word check
   at every possible symbol-boundary re-pairing, since the 16-symbol word is just 32 bits of the
   frame at one particular alignment).
4. Recompute/report the §87 stall geometry (L, position, whether a whole-frame stall precedes
   the None transition) directly from the already-computed sel6_stall_geometry.py JSON outputs,
   and report the exact record offset (relative to the frame end) where None-state content
   begins.

Frame anchor: mark_demod (per ddrcap2_decode.decode / ddrcap2_beat_analysis.per_frame_offsets,
skew=1: the frame's first data symbol is 1 record after the mark_demod record). Record index is
a valid time base at sel6 (12320 records/frame, no record-index drops at this full sel6 tap
within one contiguous capture segment -- unlike the full-rate DDRCAP taps).
[silicon] unless marked [inferred].
"""
import json, os, sys
import numpy as np
from ddrcap2_decode import load, decode
from ddrcap2_beat_analysis import load_map, per_frame_offsets

HERE = os.path.dirname(os.path.abspath(__file__))
CAPDIR = os.path.join(HERE, 'beatcap', '20260902_185552_sel6')
FRAME_SYM = 12320
FRAME_BIT = 2 * FRAME_SYM
SKEW = 1


def frame_signs(a, mk_rec, skew=SKEW):
    """Hard-decision sign bits (si=1 if I<0, sq=1 if Q<0) for one 12320-symbol frame
    starting `skew` records after a mark_demod record `mk_rec`. Returns (si, sq) int8 arrays,
    or None if the frame runs past the end of the capture."""
    s = mk_rec + skew
    if s + FRAME_SYM > len(a):
        return None
    I = a[s:s + FRAME_SYM, 0]
    Q = a[s:s + FRAME_SYM, 1]
    return (I < 0).astype(np.int8), (Q < 0).astype(np.int8)


def transform_signs(si, sq, rot, conj):
    """Apply one of the 8 QPSK-symmetry-group elements (rotation by rot*90deg, then optional
    conjugation) to sign bits, via the +-1 constellation representation."""
    I = (1 - 2 * si.astype(np.int32))
    Q = (1 - 2 * sq.astype(np.int32))
    for _ in range(rot % 4):
        I, Q = -Q, I
    if conj:
        Q = -Q
    return (I < 0).astype(np.int8), (Q < 0).astype(np.int8)


def pack_bits(si, sq, pairing):
    bits = np.empty(2 * len(si), dtype=np.int8)
    if pairing == 'IQ':
        bits[0::2] = si; bits[1::2] = sq
    else:
        bits[0::2] = sq; bits[1::2] = si
    return bits


def cyclic_xcorr(bits_a, bits_b):
    """Circular cross-correlation over all len(bits_a) shifts via FFT, +-1 (antipodal) mapping.
    Returns real array c[] where c[k] = sum_n a[(n+k) mod N] * b[n]; a perfect match at shift k0
    gives c[k0] == N (== FRAME_BIT for full-length inputs)."""
    a = 1.0 - 2.0 * bits_a.astype(np.float64)
    b = 1.0 - 2.0 * bits_b.astype(np.float64)
    N = len(a)
    A = np.fft.rfft(a); B = np.fft.rfft(b)
    c = np.fft.irfft(A * np.conj(B), n=N)
    return np.round(c).astype(np.int64)


def best_match(test_si, test_sq, golden_bits_IQ):
    """Try both pairings x 8 symmetry-group elements of (test_si, test_sq) against the fixed
    golden bitstream (packed I-then-Q, untransformed). Returns dict with the best (highest-peak)
    variant's shift, peak value, noise-floor stats, and which variant won."""
    best = None
    for pairing in ('IQ', 'QI'):
        for rot in range(4):
            for conj in (False, True):
                si2, sq2 = transform_signs(test_si, test_sq, rot, conj)
                bits = pack_bits(si2, sq2, pairing)
                c = cyclic_xcorr(bits, golden_bits_IQ)
                shift = int(np.argmax(c)); peak = int(c[shift])
                mask = np.ones(len(c), dtype=bool); mask[max(0, shift - 5):shift + 6] = False
                mask[max(0, shift - 5 - len(c)):] &= True  # no-op guard, wrap handled below
                floor_vals = np.delete(c, np.arange(max(0, shift - 5), min(len(c), shift + 6)))
                noise_mean = float(floor_vals.mean()); noise_std = float(floor_vals.std())
                rec = dict(pairing=pairing, rot=rot, conj=conj, shift=shift, peak=peak,
                           noise_mean=noise_mean, noise_std=noise_std,
                           z=(peak - noise_mean) / noise_std if noise_std > 0 else float('inf'))
                if best is None or peak > best['peak']:
                    best = rec
    return best


def hamming_frac(bits_a, bits_b):
    return float((bits_a != bits_b).mean())


def entropy_bits(bits):
    p = bits.mean()
    if p <= 0 or p >= 1:
        return 0.0
    return float(-(p * np.log2(p) + (1 - p) * np.log2(1 - p)))


def find_frame(mk, offs_by_rec, lo, hi, want_offset):
    """First frame index f with mk[lo] <= mk[f] <= mk[hi] and per_frame_offsets offset == want_offset
    (or, if want_offset is None, offset is None -- the 'None' state)."""
    for f in range(lo, min(hi, len(mk) - 3)):
        o = offs_by_rec.get(int(mk[f]))
        if want_offset is None:
            if o is None:
                return f
        elif o == want_offset:
            return f
    return None


def analyse_capture(path, none_lo, none_hi, none_pred_offset, quiet_lo, quiet_hi,
                     rung_lo, rung_hi, rung_offset):
    a = load(path)
    d = decode(a)
    m = load_map()
    fr = per_frame_offsets(a, d, m)
    offs = dict(fr)
    mk = np.flatnonzero(d['mark_demod'])

    out = {'file': path, 'n_frames': int(len(mk))}

    # --- golden frame(s) ---
    gA_f = find_frame(mk, offs, quiet_lo, quiet_hi, 0)
    gB_f = find_frame(mk, offs, gA_f + 5 if gA_f is not None else quiet_lo, quiet_hi, 0)
    if gA_f is None or gB_f is None:
        out['error'] = 'no two quiet (offset==0) frames found in quiet window'
        return out
    gA = frame_signs(a, int(mk[gA_f])); gB = frame_signs(a, int(mk[gB_f]))
    golden_bits = pack_bits(*gA, 'IQ')
    out['golden_frame_A'] = gA_f; out['golden_frame_B'] = gB_f

    # positive control 1: golden vs golden (different frame instances)
    ctrl_gg = best_match(*gB, golden_bits)
    out['control_golden_vs_golden'] = ctrl_gg

    # positive control 2: rung-state frame vs golden
    rung_f = find_frame(mk, offs, rung_lo, rung_hi, rung_offset)
    out['rung_frame'] = rung_f
    if rung_f is not None:
        rs = frame_signs(a, int(mk[rung_f]))
        ctrl_rung = best_match(*rs, golden_bits)
        pred1 = (2 * rung_offset) % FRAME_BIT
        pred2 = (2 * (FRAME_SYM - rung_offset)) % FRAME_BIT
        ctrl_rung['predicted_shift_fwd'] = pred1
        ctrl_rung['predicted_shift_rev'] = pred2
        ctrl_rung['matches_prediction'] = (ctrl_rung['shift'] in (pred1, pred2))
        ctrl_rung['shift_is_even'] = (ctrl_rung['shift'] % 2 == 0)
        out['control_rung_vs_golden'] = ctrl_rung

    # --- the None-state frame(s) under test ---
    none_frames = [f for f in range(none_lo, min(none_hi, len(mk) - 3)) if offs.get(int(mk[f])) is None]
    out['none_frame_count_in_window'] = len(none_frames)
    if not none_frames:
        out['error_none'] = 'no None-offset frames found in stated window'
        return out
    test_f = none_frames[len(none_frames) // 2]  # a representative frame well inside the episode
    out['none_test_frame'] = test_f
    ns = frame_signs(a, int(mk[test_f]))
    if ns is None:
        out['error_none'] = 'frame ran past end of capture'
        return out
    none_result = best_match(*ns, golden_bits)
    pred1 = (2 * none_pred_offset) % FRAME_BIT
    pred2 = (2 * (FRAME_SYM - none_pred_offset)) % FRAME_BIT
    none_result['predicted_shift_fwd'] = pred1
    none_result['predicted_shift_rev'] = pred2
    none_result['matches_prediction'] = (none_result['shift'] in (pred1, pred2))
    out['none_vs_golden'] = none_result

    # --- test 2: only run the deeper structural tests if test 1 found no clean peak ---
    # "clean peak" threshold: z-score > 8 (golden-vs-golden / rung-vs-golden controls should be
    # far above this; a chance/no-match frame's best-of-16-variants max z over ~24640 shifts x 16
    # variants stays well under this under a null model).
    clean = none_result['z'] > 8 and none_result['peak'] > 0.9 * FRAME_BIT
    out['none_vs_golden_clean_peak'] = bool(clean)

    struct = {}
    if not clean:
        # 2a: bit-exact frame-to-frame periodicity within the None episode
        other_f = none_frames[min(3, len(none_frames) - 1)]
        if other_f != test_f:
            os_ = frame_signs(a, int(mk[other_f]))
            if os_ is not None:
                b1 = pack_bits(*ns, 'IQ'); b2 = pack_bits(*os_, 'IQ')
                struct['periodic_within_episode'] = dict(
                    frame_a=test_f, frame_b=other_f, hamming_frac=hamming_frac(b1, b2))
        # 2b: golden XOR None at best shift -- structure (periodicity/entropy)
        shift = none_result['shift']; pairing = none_result['pairing']
        si2, sq2 = transform_signs(*ns, none_result['rot'], none_result['conj'])
        tb = pack_bits(si2, sq2, pairing)
        tb_shifted = np.roll(tb, -shift)
        xor = tb_shifted ^ golden_bits
        struct['xor_mean'] = float(xor.mean())  # 0.5 = looks random; far from 0.5 = structure
        struct['xor_entropy_bits'] = entropy_bits(xor)
        # autocorrelation of the XOR sequence to hunt for a short repeating period
        xc = cyclic_xcorr(xor, xor)
        xc0 = xc[0]
        xc_rel = xc[1:2000].astype(np.float64) / xc0
        top = np.argsort(-xc_rel)[:5] + 1
        struct['xor_autocorr_top_periods'] = [dict(period=int(p), rel=float(xc_rel[p - 1])) for p in top]

        # 2c: per-plane (I vs Q) re-pairing search. The whole-frame correlation found ~75.5%
        # agreement at the predicted shift; that number is suspiciously close to (100%+50%)/2,
        # i.e. one quadrature plane matching golden exactly while the other looks like chance.
        # Split into I-plane (even bit positions) and Q-plane (odd) at the best (shift, variant)
        # and search a small +-4 SYMBOL re-pairing offset per plane against golden's same plane
        # (this directly implements the coordinator's test-3 "re-pair bits across symbol
        # boundaries" idea, at symbol rather than raw-bit granularity, which is the granularity
        # that actually matters for a QPSK I/Q demux).
        si_g_plane = golden_bits[0::2]; sq_g_plane = golden_bits[1::2]
        si_t_plane = tb_shifted[0::2]; sq_t_plane = tb_shifted[1::2]
        plane = {}
        for name, t_plane, g_plane in (('I', si_t_plane, si_g_plane),
                                        ('Q', sq_t_plane, sq_g_plane)):
            best_k = None; best_frac = -1.0
            for k in range(-4, 5):
                if k >= 0:
                    frac = (t_plane[:len(t_plane) - k] == g_plane[k:]).mean() if k > 0 else (t_plane == g_plane).mean()
                else:
                    frac = (t_plane[-k:] == g_plane[:len(g_plane) + k]).mean()
                if frac > best_frac:
                    best_frac = float(frac); best_k = k
            plane[name] = dict(best_symbol_skew=best_k, agree_frac_at_best_skew=best_frac,
                               agree_frac_at_zero_skew=float((t_plane == g_plane).mean()))
        struct['per_plane_symbol_skew_search'] = plane
    out['none_structure_tests'] = struct

    return out


def stall_geometry_summary(stalls_json_path, none_frame_no):
    j = json.load(open(stalls_json_path))
    rows = j['stalls']
    hit = None; prev = None
    for i, r in enumerate(rows):
        if r['frame'] == none_frame_no and r.get('offset_after') is None:
            hit = r; prev = rows[i - 1] if i > 0 else None
            break
    if hit is None:
        return {'error': f'no stall row with frame=={none_frame_no}, offset_after=None'}
    # record index where None-state content begins = start + length (end of the frozen run);
    # relative to frame end (frame length 12320 symbols from the mark) that is:
    rel_to_frame_end = FRAME_SYM - (hit['pos_in_frame'] + hit['length'])
    # "prev" (previous JSON row) is NOT necessarily the immediately-preceding frame -- the JSON
    # only records rows for frames that had a stall, and there are normal (unstalled) frames in
    # between events. The actual question ("does a whole-frame stall immediately precede the
    # None-triggering stall") requires checking whether ANY row exists for frame `none_frame_no
    # - 1` specifically (adjacency), not just "the previous row in event order".
    immediate_prev_frame = none_frame_no - 1
    immediate_prev_row = next((r for r in rows if r['frame'] == immediate_prev_frame), None)
    frames_since_prev_event = none_frame_no - prev['frame'] if prev else None
    return dict(stall_row=hit, most_recent_prior_event_row=prev,
                frames_between_prior_event_and_this_one=frames_since_prev_event,
                immediately_preceding_frame_has_stall_row=bool(immediate_prev_row),
                whole_frame_stall_immediately_precedes=bool(
                    immediate_prev_row and immediate_prev_row.get('full_frame')),
                none_state_begin_record=hit['start'] + hit['length'],
                none_state_begin_relative_to_frame_end_symbols=rel_to_frame_end)


def main():
    results = {}

    results['onset'] = analyse_capture(
        os.path.join(CAPDIR, 'onset.bin'),
        none_lo=4170, none_hi=5420, none_pred_offset=6490,
        quiet_lo=900, quiet_hi=1800,
        rung_lo=1900, rung_hi=3100, rung_offset=6363)

    results['mid'] = analyse_capture(
        os.path.join(CAPDIR, 'mid.bin'),
        none_lo=3280, none_hi=4540, none_pred_offset=6548,
        quiet_lo=100, quiet_hi=1000,
        rung_lo=1050, rung_hi=2250, rung_offset=6432)

    # cross-capture: is the onset None frame bit-identical to the mid None frame (test 2)?
    try:
        a_on = load(os.path.join(CAPDIR, 'onset.bin')); d_on = decode(a_on)
        mk_on = np.flatnonzero(d_on['mark_demod'])
        f_on = results['onset']['none_test_frame']
        s_on = frame_signs(a_on, int(mk_on[f_on]))

        a_mid = load(os.path.join(CAPDIR, 'mid.bin')); d_mid = decode(a_mid)
        mk_mid = np.flatnonzero(d_mid['mark_demod'])
        f_mid = results['mid']['none_test_frame']
        s_mid = frame_signs(a_mid, int(mk_mid[f_mid]))

        b_on = pack_bits(*s_on, 'IQ')
        best = None
        for pairing in ('IQ', 'QI'):
            for rot in range(4):
                for conj in (False, True):
                    si2, sq2 = transform_signs(*s_mid, rot, conj)
                    bits = pack_bits(si2, sq2, pairing)
                    c = cyclic_xcorr(bits, b_on)
                    shift = int(np.argmax(c)); peak = int(c[shift])
                    if best is None or peak > best['peak']:
                        best = dict(pairing=pairing, rot=rot, conj=conj, shift=shift, peak=peak)
        results['onset_none_vs_mid_none'] = best
    except Exception as e:
        results['onset_none_vs_mid_none'] = {'error': str(e)}

    # test 4: stall geometry recap, from already-computed JSON
    results['stall_geometry'] = {
        'onset': stall_geometry_summary(os.path.join(CAPDIR, 'onset_stalls.json'), 4166),
        'mid': stall_geometry_summary(os.path.join(CAPDIR, 'mid_stalls.json'), 3278),
    }

    out_path = os.path.join(CAPDIR, 'none_state_result.json')
    with open(out_path, 'w') as fh:
        json.dump(results, fh, indent=1)
    print(json.dumps(results, indent=1, default=str))
    print(f"\nwrote {out_path}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
