import os, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'agents'))
from render_pipeline import ledger_state, plan_tasks, render

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
        out = render(d, os.path.join(d, 'out', 'pipeline.html'), sentinel=os.path.join(d, 'none.log'))
        h = open(out).read()
        assert 'Build thing' in h and 'complete' in h and 'running' in h and '§77 SCORER' in h and 'Rulings (1)' in h
