import json, os, sys, tempfile, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'agents'))
from render_pipeline import ledger_state, plan_tasks, render, lanes_block

def test_ledger_state_uses_last_line_per_task():
    txt = ("# SDD ledger — plan: docs/superpowers/plans/p.md\nTask 1: dispatched implementer\nTask 1: implementer DONE; reviewer dispatched\n"
           "Task 1: complete (commits a..b, review clean)\nTask 2: dispatched implementer\nTask 3: fix round 1/5 (1 open)\n")
    s = ledger_state(txt)
    assert s[1][0] == 'complete' and s[2][0] == 'running' and s[3][0] == 'fix round'

def test_render_synthetic_tree():
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, '.superpowers/sdd/x')); os.makedirs(os.path.join(d, 'docs/superpowers/plans')); os.makedirs(os.path.join(d, 'two_jup'))
        open(os.path.join(d, 'docs/superpowers/plans/p.md'), 'w').write("### Task 1: Build thing\n### Task 2: Test thing\n")
        open(os.path.join(d, '.superpowers/sdd/x/progress.md'), 'w').write("# SDD ledger — plan: docs/superpowers/plans/p.md\n- Ruling: keep it — why — cost\nTask 1: complete (x..y, review clean)\nTask 2: dispatched implementer\n")
        open(os.path.join(d, 'two_jup/SESSION_20260830_AUTONOMOUS.md'), 'w').write("## §76 KICK RESULT\n## §77 SCORER\n")
        out = render(d, os.path.join(d, 'out', 'pipeline.html'), sentinel=os.path.join(d, 'none.log'),
                     stalls_path=os.path.join(d, 'nostalls.json'), notify_dir=os.path.join(d, 'nonotify'))
        h = open(out).read()
        assert 'Build thing' in h and 'complete' in h and 'running' in h and '§77 SCORER' in h and 'Rulings (1)' in h
        assert 'Lanes / stalls' in h and 'no lanes registered' in h

def test_lanes_block_shows_lane_state_and_stalls():
    with tempfile.TemporaryDirectory() as d:
        agents_dir = os.path.join(d, 'two_jup', 'agents')
        os.makedirs(agents_dir)
        log_path = os.path.join(d, 'somelane.log')
        open(log_path, 'w').write('x')
        old_ts = time.time() - 3600
        os.utime(log_path, (old_ts, old_ts))
        json.dump([{'name': 'simlane', 'unit': 'sim-fake-unit', 'log': log_path, 'max_age_min': 15}],
                   open(os.path.join(agents_dir, 'lanes.json'), 'w'))
        stalls_path = os.path.join(d, 'stalls.json')
        json.dump([{'key': 'lane:simlane', 'type': 'lane', 'name': 'simlane', 'age_min': 60.0}],
                   open(stalls_path, 'w'))
        notify_dir = os.path.join(d, 'NOTIFY')
        os.makedirs(notify_dir)
        open(os.path.join(notify_dir, 'watch-sim-fake-unit.done'), 'w').close()

        html_out = lanes_block(d, stalls_path=stalls_path, notify_dir=notify_dir, is_active=lambda u: True)
        assert 'simlane' in html_out and 'sim-fake-unit' in html_out and 'active' in html_out
        assert 'Stalls (1)' in html_out and 'lane:simlane' in html_out
        assert 'watch-sim-fake-unit.done' in html_out

def test_lanes_block_no_lanes_no_stalls():
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, 'two_jup', 'agents'))
        html_out = lanes_block(d, stalls_path=os.path.join(d, 'missing_stalls.json'),
                                notify_dir=os.path.join(d, 'missing_notify'), is_active=lambda u: False)
        assert 'no lanes registered' in html_out
        assert 'stalls.json: none' in html_out
        assert 'NOTIFY: none pending' in html_out
