import os, subprocess, sys, tempfile
from datetime import datetime, timedelta

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'agents'))
from agent_watch import (plan_tasks, ledger_state, parse_heartbeats, agent_rows,
                          all_agent_rows, digest_lines, unit_matches_task,
                          unit_running_for_task, campaign_name)


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


def _iso(dt):
    return dt.isoformat(timespec='seconds')


SYNTH_LEDGER = """# SDD ledger — plan: docs/superpowers/plans/p.md
Tasks: 1 = Harness taps; 2 = Docs; 3 = Rig scripts; 4 = Dashboard; 5 = Rig legs
Task 1: dispatched implementer
Task 2: dispatched implementer
Task 3: dispatched implementer
Task 4: dispatched implementer
"""


# --- ledger_state / plan_tasks (moved here from render_pipeline, kept for
#     back-compat via render_pipeline's re-export) ---

def test_ledger_state_uses_last_line_per_task():
    txt = ("Task 1: dispatched implementer\nTask 1: implementer DONE; reviewer dispatched\n"
           "Task 1: complete (commits a..b, review clean)\nTask 2: dispatched implementer\n"
           "Task 3: fix round 1/5 (1 open)\n")
    s = ledger_state(txt)
    assert s[1][0] == 'complete' and s[2][0] == 'running' and s[3][0] == 'fix round'


def test_plan_tasks_fallback_from_ledger_tasks_line():
    tasks = plan_tasks('/nonexistent/plan.md', SYNTH_LEDGER)
    assert tasks == [(1, 'Harness taps'), (2, 'Docs'), (3, 'Rig scripts'), (4, 'Dashboard'), (5, 'Rig legs')]


# --- heartbeat parsing ---

def test_parse_heartbeats_last_wins_and_skips_non_iso():
    now = datetime.now().astimezone()
    older = _iso(now - timedelta(minutes=10))
    newer = _iso(now - timedelta(minutes=1))
    txt = (f"HEARTBEAT task1 {older} first\n"
           f"HEARTBEAT task1 05:12 bare-time-not-iso-skipped\n"
           f"HEARTBEAT task1 {newer} second\n")
    hb = parse_heartbeats(txt)
    dt, state, raw = hb['task1']
    assert state == 'second'


# --- unit matching ---

def test_unit_matches_task_by_t_token_and_task_prefix():
    assert unit_matches_task('legrun-T2-m16', 2)
    assert unit_matches_task('ddrcap-T3-sel13', 3)
    assert unit_matches_task('task4-render', 4)
    assert not unit_matches_task('legrun-T2-m16', 3)
    assert not unit_matches_task('seqbist-s1-ctrlA', 1)


def test_unit_running_for_task():
    active = ['legrun-T2-m16.service', 'watch-legrun-T2-m16.service']
    assert unit_running_for_task(2, active)
    assert not unit_running_for_task(5, active)


# --- agent_rows: STALE vs ON-TASK vs PENDING ---

def test_agent_rows_stale_heartbeat_flagged_stale():
    now = datetime.now().astimezone()
    stale_hb = _iso(now - timedelta(minutes=7))
    txt = (SYNTH_LEDGER + f"HEARTBEAT task1 {stale_hb} working on taps\n")
    rows = agent_rows(txt, '/nonexistent/plan.md', stale_min=5, now=now, active_units=[])
    row1 = next(r for r in rows if r['task'] == 1)
    assert row1['flag'] == 'STALE'
    assert row1['hb_age_min'] > 5


def test_agent_rows_recent_heartbeat_flagged_on_task():
    now = datetime.now().astimezone()
    recent_hb = _iso(now - timedelta(minutes=1))
    txt = (SYNTH_LEDGER + f"HEARTBEAT task2 {recent_hb} working on docs\n")
    rows = agent_rows(txt, '/nonexistent/plan.md', stale_min=5, now=now, active_units=[])
    row2 = next(r for r in rows if r['task'] == 2)
    assert row2['flag'] == 'ON-TASK'
    assert row2['hb_age_min'] <= 5


def test_agent_rows_stale_heartbeat_but_running_unit_is_on_task():
    """A stale heartbeat while parked on a live rig unit is ON-TASK, not STALE --
    the unit watcher (watch_unit.sh) is the thing writing the next heartbeat."""
    now = datetime.now().astimezone()
    stale_hb = _iso(now - timedelta(minutes=7))
    txt = (SYNTH_LEDGER + f"HEARTBEAT task3 {stale_hb} parked on legrun-T3-a1\n")
    rows = agent_rows(txt, '/nonexistent/plan.md', stale_min=5, now=now,
                       active_units=['legrun-T3-a1.service'])
    row3 = next(r for r in rows if r['task'] == 3)
    assert row3['flag'] == 'ON-TASK'


def test_agent_rows_pending_task_not_flagged_stale():
    """A task with no heartbeat and ledger status 'pending' hasn't started yet --
    it must not be flagged STALE just because 5 minutes have passed since dispatch."""
    txt = "Tasks: 1 = Something; 2 = Not yet dispatched\nTask 1: dispatched implementer\n"
    rows = agent_rows(txt, '/nonexistent/plan.md', stale_min=5, active_units=[])
    row2 = next(r for r in rows if r['task'] == 2)
    assert row2['status'] == 'pending'
    assert row2['flag'] == 'PENDING'


def test_agent_rows_excludes_complete_tasks():
    txt = "Tasks: 1 = Something\nTask 1: complete (all done)\n"
    rows = agent_rows(txt, '/nonexistent/plan.md', stale_min=5, active_units=[])
    assert rows == []


# --- all_agent_rows across newest N ledgers ---

def test_all_agent_rows_spans_newest_two_ledgers():
    with tempfile.TemporaryDirectory() as d:
        now = datetime.now().astimezone()
        recent = _iso(now - timedelta(minutes=1))
        newer_ledger = os.path.join(d, 'two_jup', 'sdd_archive', 'zzz-newest', 'progress.md')
        older_ledger = os.path.join(d, 'two_jup', 'sdd_archive', 'aaa-older', 'progress.md')
        _write(newer_ledger, f"Tasks: 1 = New task\nTask 1: dispatched\nHEARTBEAT task1 {recent} going\n")
        _write(older_ledger, f"Tasks: 1 = Old task\nTask 1: dispatched\nHEARTBEAT task1 {recent} going\n")
        os.utime(older_ledger, (now.timestamp() - 3600, now.timestamp() - 3600))
        os.utime(newer_ledger, (now.timestamp(), now.timestamp()))
        rows = all_agent_rows(d, stale_min=5, now=now, active_units=[], n_ledgers=2)
        campaigns = {r['campaign'] for r in rows}
        assert campaigns == {'zzz-newest', 'aaa-older'}


def test_campaign_name_from_ledger_path():
    assert campaign_name('/x/two_jup/sdd_archive/2026-09-04-rxfix/progress.md') == '2026-09-04-rxfix'


# --- digest_lines / agent_digest.sh ---

def test_digest_lines_format_and_filters_pending():
    with tempfile.TemporaryDirectory() as d:
        now = datetime.now().astimezone()
        recent = _iso(now - timedelta(minutes=1))
        stale = _iso(now - timedelta(minutes=7))
        ledger = os.path.join(d, 'two_jup', 'sdd_archive', '2026-09-04-rxfix', 'progress.md')
        _write(ledger, "Tasks: 1 = A; 2 = B; 3 = Not started\n"
                        "Task 1: dispatched\nTask 2: dispatched\n"
                        f"HEARTBEAT task1 {recent} on-task action here\n"
                        f"HEARTBEAT task2 {stale} stale action here\n")
        lines = digest_lines(d, stale_min=5, now=now, active_units=[])
        assert len(lines) == 2  # task3 is PENDING, excluded from the digest
        by_task = {l.split()[0]: l for l in lines}
        assert 'task1' in by_task and 'flag=ON-TASK' in by_task['task1']
        assert 'task2' in by_task and 'flag=STALE' in by_task['task2']
        for l in lines:
            assert l.startswith('task')
            assert 'hb_age=' in l and 'unit=' in l and 'last=' in l and 'flag=' in l


def test_agent_digest_sh_runs_against_synthetic_root():
    with tempfile.TemporaryDirectory() as d:
        now_iso = _iso(datetime.now().astimezone() - timedelta(minutes=1))
        ledger = os.path.join(d, 'two_jup', 'sdd_archive', '2026-09-04-rxfix', 'progress.md')
        _write(ledger, f"Tasks: 1 = A\nTask 1: dispatched\nHEARTBEAT task1 {now_iso} going\n")
        script = os.path.join(os.path.dirname(__file__), '..', 'agents', 'agent_digest.sh')
        r = subprocess.run(['bash', script, d], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0
        assert 'task1' in r.stdout and 'flag=ON-TASK' in r.stdout


# --- render_pipeline renders a synthetic ledger without error ---

def test_render_pipeline_renders_synthetic_ledger_with_agents_block():
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'agents'))
    from render_pipeline import render
    with tempfile.TemporaryDirectory() as d:
        now = datetime.now().astimezone()
        recent = _iso(now - timedelta(minutes=1))
        os.makedirs(os.path.join(d, 'docs', 'superpowers', 'plans'))
        os.makedirs(os.path.join(d, 'two_jup'))
        _write(os.path.join(d, 'docs', 'superpowers', 'plans', 'p.md'),
               "### Task 1: Build thing\n### Task 2: Test thing\n")
        ledger = os.path.join(d, 'two_jup', 'sdd_archive', '2026-09-04-rxfix', 'progress.md')
        _write(ledger, "# SDD ledger — plan: docs/superpowers/plans/p.md\n"
                        "Task 1: dispatched implementer\n"
                        f"HEARTBEAT task1 {recent} building\n"
                        "Task 2: complete (x..y, review clean)\n")
        out = render(d, os.path.join(d, 'out', 'pipeline.html'), sentinel=os.path.join(d, 'none.log'),
                     stalls_path=os.path.join(d, 'nostalls.json'), notify_dir=os.path.join(d, 'nonotify'),
                     is_active=lambda u: False)
        h = open(out).read()
        assert 'Agents (5-min heartbeat check)' in h
        assert 'Pipeline — 2026-09-04-rxfix' in h
        assert 'task1' in h
        assert 'building' in h
        assert 'Hold files / image state' in h
