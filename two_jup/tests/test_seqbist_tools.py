"""test_seqbist_tools.py -- Task 4 (T0d) SEQ-BIST host tools, DRY only.

ABSOLUTELY NO board contact: every subprocess here runs with DRY=1 plus a PATH
shim that replaces `ssh`/`scp` with a fake binary that logs its invocation and
exits 1 (two_jup/tests/fake_anyssh.sh pattern, see test_comb_rig_scripts.py). An
empty shim log after a run is the proof of zero board contact.

No subagents. No push.
"""
import json
import os
import stat
import subprocess
import sys
import tempfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
TJ = os.path.abspath(os.path.join(HERE, '..'))            # two_jup/
SEQBIST = os.path.join(TJ, 'seqbist')
sys.path.insert(0, SEQBIST)

import seqbist_score  # noqa: E402


def _make_shim(tmpdir):
    shim = os.path.join(tmpdir, 'shim')
    os.makedirs(shim, exist_ok=True)
    log = os.path.join(tmpdir, 'shim.log')
    for name in ('ssh', 'scp'):
        p = os.path.join(shim, name)
        with open(p, 'w') as f:
            f.write(f'#!/bin/bash\necho "SHIM_CALLED {name} $*" >> "{log}"\nexit 1\n')
        os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return shim, log


def _env(tmpdir, extra=None):
    shim, log = _make_shim(tmpdir)
    env = dict(os.environ)
    env['PATH'] = shim + os.pathsep + env.get('PATH', '')
    env.setdefault('DRY', '1')
    if extra:
        env.update(extra)
    return env, log


def _shim_log_empty(log):
    return (not os.path.exists(log)) or os.stat(log).st_size == 0


def _run(cmd, env, cwd=None, timeout=60):
    return subprocess.run(cmd, env=env, cwd=cwd or SEQBIST, capture_output=True,
                           text=True, timeout=timeout)


# ---------------------------------------------------------------------------
# seqbist_read.py
# ---------------------------------------------------------------------------

def test_read_dry_no_ssh_and_valid_json():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp)
        r = _run([sys.executable, os.path.join(SEQBIST, 'seqbist_read.py'), '148', '--dry'], env)
        assert r.returncode == 0, r.stderr
        assert _shim_log_empty(log), f'shim log not empty: {open(log).read() if os.path.exists(log) else ""}'
        line = r.stdout.strip().splitlines()[-1]
        rec = json.loads(line)
        for key in ('ts_wall', 'ts_mono', 'board', 'reg_0x104', 'reg_0x124',
                    'frames', 'crc_ok', 'crc_fail', 'magic_bad', 'short', 'orphan',
                    'acc_beats', 'acc_user',
                    'chk_frames', 'chk_good', 'chk_garbage', 'chk_crc_fail',
                    'chk_lost_slots', 'chk_gap_events', 'chk_gap1', 'chk_gap2',
                    'chk_gap3plus', 'chk_dup_or_reorder', 'chk_last_seq',
                    'chk_int_last', 'chk_int_hist_lt30', 'chk_int_32', 'chk_int_33',
                    'chk_int_other'):
            assert key in rec, f'missing field {key}'


def test_read_watch_rejects_below_5s():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp)
        r = _run([sys.executable, os.path.join(SEQBIST, 'seqbist_read.py'), '148',
                  '--dry', '--watch', '3'], env)
        assert r.returncode != 0
        assert _shim_log_empty(log)


def test_read_watch_5s_ok_two_samples():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp)
        # --watch loops forever by design (bounded externally via `timeout`, as
        # seqbist_run.sh does) -- so bound it here too and expect a timeout kill,
        # not a clean exit.
        proc = subprocess.Popen(
            ['timeout', '12', sys.executable, os.path.join(SEQBIST, 'seqbist_read.py'),
             '148', '--dry', '--watch', '5'],
            env=env, cwd=SEQBIST, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        stdout, stderr = proc.communicate(timeout=20)
        lines = [ln for ln in stdout.strip().splitlines() if ln.strip()]
        assert len(lines) >= 2, stdout + stderr
        json.loads(lines[0])
        json.loads(lines[1])
        assert _shim_log_empty(log)


# ---------------------------------------------------------------------------
# seqbist_run.sh
# ---------------------------------------------------------------------------

def test_run_dry_end_to_end_produces_files():
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run1')
        env, log = _env(tmp, {'OUT': out, 'DUR': '12', 'DRY': '1'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=60)
        assert 'SEQBIST_DONE' in r.stdout, r.stdout + r.stderr
        assert _shim_log_empty(log), f'shim log not empty: {open(log).read() if os.path.exists(log) else ""}'
        for fname in ('meta.txt', 'readings.jsonl', 'run.log'):
            assert os.path.exists(os.path.join(out, fname)), f'{fname} missing'
        with open(os.path.join(out, 'readings.jsonl')) as f:
            lines = [ln for ln in f if ln.strip()]
        assert len(lines) >= 1
        json.loads(lines[0])


def test_run_refuses_fill_below_100():
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run_fill')
        env, log = _env(tmp, {'OUT': out, 'DUR': '5', 'FILL': '47', 'DRY': '1'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=30)
        assert r.returncode != 0
        assert 'SEQBIST_REFUSED' in (r.stdout + r.stderr)
        assert 'FILL' in (r.stdout + r.stderr)
        assert _shim_log_empty(log)


def test_run_refuses_both_skip_and_corrupt():
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run_both')
        env, log = _env(tmp, {'OUT': out, 'DUR': '5', 'SKIP_EVERY': '50',
                               'CORRUPT_EVERY': '40', 'DRY': '1'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=30)
        assert r.returncode != 0
        assert 'SEQBIST_REFUSED' in (r.stdout + r.stderr)
        assert _shim_log_empty(log)


def test_run_tgen_words_skip_every_encoding():
    # Interface contract: ctrl@0x9D400000 [31:16]=N [15:4]=fill [0]=enable;
    # gap@0x9D400008 [26:0]=gap clks, bit27=mode (0=skip_every, 1=corrupt_every).
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run_skip')
        env, log = _env(tmp, {'OUT': out, 'DUR': '12', 'DRY': '1', 'FILL': '1516',
                               'GAP': '200000', 'SKIP_EVERY': '50'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=60)
        assert _shim_log_empty(log)
        line = [ln for ln in r.stdout.splitlines() if 'TGEN_WORDS' in ln][0]
        ctrl = int([t for t in line.split() if t.startswith('ctrl=')][0].split('=')[1], 16)
        gap = int([t for t in line.split() if t.startswith('gap=')][0].split('=')[1], 16)
        assert (ctrl >> 16) & 0xFFFF == 50
        assert (ctrl >> 4) & 0xFFF == 1516
        assert ctrl & 1 == 1
        assert (gap >> 27) & 1 == 0
        assert gap & 0x7FFFFFF == 200000


def test_run_tgen_words_corrupt_every_encoding():
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run_corrupt')
        env, log = _env(tmp, {'OUT': out, 'DUR': '12', 'DRY': '1', 'FILL': '1516',
                               'GAP': '0', 'CORRUPT_EVERY': '40'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=60)
        assert _shim_log_empty(log)
        line = [ln for ln in r.stdout.splitlines() if 'TGEN_WORDS' in ln][0]
        ctrl = int([t for t in line.split() if t.startswith('ctrl=')][0].split('=')[1], 16)
        gap = int([t for t in line.split() if t.startswith('gap=')][0].split('=')[1], 16)
        assert (ctrl >> 16) & 0xFFFF == 40
        assert (gap >> 27) & 1 == 1


def test_run_flags_short_window_uninformative():
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run_short')
        env, log = _env(tmp, {'OUT': out, 'DUR': '12', 'DRY': '1'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=60)
        # DUR=12 < 150s window -> non-zero exit, but files still produced
        assert r.returncode != 0
        assert 'SEQBIST_DONE' in r.stdout
        assert _shim_log_empty(log)
        with open(os.path.join(out, 'meta.txt')) as f:
            meta_txt = f.read()
        assert 'window_s=' in meta_txt


# ---------------------------------------------------------------------------
# seqbist_score.py -- synthetic readings, no board / no subprocess needed
# ---------------------------------------------------------------------------

def _write_run(tmp, readings, meta_extra=''):
    out = os.path.join(tmp, 'scored_run')
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, 'readings.jsonl'), 'w') as f:
        for r in readings:
            f.write(json.dumps(r) + '\n')
    with open(os.path.join(out, 'meta.txt'), 'w') as f:
        f.write(f'leg=seqbist board=10.0.0.148 mode=loopback dur=200 window_s=200 dry=1\n')
        f.write(meta_extra + '\n')
        f.write('rearms_in_window=0\n')
    return out


def _base_row(i, frames, extra=None):
    row = {
        'ts_wall': f't{i}', 'ts_mono': float(i * 10), 'board': 'dry-no-board',
        'reg_0x104': frames, 'reg_0x124': frames,
        'acc_user': frames, 'frames': frames, 'crc_ok': frames, 'crc_fail': 0,
        'magic_bad': 0, 'short': 0, 'orphan': 0, 'acc_beats': frames * 191,
        'ep_gt1k': 0, 'ep_gt2k': 0, 'ep_gt3k': 0, 'ep_gt6k': 0, 'ep_gt12k': 0,
        'ep_gt25k': 0, 'max_len': 0, 'starve_clk': 0,
        'chk_frames': frames, 'chk_good': frames, 'chk_garbage': 0, 'chk_crc_fail': 0,
        'chk_lost_slots': 0, 'chk_gap_events': 0, 'chk_gap1': 0, 'chk_gap2': 0,
        'chk_gap3plus': 0, 'chk_dup_or_reorder': 0, 'chk_last_seq': frames,
        'chk_int_last': 32, 'chk_int_hist_lt30': 0, 'chk_int_32': 0, 'chk_int_33': 0,
        'chk_int_other': 0,
    }
    if extra:
        row.update(extra)
    return row


def test_score_skip_every_50_scores_pass():
    with tempfile.TemporaryDirectory() as tmp:
        # 20 samples, 1000 frames each (cumulative), skip_every=50 -> 20 lost/sample
        readings = []
        cum_frames = 0
        cum_lost = 0
        cum_gap = 0
        for i in range(21):
            readings.append(_base_row(i, cum_frames, {
                'reg_0x104': cum_frames, 'reg_0x124': cum_frames,
                'chk_frames': cum_frames, 'chk_lost_slots': cum_lost,
                'chk_gap_events': cum_gap, 'chk_gap1': cum_gap, 'chk_good': cum_frames - 0,
                'chk_int_32': cum_gap,
                # skip_every=50 -> the seq-delta at each injected gap is N+1 = 51. The
                # fixture used to pin chk_int_last=32 while declaring skip_every=50, which
                # is physically inconsistent; it passed only because the old scorer checked
                # the interval peak solely when it landed in the 32/33 bins. The ruling of
                # 2026-09-04 requires POSITIVE interval evidence, so the fixture now carries
                # the interval the generator would actually produce.
                'chk_int_last': 51,
            }))
            cum_frames += 1000
            cum_lost += 1000 // 50
            cum_gap += 1000 // 50
        out = _write_run(tmp, readings, 'fill=1516 gap=0 skip_every=50 corrupt_every=0')
        summary = seqbist_score.score(out)
        assert summary['verdict'] == 'PASS', summary
        assert summary['positive_control']['pass'] is True


def test_score_int32_int33_57_43_estimates_32_4():
    with tempfile.TemporaryDirectory() as tmp:
        # single delta window: int_32=57, int_33=43 -> period_est ~= 32.43
        readings = [
            _base_row(0, 0, {'chk_int_32': 0, 'chk_int_33': 0}),
            _base_row(1, 10000, {'chk_frames': 10000, 'chk_int_32': 57, 'chk_int_33': 43,
                                  'reg_0x104': 10000, 'reg_0x124': 10000}),
        ]
        out = _write_run(tmp, readings, 'fill=1516 gap=0 skip_every=0 corrupt_every=0')
        summary = seqbist_score.score(out)
        est = summary['interval_hist']['period_est_frames']
        assert est is not None
        assert abs(est - 32.43) < 0.1, est


def test_score_reports_json_and_uninformative_on_short_window():
    with tempfile.TemporaryDirectory() as tmp:
        readings = [_base_row(0, 0), _base_row(1, 100)]
        out = os.path.join(tmp, 'short_run')
        os.makedirs(out, exist_ok=True)
        with open(os.path.join(out, 'readings.jsonl'), 'w') as f:
            for r in readings:
                f.write(json.dumps(r) + '\n')
        with open(os.path.join(out, 'meta.txt'), 'w') as f:
            f.write('leg=seqbist board=10.0.0.148 mode=loopback dur=12 window_s=12 dry=1\n')
            f.write('rearms_in_window=0\n')
        summary = seqbist_score.score(out)
        assert summary['verdict'] == 'UNINFORMATIVE'
        assert any('window_s' in r for r in summary['reasons'])


def test_score_cli_prints_json_and_verdict_line():
    with tempfile.TemporaryDirectory() as tmp:
        readings = [_base_row(0, 0), _base_row(1, 5000)]
        out = _write_run(tmp, readings)
        env, log = _env(tmp)
        r = _run([sys.executable, os.path.join(SEQBIST, 'seqbist_score.py'), out], env)
        assert r.returncode == 0, r.stderr
        assert 'SEQBIST_SCORE verdict=' in r.stdout
        assert _shim_log_empty(log)


# ---------------------------------------------------------------------------
# fix round 2: (1) TGEN-on-before-checker-clear ordering
# ---------------------------------------------------------------------------

def test_run_order_tgen_on_before_checker_clear():
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run_order')
        env, log = _env(tmp, {'OUT': out, 'DUR': '12', 'DRY': '1'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=60)
        assert _shim_log_empty(log)
        lines = r.stdout.splitlines()
        tgen_idx = next(i for i, ln in enumerate(lines) if 'TGEN on' in ln)
        settle_idx = next(i for i, ln in enumerate(lines) if 'settle 50ms' in ln)
        clear_idx = next(i for i, ln in enumerate(lines) if 'checker clear RMW' in ln)
        assert tgen_idx < settle_idx < clear_idx, lines


# ---------------------------------------------------------------------------
# fix round 2: (2) tgen_rx-enabled preflight refusal (146/148 lineage)
# ---------------------------------------------------------------------------

def test_run_refuses_when_tgen_rx_enabled():
    fake_w = os.path.join(HERE, 'fake_anyssh_seqbist.sh')
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run_tgenrx')
        env, log = _env(tmp, {'OUT': out, 'DUR': '12', 'DRY': '0',
                               'W': fake_w, 'FAKE_TGEN_RX_CTRL': '1'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=30)
        assert r.returncode != 0
        assert 'SEQBIST_REFUSED' in (r.stdout + r.stderr)
        assert 'tgen_rx' in (r.stdout + r.stderr)
        assert _shim_log_empty(log)


def test_run_dry_preflight_checks_tgen_rx():
    # DRY mode can't read the register, but the preflight step must still run
    # (and be logged) ahead of the window, per the 146/148 lineage note.
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run_tgenrx_dry')
        env, log = _env(tmp, {'OUT': out, 'DUR': '12', 'DRY': '1'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=60)
        assert _shim_log_empty(log)
        assert 'preflight: check tgen_rx enable' in r.stdout


# ---------------------------------------------------------------------------
# fix round 2: (3) interval units are seq-delta (N+1 for skip, M for corrupt),
# legacy-slot tolerance, frames != good+garbage+crc_fail note
# ---------------------------------------------------------------------------

def test_score_legacy_slots_all_zero_not_flagged():
    with tempfile.TemporaryDirectory() as tmp:
        zero_legacy = {
            'acc_user': 0, 'frames': 0, 'crc_ok': 0, 'crc_fail': 0, 'magic_bad': 0,
            'short': 0, 'orphan': 0, 'acc_beats': 0, 'ep_gt1k': 0, 'ep_gt2k': 0,
            'ep_gt3k': 0, 'ep_gt6k': 0, 'ep_gt12k': 0, 'ep_gt25k': 0, 'max_len': 0,
            'starve_clk': 0,
        }
        readings = [
            _base_row(0, 0, dict(zero_legacy)),
            _base_row(1, 5000, dict(zero_legacy, reg_0x104=5000, reg_0x124=5000,
                                     chk_frames=5000, chk_good=5000)),
        ]
        out = _write_run(tmp, readings, 'fill=1516 gap=0 skip_every=0 corrupt_every=0')
        summary = seqbist_score.score(out)
        assert summary['legacy_slots_0_15_all_zero'] is True
        assert summary['verdict'] in ('CLEAN', 'INFORMATIVE')
        assert not any('legacy' in r.lower() or 'slot' in r.lower() for r in summary['reasons'])


def test_score_skip_every_interval_peak_is_n_plus_1():
    # SKIP_EVERY=31 -> expected_interval_peak = 32 (the skipped slot adds one to
    # the seq-delta), so gap events should land almost entirely in the int_32 bin.
    with tempfile.TemporaryDirectory() as tmp:
        n = 31
        readings = []
        for i in range(21):
            cum_frames = i * 1000
            cum_gap = cum_frames // n  # exact frames/N ratio, no compounded rounding drift
            readings.append(_base_row(i, cum_frames, {
                'reg_0x104': cum_frames, 'reg_0x124': cum_frames,
                'chk_frames': cum_frames, 'chk_lost_slots': cum_gap,
                'chk_gap_events': cum_gap, 'chk_gap1': cum_gap,
                'chk_int_32': cum_gap,  # peak bin for expected_interval_peak=32
            }))
        out = _write_run(tmp, readings, f'fill=1516 gap=0 skip_every={n} corrupt_every=0')
        summary = seqbist_score.score(out)
        assert summary['positive_control']['expected_interval_peak'] == n + 1
        assert summary['positive_control']['pass'] is True
        assert summary['verdict'] == 'PASS'


def test_score_skip_every_interval_peak_wrong_bin_fails():
    # Same gap-event counts as above, but the mass is (wrongly) in int_33
    # instead of int_32 -- the interval-peak check must catch this.
    with tempfile.TemporaryDirectory() as tmp:
        n = 31
        readings = []
        for i in range(21):
            cum_frames = i * 1000
            cum_gap = cum_frames // n
            readings.append(_base_row(i, cum_frames, {
                'reg_0x104': cum_frames, 'reg_0x124': cum_frames,
                'chk_frames': cum_frames, 'chk_lost_slots': cum_gap,
                'chk_gap_events': cum_gap, 'chk_gap1': cum_gap,
                'chk_int_33': cum_gap,  # wrong bin for expected_interval_peak=32
            }))
        out = _write_run(tmp, readings, f'fill=1516 gap=0 skip_every={n} corrupt_every=0')
        summary = seqbist_score.score(out)
        assert summary['positive_control']['expected_interval_peak'] == n + 1
        assert summary['positive_control']['pass'] is False
        assert summary['verdict'] == 'FAIL'


def test_score_corrupt_every_interval_peak_is_m():
    # CORRUPT_EVERY=32 -> expected_interval_peak = 32 (no seq skip -- payload/
    # CRC only), garbage AND gap_events must both agree with frames/M, and the
    # gap-event mass must land in int_32.
    with tempfile.TemporaryDirectory() as tmp:
        m = 32
        readings = []
        for i in range(21):
            cum_frames = i * 1000
            cum_garbage = cum_frames // m
            readings.append(_base_row(i, cum_frames, {
                'reg_0x104': cum_frames, 'reg_0x124': cum_frames,
                'chk_frames': cum_frames, 'chk_garbage': cum_garbage,
                'chk_gap_events': cum_garbage, 'chk_gap1': cum_garbage,
                'chk_int_32': cum_garbage,
            }))
        out = _write_run(tmp, readings, f'fill=1516 gap=0 skip_every=0 corrupt_every={m}')
        summary = seqbist_score.score(out)
        pc = summary['positive_control']
        assert pc['expected_interval_peak'] == m
        assert pc['pass'] is True
        assert summary['verdict'] == 'PASS'


def test_score_interval_hist_reports_units():
    with tempfile.TemporaryDirectory() as tmp:
        readings = [_base_row(0, 0), _base_row(1, 5000, {'reg_0x104': 5000,
                                                           'reg_0x124': 5000,
                                                           'chk_frames': 5000})]
        out = _write_run(tmp, readings)
        summary = seqbist_score.score(out)
        assert 'seq-delta' in summary['interval_hist']['units']


# ---------------------------------------------------------------------------
# fix round 2 addendum: (a) tgen_rx ctrl RMW must preserve bit0/bit5
# ---------------------------------------------------------------------------

def test_read_remote_script_is_rmw_on_tgen_rx_ctrl():
    import seqbist_read
    script = seqbist_read.remote_script()
    assert "CTRL=$($DM 0x9D410000)" in script
    assert "$DM 0x9D410000 32 $(( CTRL | 8 ))" in script  # OR-in freeze, not a constant
    assert "$DM 0x9D410000 32 $CTRL" in script            # restore the full original word
    # never a bare/constant write to 0x9D410000 (that would drop bit0/bit5)
    assert "0x9D410000 32 0\n" not in script
    assert "0x9D410000 32 8\n" not in script


def test_run_checker_clear_dry_log_preserves_bits():
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run_rmw')
        env, log = _env(tmp, {'OUT': out, 'DUR': '12', 'DRY': '1'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=60)
        assert _shim_log_empty(log)
        line = [ln for ln in r.stdout.splitlines() if 'checker clear RMW' in ln][0]
        # bit0 (tgen_rx enable) stays 0 and bit5 (tgen_mode, 0x20) is preserved
        # across all three logged words (orig/cleared/set)
        import re
        words = re.findall(r'0x[0-9A-Fa-f]{8}', line)
        assert len(words) == 3, line
        for w in words:
            v = int(w, 16)
            assert v & 1 == 0, f"bit0 set in {w}: {line}"
            assert v & 0x20 == 0x20, f"bit5 (tgen_mode) lost in {w}: {line}"


# ---------------------------------------------------------------------------
# fix round 2 addendum: (b) int_last series is the primary flatness signal;
# 146 note in the checklist
# ---------------------------------------------------------------------------

def test_score_interval_last_series_flat():
    with tempfile.TemporaryDirectory() as tmp:
        readings = [_base_row(i, i * 1000, {'chk_int_last': 32}) for i in range(5)]
        out = _write_run(tmp, readings)
        summary = seqbist_score.score(out)
        ils = summary['interval_last_series']
        assert ils['n'] == 5
        assert ils['flat'] is True
        assert ils['min'] == ils['max'] == 32


def test_score_interval_last_series_not_flat_bimodal():
    with tempfile.TemporaryDirectory() as tmp:
        vals = [32, 32, 300, 32, 310]
        readings = [_base_row(i, i * 1000, {'chk_int_last': v}) for i, v in enumerate(vals)]
        out = _write_run(tmp, readings)
        summary = seqbist_score.score(out)
        assert summary['interval_last_series']['flat'] is False


def test_score_int_other_nonzero_not_treated_as_flatness_flag():
    # int_other present and non-zero must not, by itself, appear in `reasons`
    # (UNINFORMATIVE) -- it's a coarse cross-check, not a noise signal.
    with tempfile.TemporaryDirectory() as tmp:
        readings = [
            _base_row(0, 0, {'chk_int_32': 0, 'chk_int_other': 0}),
            _base_row(1, 5000, {'chk_frames': 5000, 'chk_int_32': 50, 'chk_int_other': 50,
                                 'reg_0x104': 5000, 'reg_0x124': 5000}),
        ]
        out = _write_run(tmp, readings, 'fill=1516 gap=0 skip_every=0 corrupt_every=0')
        summary = seqbist_score.score(out)
        assert summary['interval_hist']['int_other'] == 50
        assert not any('contamina' in r.lower() or 'noise' in r.lower() for r in summary['reasons'])


def test_score_board_146_note_present():
    with tempfile.TemporaryDirectory() as tmp:
        readings = [_base_row(0, 0), _base_row(1, 5000, {'reg_0x104': 5000,
                                                           'reg_0x124': 5000,
                                                           'chk_frames': 5000})]
        out = os.path.join(tmp, 'run146')
        os.makedirs(out, exist_ok=True)
        with open(os.path.join(out, 'readings.jsonl'), 'w') as f:
            for r in readings:
                f.write(json.dumps(r) + '\n')
        with open(os.path.join(out, 'meta.txt'), 'w') as f:
            f.write('leg=seqbist board=10.0.0.146 mode=loopback dur=200 window_s=200 dry=1\n')
            f.write('skip_every=0 corrupt_every=0 rearms_in_window=0\n')
        summary = seqbist_score.score(out)
        assert any('146' in n and 'short_frm' in n for n in summary['notes'])
        # informational only -- must not flip a clean run's verdict
        assert summary['verdict'] != 'UNINFORMATIVE'


def test_score_board_148_no_146_note():
    with tempfile.TemporaryDirectory() as tmp:
        readings = [_base_row(0, 0), _base_row(1, 5000, {'reg_0x104': 5000,
                                                           'reg_0x124': 5000,
                                                           'chk_frames': 5000})]
        out = _write_run(tmp, readings)
        summary = seqbist_score.score(out)
        assert summary['notes'] == []


# ---------------------------------------------------------------------------
# fix round 2 addendum: TX-side witness (txchk_gpio) must not be asserted
# against RX chk_frames under CORRUPT_EVERY
# ---------------------------------------------------------------------------

def test_score_tx_rx_not_compared_under_corrupt_every():
    with tempfile.TemporaryDirectory() as tmp:
        m = 40
        readings = []
        for i in range(5):
            frames = i * 1000
            garbage = frames // m
            tx_checked = frames - garbage  # tx_seam_checker undercounts by construction
            readings.append(_base_row(i, frames, {
                'reg_0x104': frames, 'reg_0x124': frames, 'chk_frames': frames,
                'chk_garbage': garbage, 'chk_gap_events': garbage, 'chk_gap1': garbage,
                'chk_int_32': garbage, 'tx_frames_checked': tx_checked,
            }))
        out = _write_run(tmp, readings, f'fill=1516 gap=0 skip_every=0 corrupt_every={m}')
        summary = seqbist_score.score(out)
        tx_rx = summary['tx_rx_frame_agreement']
        assert tx_rx['compared'] is False
        assert 'pass' not in tx_rx


def test_score_tx_rx_compared_under_skip_every():
    with tempfile.TemporaryDirectory() as tmp:
        n = 50
        readings = []
        for i in range(5):
            frames = i * 1000
            gap = frames // n
            readings.append(_base_row(i, frames, {
                'reg_0x104': frames, 'reg_0x124': frames, 'chk_frames': frames,
                'chk_lost_slots': gap, 'chk_gap_events': gap, 'chk_gap1': gap,
                'chk_int_32': gap, 'tx_frames_checked': frames,  # TX unaffected by skip
            }))
        out = _write_run(tmp, readings, f'fill=1516 gap=0 skip_every={n} corrupt_every=0')
        summary = seqbist_score.score(out)
        tx_rx = summary['tx_rx_frame_agreement']
        assert tx_rx['compared'] is True
        assert tx_rx['pass'] is True


def test_score_tx_rx_absent_when_no_tx_field():
    with tempfile.TemporaryDirectory() as tmp:
        readings = [_base_row(0, 0), _base_row(1, 5000, {'reg_0x104': 5000,
                                                           'reg_0x124': 5000,
                                                           'chk_frames': 5000})]
        out = _write_run(tmp, readings)
        summary = seqbist_score.score(out)
        assert 'tx_rx_frame_agreement' not in summary


# ---------------------------------------------------------------------------
# Task 6 / coordinator ruling 2026-09-04: the RX-seam SINK.
#
# rx_seq_checker counts valid && ready at the DUT RX byte pins. With no daemon
# and no DMA armed the seam's ready is LOW, the ByteRxFifo never drains, and every
# checker counter reads 0 while the demod's 0x104 runs at line rate. Measured on
# silicon as leg ctrlA att.1 (2026-09-04 00:12): 0x104 advanced 179,274 over the
# window while chk_frames, legacy frames and acc_beats all stayed exactly 0.
# SINK=tgenrx holds qpsk_traffic_gen_rx2's enable high so it consumes+discards the
# DUT stream (qpsk_traffic_gen_rx2.v:114 dut_ready = en_d ? 1'b1 : dma_ready).
# ---------------------------------------------------------------------------
def test_run_sink_tgenrx_dry_rmw_sets_bit0_and_preserves_3_4_5():
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run_sink_tgenrx')
        env, log = _env(tmp, {'OUT': out, 'DUR': '12', 'DRY': '1',
                              'SINK': 'tgenrx', 'BOARD': '148'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=60)
        assert _shim_log_empty(log)
        assert 'SINK=tgenrx RMW' in r.stdout, r.stdout
        # 0x30 (bit5 tgen_mode + bit4 checker en) must survive; bit0 gets set -> 0x31
        assert '0x00000030' in r.stdout and '0x00000031' in r.stdout, r.stdout
        assert 'bits 3/4/5 preserved' in r.stdout
        # and it must be disarmed again
        assert 'SINK=tgenrx disarm' in r.stdout, r.stdout
        with open(os.path.join(out, 'meta.txt')) as f:
            meta = f.read()
        assert 'sink=tgenrx' in meta, meta
        assert 'sink_acc_beats_delta=' in meta and 'ovf_pre=' in meta, meta
        assert 'sink_witness_ok=' in meta, meta


def test_run_sink_tgenrx_refused_on_146():
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run_sink_146')
        env, log = _env(tmp, {'OUT': out, 'DUR': '12', 'DRY': '1',
                              'SINK': 'tgenrx', 'BOARD': '146'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=30)
        assert r.returncode != 0
        assert 'SEQBIST_REFUSED' in (r.stdout + r.stderr)
        assert '148-only' in (r.stdout + r.stderr)
        assert _shim_log_empty(log)


def test_run_sink_cyclic_dry_emits_the_rx_arm_cyclic_sequence():
    # qpsk_tun.c rx_arm_cyclic():1256-1265 -- CONTROL 0 -> CONTROL 1 -> DEST ->
    # X_LENGTH (ring bytes - 1) -> FLAGS cyclic bit0 -> SUBMIT. Order matters.
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run_sink_cyc')
        env, log = _env(tmp, {'OUT': out, 'DUR': '12', 'DRY': '1',
                              'SINK': 'cyclic', 'BOARD': '146',
                              'CYC_DEST': '0x7FE40000', 'CYC_RING_BYTES': '98304'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=60)
        assert _shim_log_empty(log)
        assert 'SINK=cyclic' in r.stdout, r.stdout
        line = [l for l in r.stdout.splitlines() if 'SINK=cyclic' in l and '0x400' in l][0]
        for frag in ('+0x400=0', '+0x400=1', '0x7FE40000', '98303', '+0x40C=1', '+0x408=1'):
            assert frag in line, f'{frag} missing from {line}'
        assert line.index('+0x400=1') < line.index('+0x410') < line.index('+0x408=1')
        assert 'SINK=cyclic disarm' in r.stdout
        with open(os.path.join(out, 'meta.txt')) as f:
            assert 'sink=cyclic' in f.read()


def test_run_sink_none_still_refuses_when_tgen_rx_enabled():
    # the original refusal must survive for SINK=none (the default)
    fake_w = os.path.join(HERE, 'fake_anyssh_seqbist.sh')
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run_sink_none')
        env, log = _env(tmp, {'OUT': out, 'DUR': '12', 'DRY': '0',
                              'W': fake_w, 'FAKE_TGEN_RX_CTRL': '1', 'SINK': 'none'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=30)
        assert r.returncode != 0
        assert 'SEQBIST_REFUSED' in (r.stdout + r.stderr)
        assert _shim_log_empty(log)


def test_run_sink_unknown_is_refused():
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run_sink_bad')
        env, log = _env(tmp, {'OUT': out, 'DUR': '12', 'DRY': '1', 'SINK': 'wat'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=30)
        assert r.returncode != 0
        assert 'unknown SINK' in (r.stdout + r.stderr)
        assert _shim_log_empty(log)


def test_postflash_sink_tgenrx_dry_arms_and_disarms():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp, {'DRY': '1', 'SINK': 'tgenrx'})
        r = _run(['bash', os.path.join(SEQBIST, 'postflash_check.sh')], env, timeout=60)
        assert _shim_log_empty(log)
        assert 'SINK=tgenrx arm' in r.stdout, r.stdout
        assert 'SINK=tgenrx disarm' in r.stdout, r.stdout
        assert 'POSTFLASH_OK' in r.stdout


# ---------------------------------------------------------------------------
# Task 6 / coordinator ruling 2026-09-04: 0x158, 0x114 and 0x118 are WRITE-ONLY in
# the HDL-Coder AXI decoder (BIST_SEQ_SURVEY.md:29 READ-taken list excludes them;
# TxRxCompo_ip_addr_decoder.v:602-604 "anything else returns const_0"). Measured on
# silicon (unit t6-probe158): 0x158 read 0x0 immediately after writing 0x1, after
# 1 s, after a 0x110 pulse, after a full arm, and after writing 0x0 -- five reads,
# one value, while 0x104 advanced at 1247-1248 f/s. So the arm must be verified BY
# EFFECT (chk_frames advancing with 0x104), never by reading those registers back.
# ---------------------------------------------------------------------------
def test_run_never_compares_readback_of_write_only_registers():
    with open(os.path.join(SEQBIST, 'seqbist_run.sh')) as f:
        src = f.read()
    # the old false gate compared parsed read-backs; none of that may survive
    # code-level tokens only: the explanatory comment is allowed (and wanted) to name
    # the old failure, so match on things only the removed implementation would emit.
    for banned in ('ARM_READBACK', 'want158', 'WANT114', "sed -n 's/.*r158="):
        assert banned not in src, f'{banned!r} still present -- write-only read-back gate is back'
    assert 'verify_arm_by_effect' in src
    # and the write-only trio must never be fed to the read idiom `echo <addr> > $DRA; cat`
    assert 'rd 0x158' not in src and 'rd 0x114' not in src and 'rd 0x118' not in src


def test_run_dry_logs_effect_gate_and_meta_flag():
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'run_effect')
        env, log = _env(tmp, {'OUT': out, 'DUR': '12', 'DRY': '1',
                              'SINK': 'tgenrx', 'BOARD': '148'})
        r = _run(['bash', os.path.join(SEQBIST, 'seqbist_run.sh')], env, timeout=60)
        assert _shim_log_empty(log)
        assert 'verify_arm_by_effect' in r.stdout, r.stdout
        assert 'chk_frames AND 0x104 to advance' in r.stdout, r.stdout
        with open(os.path.join(out, 'meta.txt')) as f:
            assert 'arm_verified_by_effect=1' in f.read()


def test_effect_gate_delta_arithmetic():
    # the exact expression the gate runs, in isolation: it must key off chk_frames
    # (slot 16) and 0x104, and a demod-running/seam-dead case must NOT pass.
    import subprocess as sp
    expr = ('import json, sys\n'
            'a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])\n'
            'print(b["reg_0x104"] - a["reg_0x104"], b["chk_frames"] - a["chk_frames"])')
    a = json.dumps({'reg_0x104': 100, 'chk_frames': 10})
    live = json.dumps({'reg_0x104': 6325, 'chk_frames': 6230})
    seam_dead = json.dumps({'reg_0x104': 6325, 'chk_frames': 10})
    modem_dead = json.dumps({'reg_0x104': 100, 'chk_frames': 10})
    for other, want_pass in ((live, True), (seam_dead, False), (modem_dead, False)):
        d104, dchk = sp.run([sys.executable, '-c', expr, a, other],
                            capture_output=True, text=True, check=True).stdout.split()
        passed = int(d104) > 0 and int(dchk) > 0
        assert passed is want_pass, f'{other} -> d104={d104} dchk={dchk}'


# ---------------------------------------------------------------------------
# Ruling 2026-09-04: controls are scored BACKGROUND-CORRECTED against EMITTED
# frames, tolerance max(2, 3*sqrt(expected)), and the interval evidence must be
# positive (the N+1 / N peak distinct from the background intervals).
# ---------------------------------------------------------------------------
def _ctrl_run(tmp, *, emitted, frames, gaps, gap1, meta_extra='', int_last=1001,
              garbage=0, n=18):
    """Synthetic control leg: cumulative counters ramped linearly over n samples."""
    readings = []
    for i in range(n):
        f = frames * i // (n - 1)
        e = emitted * i // (n - 1)
        g = gaps * i // (n - 1)
        readings.append(_base_row(i, f, {
            'reg_0x104': f, 'reg_0x124': f, 'chk_frames': f,
            'chk_good': e - g, 'chk_garbage': garbage * i // (n - 1),
            'chk_lost_slots': g, 'chk_gap_events': g,
            'chk_gap1': gap1 * i // (n - 1), 'chk_gap2': 0,
            'chk_last_seq': e, 'chk_int_last': int_last,
        }))
    return _write_run(tmp, readings, meta_extra)


def test_score_control_background_corrected_passes():
    # the real ctrlA-m numbers [silicon]: emitted 110,208, observed 164 gap events,
    # background 0.000582/emitted -> 64.1, corrected 99.9 vs expected 110.2, tol 31.5
    with tempfile.TemporaryDirectory() as tmp:
        out = _ctrl_run(tmp, emitted=110208, frames=220182, gaps=164, gap1=151,
                        meta_extra='fill=1516 gap=73384 skip_every=1000 corrupt_every=0\n'
                                   'background_gap_per_emitted=0.000582')
        s = seqbist_score.score(out)
        pc = s['positive_control']
        assert pc['emitted_frames'] == 110208
        assert abs(pc['expected_gap_events'] - 110.208) < 0.01
        assert abs(pc['background_events_est'] - 64.1) < 1.0
        assert abs(pc['corrected_gap_events'] - 99.9) < 1.0
        assert abs(pc['tolerance'] - 31.5) < 0.5, pc
        assert pc['pass'] is True, pc
        # filler must be reported and must NOT be in the control denominator
        assert abs(pc['filler_frac'] - 0.4994) < 0.01


def test_score_control_uncorrected_would_fail_the_same_data():
    with tempfile.TemporaryDirectory() as tmp:
        out = _ctrl_run(tmp, emitted=110208, frames=220182, gaps=164, gap1=151,
                        meta_extra='fill=1516 gap=73384 skip_every=1000 corrupt_every=0')
        s = seqbist_score.score(out)
        pc = s['positive_control']
        assert pc['background_gap_per_emitted'] is None
        assert 'background_note' in pc
        # 164 vs 110.2 with tol 31.5 -> 53.8 off, fails without the correction
        assert pc['pass'] is False, pc


def test_score_control_tolerance_is_three_sigma_not_two_absolute():
    with tempfile.TemporaryDirectory() as tmp:
        out = _ctrl_run(tmp, emitted=100000, frames=100000, gaps=100, gap1=100,
                        meta_extra='fill=1516 gap=1 skip_every=1000 corrupt_every=0\n'
                                   'background_gap_per_emitted=0')
        pc = seqbist_score.score(out)['positive_control']
        assert abs(pc['tolerance'] - 30.0) < 0.01      # 3*sqrt(100)
        assert pc['pass'] is True
    # small expectation falls back to the original +/- 2
    with tempfile.TemporaryDirectory() as tmp:
        out = _ctrl_run(tmp, emitted=400, frames=400, gaps=0, gap1=0,
                        meta_extra='fill=1516 gap=1 skip_every=1000 corrupt_every=0\n'
                                   'background_gap_per_emitted=0')
        pc = seqbist_score.score(out)['positive_control']
        assert pc['tolerance'] == 2


def test_score_control_requires_positive_interval_evidence():
    # right counts, but int_last nowhere near N+1 -> the control must NOT pass
    with tempfile.TemporaryDirectory() as tmp:
        out = _ctrl_run(tmp, emitted=100000, frames=100000, gaps=100, gap1=100,
                        int_last=7,
                        meta_extra='fill=1516 gap=1 skip_every=1000 corrupt_every=0\n'
                                   'background_gap_per_emitted=0')
        pc = seqbist_score.score(out)['positive_control']
        assert pc['int_last_distinct'] is False
        assert pc['pass'] is False, pc


def test_score_corrupt_control_subtracts_filler_from_garbage():
    # CORRUPT_EVERY=1000 on 100k emitted inside 200k byte-plane frames: garbage carries
    # a 100k filler pedestal plus the 100 corrupted frames.
    with tempfile.TemporaryDirectory() as tmp:
        out = _ctrl_run(tmp, emitted=100000, frames=200000, gaps=100, gap1=100,
                        int_last=1000, garbage=100100,
                        meta_extra='fill=1516 gap=73384 skip_every=0 corrupt_every=1000\n'
                                   'background_gap_per_emitted=0')
        pc = seqbist_score.score(out)['positive_control']
        assert pc['filler_est'] == 100000
        assert abs(pc['corrected_garbage'] - 100) < 2, pc
        assert pc['pass'] is True, pc
        # ruling 2026-09-04: garbage - filler is REPORT-ONLY
        assert 'garbage_within_tol' in pc and 'report-only' in pc['garbage_criterion']


def test_score_corrupt_control_passes_on_seq_axis_when_garbage_is_off():
    # filler = chk_frames - emitted is only exact with zero loss; perturb garbage well
    # outside tolerance and the control must STILL pass on the seq axis alone.
    with tempfile.TemporaryDirectory() as tmp:
        out = _ctrl_run(tmp, emitted=100000, frames=200000, gaps=100, gap1=100,
                        int_last=1000, garbage=105000,   # 5000 off the filler pedestal
                        meta_extra='fill=1516 gap=60000 skip_every=0 corrupt_every=1000\n'
                                   'background_gap_per_emitted=0')
        pc = seqbist_score.score(out)['positive_control']
        assert pc['garbage_within_tol'] is False, pc
        assert pc['pass'] is True, pc


def test_score_non_cumulative_counters_do_not_trigger_uninformative():
    # chk_int_last re-latches (moves both ways) and starve_clk is a free-running wrapping
    # clock; neither is a mid-window clear. Real ctrlA-m tripped on both.
    with tempfile.TemporaryDirectory() as tmp:
        readings = []
        for i in range(18):
            f = 10000 * i
            readings.append(_base_row(i, f, {
                'reg_0x104': f, 'reg_0x124': f, 'chk_frames': f, 'chk_good': f,
                'chk_last_seq': f, 'chk_gap_events': 0, 'chk_lost_slots': 0,
                'chk_int_last': 950 if i % 2 else 3,          # swings both ways
                'starve_clk': (4000000000 + i * 300000000) % (2**32),  # wraps
                'max_len': 0xFFFFFFFF if i % 3 else 5,
            }))
        out = _write_run(tmp, readings, 'fill=1516 gap=73384 skip_every=0 corrupt_every=0')
        s = seqbist_score.score(out)
        assert not any('negative delta' in r for r in s['reasons']), s['reasons']
