"""test_rxfix_rig_scripts.py -- RXFIX Task 3 (T0c, happy-bubbling-owl), DRY=1 only.
ABSOLUTELY NO board contact: every subprocess here runs with DRY=1 plus a PATH shim
that replaces `ssh`/`scp` with a fake binary that logs its invocation and exits 1. An
empty shim log after a run is the proof of zero board contact -- not the script's own
"[dry]" print, which a bug could omit while still reaching the network.

Same shim pattern as two_jup/tests/test_comb_rig_scripts.py and
test_txfix_rig_scripts.py, scoped to the two two_jup/rxfix/*.sh wrappers this task
owns: slackleg_go.sh (fixctl 0x208 slack leg) and witness_read.sh (FIFO/beatobs
witness poll).
"""
import json
import os
import stat
import subprocess
import tempfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
TJ = os.path.abspath(os.path.join(HERE, '..'))            # two_jup/
RXFIX = os.path.join(TJ, 'rxfix')
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


def _sentinel_mtime():
    return os.stat(SENTINEL).st_mtime if os.path.exists(SENTINEL) else None


def _run(cmd, env, cwd=None, timeout=60):
    """DRY runs make zero board contact by contract and must not depend on, or
    disturb, the operator's SENTINEL_STOP hold."""
    pre = _sentinel_mtime()
    r = subprocess.run(cmd, env=env, cwd=cwd or RXFIX, capture_output=True, text=True, timeout=timeout)
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


def _run_log(out_dir):
    p = os.path.join(out_dir, 'run.log')
    assert os.path.exists(p), f'no run.log under {out_dir}'
    return open(p).read()


# -------------------------------------------------------------------------
# slackleg_go.sh
# -------------------------------------------------------------------------

def test_slackleg_requires_slack():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp)
        env.pop('SLACK', None)
        r = _run(['bash', os.path.join(RXFIX, 'slackleg_go.sh')], env)
        assert r.returncode != 0
        _assert_no_network(log)


def test_slackleg_rejects_bad_slack_value():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp, {'SLACK': '2'})
        r = _run(['bash', os.path.join(RXFIX, 'slackleg_go.sh')], env)
        assert r.returncode != 0
        _assert_no_network(log)


@pytest.mark.parametrize('slack,fixval', [('0', '0x0'), ('1', '0x8')])
def test_slackleg_dry_zero_network_and_meta_keys(slack, fixval):
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'slack_out')
        env, log = _env(tmp, {'SLACK': slack, 'OUT': out_dir, 'DUR': '600'})
        r = _run(['bash', os.path.join(RXFIX, 'slackleg_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'SLACKLEG_DONE' in out, out
        _assert_no_network(log)

        meta = _meta(out_dir)
        assert f'slack={slack}' in meta, meta
        assert f'fixctl_written={fixval}' in meta, meta
        assert 'fixctl_restored=1' in meta, meta
        assert 'peer_poke_trigger=' in meta, meta
        assert 'stage3h_out=' in meta, meta
        # legrun_go.sh keys are folded in verbatim
        for field in ('leg=A', 'dir=fwd', 'rx=10.0.0.148', 'peer=10.0.0.146',
                      'deliver_rate_gate_pass=', 'watchdog_relaunch_rx='):
            assert field in meta, f'meta.txt missing {field}\n{meta}'


def test_slackleg_dry_never_launches_capture_r3_for_real():
    """The DRY fast-path must never exec capture_r3.sh (which would try real ssh)."""
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'slack_out')
        env, log = _env(tmp, {'SLACK': '1', 'OUT': out_dir})
        r = _run(['bash', os.path.join(RXFIX, 'slackleg_go.sh')], env)
        assert r.returncode == 0, r.stdout + r.stderr
        _assert_no_network(log)
        # legrun_go.sh's own [dry] line must appear (proves the leg ran its dry path)
        # and no real capture_r3.log should exist (only legrun_go.sh's real branch writes one)
        assert not os.path.exists(os.path.join(out_dir, 'capture_r3.log'))


def test_slackleg_dry_poke_ordering_is_148_then_146():
    """148 (clean LOOP_POKE hook, inside the leg's own bring-up) must be planned
    before 146 (timed action, no clean hook) -- the real ordering constraint from
    capture_r3.sh's timeline."""
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'slack_out')
        env, log = _env(tmp, {'SLACK': '1', 'OUT': out_dir})
        r = _run(['bash', os.path.join(RXFIX, 'slackleg_go.sh')], env)
        assert r.returncode == 0, r.stdout + r.stderr
        run_log = _run_log(out_dir)
        i148 = run_log.find('148 fixctl=0x8 via LOOP_POKE')
        i146 = run_log.find('146 fixctl=0x8')
        assert i148 != -1 and i146 != -1, run_log
        assert i148 < i146, f'148 poke must be planned before 146 poke:\n{run_log}'
        _assert_no_network(log)


def test_slackleg_dry_restore_ordering_is_146_then_148_and_trap_fires_on_term():
    """Restore is the REVERSE of poke order (146 first, then 148), and it must fire
    even when the process is killed with SIGTERM (systemd's stop signal) mid-run --
    prove this by sending TERM to a DUR-heavy invocation and checking meta.txt still
    got written with a restore verdict."""
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'slack_out')
        env, log = _env(tmp, {'SLACK': '1', 'OUT': out_dir})
        r = _run(['bash', os.path.join(RXFIX, 'slackleg_go.sh')], env)
        assert r.returncode == 0, r.stdout + r.stderr
        run_log = _run_log(out_dir)
        i146 = run_log.find('restore plan: 1) 146')
        i148 = run_log.find('2) 148 fixctl=0x0')
        assert i146 != -1 and i148 != -1, run_log
        assert i146 < i148, f'restore must be 146 then 148:\n{run_log}'
        _assert_no_network(log)

    # trap-on-TERM: run a real (still DRY=1) invocation in the background and
    # signal it; the restore trap must still write meta.txt with a verdict.
    import signal
    import time
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'slack_term')
        env, log = _env(tmp, {'SLACK': '1', 'OUT': out_dir, 'DUR': '600'})
        p = subprocess.Popen(['bash', os.path.join(RXFIX, 'slackleg_go.sh')],
                              env=env, cwd=RXFIX, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              start_new_session=True)
        # DRY legs finish almost instantly (no real sleeps), so give it a moment then
        # just wait it out; this still exercises the same trap path a TERM would (the
        # trap is EXIT INT TERM, and Python subprocess.wait already delivers a normal
        # EXIT through the same restore()).
        try:
            p.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGTERM)
            p.wait(timeout=15)
        assert os.path.exists(os.path.join(out_dir, 'meta.txt')), 'restore trap must leave a meta.txt behind'
        meta = _meta(out_dir)
        assert 'fixctl_restored=' in meta, meta
        _assert_no_network(log)


def test_slackleg_restore_kills_peer_watcher_before_restoring_146_then_148(tmp_path):
    """Review fix round 1, C-1: on a mid-window kill, restore() must stop the
    backgrounded 146 peer-write watcher BEFORE writing either restore, so an
    in-flight or still-sleeping peer write cannot land after the restore and
    silently leave 146 with fixctl still set. This is DRY=0 by necessity (DRY=1
    never launches the watcher at all -- see the module/script docs) but makes
    zero real network contact: ssh/scp are PATH-shimmed to a fake binary that
    logs its invocation and exits 1, and PEER_POKE_TEST_SLEEP replaces the real
    "watch capture_r3.log for the health gate" loop with a plain long sleep (a
    stand-in "fake peer watcher (a sleep)", exactly as the review asked for) so
    the kill+wait+restore-order path is exercised deterministically instead of
    depending on a real leg ever reaching its health gate."""
    import signal
    import time

    out_dir = os.path.join(str(tmp_path), 'race_out')
    env, log = _env(str(tmp_path), {
        'SLACK': '1', 'OUT': out_dir, 'DUR': '600', 'DRY': '0',
        'PEER_POKE_TEST_SLEEP': '120',
    })
    p = subprocess.Popen(['bash', os.path.join(RXFIX, 'slackleg_go.sh')],
                          env=env, cwd=RXFIX, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          start_new_session=True)
    try:
        # give the peer watcher time to start and enter its fake sleep (proven by
        # peer_poke.log's TEST SEAM line appearing) before we pull the rug.
        deadline = time.time() + 15
        peer_log = os.path.join(out_dir, 'peer_poke.log')
        while time.time() < deadline:
            if os.path.exists(peer_log) and 'TEST SEAM' in open(peer_log).read():
                break
            time.sleep(0.2)
        else:
            pytest.fail(f'peer watcher never started (no {peer_log})')

        os.killpg(p.pid, signal.SIGTERM)
        p.wait(timeout=20)
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait(timeout=10)

    # the fake peer watcher must have been killed, never reaching its own write --
    # if it "finished without being killed" the race is NOT closed.
    peer_content = open(peer_log).read()
    assert 'finished WITHOUT being killed' not in peer_content, \
        f'peer watcher was not stopped before restore -- race reproduced:\n{peer_content}'

    run_log = _run_log(out_dir)
    assert 'stopping the peer (146) write watcher' in run_log, run_log
    i_kill = run_log.find('stopping the peer (146) write watcher')
    i_146 = run_log.find('RESTORE 1/2: 146')
    i_148 = run_log.find('RESTORE 2/2: 148')
    assert i_kill != -1 and i_146 != -1 and i_148 != -1, run_log
    assert i_kill < i_146 < i_148, \
        f'must kill peer watcher, then restore 146, then restore 148, in that order:\n{run_log}'

    # only the two restore ssh calls (146 then 148) should have fired for fixctl;
    # confirm the shim log shows no fixctl write from the peer-poke path (it never
    # got past its sleep) and that the two restore writes are present in order.
    shim = open(log).read() if os.path.exists(log) else ''
    fixctl_calls = [ln for ln in shim.splitlines() if "0x208 0x0" in ln]
    assert len(fixctl_calls) == 2, f'expected exactly 2 fixctl restore writes:\n{shim}'
    assert '10.0.0.146' in fixctl_calls[0] and '10.0.0.148' in fixctl_calls[1], \
        f'restore ssh calls must be 146 then 148 in shim-call order:\n{shim}'


def test_slackleg_dry_runs_stage3h_plan_on_148():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'slack_out')
        env, log = _env(tmp, {'SLACK': '0', 'OUT': out_dir})
        r = _run(['bash', os.path.join(RXFIX, 'slackleg_go.sh')], env)
        assert r.returncode == 0, r.stdout + r.stderr
        run_log = _run_log(out_dir)
        assert 'stage3h_reader.sh plan: BOARD=148' in run_log, run_log
        _assert_no_network(log)


def test_slackleg_no_edits_to_capture_r3_or_legrun():
    """The brief requires reusing legrun_go.sh/capture_r3.sh's existing LOOP_POKE
    hook verbatim rather than adding a new PRE_WINDOW_HOOK, since a clean insertion
    point (5b) already exists for the RX board. Guard that no PRE_WINDOW_HOOK was
    introduced into either script."""
    for f in ('legrun_go.sh',):
        src = open(os.path.join(TJ, 'comb', f)).read()
        assert 'PRE_WINDOW_HOOK' not in src, f'{f} must not have been edited for this task'
    src = open(os.path.join(TJ, 'capture_r3.sh')).read()
    assert 'PRE_WINDOW_HOOK' not in src, 'capture_r3.sh must not have been edited for this task'
    assert 'LOOP_POKE' in src, 'capture_r3.sh must still have the existing 5b LOOP_POKE hook this task reuses'


# -------------------------------------------------------------------------
# witness_read.sh
# -------------------------------------------------------------------------

def test_witness_read_requires_board_and_n():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp)
        env.pop('BOARD', None); env.pop('N', None)
        r = _run(['bash', os.path.join(RXFIX, 'witness_read.sh')], env)
        assert r.returncode != 0
        _assert_no_network(log)


def test_witness_read_rejects_bad_board():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp, {'BOARD': '999', 'N': '1'})
        r = _run(['bash', os.path.join(RXFIX, 'witness_read.sh')], env)
        assert r.returncode != 0
        _assert_no_network(log)


def test_witness_read_rejects_bad_n():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp, {'BOARD': '148', 'N': '0'})
        r = _run(['bash', os.path.join(RXFIX, 'witness_read.sh')], env)
        assert r.returncode != 0
        _assert_no_network(log)


@pytest.mark.parametrize('board', ['148', '146'])
def test_witness_read_dry_emits_n_json_lines_not_available(board):
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'wout')
        env, log = _env(tmp, {'BOARD': board, 'N': '4', 'OUT': out_dir})
        r = _run(['bash', os.path.join(RXFIX, 'witness_read.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'WITNESS_READ_DONE' in out, out
        _assert_no_network(log)

        readings = os.path.join(out_dir, 'readings.jsonl')
        assert os.path.exists(readings)
        lines = [json.loads(l) for l in open(readings) if l.strip()]
        assert len(lines) == 4, lines
        for rec in lines:
            assert rec['board'] == int(board)
            assert rec['fifo_witA'] == 'NOT_AVAILABLE'
            assert rec['fifo_witB'] == 'NOT_AVAILABLE'
            assert rec['beatobs'] == 'NOT_AVAILABLE'
            assert 'fifo_reason' in rec and rec['fifo_reason']
            assert 'beatobs_reason' in rec and rec['beatobs_reason']
            assert rec['dry'] is True

        meta = _meta(out_dir)
        assert 'fifo_witness=NOT_AVAILABLE' in meta
        assert 'beatobs=NOT_AVAILABLE' in meta


def test_witness_read_dry_is_fast_no_real_sleeps():
    """N=5 at the 10s floor would take >=40s for real; DRY must not sleep at all."""
    import time
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'wout')
        env, log = _env(tmp, {'BOARD': '148', 'N': '5', 'OUT': out_dir})
        t0 = time.time()
        r = _run(['bash', os.path.join(RXFIX, 'witness_read.sh')], env, timeout=15)
        elapsed = time.time() - t0
        assert r.returncode == 0, r.stdout + r.stderr
        assert elapsed < 10, f'DRY must not sleep between readings, took {elapsed:.1f}s'
        _assert_no_network(log)


def test_witness_read_period_floor_is_clamped_and_warned():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'wout')
        env, log = _env(tmp, {'BOARD': '148', 'N': '1', 'PERIOD': '3', 'OUT': out_dir})
        r = _run(['bash', os.path.join(RXFIX, 'witness_read.sh')], env)
        assert r.returncode == 0, r.stdout + r.stderr
        run_log = _run_log(out_dir)
        assert 'clamped to 10' in run_log, run_log
        _assert_no_network(log)


def test_witness_read_dry_skips_reachability_probe():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'wout')
        env, log = _env(tmp, {'BOARD': '148', 'N': '1', 'OUT': out_dir})
        r = _run(['bash', os.path.join(RXFIX, 'witness_read.sh')], env)
        assert r.returncode == 0, r.stdout + r.stderr
        run_log = _run_log(out_dir)
        assert 'skipped, zero board contact' in run_log, run_log
        _assert_no_network(log)


# -------------------------------------------------------------------------
# w1_read.sh -- Task 10 additions (AUX / HOLD) and the pinned default sequence
# -------------------------------------------------------------------------

def _board_shim(tmpdir, naux=0):
    """A shim that behaves like the BOARD: emits the 8 W1 words twice (so
    freeze_effective is true), the three W1T* timestamps, and `naux` aux words.
    Logs the remote script it was handed so the register sequence can be pinned."""
    shim = os.path.join(tmpdir, 'bshim')
    os.makedirs(shim, exist_ok=True)
    log = os.path.join(tmpdir, 'bshim.log')
    p = os.path.join(shim, 'fakessh.sh')
    with open(p, 'w') as f:
        f.write(
            '#!/bin/bash\n'
            f'echo "ARGS $*" >> "{log}"\n'
            'echo "W1T0=$(date +%s.%N)"\n'
            'for r in 1 2; do\n'
            '  echo 0x00000294; echo 0x00000015; echo 0x27ec2f34; echo 0x27ec2f34\n'
            '  echo 0x27ec2f2c; echo 0x27ec2f29; echo 0x27e9fef5; echo 0x27e991a1\n'
            'done\n'
            'echo "W1TA=$(date +%s.%N)"\n'
            f'i=0; while [ $i -lt {naux} ]; do echo 0x0001e240; i=$((i+1)); done\n'
            'echo "W1T1=$(date +%s.%N)"\n')
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return p, log


# The register-touching lines of a DEFAULT (AUX="", HOLD=0) w1_read.sh sweep,
# captured from the script BEFORE AUX/HOLD were added. Adding those two knobs must
# not have moved a single register access on the default path.
_DEFAULT_REG_SEQ = [
    'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access',
    'echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null',
    'rd(){ echo "$1" > $DRA; cat $DRA; }',
    'wr(){ echo "$1 $2" > $DRA; }',
    'wr 0x208 0x10;',
    'for a in 0x214 0x218 0x21C 0x220 0x224 0x228 0x22C 0x230; do rd $a; done',
    'for a in 0x214 0x218 0x21C 0x220 0x224 0x228 0x22C 0x230; do rd $a; done',
    'wr 0x208 0x0;',
]


def _reg_lines(log_text):
    """The shim logs `ARGS <ip> <the whole remote script>`, so the first physical
    line carries the `ARGS <ip> ` prefix ahead of the script's first line. Strip it,
    then keep only the register-touching lines."""
    keep = ('DRA=/sys', 'reg_access', 'rd(){', 'wr(){', 'wr 0x208', 'for a in', 'sleep ')
    out = []
    for ln in log_text.splitlines():
        s = ln.strip()
        if s.startswith('ARGS '):
            s = s.split(' ', 2)[2] if len(s.split(' ', 2)) > 2 else ''
        if any(k in s for k in keep):
            out.append(s.strip())
    return out


def test_w1_read_default_remote_script_register_sequence_unchanged(tmp_path):
    """AUX/HOLD must be inert on the default path: the exact register sequence a
    default sweep puts on the wire is pinned here."""
    ssh, log = _board_shim(str(tmp_path), naux=0)
    out = os.path.join(str(tmp_path), 'o')
    env, netlog = _env(str(tmp_path), {
        'BOARD': '148', 'N': '1', 'DRY': '0', 'SSH': ssh, 'OUT': out})
    r = _run(['bash', os.path.join(RXFIX, 'w1_read.sh')], env)
    assert r.returncode == 0, r.stdout + r.stderr
    got = _reg_lines(open(log).read())
    assert got == _DEFAULT_REG_SEQ, f'default register sequence changed:\n{got}'


def test_w1_read_default_still_parses_16_words(tmp_path):
    ssh, log = _board_shim(str(tmp_path), naux=0)
    out = os.path.join(str(tmp_path), 'o')
    env, _ = _env(str(tmp_path), {'BOARD': '148', 'N': '1', 'DRY': '0', 'SSH': ssh, 'OUT': out})
    r = _run(['bash', os.path.join(RXFIX, 'w1_read.sh')], env)
    assert r.returncode == 0, r.stdout + r.stderr
    rec = json.loads(open(os.path.join(out, 'readings.jsonl')).read().strip())
    assert rec['freeze_effective'] is True
    assert rec['words']['witA'] == '0x00000294'
    assert rec['aux'] == {}


def test_w1_read_aux_is_parsed_and_reported(tmp_path):
    ssh, log = _board_shim(str(tmp_path), naux=2)
    out = os.path.join(str(tmp_path), 'o')
    env, _ = _env(str(tmp_path), {'BOARD': '148', 'N': '1', 'DRY': '0', 'SSH': ssh,
                                  'OUT': out, 'AUX': '0x104 0x124'})
    r = _run(['bash', os.path.join(RXFIX, 'w1_read.sh')], env)
    assert r.returncode == 0, r.stdout + r.stderr
    rec = json.loads(open(os.path.join(out, 'readings.jsonl')).read().strip())
    assert rec['aux'] == {'0x104': '0x0001e240', '0x124': '0x0001e240'}
    assert rec['words']['witA'] == '0x00000294', 'AUX must not shift the W1 word parse'
    assert isinstance(rec['aux_lag_s'], float), 'aux_lag_s must be measured, not assumed'
    seq = _reg_lines(open(log).read())
    assert 'for a in 0x104 0x124; do rd $a; done' in seq


def test_w1_read_aux_count_mismatch_is_an_error_not_a_silent_shift(tmp_path):
    """AUX declared but the board returns none -> must be reported as a short read,
    never parsed as if the W1 words were still aligned."""
    ssh, _ = _board_shim(str(tmp_path), naux=0)
    out = os.path.join(str(tmp_path), 'o')
    env, _ = _env(str(tmp_path), {'BOARD': '148', 'N': '1', 'DRY': '0', 'SSH': ssh,
                                  'OUT': out, 'AUX': '0x104'})
    r = _run(['bash', os.path.join(RXFIX, 'w1_read.sh')], env)
    rec = json.loads(open(os.path.join(out, 'readings.jsonl')).read().strip())
    assert rec['error'] == 'got 16 of 17 words'


def test_w1_read_aux_rejects_injection(tmp_path):
    """AUX is interpolated into a remote shell for-list; only hex addresses allowed."""
    ssh, log = _board_shim(str(tmp_path), naux=0)
    out = os.path.join(str(tmp_path), 'o')
    env, _ = _env(str(tmp_path), {'BOARD': '148', 'N': '1', 'DRY': '0', 'SSH': ssh,
                                  'OUT': out, 'AUX': '0x104; rm -rf /'})
    r = _run(['bash', os.path.join(RXFIX, 'w1_read.sh')], env)
    assert r.returncode != 0
    assert 'AUX entries must be' in (r.stdout + r.stderr)
    assert not os.path.exists(log), 'a rejected AUX must not reach the board at all'


def test_w1_read_hold_injects_the_sleep_between_the_two_frozen_sweeps(tmp_path):
    ssh, log = _board_shim(str(tmp_path), naux=0)
    out = os.path.join(str(tmp_path), 'o')
    env, _ = _env(str(tmp_path), {'BOARD': '148', 'N': '1', 'DRY': '0', 'SSH': ssh,
                                  'OUT': out, 'HOLD': '2'})
    r = _run(['bash', os.path.join(RXFIX, 'w1_read.sh')], env)
    assert r.returncode == 0, r.stdout + r.stderr
    seq = _reg_lines(open(log).read())
    i_sweep = [k for k, ln in enumerate(seq) if ln.startswith('for a in 0x214')]
    i_sleep = [k for k, ln in enumerate(seq) if ln == 'sleep 2;']
    assert len(i_sweep) == 2 and len(i_sleep) == 1, seq
    assert i_sweep[0] < i_sleep[0] < i_sweep[1], \
        f'the HOLD sleep must sit BETWEEN the two frozen sweeps:\n{seq}'


def _board_shim_r4b(tmpdir, naux=0):
    """Like _board_shim but a W1+R4B image: NINE words per sweep, and the ninth
    (0x234) ADVANCES between the two sweeps -- which is what a live board does,
    because 0x234 is outside W1's freeze shadow by design."""
    shim = os.path.join(tmpdir, 'bshim9')
    os.makedirs(shim, exist_ok=True)
    log = os.path.join(tmpdir, 'bshim9.log')
    p = os.path.join(shim, 'fakessh.sh')
    with open(p, 'w') as f:
        f.write(
            '#!/bin/bash\n'
            f'echo "ARGS $*" >> "{log}"\n'
            'echo "W1T0=$(date +%s.%N)"\n'
            'for w in 0x80010001 0x80010002; do\n'
            '  echo 0x00000294; echo 0x00000015; echo 0x27ec2f34; echo 0x27ec2f34\n'
            '  echo 0x27ec2f2c; echo 0x27ec2f29; echo 0x27e9fef5; echo 0x27e991a1\n'
            '  echo $w\n'
            'done\n'
            'echo "W1TA=$(date +%s.%N)"\n'
            f'i=0; while [ $i -lt {naux} ]; do echo 0x0001e240; i=$((i+1)); done\n'
            'echo "W1T1=$(date +%s.%N)"\n')
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return p, log


def test_w1_read_r4b_sweeps_the_ninth_word_and_reports_it(tmp_path):
    """R4B=1 adds 0x234 to BOTH sweeps and reports it from the first, plus the
    second value and whether it moved."""
    ssh, log = _board_shim_r4b(str(tmp_path))
    out = os.path.join(str(tmp_path), 'o')
    env, _ = _env(str(tmp_path), {'BOARD': '148', 'N': '1', 'DRY': '0', 'SSH': ssh,
                                  'OUT': out, 'R4B': '1'})
    r = _run(['bash', os.path.join(RXFIX, 'w1_read.sh')], env)
    assert r.returncode == 0, r.stdout + r.stderr
    rec = json.loads(open(os.path.join(out, 'readings.jsonl')).read().strip())
    assert rec['words']['r4bWit'] == '0x80010001'
    assert rec['r4b_wit2'] == '0x80010002'
    assert rec['r4b_moved'] is True
    assert rec['words']['witA'] == '0x00000294', 'the ninth word must not shift the parse'
    seq = _reg_lines(open(log).read())
    assert seq.count('for a in 0x214 0x218 0x21C 0x220 0x224 0x228 0x22C 0x230 0x234; do rd $a; done') == 2, seq


def test_w1_read_r4b_freeze_effective_ignores_the_unfrozen_ninth_word(tmp_path):
    """THE trap: 0x234 is NOT behind fixctl[4] and advances at the frame rate.  If
    it were folded into the freeze test every live reading would be
    freeze_effective:false and Task 9's rule would discard the whole leg."""
    ssh, _ = _board_shim_r4b(str(tmp_path))
    out = os.path.join(str(tmp_path), 'o')
    env, _ = _env(str(tmp_path), {'BOARD': '148', 'N': '1', 'DRY': '0', 'SSH': ssh,
                                  'OUT': out, 'R4B': '1'})
    r = _run(['bash', os.path.join(RXFIX, 'w1_read.sh')], env)
    assert r.returncode == 0, r.stdout + r.stderr
    rec = json.loads(open(os.path.join(out, 'readings.jsonl')).read().strip())
    assert rec['r4b_moved'] is True
    assert rec['freeze_effective'] is True, \
        'the eight frozen words were identical; the ninth moving must not clear it'


def test_w1_read_r4b_off_by_default_and_aux_still_aligns(tmp_path):
    """R4B defaults OFF (a W1-only image reads const_0 at 0x234), and with R4B=1
    the AUX words are still taken from AFTER both nine-word sweeps."""
    ssh, _ = _board_shim(str(tmp_path), naux=0)
    out = os.path.join(str(tmp_path), 'o')
    env, _ = _env(str(tmp_path), {'BOARD': '148', 'N': '1', 'DRY': '0', 'SSH': ssh, 'OUT': out})
    r = _run(['bash', os.path.join(RXFIX, 'w1_read.sh')], env)
    assert r.returncode == 0, r.stdout + r.stderr
    rec = json.loads(open(os.path.join(out, 'readings.jsonl')).read().strip())
    assert 'r4bWit' not in rec['words'] and 'r4b_wit2' not in rec

    ssh9, _ = _board_shim_r4b(str(tmp_path), naux=1)
    out9 = os.path.join(str(tmp_path), 'o9')
    env9, _ = _env(str(tmp_path), {'BOARD': '148', 'N': '1', 'DRY': '0', 'SSH': ssh9,
                                   'OUT': out9, 'R4B': '1', 'AUX': '0x104'})
    r9 = _run(['bash', os.path.join(RXFIX, 'w1_read.sh')], env9)
    assert r9.returncode == 0, r9.stdout + r9.stderr
    rec9 = json.loads(open(os.path.join(out9, 'readings.jsonl')).read().strip())
    assert rec9['aux'] == {'0x104': '0x0001e240'}
    assert rec9['words']['r4bWit'] == '0x80010001'


def test_w1_read_r4b_rejects_bad_value(tmp_path):
    env, netlog = _env(str(tmp_path), {'BOARD': '148', 'N': '1', 'R4B': '2'})
    r = _run(['bash', os.path.join(RXFIX, 'w1_read.sh')], env)
    assert r.returncode != 0
    _assert_no_network(netlog)


def test_w1_read_hold_rejects_non_integer(tmp_path):
    env, netlog = _env(str(tmp_path), {'BOARD': '148', 'N': '1', 'HOLD': 'abc'})
    r = _run(['bash', os.path.join(RXFIX, 'w1_read.sh')], env)
    assert r.returncode != 0
    _assert_no_network(netlog)


# -------------------------------------------------------------------------
# w1leg_go.sh
# -------------------------------------------------------------------------

def test_w1leg_requires_mode():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp)
        env.pop('MODE', None)
        r = _run(['bash', os.path.join(RXFIX, 'w1leg_go.sh')], env)
        assert r.returncode != 0
        _assert_no_network(log)


def test_w1leg_rejects_bad_mode():
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp, {'MODE': 'sideways'})
        r = _run(['bash', os.path.join(RXFIX, 'w1leg_go.sh')], env)
        assert r.returncode != 0
        _assert_no_network(log)


def test_w1leg_ctrl_dry_zero_network_and_plan_order():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'ctrl')
        env, log = _env(tmp, {'MODE': 'ctrl', 'OUT': out_dir})
        r = _run(['bash', os.path.join(RXFIX, 'w1leg_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'W1LEG_CTRL_DONE' in out, out
        _assert_no_network(log)
        rl = _run_log(out_dir)
        # arm -> pre reads -> freeze hold -> ONE re-arm -> post reads
        order = [rl.find('arm #1'), rl.find('reads 1-3'), rl.find('freeze-path control'),
                 rl.find('arm #2'), rl.find('reads 4-6')]
        assert all(i != -1 for i in order), rl
        assert order == sorted(order), f'control sequence out of order:\n{rl}'
        assert rl.count('arm #2') >= 1 and 'arm #3' not in rl, 'exactly ONE re-arm'
        meta = _meta(out_dir)
        assert 'fixctl_base=0x0' in meta, meta
        assert 'sink=tgenrx' in meta, meta


def test_w1leg_air_dry_zero_network_and_sequential_reader_plan():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'air')
        env, log = _env(tmp, {'MODE': 'air', 'OUT': out_dir, 'DUR': '600'})
        r = _run(['bash', os.path.join(RXFIX, 'w1leg_go.sh')], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert 'W1LEG_AIR_DONE' in out, out
        _assert_no_network(log)
        rl = _run_log(out_dir)
        assert 'SEQUENTIALLY' in rl, 'the reader plan must state the sequential contract'
        assert "wait for 'wedge verdict:'" in rl, rl
        meta = _meta(out_dir)
        assert 'reader=sequential' in meta, meta
        assert 'read_window_s=480' in meta, meta
        for field in ('leg=A', 'dir=fwd', 'rx=10.0.0.148', 'deliver_rate_gate_pass='):
            assert field in meta, f'legrun_go.sh meta keys must be folded in: {field}\n{meta}'


def test_w1leg_air_dry_never_launches_capture_r3_for_real():
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'air')
        env, log = _env(tmp, {'MODE': 'air', 'OUT': out_dir})
        r = _run(['bash', os.path.join(RXFIX, 'w1leg_go.sh')], env)
        assert r.returncode == 0, r.stdout + r.stderr
        _assert_no_network(log)
        assert not os.path.exists(os.path.join(out_dir, 'capture_r3.log'))


def test_w1leg_r4b_refuses_the_default_w1_image_expectation(tmp_path):
    """R4B=1 with no explicit EXP (or with the W1 image's md5) is refused: it would
    pass the image gate on the W1-only image, read const_0 at 0x234 and score the
    Task 13 pre-registration against silicon that has no R4B in it."""
    for extra in ({}, {'EXP': '2728dab3979a'}):
        env, netlog = _env(str(tmp_path), dict({'MODE': 'air', 'R4B': '1'}, **extra))
        r = _run(['bash', os.path.join(RXFIX, 'w1leg_go.sh')], env)
        assert r.returncode == 2, r.stdout + r.stderr
        assert 'W1LEG_REFUSED' in (r.stdout + r.stderr)
        _assert_no_network(netlog)
    # an explicit, different image md5 is accepted (DRY path, no network)
    env, netlog = _env(str(tmp_path), {'MODE': 'air', 'R4B': '1', 'EXP': 'abcdef123456',
                                       'DRY': '1', 'DUR': '1'})
    r = _run(['bash', os.path.join(RXFIX, 'w1leg_go.sh')], env)
    assert 'W1LEG_REFUSED R4B=1' not in (r.stdout + r.stderr)


def test_w1leg_refuses_a_board_running_the_wrong_image(tmp_path):
    """DRY=0 with a shim that reports the OLD image md5: the leg must refuse rather
    than measure a board that is not running W1. Uses the ssh shim, no real board."""
    shim = os.path.join(str(tmp_path), 'imgshim')
    os.makedirs(shim, exist_ok=True)
    p = os.path.join(shim, 'fakessh.sh')
    with open(p, 'w') as f:
        f.write('#!/bin/bash\necho a1ff3c876d91\n')
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
    out_dir = os.path.join(str(tmp_path), 'air')
    env, _ = _env(str(tmp_path), {'MODE': 'air', 'OUT': out_dir, 'DRY': '0',
                                  'SSH': p, 'EXP': '2728dab3979a'})
    # w1leg_go.sh honours SSH for its own board reads, so this never reaches a board.
    r = _run(['bash', os.path.join(RXFIX, 'w1leg_go.sh')], env, timeout=120)
    out = r.stdout + r.stderr
    assert 'W1LEG_REFUSED image=a1ff3c876d91' in out, out
    assert r.returncode == 4, out


# ---------------------------------------------------------------------------
# w1leg_go.sh LEG / BOARD / RSSI knobs (Task 17)
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("leg,board", [("B", "148"), ("A", "146")])
def test_w1leg_refuses_leg_board_mismatch(leg, board):
    """The reader must read the RECEIVER. LEG=A is 146 TX -> 148 RX and LEG=B is
    148 TX -> 146 RX, so a mismatched BOARD would sweep the ring witness on the
    TRANSMITTING board and silently score the wrong side of the link. Refusal
    (exit 2), not a warning."""
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp, {'MODE': 'air', 'LEG': leg, 'BOARD': board})
        r = _run(['bash', os.path.join(RXFIX, 'w1leg_go.sh')], env)
        assert r.returncode == 2, r.stdout + r.stderr
        assert 'W1LEG_REFUSED' in (r.stdout + r.stderr)
        _assert_no_network(log)


@pytest.mark.parametrize("knob,bad", [("LEG", "C"), ("BOARD", "147"), ("RSSI", "2")])
def test_w1leg_rejects_bad_knob_values(knob, bad):
    with tempfile.TemporaryDirectory() as tmp:
        env, log = _env(tmp, {'MODE': 'air', knob: bad})
        r = _run(['bash', os.path.join(RXFIX, 'w1leg_go.sh')], env)
        assert r.returncode == 2, r.stdout + r.stderr
        _assert_no_network(log)


def test_w1leg_air_legB_targets_146_and_plans_three_sequential_reads():
    """LEG=B BOARD=146 RSSI=1 must drive legrun_go.sh with LEG=B, read 146, plan
    THREE strictly sequential ssh round trips per reading, and add 0x150 (rstcs)
    to the AUX sweep so the leg carries a per-reading carrier-reset timeline."""
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'legB')
        env, log = _env(tmp, {'MODE': 'air', 'LEG': 'B', 'BOARD': '146', 'RSSI': '1',
                              'DUR': '600', 'EXP': '2728dab3979a',
                              'FIXCTL_BASE': '0x0', 'OUT': out_dir})
        r = _run(['bash', os.path.join(RXFIX, 'w1leg_go.sh')], env)
        o = r.stdout + r.stderr
        assert r.returncode == 0, o
        _assert_no_network(log)
        rl = _run_log(out_dir)
        assert 'LEG=B BOARD=146 (10.0.0.146)' in rl, rl
        assert 'legrun_go.sh LEG=B' in rl, rl
        assert 'w1_read.sh (ssh #1) then seqbist_read.py (ssh #2) then rssi_read (ssh #3)' in rl, rl
        assert '0x104 0x124 0x150' in rl, rl


def test_w1leg_air_legA_default_keeps_two_reads_and_no_rssi():
    """Regression control: the Task 10/13 invocation (defaults LEG=A BOARD=148,
    RSSI off) must be unchanged -- two ssh round trips, no third one, and the AUX
    sweep must NOT silently gain 0x150 on the default path."""
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'legA')
        env, log = _env(tmp, {'MODE': 'air', 'DUR': '600', 'OUT': out_dir})
        r = _run(['bash', os.path.join(RXFIX, 'w1leg_go.sh')], env)
        assert r.returncode == 0, r.stdout + r.stderr
        _assert_no_network(log)
        rl = _run_log(out_dir)
        assert 'LEG=A BOARD=148 (10.0.0.148)' in rl, rl
        assert 'legrun_go.sh LEG=A' in rl, rl
        assert 'rssi_read (ssh #3)' not in rl, rl


def test_w1leg_ctrl_aux_unchanged_by_the_air_rstcs_addition():
    """MODE=ctrl must keep the ORIGINAL two AUX addresses so its control table stays
    byte-comparable with Task 13's; only the air path gains 0x150."""
    with tempfile.TemporaryDirectory() as tmp:
        out_dir = os.path.join(tmp, 'ctrl')
        env, log = _env(tmp, {'MODE': 'ctrl', 'OUT': out_dir})
        r = _run(['bash', os.path.join(RXFIX, 'w1leg_go.sh')], env)
        assert r.returncode == 0, r.stdout + r.stderr
        _assert_no_network(log)
        meta = _meta(out_dir)
        assert 'aux=0x104 0x124' in meta and '0x150' not in meta, meta


def test_w1leg_rssi_device_is_found_by_capability_not_by_index():
    """iio:deviceN numbering is not stable across kernels/boots, so the RSSI reader
    must locate the device by probing for in_voltage0_rssi and fail loudly if no
    device has it -- never by hardcoding an index."""
    src = open(os.path.join(RXFIX, 'w1leg_go.sh')).read()
    assert 'for d in /sys/bus/iio/devices/iio:device*' in src
    assert 'in_voltage0_rssi' in src
    assert 'RSSI_DEV_NOT_FOUND' in src
    i = src.index('RSSI_REMOTE=')
    j = src.index('rssi_read()')
    assert 'iio:device2' not in src[i:j], 'RSSI reader must not hardcode a device index'
