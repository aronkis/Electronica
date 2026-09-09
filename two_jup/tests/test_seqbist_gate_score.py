"""Unit tests for jupiter_240k5_byte/rtl_sim/seqbist_gate_score.py (SEQ-BIST T0c).

Pure host tests on synthetic CSV / summary / wrapper-log files -- no Verilator,
no board.  The two refusals that matter most are covered explicitly: a run with
no `SEQBIST_GATE_RUN_EXIT` trailer must never be scored (it may still be in
flight and its files still growing), and a build stamped with the wrong
interval units must be refused rather than scored against the wrong constant.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..',
                                'jupiter_240k5_byte', 'rtl_sim'))
import seqbist_gate_score as S  # noqa: E402


# ------------------------------------------------------------- fixtures -----
def write_log(br, gid, codes=(0,), extra=''):
    os.makedirs(br, exist_ok=True)
    p = os.path.join(br, 'seqbist_gate_%s.log' % gid)
    with open(p, 'w') as f:
        f.write('SEQBIST_GATE_LAUNCH id=%s\n%s' % (gid, extra))
        for c in codes:
            f.write('SEQBIST_GATE_RUN_EXIT=%d\n' % c)
    return p


def write_summary(pfx, **kv):
    base = dict(rtl_sha='53f5eff', int_units='seqdelta', complete=1,
                force='none', force_end_clk=-1, frames=0, good=0, garbage=0,
                crc_fail=0, lost_slots=0, gap_events=0, gap1=0, gap2=0,
                gap3plus=0, dup_or_reorder=0, last_seq=0, int_last=0,
                int_lt30=0, int_32=0, int_33=0, int_other=0, packets_delta=0,
                emitted_in_window=0, bwb_min_force=255, avail_low_in_force=0)
    base.update(kv)
    os.makedirs(os.path.dirname(pfx), exist_ok=True)
    with open(pfx + '_summary.txt', 'w') as f:
        for k, v in base.items():
            f.write('%s=%s\n' % (k, v))


CSV_HDR = ('# clk,frames,good,garbage,crc_fail,lost_slots,gap_events,gap1,gap2,'
           'gap3plus,dup_or_reorder,last_seq,int_last,int_lt30,int_32,int_33,'
           'int_other,packets_delta,emitted,rx_frames,bwb_min_win,stalled\n')


def write_csv(pfx, rows):
    with open(pfx + '_csv.txt', 'w') as f:
        f.write(CSV_HDR)
        for r in rows:
            f.write(','.join(str(x) for x in r) + '\n')


def cfg(gid, tmp, **kv):
    d = dict(gid=gid, nframes=100, skip_every=0, corrupt_every=0, fill=1516,
             gap=0, pfx=os.path.join(str(tmp), gid.lower()), force='none',
             max_mclks=400, expect_filler=0)
    d.update(kv)
    return d


# --------------------------------------------------------------- manifest ---
def test_read_manifest_parses_and_types(tmp_path):
    p = tmp_path / 'runs.txt'
    p.write_text('# comment\n\nG1|2000|0|0|1516|0|beat_runs/g1|none|400|1\n')
    runs = S.read_manifest(str(p))
    assert len(runs) == 1
    r = runs[0]
    assert r['gid'] == 'G1' and r['nframes'] == 2000 and r['expect_filler'] == 1
    assert r['force'] == 'none'


def test_read_kv_and_csv_roundtrip(tmp_path):
    pfx = str(tmp_path / 'x')
    write_summary(pfx, frames=7)
    write_csv(pfx, [[100, 7] + [0] * 20])
    assert S.as_int(S.read_kv(pfx + '_summary.txt'), 'frames') == 7
    rows = S.read_csv(pfx + '_csv.txt')
    assert rows and rows[0]['frames'] == 7 and rows[0]['clk'] == 100


# ------------------------------------------------------- trailer refusals ---
def test_missing_trailer_is_refused_not_scored(tmp_path):
    br = str(tmp_path / 'beat_runs')
    os.makedirs(br)
    # a wrapper log that exists but has NOT yet printed the trailer
    with open(os.path.join(br, 'seqbist_gate_G1.log'), 'w') as f:
        f.write('SEQBIST_GATE_LAUNCH id=G1\n')
    c = cfg('G1', tmp_path, nframes=100)
    # a summary that would otherwise PASS
    write_summary(c['pfx'], frames=100, packets_delta=100, emitted_in_window=100)
    write_csv(c['pfx'], [[100, 100] + [0] * 20])
    gid, verdict, ev = S.score_run(c, br=br)
    assert verdict == 'FAIL' and 'no-exit-trailer' in ev


def test_absent_wrapper_log_is_refused(tmp_path):
    br = str(tmp_path / 'beat_runs')
    os.makedirs(br)
    c = cfg('G1', tmp_path, nframes=100)
    write_summary(c['pfx'], frames=100, packets_delta=100, emitted_in_window=100)
    assert S.run_exit_codes(S.log_path_for('G1', br)) == []
    gid, verdict, ev = S.score_run(c, br=br)
    assert verdict == 'FAIL' and 'no-exit-trailer' in ev


def test_nonzero_trailer_fails(tmp_path):
    br = str(tmp_path / 'beat_runs')
    write_log(br, 'G1', codes=(3,))
    c = cfg('G1', tmp_path, nframes=100)
    write_summary(c['pfx'], frames=100, packets_delta=100, emitted_in_window=100)
    gid, verdict, ev = S.score_run(c, br=br)
    assert verdict == 'FAIL' and 'run-exit=3' in ev


def test_driver_and_wrapper_trailers_must_all_be_zero(tmp_path):
    br = str(tmp_path / 'beat_runs')
    write_log(br, 'G1', codes=(0, 0))
    c = cfg('G1', tmp_path, nframes=100)
    write_summary(c['pfx'], frames=100, packets_delta=100, emitted_in_window=100)
    write_csv(c['pfx'], [[100, 100] + [0] * 20])
    assert S.score_run(c, br=br)[1] == 'PASS'
    write_log(br, 'G1', codes=(0, 3))
    assert S.score_run(c, br=br)[1] == 'FAIL'


# ------------------------------------------------------------ unit stamps ---
def test_wrong_int_units_is_refused(tmp_path):
    br = str(tmp_path / 'beat_runs')
    write_log(br, 'G2')
    c = cfg('G2', tmp_path, nframes=100, skip_every=50)
    write_summary(c['pfx'], int_units='received', frames=100,
                  emitted_in_window=100, packets_delta=100)
    gid, verdict, ev = S.score_run(c, br=br)
    assert verdict == 'FAIL' and 'stale build' in ev


def test_expected_interval_depends_on_units():
    c = cfg('G2', '/tmp', skip_every=50)
    assert S.expected_interval(c, 'seqdelta') == 51
    assert S.expected_interval(c, 'received') == 50
    c3 = cfg('G3', '/tmp', corrupt_every=40)
    assert S.expected_interval(c3, 'seqdelta') == 40
    assert S.expected_interval(c3, 'received') == 39


def test_interval_bins():
    assert S.interval_bin(29) == 'int_lt30'
    assert S.interval_bin(30) == 'int_other'
    assert S.interval_bin(32) == 'int_32'
    assert S.interval_bin(33) == 'int_33'
    assert S.interval_bin(51) == 'int_other'


# ------------------------------------------------------------------- G1 -----
def _g1(tmp_path, **kv):
    br = str(tmp_path / 'beat_runs')
    write_log(br, 'G1')
    c = cfg('G1', tmp_path, nframes=100)
    base = dict(frames=100, packets_delta=100, emitted_in_window=100)
    base.update(kv)
    write_summary(c['pfx'], **base)
    write_csv(c['pfx'], [[100, base['frames']] + [0] * 20])
    return S.score_run(c, br=br)


def test_g1_clean_passes(tmp_path):
    assert _g1(tmp_path)[1] == 'PASS'


def test_g1_fails_on_lost_slots(tmp_path):
    gid, v, ev = _g1(tmp_path, lost_slots=3)
    assert v == 'FAIL' and 'lost_slots=3' in ev


def test_g1_fails_on_garbage_when_no_filler_expected(tmp_path):
    gid, v, ev = _g1(tmp_path, garbage=5)
    assert v == 'FAIL' and 'garbage=5' in ev


def test_g1_fails_when_packets_disagree(tmp_path):
    gid, v, ev = _g1(tmp_path, packets_delta=80)
    assert v == 'FAIL' and 'packets_delta' in ev


def test_g1_fails_when_incomplete(tmp_path):
    gid, v, ev = _g1(tmp_path, complete=0, frames=40)
    assert v == 'FAIL' and 'run-incomplete' in ev


def test_g1_filler_mode_accounts_the_all_zero_frames(tmp_path):
    br = str(tmp_path / 'beat_runs')
    write_log(br, 'G1')
    c = cfg('G1', tmp_path, nframes=200, expect_filler=1)
    write_summary(c['pfx'], frames=200, garbage=100, emitted_in_window=100,
                  packets_delta=200)
    write_csv(c['pfx'], [[100, 200] + [0] * 20])
    gid, v, ev = S.score_run(c, br=br)
    assert v == 'PASS' and 'filler_ratio=0.5' in ev


def test_g1_filler_mode_fails_on_corruption_hiding_inside_the_filler(tmp_path):
    """500 emitted (40 of them delivered corrupted) + 500 rail filler: the
    filler equality garbage == frames-emitted and the good_magic == emitted
    check are the same equality seen from two sides, and both must fire."""
    br = str(tmp_path / 'beat_runs')
    write_log(br, 'G1')
    c = cfg('G1', tmp_path, nframes=1000, expect_filler=1)
    write_summary(c['pfx'], frames=1000, garbage=540, emitted_in_window=500,
                  packets_delta=1000)
    write_csv(c['pfx'], [[100, 1000] + [0] * 20])
    gid, v, ev = S.score_run(c, br=br)
    assert v == 'FAIL' and 'corrupted beyond the rail filler' in ev


def test_g1_fails_if_intervals_are_binned_with_no_gap_events(tmp_path):
    gid, v, ev = _g1(tmp_path, int_32=1)
    assert v == 'FAIL' and 'int_32=1' in ev


def test_g1_filler_mode_still_fails_if_real_frames_are_lost(tmp_path):
    br = str(tmp_path / 'beat_runs')
    write_log(br, 'G1')
    c = cfg('G1', tmp_path, nframes=200, expect_filler=1)
    # 100 good-magic frames claimed but 140 were emitted -> 40 real losses
    write_summary(c['pfx'], frames=200, garbage=100, emitted_in_window=140,
                  packets_delta=200)  # 140 emitted, only 100 good-magic
    write_csv(c['pfx'], [[100, 200] + [0] * 20])
    assert S.score_run(c, br=br)[1] == 'FAIL'


# ------------------------------------------------------------------- G2 -----
def _g2(tmp_path, **kv):
    br = str(tmp_path / 'beat_runs')
    write_log(br, 'G2')
    c = cfg('G2', tmp_path, nframes=1000, skip_every=50)
    base = dict(frames=1000, emitted_in_window=1000, packets_delta=1000,
                gap_events=20, gap1=20, lost_slots=20, int_last=51,
                int_other=19)
    base.update(kv)
    write_summary(c['pfx'], **base)
    write_csv(c['pfx'], [[100, base['frames']] + [0] * 20])
    return S.score_run(c, br=br)


def test_g2_skip_every_50_passes_with_seqdelta_51(tmp_path):
    gid, v, ev = _g2(tmp_path)
    assert v == 'PASS' and 'int_last=51' in ev and 'int_bin=int_other' in ev


def test_g2_received_units_value_fails_under_seqdelta(tmp_path):
    """50 is the RECEIVED-units answer; under the 2026-09-03 ruling the RTL must
    report 51.  An accept-either gate could not tell the two builds apart."""
    gid, v, ev = _g2(tmp_path, int_last=50)
    assert v == 'FAIL' and 'expected 51' in ev


def test_g2_fails_when_gap_count_is_wrong(tmp_path):
    gid, v, ev = _g2(tmp_path, gap_events=14, gap1=14, lost_slots=14,
                     int_other=13)
    assert v == 'FAIL' and 'gap_events=14' in ev


def test_g2_fails_when_a_gap_is_bigger_than_one_slot(tmp_path):
    gid, v, ev = _g2(tmp_path, gap1=18, gap2=2)
    assert v == 'FAIL'


def test_g2_fails_when_intervals_land_in_the_wrong_bin(tmp_path):
    gid, v, ev = _g2(tmp_path, int_other=0, int_32=19)
    assert v == 'FAIL'


# ------------------------------------------------------------------- G3 -----
def _g3(tmp_path, **kv):
    br = str(tmp_path / 'beat_runs')
    write_log(br, 'G3')
    c = cfg('G3', tmp_path, nframes=1000, corrupt_every=40)
    base = dict(frames=1000, emitted_in_window=1000, packets_delta=1000,
                garbage=25, gap_events=25, gap1=25, lost_slots=25, int_last=40,
                int_other=24)
    base.update(kv)
    write_summary(c['pfx'], **base)
    write_csv(c['pfx'], [[100, base['frames']] + [0] * 20])
    return S.score_run(c, br=br)


def test_g3_corrupt_every_40_passes(tmp_path):
    gid, v, ev = _g3(tmp_path)
    assert v == 'PASS' and 'expected_corrupt=25' in ev


def test_g3_counts_one_gap_per_corrupted_frame(tmp_path):
    gid, v, ev = _g3(tmp_path, gap_events=0, gap1=0, lost_slots=0)
    assert v == 'FAIL' and 'gap_events=0' in ev


def test_g3_fails_when_garbage_is_short(tmp_path):
    gid, v, ev = _g3(tmp_path, garbage=10)
    assert v == 'FAIL' and 'garbage-filler=10' in ev


def test_g3_interval_is_M_not_M_minus_1_in_seqdelta(tmp_path):
    gid, v, ev = _g3(tmp_path, int_last=39)
    assert v == 'FAIL' and 'expected 40' in ev


def test_g3_filler_mode_subtracts_the_loopback_filler(tmp_path):
    br = str(tmp_path / 'beat_runs')
    write_log(br, 'G3')
    c = cfg('G3', tmp_path, nframes=2000, corrupt_every=40, expect_filler=1)
    write_summary(c['pfx'], frames=2000, emitted_in_window=1000,
                  packets_delta=2000, garbage=1025, gap_events=25, gap1=25,
                  lost_slots=25, int_last=40, int_other=24)
    write_csv(c['pfx'], [[100, 2000] + [0] * 20])
    assert S.score_run(c, br=br)[1] == 'PASS'


# ------------------------------------------------------------------- G4 -----
def _g4rows(pre, post, tail_garbage_growth=0, tail_gap_growth=0, filler=1):
    """CSV rows 100 frames apart: `pre` before the force, `post` after."""
    rows = []
    f = clk = g = ge = lo = 0
    for i in range(pre):
        f += 100
        clk += 100 * 98664
        g += 50 * filler
        rows.append([clk, f, 0, g, 0, lo, ge, 0, 0, 0, 0, f, 0, 0, 0, 0, 0,
                     f, f, f, 8, 0])
    ge += 5
    lo += 10
    for i in range(post):
        f += 100
        clk += 100 * 98664
        g += 50 * filler + tail_garbage_growth
        ge += tail_gap_growth
        rows.append([clk, f, 0, g, 0, lo, ge, 0, 0, 0, 0, f, 0, 0, 0, 0, 0,
                     f, f, f, 8, 1])
    return rows


def _g4(tmp_path, rows=None, recovery=500, **kv):
    br = str(tmp_path / 'beat_runs')
    write_log(br, 'G4')
    c = cfg('G4', tmp_path, nframes=1000, force='overrun:100:2000000',
            expect_filler=1)
    rows = rows if rows is not None else _g4rows(3, 8)
    force_end = rows[2][0] + 1
    base = dict(frames=rows[-1][1], emitted_in_window=rows[-1][1] // 2,
                packets_delta=rows[-1][1], force='overrun:100:2000000',
                force_kind=2, emitted_in_force=30,
                frames_per_force_window='10.13',
                force_end_clk=force_end, garbage=rows[-1][3],
                gap_events=rows[-1][6], lost_slots=rows[-1][5])
    base.update(kv)
    write_summary(c['pfx'], **base)
    write_csv(c['pfx'], rows)
    return S.score_run(c, br=br, recovery_frames=recovery)


def test_g4_overrun_loss_counted_and_checker_recovers(tmp_path):
    gid, v, ev = _g4(tmp_path)
    assert v == 'PASS' and 'emitted_in_force=30' in ev


def test_g4_fails_if_the_force_never_landed(tmp_path):
    gid, v, ev = _g4(tmp_path, emitted_in_force=8)
    assert v == 'FAIL' and 'force did not land' in ev


def test_g4_fails_if_no_loss_was_counted(tmp_path):
    rows = _g4rows(3, 8)
    for r in rows:
        r[5] = 0
        r[6] = 0
    gid, v, ev = _g4(tmp_path, rows=rows, gap_events=0, lost_slots=0)
    assert v == 'FAIL' and 'no counted loss' in ev


def test_g4_rejects_the_starve_force_as_the_gate(tmp_path):
    """`starve` only delays frames on this rail (back-pressure), so it cannot be
    the G4 evidence -- the scorer must refuse it rather than score it."""
    gid, v, ev = _g4(tmp_path, force_kind=1, force='starve:100:200000')
    assert v == 'FAIL' and 'overrun force' in ev


def test_g4_fails_if_the_checker_desynchronises_after_the_event(tmp_path):
    rows = _g4rows(3, 8, tail_garbage_growth=30)
    gid, v, ev = _g4(tmp_path, rows=rows)
    assert v == 'FAIL' and 'desynchronised' in ev


def test_g4_fails_if_losses_continue_after_the_event(tmp_path):
    rows = _g4rows(3, 8, tail_gap_growth=2)
    gid, v, ev = _g4(tmp_path, rows=rows)
    assert v == 'FAIL' and 'desynchronised' in ev


def test_g4_fails_if_the_recovery_window_is_too_short(tmp_path):
    rows = _g4rows(3, 2)
    gid, v, ev = _g4(tmp_path, rows=rows, recovery=500)
    assert v == 'FAIL' and 'post-force frames advanced only' in ev


# -------------------------------------------------------------------- main --
def test_main_writes_summary_lines_and_returns_nonzero_on_fail(tmp_path):
    br = tmp_path / 'beat_runs'
    br.mkdir()
    write_log(str(br), 'G1')
    c = cfg('G1', tmp_path, nframes=100)
    write_summary(c['pfx'], frames=100, packets_delta=100, emitted_in_window=100,
                  lost_slots=1)
    write_csv(c['pfx'], [[100, 100] + [0] * 20])
    man = tmp_path / 'runs.txt'
    man.write_text('G1|100|0|0|1516|0|%s|none|400|0\n' % c['pfx'])
    out = tmp_path / 'sum.txt'
    rc = S.main(['--manifest', str(man), '--beat-runs', str(br),
                 '--out', str(out)])
    assert rc == 1
    txt = out.read_text()
    assert txt.startswith('SEQBIST_GATE G1 FAIL')
