"""test_txfix_rig_scripts.py -- Task 4 (T0c) rig scripts, DRY=1 only. ABSOLUTELY NO board contact:
every subprocess here runs with DRY=1 and a PATH shim that replaces `ssh`/`scp` with a fake binary
that logs its invocation and exits 1 -- if any script under test tries to actually reach the network
in DRY mode, the test catches it (empty shim log == proven zero board contact), rather than trusting
the script's own [dry] print. SENTINEL_STOP is asserted present with an UNCHANGED mtime before and
after every run in this file.
"""
import hashlib
import os
import stat
import subprocess
import sys
import tempfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
D = os.path.abspath(os.path.join(HERE, '..'))          # two_jup/
ROOT = os.path.abspath(os.path.join(D, '..'))           # repo root
SKIDFIX = os.path.join(D, 'skidfix')
SENTINEL = os.path.expanduser('~/modem-status/SENTINEL_STOP')


def _make_shim(tmpdir):
    """A PATH dir with fake `ssh`/`scp` that log their invocation to shim.log and exit 1.
    Any real network attempt shows up here even if the script under test never checks its
    exit code."""
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
    env['DRY'] = '1'
    if extra:
        env.update(extra)
    return env, log


# These tests are coupled to the operator's out-of-service hold: they assert that a DRY run
# leaves ~/modem-status/SENTINEL_STOP untouched. Once the operator lifts the hold (removes the
# file) that assertion is no longer meaningful, and a missing sentinel is NOT a test failure --
# it is a rig-state precondition this suite cannot satisfy. Skip, so the suite still runs green
# on a host with the link back in service, and so a genuine failure here always means a real
# defect. The pre/post mtime comparison inside _run keeps its hard assert: if the sentinel is
# present when a run starts, it must still be present and unchanged when it ends.
requires_sentinel = pytest.mark.skipif(
    not os.path.exists(SENTINEL),
    reason=f'SENTINEL_STOP absent ({SENTINEL}) -- operator hold lifted; '
           'the sentinel-hold assertions have no subject on this host',
)


def _require_sentinel():
    """Skip (not fail) the calling test when the operator hold is not in place."""
    if not os.path.exists(SENTINEL):
        pytest.skip(f'SENTINEL_STOP absent ({SENTINEL}) -- operator hold lifted')


def _sentinel_mtime():
    assert os.path.exists(SENTINEL), 'SENTINEL_STOP must exist before/after every DRY run'
    return os.stat(SENTINEL).st_mtime


def _run(cmd, env, cwd=None, timeout=180):
    _require_sentinel()
    pre = _sentinel_mtime()
    r = subprocess.run(cmd, env=env, cwd=cwd or D, capture_output=True, text=True, timeout=timeout)
    post = _sentinel_mtime()
    assert pre == post, f'SENTINEL_STOP mtime changed: {pre} -> {post}'
    return r


def _shim_log_empty(log):
    return (not os.path.exists(log)) or os.stat(log).st_size == 0


def _assert_no_network(r, log):
    assert _shim_log_empty(log), f'network shim was called (real ssh/scp attempted): {open(log).read() if os.path.exists(log) else ""}'


# -------------------------------------------------------------------------
# flash_148_txfix.sh (via txfix_flash_go.sh, env like launch_rig_unit.sh would set)
# -------------------------------------------------------------------------

def _make_banked_bb(tag, content=b'x'):
    """Drop a throwaway BOOT.BIN under boot_known_good/ with a real md5 so the flash chain's
    local precondition check ([1/5], not a board action) can pass. Returns (md5-12, path)."""
    md5 = hashlib.md5(content).hexdigest()[:12]
    path = os.path.join(ROOT, 'boot_known_good', f'BOOT.BIN.148.{tag}.{md5}')
    with open(path, 'wb') as f:
        f.write(content)
    return md5, path


def test_flash_chain_dry_stage_lines_and_ok():
    with tempfile.TemporaryDirectory() as tmp:
        md5, bb = _make_banked_bb('txfixTESTpy')
        try:
            env, log = _env(tmp, {'FLASH_MD5': md5, 'FLASH_TAG': 'txfixTESTpy'})
            r = _run(['bash', os.path.join(SKIDFIX, 'txfix_flash_go.sh')], env)
            out = r.stdout + r.stderr
            assert r.returncode == 0, out
            for stage in ('[1/5]', '[2/5]', '[3/5]', '[4/5]', '[5/5]'):
                assert stage in out, f'missing {stage}\n{out}'
            assert '[dry]' in out
            assert 'FLASH_DDRCAP2_OK' in out
            _assert_no_network(r, log)
        finally:
            os.remove(bb)


def test_flash_chain_requires_flash_md5_and_flash_tag():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp)  # no FLASH_MD5/FLASH_TAG set -> ${VAR:?} must fail fast, no board touched
        r = _run(['bash', os.path.join(SKIDFIX, 'flash_148_txfix.sh')], env)
        assert r.returncode != 0
        _assert_no_network(r, log)


def test_flash_bak_default_is_638b():
    with tempfile.TemporaryDirectory() as tmp:
        md5, bb = _make_banked_bb('txfixTESTpy2')
        try:
            env, log = _env(tmp, {'FLASH_MD5': md5, 'FLASH_TAG': 'txfixTESTpy2'})
            r = _run(['bash', os.path.join(SKIDFIX, 'flash_148_txfix.sh')], env)
            out = r.stdout + r.stderr
            assert 'expect 638b36de3493' in out
            _assert_no_network(r, log)
        finally:
            os.remove(bb)


# -------------------------------------------------------------------------
# flash_146_txfix.sh (via txfix_flash146_go.sh) -- the 146 / TMR-vendh lineage chain.
# Same rules as the 148 chain: DRY=1 + ssh/scp PATH shim, and the shim log must stay
# empty (proven zero contact with EITHER board -- this chain talks to 10.0.0.146 and
# to 10.0.0.148, its gate instrument, plus restore_known_good.sh /
# health_probe_reset_aware.sh which open their own ssh sessions).
# -------------------------------------------------------------------------

FLASH146 = os.path.join(SKIDFIX, 'flash_146_txfix.sh')
GO146 = os.path.join(SKIDFIX, 'txfix_flash146_go.sh')
VENDH_BANK = os.path.join(ROOT, 'jupiter_byte_tmr146_gates', 'variants_placement',
                          'v_endh', 'BOOT.BIN')


def _make_banked_bb_146(tag, content=b'y'):
    """Throwaway boot_known_good/BOOT.BIN.146.<tag>.<md5-12> so the chain's LOCAL
    [1/6] precondition (a file check, not a board action) can pass."""
    md5 = hashlib.md5(content).hexdigest()[:12]
    path = os.path.join(ROOT, 'boot_known_good', f'BOOT.BIN.146.{tag}.{md5}')
    with open(path, 'wb') as f:
        f.write(content)
    return md5, path


def _fake_rollback_bank(tmpdir, md5_of=b'z'):
    """A stand-in ROLLBACK_BANK whose md5-12 the caller can pin FLASH_BAK to, so the
    A0 gate can be exercised without depending on the real v_endh BOOT.BIN being
    present on this host."""
    path = os.path.join(tmpdir, 'rollback_BOOT.BIN')
    with open(path, 'wb') as f:
        f.write(md5_of)
    return hashlib.md5(md5_of).hexdigest()[:12], path


def test_flash146_dry_all_stages_and_ok():
    with tempfile.TemporaryDirectory() as tmp:
        md5, bb = _make_banked_bb_146('txfixTEST146')
        bak, bank = _fake_rollback_bank(tmp)
        try:
            env, log = _env(tmp, {'FLASH_MD5': md5, 'FLASH_TAG': 'txfixTEST146',
                                  'FLASH_BAK': bak, 'ROLLBACK_BANK': bank})
            r = _run(['bash', GO146], env)
            out = r.stdout + r.stderr
            assert r.returncode == 0, out
            for stage in ('[1/6]', '[2/6]', '[3/6]', '[4/6]', '[5/6]', '[6/6]'):
                assert stage in out, f'missing {stage}\n{out}'
            assert '[dry]' in out
            assert 'HEALTH_GATE_PASS' in out, out
            assert 'FLASH_146T_DONE' in out, out
            _assert_no_network(r, log)
        finally:
            os.remove(bb)


def test_flash146_requires_flash_md5_and_flash_tag():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp)  # no FLASH_MD5/FLASH_TAG -> ${VAR:?} fails fast
        r = _run(['bash', FLASH146], env)
        assert r.returncode != 0
        _assert_no_network(r, log)


def test_flash146_default_bak_is_ec414d2df8bc():
    """The default restore point is the image 146 actually runs (ec414d2df8bc), and
    with that default the A0 gate must resolve to the banked v_endh BOOT.BIN."""
    src = open(FLASH146).read()
    assert 'BAK=${FLASH_BAK:-ec414d2df8bc}' in src
    assert 'variants_placement/v_endh/BOOT.BIN' in src


def test_flash146_a0_gate_rejects_wrong_rollback_bank():
    """The vendh script only checked that a nemo-side file EXISTED -- and the file it
    checked is 4be9286ca111, not the ec414d2df8bc restore point. The md5 equality
    check must reject a bank whose content is not $FLASH_BAK, before any board touch."""
    with tempfile.TemporaryDirectory() as tmp:
        md5, bb = _make_banked_bb_146('txfixTEST146b')
        _, bank = _fake_rollback_bank(tmp, b'not-the-rollback-image')
        try:
            env, log = _env(tmp, {'FLASH_MD5': md5, 'FLASH_TAG': 'txfixTEST146b',
                                  'FLASH_BAK': 'ec414d2df8bc', 'ROLLBACK_BANK': bank})
            r = _run(['bash', FLASH146], env)
            out = r.stdout + r.stderr
            assert r.returncode != 0, out
            assert 'A0 gate' in out, out
            assert '[2/6]' not in out, f'aborted too late -- reached staging\n{out}'
            _assert_no_network(r, log)
        finally:
            os.remove(bb)


def test_flash146_creates_the_missing_bak_after_verifying_the_live_image():
    """146 has no /root/BOOT.BIN.ec414d2df8bc.bak today. [2/6] must verify the LIVE
    /boot/BOOT.BIN md5 first and only then copy it -- never copy blind."""
    src = open(FLASH146).read()
    i_verify = src.index('md5sum /boot/BOOT.BIN | grep -q ^${BAK}')
    i_copy = src.index('cp /boot/BOOT.BIN /root/BOOT.BIN.${BAK}.bak')
    i_reverify = src.index('md5sum /root/BOOT.BIN.${BAK}.bak | grep -q ^${BAK}')
    assert i_verify < i_copy < i_reverify, 'verify -> copy -> re-verify order broken'
    assert 'cp /root/BOOT.BIN.${BAK}.bak /boot/BOOT.BIN' in src, 'rollback must restore from the parameterised .bak'


def test_flash146_no_unguarded_helper_invocations():
    """restore_known_good.sh / health_probe_reset_aware.sh / the 0x1C0 direct_reg_access
    read all open their own ssh sessions. They may only be reached through the
    DRY-guarded wrappers (bringup / health_rx / read1c0), never called directly."""
    src = open(FLASH146).read()
    # Each helper must be invoked exactly once, and that single invocation must sit in
    # the DRY-guarded wrapper section -- i.e. ABOVE the first stage marker. Anything
    # below `=== [1/6]` runs unconditionally in the staged flow and would touch a board.
    first_stage = src.index('echo "=== [1/6]')
    for helper, wrapper in (('bash "$D/restore_known_good.sh"', 'bringup(){'),
                            ('bash "$D/health_probe_reset_aware.sh"', 'health_rx(){'),
                            ('DRA=/sys/kernel/debug/iio', 'read1c0(){')):
        assert src.count(helper) == 1, f'{helper} invoked {src.count(helper)} times (want 1)'
        i = src.index(helper)
        assert i < first_stage, f'{helper} is called outside the DRY-guarded wrapper section'
        w = src.index(wrapper)
        assert w < i, f'{helper} does not sit inside {wrapper}'
        # the wrapper it sits in must itself test DRY before reaching the helper
        assert 'DRY' in src[w:i], f'{wrapper} does not check DRY before calling {helper}'


def test_fetch_146_readme_row_anchor_resolves():
    """jupiter_byte_txfix_fetch.sh inserts a BOARD=146 row after the last existing
    BOOT.BIN.146.* row in boot_known_good/README.md. Run the script's OWN grep against
    the real README so a broken/over-escaped pattern is caught before a build lands."""
    src = open(os.path.join(ROOT, 'jupiter_byte_txfix_fetch.sh')).read()
    line = [l for l in src.splitlines() if l.strip().startswith('LASTROW=')]
    assert len(line) == 1, line
    pat = line[0].split("grep -n '", 1)[1].rsplit("'", 1)[0]
    readme = os.path.join(ROOT, 'boot_known_good', 'README.md')
    r = subprocess.run(['grep', '-n', pat, readme], capture_output=True, text=True)
    assert r.returncode == 0 and r.stdout.strip(), (
        f'the fetch script\'s 146-row pattern matches nothing in README.md: {pat!r}')
    last = int(r.stdout.strip().splitlines()[-1].split(':', 1)[0])
    assert last > 0


def test_fetch_already_banked_does_not_skip_readme_and_md5sums():
    """A re-run after a half-failed fetch must still reach the README/MD5SUMS/verify
    steps -- the old `exit 0` on ALREADY_BANKED made the obvious repair a silent no-op."""
    src = open(os.path.join(ROOT, 'jupiter_byte_txfix_fetch.sh')).read()
    i_banked = src.index('TXFIX_FETCH_ALREADY_BANKED')
    tail = src[i_banked:]
    # no `exit 0` between the already-banked message and the README append
    i_readme = tail.index('TXFIX_FETCH_README_ROW_ALREADY_PRESENT')
    assert 'exit 0' not in tail[:i_readme], 'ALREADY_BANKED still short-circuits the row steps'
    assert 'TXFIX_FETCH_DONE' in tail


def test_flash146_live_md5_bad_is_visible():
    """LIVE_MD5_BAD must not be swallowed by the BAK_OK grep."""
    src = open(FLASH146).read()
    i = src.index('LIVE_MD5_BAD')
    j = src.index('grep -q BAK_OK', i)
    assert 'tee /dev/stderr' in src[i:j], 'LIVE_MD5_BAD is swallowed before it can be seen'


def test_flash146_rails_carried_from_vendh_chain():
    """Every rail the 146 chain enforces today must still be present."""
    src = open(FLASH146).read()
    for rail in ('A=10.0.0.146', 'RX=10.0.0.148',
                 'nakstat', 'NAK" = "4"',
                 'fsync>=1100', 'clean=[0-9]+',
                 'for pass in 1 2;', 'ONE re-bring-up',
                 'no witness gpio on the TMR lineage'):
        assert rail in src, f'rail lost: {rail}'


# -------------------------------------------------------------------------
# beat_timeline.sh (via beat_timeline_go.sh)
# -------------------------------------------------------------------------

def test_beat_timeline_dry_ok_and_three_bursts():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'btl_out')
        env, log = _env(tmp, {'OUT': out_dir, 'SECS': '420'})
        r = _run(['bash', os.path.join(D, 'beat_timeline_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'TIMELINE_OK secs=420 gaps=0' in out, out
        assert 'BURSTS n=3' in out, out
        assert os.path.exists(os.path.join(out_dir, 'errps.csv'))
        assert os.path.exists(os.path.join(out_dir, 'meta.txt'))
        meta = open(os.path.join(out_dir, 'meta.txt')).read()
        assert 'pre_capTAP=' in meta and 'post_capTAP=' in meta and 'gaps_gt_2s=' in meta
        _assert_no_network(r, log)


def test_beat_timeline_csv_is_beat_detect_compatible():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'btl_out2')
        env, log = _env(tmp, {'OUT': out_dir, 'SECS': '420'})
        r = _run(['bash', os.path.join(D, 'beat_timeline.sh')], env)
        assert r.returncode == 0, r.stdout + r.stderr
        r2 = subprocess.run([sys.executable, os.path.join(D, 'beat_detect.py'),
                              os.path.join(out_dir, 'errps.csv'), '--per-second'],
                             capture_output=True, text=True)
        assert 'BURSTS n=3' in r2.stdout, r2.stdout
        _assert_no_network(r, log)


# -------------------------------------------------------------------------
# txfix_witness_go.sh
# -------------------------------------------------------------------------

def test_witness_dry_positive_and_negative_controls():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'wit_out')
        env, log = _env(tmp, {'VAR': 'testF3', 'OUT': out_dir})
        r = _run(['bash', os.path.join(D, 'txfix_witness_go.sh')], env, timeout=300)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert '[dry]' in out
        lines = [l for l in out.splitlines() if l.startswith('WITNESS_testF3 ')]
        assert len(lines) == 2, out
        assert any('stalls=6 ' in l for l in lines), out   # positive control (mid.bin) -- see report re: plan's stale "stalls=4"
        assert any('stalls=0 ' in l for l in lines), out   # synthetic all-quiet control
        for l in lines:
            assert 'tier2=' in l and 'credited=' in l
        _assert_no_network(r, log)


# -------------------------------------------------------------------------
# arm148_mode1.sh's ONE change: GOLD is now an input
# -------------------------------------------------------------------------

def test_arm148_mode1_gold_is_env_input():
    src = open(os.path.join(D, 'arm148_mode1.sh')).read()
    assert 'GOLD=${GOLD:-BCF94856}' in src
    # Exactly one behavioural change from the original -- everything else untouched.
    # `GOLD=` must appear EXACTLY once: the single env-overridable assignment. A second
    # occurrence would mean a stray reassignment that could silently shadow the operator's
    # override and re-hardcode the golden word. (The old form of this assert was
    # `count == 1 or 'GOLD=${GOLD:-BCF94856}' in src`, which the line above already
    # guarantees -- it was a tautology and could never fail.)
    assert src.count('GOLD=') == 1, f"expected exactly one 'GOLD=' assignment, found {src.count('GOLD=')}"


# -------------------------------------------------------------------------
# sentinel present at import time too (fails loudly if the operator's hold vanished)
# -------------------------------------------------------------------------

@requires_sentinel
def test_sentinel_present():
    assert os.path.exists(SENTINEL)
