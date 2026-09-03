#!/usr/bin/env python3
"""sel8_tx_restart.py -- P-TX detector (SEL8_PREREG.md): does the TX SAMPLE stream (sel8,
Transmitter_dataOutI/Q) itself restart a frame at the extra `mark_fec` pulse located on the
symbol-domain campaign (sel6)?

Method (see SEL8_PREREG.md for the full pre-registered text):
  1. Reconstruct a per-record symbol-time via the sidecar `tref` field (slot==1 records only),
     using the exact 4-record group membership (slot 0..3), NOT record index -- immune to the
     rx2 DMA record drops that already broke ddrcap2_txmark_scan's cadence chaining on every
     full-rate tap scanned so far.
  2. Classify each `mark_fec` record as REGULAR or EXTRA via the symbol-time gap to the previous
     known-time `mark_fec` record: EXTRA iff that gap is < half the modal (regular) gap.
  3. Build a TEMPLATE from the 52-record (13-symbol) snippet following each regular pulse; this is
     the method's own positive control (regular frame starts must be mutually identical/near-
     identical).
  4. Score each extra pulse: does its 52-record snippet match the template (restart) or match the
     same in-frame position one regular period earlier (continuation, falsifier)?
  5. Negative control: a random no-pulse in-frame position must NOT match the template.

No arm, no board contact in this file -- it operates on already-captured .bin files.
"""
import argparse, json, sys
import numpy as np
from ddrcap2_decode import load, decode

N_SNIPPET = 52          # 13 symbols x 4 records/symbol
EXACT_MATCH = True       # a-priori expectation: ROM-driven frame starts match exactly, not just correlate
CORR_THRESH = 0.999      # fallback similarity threshold if exact match rate is low (reported explicitly, not silently substituted)
TEMPLATE_AGREE_FRAC = 0.90
RUNGS = (6176, 6240, 6299, 6363, 6432, 6489, 6548)
RUNG_TOL = 4


P_FRAME = 12333  # tref modulus / symbols per frame


def build_global_tref_axis(d):
    """Build ONE globally-unwrapped tref time axis by walking every slot==1 (tref-bearing) record
    in file order and cumulatively summing per-step deltas, correcting ONLY genuine backward wraps
    (delta < -P_FRAME/2 => + P_FRAME). A forward jump from a dropped span of records (silicon shows
    these up to several thousand symbols in a burst region -- see module docstring deviation note)
    is real elapsed time and is left untouched, not folded.

    This replaces an earlier per-mark_fec-pair wrap-count GUESS (`round((record_gap/4 - raw_diff) /
    p)`) that failed during development: real silicon burst regions can locally violate the
    assumption that a pair's record-index gap approximates its true symbol gap to within half a
    frame period (one measured span: 17,391 records between two `mark_fec` events that direct
    tref-delta summation shows are 12,332 symbols -- one full frame -- apart, not the ~4,348 symbols
    the record-gap/4 heuristic implied; a single delta of 6,638 symbols across one localized drop
    burst caused the old per-pair guess to pick zero wraps instead of one). Summing every actual
    tref delta in file order needs no such guess, only that no INDIVIDUAL slot1-to-slot1 delta
    itself exceeds P_FRAME/2, which -- unlike the discredited per-pair heuristic -- ddrcap2_pc.py's
    tref_cadence rule and its own PASS on both credited captures directly confirm for the bulk of
    the file, and which is separately checked at use (see EXCESSIVE_STEP guard below).

    Returns (positions, global_symtime): `positions` are the slot1 record indices in increasing
    order; `global_symtime[k]` is positions[k]'s unwrapped symbol time.
    """
    slot = d['slot']; tref = d['tref']
    mask = (slot == 1) & (tref >= 0)
    positions = np.flatnonzero(mask)
    if len(positions) == 0:
        return positions, np.array([], dtype=np.int64)
    raw = tref[positions].astype(np.int64)
    dt = np.diff(raw)
    dt_fixed = np.where(dt < -P_FRAME // 2, dt + P_FRAME, dt)
    global_symtime = np.empty(len(raw), dtype=np.int64)
    global_symtime[0] = raw[0]
    global_symtime[1:] = raw[0] + np.cumsum(dt_fixed)
    return positions, global_symtime


EXCESSIVE_STEP_SYMBOLS = P_FRAME  # a single slot1-to-slot1 step this large is untrustworthy (ambiguous wrap)


def excessive_steps(positions, global_symtime):
    """Diagnostic: any single slot1-to-slot1 unwrapped step >= EXCESSIVE_STEP_SYMBOLS is a point
    where build_global_tref_axis's forward-jump-is-real assumption could itself be wrong (a step
    this large could also be >=2 wraps). Reported so scoring downstream can flag results that
    depend on such a span, not silently trusted."""
    if len(global_symtime) < 2:
        return []
    d = np.diff(global_symtime)
    idx = np.flatnonzero(d >= EXCESSIVE_STEP_SYMBOLS)
    return [{'record': int(positions[i]), 'next_record': int(positions[i + 1]), 'step_symbols': int(d[i])} for i in idx]


def symbol_time_lookup(rec_indices, d, positions, global_symtime):
    """For each record index in `rec_indices`, resolve its own 4-record group's slot1 record via
    exact slot arithmetic (no drop-tolerance needed -- this is a LOCAL, same-group lookup) and
    return its globally-unwrapped symbol time. Returns (sym, valid) arrays aligned to rec_indices."""
    rec_indices = np.asarray(rec_indices, dtype=np.int64)
    n_total = len(d['slot'])
    slot_at_rec = d['slot'][np.clip(rec_indices, 0, n_total - 1)].astype(np.int64)
    j = rec_indices + (1 - slot_at_rec)
    inb = (j >= 0) & (j < n_total)
    jc = np.clip(j, 0, n_total - 1)
    idx = np.searchsorted(positions, jc)
    idx_ok = idx < len(positions)
    idxc = np.clip(idx, 0, max(len(positions) - 1, 0))
    match = inb & idx_ok & (positions[idxc] == jc) if len(positions) else np.zeros(len(rec_indices), dtype=bool)
    sym = np.where(match, global_symtime[idxc] if len(positions) else -1, -1)
    return sym, match


def symbol_time(a, d):
    """Convenience wrapper: per-record symbol-time for EVERY record in the capture (used by the
    original P-TX flow). Prefer build_global_tref_axis + symbol_time_lookup directly when only a
    sparse set of records needs resolving (e.g. mark_fec positions, frame_symbol_series)."""
    positions, global_symtime = build_global_tref_axis(d)
    idx = np.arange(len(a), dtype=np.int64)
    sym, valid = symbol_time_lookup(idx, d, positions, global_symtime)
    return sym, valid


def unwrap_symbol_series(positions_list, sym, valid, p=P_FRAME, records_per_symbol=4):
    """Kept for API compatibility with callers that already have per-record sym/valid arrays (from
    symbol_time()); simply filters to valid positions and returns their (already globally
    unwrapped) symbol times in the given order. No further wrap-guessing is performed here -- see
    build_global_tref_axis for why the old pairwise guess was replaced."""
    kept, uw = [], []
    for pos in positions_list:
        if pos < len(valid) and valid[pos]:
            kept.append(int(pos)); uw.append(int(sym[pos]))
    return kept, uw


def classify_fec(a, d, tol=60):
    """Doublet-chain classification in symbol-time (immune to DMA record drops -- see
    SEL8_PREREG.md and build_global_tref_axis's docstring for the wrap-unwrap method). NOTE
    (self-test finding): the RUNGS set (6176-6548) sits close to HALF the 12333-symbol frame
    period, so a naive "gap < half the modal period => extra" rule misclassifies a genuine
    mid-frame extra pulse as a second regular pulse (confirmed by a synthetic self-test during
    development). Uses the same doublet-sum test as `ddrcap2_txmark_scan.find_regular_and_extra`
    (a position continues the regular chain if its gap from the last regular position is ~modal;
    otherwise it is EXTRA iff the FOLLOWING position's gap from the last regular position is
    ~modal -- i.e. two short gaps summing to one modal period), applied here to symbol-time
    instead of raw record index."""
    positions, global_symtime = build_global_tref_axis(d)
    fec = np.flatnonzero(d['mark_fec'])
    sym, valid = symbol_time_lookup(fec, d, positions, global_symtime)
    # sym/valid are aligned to `fec` (symbol_time_lookup's output order), not indexed by record
    # position -- filter directly, no positional indirection needed (unlike the old per-record
    # symbol_time() + unwrap_symbol_series(record_index_list, ...) pairing this replaced).
    kept = fec[valid].tolist(); uw = sym[valid].tolist()
    exc = excessive_steps(positions, global_symtime)
    if len(kept) < 3:
        return {'kept': kept, 'gaps': [], 'modal_gap': None, 'regular': [], 'extra': [], 'excessive_tref_steps': exc}
    all_gaps = [uw[k] - uw[k - 1] for k in range(1, len(uw))]
    vals, cnts = np.unique(all_gaps, return_counts=True)
    modal_gap = int(vals[cnts.argmax()])
    regular = [kept[0]]; reg_sym = [uw[0]]; extra = []
    i = 1
    n = len(kept)
    while i < n:
        gap = uw[i] - reg_sym[-1]
        if abs(gap - modal_gap) <= tol:
            regular.append(kept[i]); reg_sym.append(uw[i]); i += 1
        elif i + 1 < n and abs((uw[i + 1] - reg_sym[-1]) - modal_gap) <= tol:
            extra.append({'record': kept[i], 'symtime': uw[i], 'p_tref_units': gap,
                           'prev_regular_record': regular[-1]})
            i += 1
        else:
            # cadence broken by more than one inserted pulse -- resync (best effort)
            regular.append(kept[i]); reg_sym.append(uw[i]); i += 1
    return {'kept': kept, 'gaps': all_gaps, 'modal_gap': modal_gap,
            'regular': regular, 'regular_symtime': reg_sym, 'extra': extra, 'excessive_tref_steps': exc}


def snippet(a, start, n=N_SNIPPET):
    if start < 0 or start + n > len(a):
        return None
    return a[start:start + n, :2].copy()  # I,Q only


def snippets_agree(s1, s2, exact=EXACT_MATCH):
    if s1 is None or s2 is None:
        return False, 0.0
    frac_equal = float((s1 == s2).all(axis=1).mean())
    if exact:
        return bool(frac_equal == 1.0), frac_equal
    num = float((s1.astype(np.float64) * s2.astype(np.float64)).sum())
    den = float(np.linalg.norm(s1) * np.linalg.norm(s2))
    corr = num / den if den > 0 else 0.0
    return bool(corr >= CORR_THRESH), corr


def build_template(a, regular_records):
    """POSITION-WISE template construction (deviation from the pre-registered whole-52-record-
    block equality test, recorded here per SEL8_PREREG.md's own deviation-reporting rule): a
    dry run against the real mid.bin capture showed the whole-block test fails (23-9% snippets
    agree with an arbitrary first snippet) NOT because the method is broken, but because most of
    the 52-record window is TX PAYLOAD, which SEL8_PREREG.md's own frame-identity limit already
    warns is fixed only when the burst/displacement state is stationary -- payload legitimately
    differs frame-to-frame once a displacement (rung) has occurred (P-TX' predicts exactly this:
    the RAM read pointer resumes from a shifted position, so payload from that point on is a
    time-shifted continuation, not noise). Directly inspecting a mismatching pair (real mid.bin,
    regular record 16031614 vs the first regular record) confirms: positions 0-27 of the 52-record
    window are BIT-IDENTICAL across every regular pulse checked, positions 28-51 are not -- a clean
    preamble/payload boundary. So the template is built PER-POSITION: for each of the 52 positions,
    take the modal (I,Q) value across all regular-pulse snippets; a position joins the template iff
    that modal value covers >=90% of snippets (TEMPLATE_AGREE_FRAC) at that position. The template is
    truncated to its longest STABLE PREFIX (a position that fails ends the template -- payload
    positions are expected/allowed to fail and are simply excluded, not a positive-control failure)
    so a later, coincidentally-stable payload position cannot masquerade as part of the fixed
    preamble."""
    snips = [snippet(a, r + 1) for r in regular_records]
    snips = [s for s in snips if s is not None]
    if len(snips) < 3:
        return None, {'n_candidates': len(snips), 'pass': False, 'reason': 'fewer than 3 regular pulses with a full window'}
    stack = np.stack(snips)  # (n_candidates, N_SNIPPET, 2)
    n = stack.shape[0]
    template_len = 0
    per_position_frac = []
    for pos in range(N_SNIPPET):
        vals = stack[:, pos, :]
        uniq, counts = np.unique(vals, axis=0, return_counts=True)
        frac = float(counts.max() / n)
        per_position_frac.append(round(frac, 4))
        if frac >= TEMPLATE_AGREE_FRAC and template_len == pos:
            template_len = pos + 1
        elif frac < TEMPLATE_AGREE_FRAC and template_len == pos:
            break  # first unstable position ends the stable prefix
    passed = template_len >= 8  # need a non-trivial preamble-length template to be usable
    template = stack[0, :template_len, :].copy() if passed else None
    # majority-vote template values (not just candidate 0) for the stable prefix
    if passed:
        for pos in range(template_len):
            vals = stack[:, pos, :]
            uniq, counts = np.unique(vals, axis=0, return_counts=True)
            template[pos] = uniq[counts.argmax()]
    return template, {'n_candidates': n, 'template_len_records': template_len,
                       'per_position_agree_frac': per_position_frac, 'pass': bool(passed)}


def negative_control(a, regular_records, modal_gap, template):
    """Pick an in-frame position far (>= 0.4*modal_gap records) from any regular pulse; its
    snippet (sliced to the template's own length -- see build_template) must NOT match the
    template."""
    if not regular_records or template is None:
        return {'pass': None, 'reason': 'no regular records or no template'}
    r0 = regular_records[0]
    probe = r0 + int(modal_gap * 0.5) if modal_gap else r0 + 5000
    for r in regular_records:
        if abs(probe - r) < 5000:
            probe += 5000  # nudge away from any nearby regular record's raw index
    tlen = len(template)
    s = snippet(a, probe, n=tlen)
    if s is None:
        return {'pass': None, 'reason': 'probe window out of range', 'probe_record': probe}
    ok, score = snippets_agree(s, template)
    return {'probe_record': int(probe), 'matches_template': bool(ok), 'score': score, 'pass': bool(not ok)}


def score_extra(a, ex, template, frame_period_records):
    """frame_period_records: the regular frame period expressed in RECORD units (not symbol/tref
    units -- ex['p_tref_units'] and `modal_gap` from classify_fec() are symbol counts; the
    continuation reference must be looked up `frame_period_records` records earlier in the same
    raw record-index space snippet() operates in). template_match compares only the template's own
    (stable-prefix) length; continuation_match compares the FULL N_SNIPPET window (payload included)
    against the same in-frame position one period earlier, per SEL8_PREREG.md's falsifier text."""
    rec = ex['record']
    tlen = len(template) if template is not None else N_SNIPPET
    after_tmpl = snippet(a, rec + 1, n=tlen)
    tmpl_ok, tmpl_score = snippets_agree(after_tmpl, template)
    after_full = snippet(a, rec + 1)
    cont_ref = None
    if frame_period_records:
        cont_ref = snippet(a, rec + 1 - frame_period_records)
    cont_ok, cont_score = (snippets_agree(after_full, cont_ref) if cont_ref is not None else (None, None))
    return dict(ex, template_match=tmpl_ok, template_score=tmpl_score,
                continuation_match=cont_ok, continuation_score=cont_score)


def symbols_per_tref_unit(a, d, regular_records, reg_symtime):
    """Calibration: modal record-gap between consecutive regular mark_demod records vs the
    tref-unit gap between the corresponding mark_fec pulses, reported (not assumed) so p can be
    compared with the sel6 RUNGS set on a like-for-like symbol basis. If mark_demod density is too
    low to calibrate, returns None (p is then reported in raw tref units only)."""
    demod = np.flatnonzero(d['mark_demod'])
    if len(demod) < 2:
        return None
    gaps = np.diff(demod.astype(np.int64))
    vals, cnts = np.unique(gaps, return_counts=True)
    modal_demod_gap_records = int(vals[cnts.argmax()])
    if len(reg_symtime) < 2:
        return None
    tref_gaps = np.diff(np.array(reg_symtime))
    v2, c2 = np.unique(tref_gaps, return_counts=True)
    modal_tref_gap = int(v2[c2.argmax()])
    return {'modal_demod_gap_records': modal_demod_gap_records, 'modal_regular_fec_gap_tref_units': modal_tref_gap}


def p_vs_rungs(p_symbols, frame_period_symbols):
    hits = []
    for cand, label in ((p_symbols, 'p'), (frame_period_symbols - p_symbols if frame_period_symbols else None, 'period-p')):
        if cand is None:
            continue
        for g in RUNGS:
            if abs(cand - g) <= RUNG_TOL:
                hits.append({'which': label, 'value': cand, 'rung': g, 'delta': cand - g})
    return hits


MIN_STALL_SYMBOLS = 300  # comfortably above chance-coincidence runs in ROM-driven payload (see controls)
DATA_PREAMBLE_SYMBOLS = 13  # TX_ORIGIN_TRACE_A.md sec0: 26 half-rate sampleCount preamble slots = 13 real symbols
DATA_FRAME_SYMBOLS = 12320  # sec0: 24,640 data bits / 2 (QPSK) = 12,320 data symbols; DATA_PREAMBLE_SYMBOLS + this = P_FRAME (12,333)


def frame_symbol_series(a, d):
    """One (I,Q) sample per symbol, from the slot==1 (tref-bearing) record of each symbol group
    -- the natural fixed-phase decimation point (see SEL8_PREREG.md original method / module
    docstring). Uses build_global_tref_axis directly (these ARE the slot1 records, so no lookup
    is needed). Returns (kept_record_indices, unwrapped_symbol_time, IQ)."""
    positions, global_symtime = build_global_tref_axis(d)
    IQ = a[positions, :2].copy()
    return positions.astype(np.int64), global_symtime, IQ


def frame_marker_cross_check(d, positions, global_symtime, frame_targets, p=P_FRAME, tol=100):
    """Diagnostic: for each target frame_index in `frame_targets`, does a `mark_fec` record fall
    near that frame's own tref==0 boundary (within +/-tol records)? Used only as a cross-check /
    "preamble on cadence" indicator, never to define a stall or a frame boundary."""
    fec = np.flatnonzero(d['mark_fec'])
    sym, valid = symbol_time_lookup(fec, d, positions, global_symtime)
    fec_symtime = sym[valid]
    out = {}
    for f in frame_targets:
        target = f * p
        out[f] = bool(len(fec_symtime) and (np.abs(fec_symtime - target) <= tol).any())
    return out


def find_all_constant_runs(vals, min_run=MIN_STALL_SYMBOLS):
    """Every MAXIMAL run of >= min_run bit-identical consecutive (I,Q) samples in `vals`, in
    sample-index order (NOT cut at frame boundaries -- see module docstring / coordinator
    direction). Returns a list of (start_idx, end_idx) INCLUSIVE index pairs into `vals`, where
    vals[start_idx] == vals[start_idx+1] == ... == vals[end_idx] (end_idx itself IS part of the
    constant run -- see the off-by-one fix note below).

    same[k] = (vals[k] == vals[k+1]). If same[i..j-1] are all True and same[j] is False (or
    j==n), the constant block is indices i..j INCLUSIVE (vals[i]==...==vals[j]; vals[j+1], if it
    exists, is the first DIFFERING sample and must not be included). An earlier version appended
    (i, j+1) -- one past the true end -- which silently included the first differing sample as
    part of the reported run; this was caught by direct inspection of real mid.bin data (an
    end-of-run IQ value that should have been the frozen stall value, (5736,5736), was instead a
    transition sample, (5557,5557)), which in turn explained why merge_nearby_same_value_runs was
    never bridging real adjacent fragments -- the corrupted end-of-run value never equalled the
    next fragment's start value."""
    if len(vals) < 2:
        return []
    same = (vals[1:] == vals[:-1]).all(axis=1)
    out = []
    i = 0; n = len(same)
    while i < n:
        if same[i]:
            j = i
            while j < n and same[j]:
                j += 1
            length = (j - i) + 1
            if length >= min_run:
                out.append((i, j))
            i = j + 1
        else:
            i += 1
    return out


SEL6_STALL_LENGTHS = (5772, 5830, 5890, 5958, 6250, 6364, 6437, 6494, 6556)  # sec87 (sel6_stall_geometry.py), 2026-09-02
STALL_START_END_TOL = 16  # symbols -- widened from the original +/-4 (coordinator direction: DMA drops on this
                           # enb-domain tap make exact-symbol tref accounting noisier than the sel6 symbol-domain tap)


def find_global_stall_events(kept, uw, IQ, min_run=MIN_STALL_SYMBOLS, p=P_FRAME):
    """Per coordinator direction (2026-09-02 23:xx, following sec87's sel6 finding): find constant
    runs on the FULL, uncut symbol-time series (kept, uw, IQ from frame_symbol_series -- ONE
    sample/symbol, at the fixed slot==1 phase, so symbol index IS tref within a frame), then
    classify each run's geometry against frame boundaries (tref wraps) after the fact, instead of
    pre-cutting the search at every wrap (which was shown, on real data, to fragment a single
    multi-frame event into separate same-length "stalls" per frame).

    Per event: start_frame/start_offset_tref (where the constant run begins), whether it reaches
    that first frame's end (tref p-1, within a small tolerance), how many WHOLE subsequent frames
    are entirely covered by the SAME run, where it finally ends, and L_first_frame_stall = the
    stall length restricted to the first frame only (frame_end - start_offset), which is the
    quantity sec87's sel6 geometry (`new_offset = old - L mod 12320`) is defined against."""
    runs = find_all_constant_runs(IQ, min_run=min_run)
    runs, interruptions_by_merge = merge_nearby_same_value_runs(runs, uw, IQ)
    events = []
    for merge_i, (start_idx, end_idx) in enumerate(runs):
        start_symtime = int(uw[start_idx]); end_symtime = int(uw[end_idx])
        start_frame = start_symtime // p; start_offset = start_symtime % p
        end_frame = end_symtime // p; end_offset = end_symtime % p
        first_frame_end = (start_frame + 1) * p - 1
        reaches_first_frame_end = bool(min(end_symtime, first_frame_end) >= first_frame_end - 10)
        L_first_frame = int(min(end_symtime, first_frame_end) - start_symtime + 1)
        n_whole_frames_after = int(max(0, end_frame - start_frame - 1)) if reaches_first_frame_end else 0
        events.append({
            'start_record': int(kept[start_idx]), 'end_record': int(kept[end_idx]),
            'start_symtime': start_symtime, 'end_symtime': end_symtime,
            'n_samples_captured': int(end_idx - start_idx + 1),
            'symtime_span_symbols': end_symtime - start_symtime + 1,
            'start_frame': int(start_frame), 'start_offset_tref': int(start_offset),
            'end_frame': int(end_frame), 'end_offset_tref': int(end_offset),
            'reaches_first_frame_end': reaches_first_frame_end,
            'L_first_frame_stall': L_first_frame,
            'n_whole_stalled_frames_after': n_whole_frames_after,
            'run_value_IQ': [int(IQ[start_idx, 0]), int(IQ[start_idx, 1])],
            'interruptions': interruptions_by_merge.get(merge_i, []),
        })
    return events


def merge_nearby_same_value_runs(runs, uw, IQ, max_gap_symbols=300):
    """Real-data finding (mid.bin, 2026-09-02 21:28 arm): a visually single, long constant-value
    span can be split by find_all_constant_runs into several fragments of the SAME (I,Q) value,
    separated either by a HANDFUL of samples at a DIFFERENT value (one inspected case: 3 transition
    samples then the diagonally-opposite QPSK corner held ~9 samples, then back) or by a plain
    tref-time GAP with no differing value at all (drops -- ddrcap2_pc.py's tref_cadence stats put
    the MEDIAN single-drop size at 154-159 symbols on this tap; one inspected real gap measured
    142 symbols). max_gap_symbols=300 is set above that median (and above one observed real gap of 286 symbols between two fragments of the same event) to bridge a typical single drop.
    Whether the value-differing case is (a) genuine brief noise/metastability interrupting an
    otherwise-frozen register, (b) a real two-level oscillation, or (c) a DMA-drop artifact
    displacing what should be a value-free drop gap into an apparent value change is NOT resolved
    here and is reported, not adjudicated: every merge records the interrupting fragment(s) it
    bridged (symtime range, length, value) under the resulting event's 'interruptions' key.

    Merges CONSECUTIVE runs sharing the SAME (I,Q) value when the symtime gap between them
    (through the interrupting material) is <= max_gap_symbols. Returns (merged_runs,
    interruptions_by_merged_event_index) where merged_runs is a list of (start_idx, end_idx) index
    pairs into the original arrays (start_idx of the first fragment, end_idx of the last)."""
    if not runs:
        return runs, {}
    merged = [[runs[0][0], runs[0][1]]]
    interruptions = {0: []}
    for start_idx, end_idx in runs[1:]:
        prev = merged[-1]
        prev_value = tuple(int(v) for v in IQ[prev[1]])
        this_value = tuple(int(v) for v in IQ[start_idx])
        gap_symbols = int(uw[start_idx]) - int(uw[prev[1]])
        if prev_value == this_value and 0 < gap_symbols <= max_gap_symbols:
            interruptions[len(merged) - 1].append({
                'between_symtime': [int(uw[prev[1]]), int(uw[start_idx])],
                'gap_symbols': gap_symbols,
                'interrupting_value_IQ': [int(v) for v in IQ[prev[1] + 1]] if prev[1] + 1 < start_idx else None,
                'interrupting_n_samples': start_idx - prev[1] - 1,
            })
            prev[1] = end_idx
        else:
            merged.append([start_idx, end_idx])
            interruptions[len(merged) - 1] = []
    return [tuple(m) for m in merged], interruptions


def rung_geometry_for_event(ev, tol=STALL_START_END_TOL):
    """Compares L_first_frame_stall (and DATA_FRAME_SYMBOLS - L) against BOTH the original RUNGS
    tuple and sec87's own sel6-measured L values (SEL6_STALL_LENGTHS), +/- tol symbols -- per
    coordinator direction: "L or 12320-L is a rung" (sec87's own reading), tested against both
    reference sets since sec87's sel6 L values are not identical to (12320 - rung) in every case
    (residual = demod-mark-to-frame-start skew, sec87's own note, up to ~10 symbols there; wider
    here given the extra DMA-drop noise sec87 does not have to contend with)."""
    L = ev['L_first_frame_stall']
    complement = DATA_FRAME_SYMBOLS - L
    hits = []
    for source, values in (('RUNGS', RUNGS), ('sec87_sel6_L', SEL6_STALL_LENGTHS)):
        for v in values:
            if abs(L - v) <= tol:
                hits.append({'source': source, 'compared': 'L', 'value': v, 'delta': L - v})
            if abs(complement - v) <= tol:
                hits.append({'source': source, 'compared': '12320-L', 'value': v, 'delta': complement - v})
    return {'L': L, 'complement_12320_minus_L': complement, 'hits': hits, 'any_fit': bool(hits)}


def qpsk_label(i_val, q_val):
    """[measured] magnitude and quadrant of a raw (I,Q) sample; [inferred] which QPSK constellation
    point this represents (a Gray-code / bit-label mapping is NOT established anywhere in this
    codebase, so only quadrant/phase is reported, not a bit pattern)."""
    import math
    mag = math.hypot(i_val, q_val)
    phase_deg = math.degrees(math.atan2(q_val, i_val)) % 360
    quadrant = ('I+,Q+ (~45 deg)' if i_val > 0 and q_val > 0 else
                'I-,Q+ (~135 deg)' if i_val < 0 and q_val > 0 else
                'I-,Q- (~225 deg)' if i_val < 0 and q_val < 0 else
                'I+,Q- (~315 deg)' if i_val > 0 and q_val < 0 else 'on-axis')
    return {'I': int(i_val), 'Q': int(q_val), 'magnitude': round(mag, 1),
            'phase_deg': round(phase_deg, 1), 'quadrant_measured': quadrant}


def stall_detector_controls(a, d, min_run=MIN_STALL_SYMBOLS, p=P_FRAME):
    """POSITIVE CONTROL: inject a synthetic constant run of 6176 symbols into a quiet region of
    the FULL global series (frame 0, offset 6000, chosen to stay within one frame so the control
    directly tests find_global_stall_events' L measurement) and confirm it is found at the right
    length/location. NEGATIVE CONTROL: the untouched global series must report no stall in frame 0.
    Operates on a COPY of the sample array -- no mutation of the caller's data."""
    positions, global_symtime = build_global_tref_axis(d)
    IQ = a[positions, :2].copy()
    kept = positions.astype(np.int64)
    neg_events = [e for e in find_global_stall_events(kept, global_symtime, IQ, min_run=min_run, p=p) if e['start_frame'] == 0]
    neg_pass = len(neg_events) == 0
    frame0_mask = (global_symtime >= 0) & (global_symtime < p)
    frame0_idx = np.flatnonzero(frame0_mask)
    if len(frame0_idx) == 0:
        return {'pass': None, 'reason': 'no samples in frame 0', 'negative_control_pass': neg_pass}
    off0 = global_symtime[frame0_idx] - 0 * p
    inj_start_sym = 6000; inj_len_sym = 6176
    inj_mask = (off0 >= inj_start_sym) & (off0 < inj_start_sym + inj_len_sym)
    inj_idx = frame0_idx[inj_mask]
    if len(inj_idx) < min_run:
        return {'pass': None, 'reason': 'not enough samples in the injection window to run the positive control',
                'negative_control_pass': neg_pass}
    IQ2 = IQ.copy()
    IQ2[inj_idx] = IQ2[inj_idx[0]]
    pos_events = [e for e in find_global_stall_events(kept, global_symtime, IQ2, min_run=min_run, p=p) if e['start_frame'] == 0]
    # Compare against the TRUE injected span (first/last actually-captured offset within the
    # nominal window), not the nominal [6000, 6176) window or the captured SAMPLE COUNT -- real
    # captures have DMA drops inside the injection window too, so the first captured sample can
    # start later than 6000, and L_first_frame_stall (a SYMTIME SPAN, which counts through any
    # drop gaps) is not the same quantity as a captured sample count. Comparing span-to-span
    # (both computed the same way) is the correct, drop-tolerant test.
    off0_inj = off0[inj_mask]
    true_first_offset = int(off0_inj[0]) if len(off0_inj) else None
    true_last_offset = int(off0_inj[-1]) if len(off0_inj) else None
    true_span = (true_last_offset - true_first_offset + 1) if true_first_offset is not None else None
    pos_pass = bool(pos_events) and true_span is not None and \
        abs(pos_events[0]['L_first_frame_stall'] - true_span) <= 5 and \
        abs(pos_events[0]['start_offset_tref'] - true_first_offset) <= 5
    return {'negative_control_pass': neg_pass, 'negative_control_n_events_frame0': len(neg_events),
            'positive_control_pass': pos_pass, 'positive_control_event': pos_events[0] if pos_events else None,
            'positive_control_injected_len': len(inj_idx),
            'positive_control_true_first_offset': true_first_offset, 'positive_control_true_span': true_span,
            'pass': bool(neg_pass and pos_pass)}


def analyse_ptx_prime(path):
    """P-TX' (SEL8_PREREG.md Addendum 1, re-scored per coordinator direction after sec87): find
    every constant-run STALL EVENT on the UNCUT global tref-indexed symbol series (not pre-cut
    into per-frame windows -- see find_global_stall_events), run controls, score each event's
    rung geometry (L_first_frame_stall and 12320-L vs. RUNGS and sec87's own sel6 L values,
    +/-16 symbols), check whether a marker (preamble) arrives on cadence right after the event
    ends, and report co-location with any extra mark_fec pulse (data, not assumed). The
    continuation-content check is DROPPED per coordinator direction -- superseded by sec87's
    offset-change test, which this file does not implement for sel8 (no injective TX-sample
    offset map exists here, unlike sel6's demod-word map)."""
    a = load(path); d = decode(a)
    positions, global_symtime = build_global_tref_axis(d)
    IQ = a[positions, :2].copy()
    kept = positions.astype(np.int64)
    result = {'file': path, 'n_slot1_samples': len(kept)}
    ctrl = stall_detector_controls(a, d)
    result['controls'] = ctrl
    if not ctrl or ctrl.get('pass') is not True:
        result['verdict'] = 'UNINFORMATIVE'
        result['reason'] = 'stall-detector controls did not both pass'
        return result
    events = find_global_stall_events(kept, global_symtime, IQ)
    result['n_events'] = len(events)
    cls = classify_fec(a, d)
    extra_symtimes = [e['symtime'] for e in cls['extra']]
    # marker-on-cadence check: does a mark_fec land near the frame boundary right after each event ends?
    next_boundary_frames = sorted({(ev['end_symtime'] // P_FRAME) + 1 for ev in events})
    marker_check = frame_marker_cross_check(d, positions, global_symtime, next_boundary_frames)
    for ev in events:
        ev['rung_geometry'] = rung_geometry_for_event(ev)
        ev['constellation'] = qpsk_label(*ev['run_value_IQ'])
        nb = (ev['end_symtime'] // P_FRAME) + 1
        ev['next_frame_boundary'] = nb
        ev['marker_on_cadence_after_stall'] = marker_check.get(nb)
        near = [et for et in extra_symtimes if abs(et - ev['start_frame'] * P_FRAME) < P_FRAME]
        ev['extra_mark_fec_near_event'] = bool(near)
    result['events'] = events
    if not events:
        result['verdict'] = "P-TX' FALSIFIED"
        result['reason'] = 'no constant-run stall event found anywhere in the capture'
        return result
    geometry_ok = all(ev['rung_geometry']['any_fit'] for ev in events)
    reaches_end_ok = all(ev['reaches_first_frame_end'] for ev in events)
    cadence_ok = all(ev['marker_on_cadence_after_stall'] for ev in events)
    if geometry_ok and reaches_end_ok and cadence_ok:
        result['verdict'] = "P-TX' CONFIRMED"
    else:
        result['verdict'] = "P-TX' PARTIAL"
        result['verdict_reason'] = f"geometry_ok={geometry_ok} reaches_frame_end_ok={reaches_end_ok} marker_on_cadence_ok={cadence_ok}"
    return result


def analyse(path):
    a = load(path); d = decode(a)
    cls = classify_fec(a, d)
    result = {'file': path, 'n_records': len(a), 'n_mark_fec': int(d['mark_fec'].sum()),
              'n_mark_demod': int(d['mark_demod'].sum()),
              'modal_gap_tref_units': cls['modal_gap'], 'n_regular': len(cls['regular']),
              'n_extra': len(cls['extra']),
              'n_excessive_tref_steps': len(cls.get('excessive_tref_steps', [])),
              'excessive_tref_steps_sample': cls.get('excessive_tref_steps', [])[:10]}
    if not cls['extra']:
        result['verdict'] = 'UNINFORMATIVE'; result['reason'] = 'no extra mark_fec pulse with known symbol-time located'
        return result
    template, tmpl_stats = build_template(a, cls['regular'])
    result['template_positive_control'] = tmpl_stats
    if template is None:
        result['verdict'] = 'UNINFORMATIVE'; result['reason'] = 'template positive control failed'
        return result
    negctl = negative_control(a, cls['regular'], cls['modal_gap'], template)
    result['negative_control'] = negctl
    if negctl.get('pass') is False:
        result['verdict'] = 'UNINFORMATIVE'; result['reason'] = 'negative control matched the template -- method not discriminating'
        return result
    calib = symbols_per_tref_unit(a, d, cls['regular'], cls.get('regular_symtime', []))
    result['calibration'] = calib
    # frame_period_records: the regular frame period in RAW RECORD units, for the continuation
    # falsifier lookup (snippet() indexes raw records). Prefer the demod-mark-measured record
    # period (direct silicon measurement); fall back to modal_gap (symbol/tref units) x 4
    # records/symbol (the enb-domain ratio documented in ddrcap2_pc.py's tref_cadence rule).
    frame_period_records = (calib['modal_demod_gap_records'] if calib else None) or (
        cls['modal_gap'] * 4 if cls['modal_gap'] else None)
    result['frame_period_records_used_for_continuation_check'] = frame_period_records
    frame_period_symbols = cls['modal_gap']  # p is already in tref/symbol units; RUNGS are symbols
    scored = [score_extra(a, ex, template, frame_period_records) for ex in cls['extra']]
    for s in scored:
        s['rung_hits'] = p_vs_rungs(s['p_tref_units'], frame_period_symbols)
    result['extra_pulses'] = scored
    n_template_match = sum(1 for s in scored if s['template_match'])
    n_continuation_match = sum(1 for s in scored if s['continuation_match'])
    if n_template_match == len(scored) and n_template_match > 0:
        result['verdict'] = 'P-TX CONFIRMED'
    elif n_continuation_match == len(scored) and n_continuation_match > 0:
        result['verdict'] = 'P-TX FALSIFIED'
    else:
        result['verdict'] = 'MIXED/NEITHER'
    result['n_template_match'] = n_template_match
    result['n_continuation_match'] = n_continuation_match
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('capture')
    ap.add_argument('--out')
    ap.add_argument('--ptx-prime-only', action='store_true')
    ap.add_argument('--ptx-only', action='store_true')
    x = ap.parse_args()
    out = {}
    if not x.ptx_prime_only:
        out['P-TX'] = analyse(x.capture)
    if not x.ptx_only:
        out["P-TX'"] = analyse_ptx_prime(x.capture)
    print(json.dumps(out, indent=1, default=str))
    if x.out:
        json.dump(out, open(x.out, 'w'), indent=1, default=str)
        print(f"wrote {x.out}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
