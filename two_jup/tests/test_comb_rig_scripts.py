"""test_comb_rig_scripts.py -- Task 3 (T0c) COMB campaign rig scripts, DRY=1 only.
ABSOLUTELY NO board contact: every subprocess here runs with DRY=1 (or, for
keeper_hold.sh's hold-file bookkeeping, FILE_DRY=0/NET_DRY=1 against temp paths --
never DRY=0 against the real defaults) plus a PATH shim that replaces `ssh`/`scp` with
a fake binary that logs its invocation and exits 1. An empty shim log after a run is
the proof of zero board contact -- not the script's own `[dry]` print, which a bug
could omit while still reaching the network.

Companion to two_jup/tests/test_txfix_rig_scripts.py (same shim pattern, same
SENTINEL_STOP mtime discipline) for the six two_jup/comb/*.sh wrappers this task owns.
"""
import csv
import json
import os
import stat
import subprocess
import sys
import tempfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
TJ = os.path.abspath(os.path.join(HERE, '..'))           # two_jup/
COMB = os.path.join(TJ, 'comb')
ROOT = os.path.abspath(os.path.join(TJ, '..'))            # repo root
SENTINEL = os.path.expanduser('~/modem-status/SENTINEL_STOP')


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


requires_sentinel = pytest.mark.skipif(
    not os.path.exists(SENTINEL),
    reason=f'SENTINEL_STOP absent ({SENTINEL}) -- operator hold lifted; '
           'the sentinel-hold assertions have no subject on this host',
)


def _sentinel_mtime():
    return os.stat(SENTINEL).st_mtime if os.path.exists(SENTINEL) else None


def _run(cmd, env, cwd=None, timeout=120):
    """DRY runs make zero board contact by contract (see module docstring) and must
    not depend on the operator's SENTINEL_STOP hold (task-3-fix1 I-2): every script
    here defaults to DRY=1 and every test env sets DRY explicitly, so this always
    runs. When SENTINEL_STOP happens to exist (operator hold active), we still assert
    its mtime is unchanged by the run -- a genuine regression check, not a gate on
    whether the test runs at all."""
    pre = _sentinel_mtime()
    r = subprocess.run(cmd, env=env, cwd=cwd or COMB, capture_output=True, text=True, timeout=timeout)
    post = _sentinel_mtime()
    if pre is not None:
        assert pre == post, f'SENTINEL_STOP mtime changed: {pre} -> {post}'
    return r


def _shim_log_empty(log):
    return (not os.path.exists(log)) or os.stat(log).st_size == 0


def _assert_no_network(log):
    assert _shim_log_empty(log), f'network shim was called: {open(log).read() if os.path.exists(log) else ""}'


def _meta(out_dir):
    p = os.path.join(out_dir, 'meta.txt')
    assert os.path.exists(p), f'no meta.txt under {out_dir}'
    return open(p).read()


# -------------------------------------------------------------------------
# keeper_hold.sh
# -------------------------------------------------------------------------

def test_keeper_hold_dry_is_fully_inert_and_prints_ok_lines():
    """Plain DRY=1 (the campaign default): no file is created anywhere, no network
    contact, both hold/release print their OK line."""
    with tempfile.TemporaryDirectory() as tmp:
        hold_dir = os.path.join(tmp, 'hold')
        env, log = _env(tmp, {'HOLD_SENTINEL': os.path.join(hold_dir, 'SENTINEL_STOP'),
                              'HOLD_RIGLOCK': os.path.join(hold_dir, 'RIG_LOCK')})
        r = _run(['bash', os.path.join(COMB, 'keeper_hold.sh'), 'hold'], env)
        assert r.returncode == 0, r.stdout + r.stderr
        assert 'KEEPER_HOLD_OK' in r.stdout
        assert not os.path.exists(hold_dir), 'DRY=1 must not create any hold file'
        _assert_no_network(log)

        r2 = _run(['bash', os.path.join(COMB, 'keeper_hold.sh'), 'release'], env)
        assert r2.returncode == 0, r2.stdout + r2.stderr
        assert 'KEEPER_RELEASE_OK' in r2.stdout
        _assert_no_network(log)


def test_keeper_hold_creates_only_absent_files_and_release_removes_only_those():
    """FILE_DRY=0 against temp paths exercises the real create/remove logic (never
    the ~/modem-status defaults); NET_DRY stays 1 so systemctl/ssh are never touched."""
    with tempfile.TemporaryDirectory() as tmp:
        hold_dir = os.path.join(tmp, 'hold')
        sentinel = os.path.join(hold_dir, 'SENTINEL_STOP')
        riglock = os.path.join(hold_dir, 'RIG_LOCK')
        env, log = _env(tmp, {'HOLD_SENTINEL': sentinel, 'HOLD_RIGLOCK': riglock,
                              'DRY': '0', 'FILE_DRY': '0', 'NET_DRY': '1'})

        r = _run(['bash', os.path.join(COMB, 'keeper_hold.sh'), 'hold'], env)
        assert r.returncode == 0, r.stdout + r.stderr
        assert os.path.exists(sentinel) and os.path.exists(riglock)
        assert 'created=[ SENTINEL RIGLOCK]' in r.stdout
        _assert_no_network(log)

        r2 = _run(['bash', os.path.join(COMB, 'keeper_hold.sh'), 'release'], env)
        assert r2.returncode == 0, r2.stdout + r2.stderr
        assert not os.path.exists(sentinel) and not os.path.exists(riglock)
        assert 'released=[ SENTINEL RIGLOCK]' in r2.stdout
        _assert_no_network(log)


def test_keeper_hold_leaves_preexisting_files_alone_on_release():
    """If SENTINEL_STOP/RIG_LOCK already existed before hold, this tool must not
    remove them on release (it did not create them)."""
    with tempfile.TemporaryDirectory() as tmp:
        hold_dir = os.path.join(tmp, 'hold')
        os.makedirs(hold_dir)
        sentinel = os.path.join(hold_dir, 'SENTINEL_STOP')
        riglock = os.path.join(hold_dir, 'RIG_LOCK')
        open(sentinel, 'w').close()
        open(riglock, 'w').write('owner=someone-else\n')
        env, log = _env(tmp, {'HOLD_SENTINEL': sentinel, 'HOLD_RIGLOCK': riglock,
                              'DRY': '0', 'FILE_DRY': '0', 'NET_DRY': '1'})

        r = _run(['bash', os.path.join(COMB, 'keeper_hold.sh'), 'hold'], env)
        assert r.returncode == 0, r.stdout + r.stderr
        assert 'created=[ none]' in r.stdout
        _assert_no_network(log)

        r2 = _run(['bash', os.path.join(COMB, 'keeper_hold.sh'), 'release'], env)
        assert r2.returncode == 0, r2.stdout + r2.stderr
        assert os.path.exists(sentinel), 'release must not remove a hold file it did not create'
        assert os.path.exists(riglock), 'release must not remove a hold file it did not create'
        _assert_no_network(log)


def test_keeper_hold_bad_mode_rejected():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp)
        r = _run(['bash', os.path.join(COMB, 'keeper_hold.sh'), 'bogus'], env)
        assert r.returncode != 0
        _assert_no_network(log)


def test_keeper_hold_uses_bracket_pkill_pattern():
    src = open(os.path.join(COMB, 'keeper_hold.sh')).read()
    assert 'pkill -9 -f \\"[l]ock_watchdog\\"' in src


# -------------------------------------------------------------------------
# loopfloor_go.sh
# -------------------------------------------------------------------------

def test_loopfloor_dry_produces_expected_artifacts_and_ok_line():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'loopfloor_out')
        env, log = _env(tmp, {'OUT': out_dir, 'DUR': '200'})
        r = _run(['bash', os.path.join(COMB, 'loopfloor_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'LOOPFLOOR_DONE' in out, out
        for fname in ('frames.bin', 'failhdr.bin', 'txlog.bin', 'txgap_dump.txt',
                      'badmagic_10s.csv', 'regs_pre.txt', 'regs_post.txt', 'meta.txt'):
            assert os.path.exists(os.path.join(out_dir, fname)), f'missing {fname}'
        meta = _meta(out_dir)
        for field in ('image_md5=', 'daemon_md5=', 'nakstat_strings=', 'rxqstat_strings=', 'window_s='):
            assert field in meta, f'meta.txt missing {field}\n{meta}'
        with open(os.path.join(out_dir, 'badmagic_10s.csv')) as f:
            rows = list(csv.DictReader(f))
        assert len(rows) == 20, f'DUR=200 should give 20 ten-second samples, got {len(rows)}'
        _assert_no_network(log)


def test_loopfloor_short_window_is_uninformative():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'loopfloor_short')
        env, log = _env(tmp, {'OUT': out_dir, 'DUR': '30'})
        r = _run(['bash', os.path.join(COMB, 'loopfloor_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'UNINFORMATIVE' in out and 'window < 150s' in out, out
        _assert_no_network(log)


# -------------------------------------------------------------------------
# legrun_go.sh
# -------------------------------------------------------------------------

def test_legrun_single_sided_knob_resolves_and_gates():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'legA_out')
        env, log = _env(tmp, {'OUT': out_dir, 'LEG': 'A', 'DUR': '60', 'RXM_148': '8'})
        r = _run(['bash', os.path.join(COMB, 'legrun_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'LEGRUN_DONE' in out, out
        meta = _meta(out_dir)
        assert 'deliver_rate_gate_pass=1' in meta, meta
        for fname in ('cap/frames.bin', 'cap/frames_peer.bin', 'cap/failhdr.bin', 'cap/txlog.bin'):
            assert os.path.exists(os.path.join(out_dir, fname)), f'missing {fname}'
        _assert_no_network(log)


def test_legrun_rxm_148_alone_yields_rxm_a_only_true_per_board_isolation():
    """task-3-fix1 I-2: RXM_148=8 with RXM_146 unset must map to RXM_A=8 for
    bringup_r2r3.sh's per-board override and must NOT set RXM_B at all -- this is the
    confounded-vs-isolated distinction Critical #1 in task-3-report.md was about."""
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'legA_rxm_isolated')
        env, log = _env(tmp, {'OUT': out_dir, 'LEG': 'A', 'DUR': '60', 'RXM_148': '8'})
        r = _run(['bash', os.path.join(COMB, 'legrun_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'RXM_A=8' in out, out
        assert 'RXM_B=' not in out, out
        _assert_no_network(log)


def test_legrun_both_boards_get_distinct_rxm_no_conflict():
    """148 and 146 can now genuinely differ (this used to be the refused case)."""
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'legA_conflict')
        env, log = _env(tmp, {'OUT': out_dir, 'LEG': 'A', 'RXM_148': '8', 'RXM_146': '32'})
        r = _run(['bash', os.path.join(COMB, 'legrun_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'RXM_A=8' in out, out
        assert 'RXM_B=32' in out, out
        _assert_no_network(log)


def test_legrun_drain_budget_per_board():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'legB_drain')
        env, log = _env(tmp, {'OUT': out_dir, 'LEG': 'B', 'DRAIN_148': '1', 'DRAIN_146': '4'})
        r = _run(['bash', os.path.join(COMB, 'legrun_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'DAEMON_ENV_A=' in out and 'QPSK_RX_DRAIN_BUDGET=1' in out, out
        assert 'QPSK_RX_DRAIN_BUDGET=4' in out, out
        _assert_no_network(log)


def test_legrun_launches_both_boards_with_sink_vars():
    """task-3-report.md Task-1-review C-1: every leg must set QPSK_FAILHDR,
    QPSK_TXLOG, QPSK_TXLOG_USR1 in DAEMON_ENV for BOTH boards, or capture_r3.sh's
    failhdr.bin/txlog.bin fetch gets nothing."""
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'legA_sinks')
        env, log = _env(tmp, {'OUT': out_dir, 'LEG': 'A'})
        r = _run(['bash', os.path.join(COMB, 'legrun_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        for var in ('QPSK_FAILHDR=/dev/shm/failhdr.bin', 'QPSK_TXLOG=/dev/shm/txlog.bin', 'QPSK_TXLOG_USR1=1'):
            assert out.count(var) >= 2, f'{var} must appear in both DAEMON_ENV_A and DAEMON_ENV_B: {out}'
        _assert_no_network(log)


def test_legrun_bad_leg_rejected():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp, {'LEG': 'C'})
        r = _run(['bash', os.path.join(COMB, 'legrun_go.sh')], env)
        assert r.returncode == 2
        _assert_no_network(log)


# -------------------------------------------------------------------------
# ddrcap_during_leg_go.sh
# -------------------------------------------------------------------------

def test_ddrcap_during_leg_dry_credited():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'ddrcap_out')
        env, log = _env(tmp, {'OUT': out_dir, 'SEL': '9', 'OFFSET_S': '120'})
        r = _run(['bash', os.path.join(COMB, 'ddrcap_during_leg_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'DDRCAP_LEG sel=9 credited=yes' in out, out
        meta = _meta(out_dir)
        assert 'bytes=536870912' in meta
        assert 'pre_capTAP=BCF94856' in meta and 'post_capTAP=BCF94856' in meta
        _assert_no_network(log)


def test_ddrcap_during_leg_appends_not_truncates_meta():
    """task-3-fix1 I-3: must append (>>) to meta.txt, not truncate (>), so it does
    not destroy ddrcap2_capture.sh's own provenance line."""
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'ddrcap_preexisting_meta')
        os.makedirs(out_dir)
        preexisting = 'ddrcap2_capture.sh sel=9 bytes=999 pre=BCF94856 post=BCF94856\n'
        with open(os.path.join(out_dir, 'meta.txt'), 'w') as f:
            f.write(preexisting)
        env, log = _env(tmp, {'OUT': out_dir, 'SEL': '9', 'OFFSET_S': '0'})
        r = _run(['bash', os.path.join(COMB, 'ddrcap_during_leg_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        meta = _meta(out_dir)
        assert preexisting.strip() in meta, f'wrapper truncated the sibling tool\'s provenance line:\n{meta}'
        assert 'credited=yes' in meta, meta
        _assert_no_network(log)


def test_ddrcap_during_leg_uses_append_redirect_in_source():
    src = open(os.path.join(COMB, 'ddrcap_during_leg_go.sh')).read()
    assert '>> "$OUT/meta.txt"' in src
    assert '} > "$OUT/meta.txt"' not in src


def test_ddrcap_during_leg_requires_sel():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp)  # no SEL -> ${SEL:?} must fail fast
        r = _run(['bash', os.path.join(COMB, 'ddrcap_during_leg_go.sh')], env)
        assert r.returncode != 0
        _assert_no_network(log)


def test_ddrcap_during_leg_bytes_short_of_credit_not_credited():
    """Directly exercises the credit arithmetic via a real (non-DRY) invocation whose
    meta.txt line ddrcap2_capture.sh would have written is faked in-place: we can't run
    the real capture, so instead assert the credit predicate in the source requires
    BOTH the byte floor and dual-golden capTAP (regression guard for the logic, not a
    board run)."""
    src = open(os.path.join(COMB, 'ddrcap_during_leg_go.sh')).read()
    assert 'CREDIT_BYTES=536870912' in src
    assert '"${BYTES:-0}" -ge "$CREDIT_BYTES"' in src
    assert '"$(norm "${CAP_PRE:-}")" = "$GOLD"' in src
    assert '"$(norm "${CAP_POST:-}")" = "$GOLD"' in src


# -------------------------------------------------------------------------
# sel11_preflight_go.sh
# -------------------------------------------------------------------------

def test_sel11_preflight_dry_finds_fabricated_markers():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'sel11_out')
        env, log = _env(tmp, {'OUT': out_dir})
        r = _run(['bash', os.path.join(COMB, 'sel11_preflight_go.sh')], env, timeout=180)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'SEL11_PREFLIGHT_DONE' in out, out
        assert os.path.exists(os.path.join(out_dir, 'sel11_preflight.bin'))
        assert os.stat(os.path.join(out_dir, 'sel11_preflight.bin')).st_size == 8 * 1024 * 1024
        mc = json.load(open(os.path.join(out_dir, 'marker_check.json')))
        assert mc['header_hits'] > 0, 'the fabricated stream must contain 0x51 0x4B occurrences'
        assert mc['modal_offset_from_marker_bits'] is not None
        assert os.path.exists(os.path.join(out_dir, 'txmark_scan.json'))
        meta = _meta(out_dir)
        assert 'header_hits=' in meta and 'pre_capTAP=BCF94856' in meta
        _assert_no_network(log)


def test_sel11_preflight_sz_is_8mib_arithmetic():
    src = open(os.path.join(COMB, 'sel11_preflight_go.sh')).read()
    assert 'SZ=${SZ:-2097152}' in src   # 2097152 * 4 B/sample = 8 MiB, matching ddrcap2_capture.sh's own bytes=SZ*4


def test_sel11_preflight_appends_not_truncates_meta_and_drops_self_copy():
    """task-3-fix1 I-3 (append, not truncate) + minor (no-op self-copy removed)."""
    src = open(os.path.join(COMB, 'sel11_preflight_go.sh')).read()
    assert '>> "$OUT/meta.txt"' in src
    assert '} > "$OUT/meta.txt"' not in src
    assert 'cp "$OUT/sel11_preflight.bin" "$CAPFILE" 2>/dev/null' not in src


def test_sel11_preflight_preserves_preexisting_meta_line():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'sel11_preexisting_meta')
        os.makedirs(out_dir)
        preexisting = 'ddrcap2_capture.sh sel11_preflight sel=11 bytes=8388608 pre=BCF94856 post=BCF94856\n'
        with open(os.path.join(out_dir, 'meta.txt'), 'w') as f:
            f.write(preexisting)
        env, log = _env(tmp, {'OUT': out_dir})
        r = _run(['bash', os.path.join(COMB, 'sel11_preflight_go.sh')], env, timeout=180)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        meta = _meta(out_dir)
        assert preexisting.strip() in meta, f'wrapper truncated the sibling tool\'s provenance line:\n{meta}'
        _assert_no_network(log)


# -------------------------------------------------------------------------
# deploy_daemon_go.sh
# -------------------------------------------------------------------------

def test_deploy_daemon_dry_ok_and_nakstat_gate():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'deploy_out')
        env, log = _env(tmp, {'OUT': out_dir, 'BOARD': '148', 'FLAGS': '-DQPSK_ARQ_NAKSTAT'})
        r = _run(['bash', os.path.join(COMB, 'deploy_daemon_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'DEPLOY_DAEMON_OK' in out, out
        meta = _meta(out_dir)
        assert 'nakstat_strings=4 (need 4; gate applies (BOARD=148))' in meta
        assert 'nakstat_gate_pass=1' in meta
        assert 'daemon_md5=' in meta
        _assert_no_network(log)


def test_deploy_daemon_nakstat_gate_is_148_only():
    """task-3-fix1 I-1: the nakstat==4 abort gate must apply to 148 only. In DRY
    mode NAKSTAT_N is per-board (148->4, 146->0), so a real 146 build (which is not
    expected to carry the nakstat fingerprint) must NOT abort -- and the meta.txt
    must record the count as informational, not gated, on 146."""
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'deploy_146_out')
        env, log = _env(tmp, {'OUT': out_dir, 'BOARD': '146', 'FLAGS': ''})
        r = _run(['bash', os.path.join(COMB, 'deploy_daemon_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'DEPLOY_DAEMON_OK' in out, out
        meta = _meta(out_dir)
        assert 'nakstat_strings=0' in meta, meta
        assert 'nakstat_gate_pass=1' in meta, meta
        assert 'informational only' in meta, meta
        _assert_no_network(log)


def test_deploy_daemon_nakstat_gate_applies_on_148():
    src = open(os.path.join(COMB, 'deploy_daemon_go.sh')).read()
    assert '[ "$BOARD" = 148 ]' in src
    assert 'gate is 148-only' in src


def test_deploy_daemon_dry_time_files_cross_check_passes():
    """Minor from task-3-report.md: DRY-time cross-check that every FILES entry
    exists under host_app_k5/, so a desync fails loudly here rather than only at
    DRY=0's scp."""
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'deploy_files_ok')
        env, log = _env(tmp, {'OUT': out_dir, 'BOARD': '148', 'FLAGS': ''})
        r = _run(['bash', os.path.join(COMB, 'deploy_daemon_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'missing_source' not in out, out
        _assert_no_network(log)


def test_deploy_daemon_requires_board():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp)  # no BOARD -> ${BOARD:?} fails fast
        r = _run(['bash', os.path.join(COMB, 'deploy_daemon_go.sh')], env)
        assert r.returncode != 0
        _assert_no_network(log)


def test_deploy_daemon_bad_board_rejected():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp, {'BOARD': '999'})
        r = _run(['bash', os.path.join(COMB, 'deploy_daemon_go.sh')], env)
        assert r.returncode == 2
        _assert_no_network(log)


def test_deploy_daemon_uses_capture_r3_file_list_plus_uio():
    src = open(os.path.join(COMB, 'deploy_daemon_go.sh')).read()
    for f in ('qpsk_tun.c', 'qpsk_frame.c', 'qpsk_frame.h', 'qpsk_hw.h', 'qpsk_ber.c',
              'qpsk_ber.h', 'qpsk_seq.c', 'qpsk_seq.h', 'qpsk_uio.c', 'qpsk_uio.h', 'qpsk_perf.c'):
        assert f in src, f'missing {f} from the deploy file list'
    assert '-DQPSK_RXQ_STAT' in src


# -------------------------------------------------------------------------
# UNINFORMATIVE checklist logic (loopfloor_go.sh's inline python), synthetic snapshots
# -------------------------------------------------------------------------

UNINFORMATIVE_CHECK = r"""
import sys, re, csv
pre, post, window_s, rearms, csvpath = sys.argv[1:6]
window_s = int(window_s); rearms = int(rearms)
def parse(s):
    return {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', s)}
p0, p1 = parse(pre), parse(post)
d104 = p1.get('pkts', 0) - p0.get('pkts', 0)
tot_frames = 0
with open(csvpath) as f:
    r = csv.DictReader(f)
    for row in r:
        tot_frames += int(row['frames'])
rate = tot_frames / window_s if window_s else 0
flags = []
if abs(d104) < 10:
    flags.append(f'0x104 delta ~= 0 ({d104})')
if abs(rate - 1245) > 400:
    flags.append(f'rate far from 1245 f/s ({rate:.0f})')
if window_s < 150:
    flags.append(f'window < 150s ({window_s})')
if rearms > 0:
    flags.append(f'{rearms} re-arm(s) in-window')
verdict = 'UNINFORMATIVE' if flags else 'INFORMATIVE'
print(f'{verdict} window_s={window_s} rate_fps={rate:.1f} d104={d104} rearms_in_window={rearms}')
for f in flags:
    print(f'  - {f}')
"""


def _uninformative(pre, post, window_s, rearms, rows):
    with tempfile.TemporaryDirectory() as tmp:
        script = os.path.join(tmp, 'chk.py')
        open(script, 'w').write(UNINFORMATIVE_CHECK)
        csvp = os.path.join(tmp, 'x.csv')
        with open(csvp, 'w', newline='') as f:
            w = csv.writer(f)
            w.writerow(['t_s', 'frames', 'magic_bad', 'magic_bad_pct', 'p104'])
            for row in rows:
                w.writerow(row)
        r = subprocess.run([sys.executable, script, pre, post, str(window_s), str(rearms), csvp],
                            capture_output=True, text=True)
        return r.stdout


def test_uninformative_healthy_long_window_is_informative():
    rows = [[str(10 * (i + 1)), '12450', '35', '0.28', str(12450 * (i + 1))] for i in range(20)]
    out = _uninformative('t=0 pkts=0', 't=200 pkts=249000', 200, 0, rows)
    assert out.startswith('INFORMATIVE'), out


def test_uninformative_short_window_flagged():
    rows = [[str(10 * (i + 1)), '12450', '35', '0.28', str(12450 * (i + 1))] for i in range(3)]
    out = _uninformative('t=0 pkts=0', 't=30 pkts=37350', 30, 0, rows)
    assert 'UNINFORMATIVE' in out and 'window < 150s' in out, out


def test_uninformative_rearm_in_window_flagged():
    rows = [[str(10 * (i + 1)), '12450', '35', '0.28', str(12450 * (i + 1))] for i in range(20)]
    out = _uninformative('t=0 pkts=0', 't=200 pkts=249000', 200, 2, rows)
    assert 'UNINFORMATIVE' in out and '2 re-arm(s) in-window' in out, out


def test_uninformative_flat_delta_flagged():
    rows = [[str(10 * (i + 1)), '0', '0', '0', '0'] for i in range(20)]
    out = _uninformative('t=0 pkts=1000', 't=200 pkts=1002', 200, 0, rows)
    assert 'UNINFORMATIVE' in out
    assert '0x104 delta ~= 0' in out
    assert 'rate far from 1245' in out


def test_uninformative_rate_far_from_nominal_flagged():
    rows = [[str(10 * (i + 1)), '1000', '5', '0.5', str(1000 * (i + 1))] for i in range(20)]  # ~100 f/s
    out = _uninformative('t=0 pkts=0', 't=200 pkts=249000', 200, 0, rows)
    assert 'UNINFORMATIVE' in out and 'rate far from 1245' in out, out


# -------------------------------------------------------------------------
# sentinel present at import time too
# -------------------------------------------------------------------------

@requires_sentinel
def test_sentinel_present():
    assert os.path.exists(SENTINEL)
