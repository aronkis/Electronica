#!/usr/bin/env python3
"""agent_watch.py -- shared ledger/heartbeat/unit parsing for the RXFIX 5-minute agent
checks (T0d, plan happy-bubbling-owl.md). One parser, three consumers:
  - render_pipeline.py imports plan_tasks/ledger_state (unchanged names, moved here)
    and agents_block() for the dashboard's "Agents" section.
  - agent_digest.sh calls this module's --digest CLI for the controller's 5-minute
    per-agent one-liner.
  - stall_detector.py keeps its own independent heartbeat scan (txfix-era, 25 min
    default) -- this module does not replace it, it is the new RXFIX-era view.

Ledger format assumed (two_jup/sdd_archive/<campaign>/progress.md):
  - first line: '# SDD ledger — plan: <path/to/plan.md> ...'
  - 'Tasks: 1 = <title>; 2 = <title>; ...' line (fallback task list when the plan
    file has no '### Task N: <title>' headings)
  - 'Task N: <status text>' lines, last one per N wins
  - 'HEARTBEAT task<N> <ISO8601> <state text>' lines, last one per task wins
  - 'UNITEXIT <unit> result=<r> code=<c> at=<ISO8601>' lines from watch_unit.sh
"""
import argparse, glob, os, re, subprocess, sys, time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))

TASK_STATUS_RE = re.compile(r'^Task (\d+): (.*)$')
HEARTBEAT_RE = re.compile(r'^HEARTBEAT\s+(\S+)\s+(\S+)\s*(.*)$')
TASK_NUM_RE = re.compile(r'(\d+)')

TERMINAL_STATUSES = ('complete',)


def read(p):
    try:
        return open(p, encoding='utf-8', errors='replace').read()
    except OSError:
        return ''


def plan_tasks(plan_path, ledger_text=''):
    """Task numbers + titles from '### Task N: title' headings in the plan; plans
    written without those headings (e.g. the COMB/RXFIX plans) list them in the
    ledger instead as one 'Tasks: 1 = ...; 2 = ...' line, which is the fallback."""
    t = [(int(m.group(1)), m.group(2).strip()) for m in re.finditer(r'^### Task (\d+): (.+)$', read(plan_path), re.M)]
    if t:
        return t
    m = re.search(r'^Tasks:\s*(.+)$', ledger_text, re.M)
    if not m:
        return []
    return [(int(a), b.strip().rstrip('.')) for a, b in re.findall(r'(\d+)\s*=\s*([^;]+)', m.group(1))]


def ledger_state(ledger_text):
    """Per task number: (status, last line). Status precedence by the LAST matching line."""
    st = {}
    for line in ledger_text.splitlines():
        m = TASK_STATUS_RE.match(line.strip())
        if not m:
            continue
        n, rest = int(m.group(1)), m.group(2)
        low = rest.lower()
        if low.startswith('complete'):
            s = 'complete'
        elif 'parked' in low:
            s = 'parked'
        elif low.startswith('fix round'):
            s = 'fix round'
        elif 'review' in low and 'needs fixes' in low:
            s = 'needs fixes'
        elif 'reviewer dispatched' in low or 'implementer done' in low or low.startswith('done') or low.startswith('in review'):
            s = 'in review'
        elif low.startswith('in progress') or low.startswith('running'):
            s = 'running'
        elif low.startswith('dispatched') or 'dispatched implementer' in low:
            s = 'running'
        elif low.startswith('blocked'):
            s = 'blocked'
        else:
            s = st.get(n, ('pending', ''))[0]
        if st.get(n, ('', ''))[0] == 'complete' and s != 'complete':
            s = 'REOPENED: ' + s
        st[n] = (s, rest)
    return st


def parse_iso(s):
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.astimezone()
    return dt


def parse_heartbeats(ledger_text):
    """task id (e.g. 'task4') -> (dt, state_text, raw_line); last ISO-parseable
    heartbeat per task wins. Heartbeats whose timestamp field doesn't parse as
    ISO8601 (a handful of early campaign lines used bare 'HH:MM') are skipped for
    age purposes but never crash the scan."""
    out = {}
    for line in ledger_text.splitlines():
        m = HEARTBEAT_RE.match(line.strip())
        if not m:
            continue
        task_id, ts, state = m.group(1), m.group(2), m.group(3)
        dt = parse_iso(ts)
        if dt is None:
            continue
        if task_id not in out or dt > out[task_id][0]:
            out[task_id] = (dt, state.strip(), line.strip())
    return out


def parse_unitexits(ledger_text):
    """unit name -> latest (dt, result, code) from UNITEXIT lines."""
    out = {}
    for line in ledger_text.splitlines():
        m = re.match(r'^UNITEXIT\s+(\S+)\s+result=(\S+)\s+code=(\S+)\s+at=(\S+)', line.strip())
        if not m:
            continue
        unit, result, code, ts = m.groups()
        dt = parse_iso(ts)
        if dt is None:
            continue
        if unit not in out or dt > out[unit][0]:
            out[unit] = (dt, result, code)
    return out


def default_active_units():
    """Currently active/running systemd --user unit names."""
    try:
        r = subprocess.run(['systemctl', '--user', 'list-units', '--no-legend', '--plain',
                             '--state=running,active'], capture_output=True, text=True, timeout=10)
        return [line.split()[0] for line in r.stdout.splitlines() if line.strip()]
    except Exception:
        return []


def task_num_from_id(task_id):
    """'task4' -> '4', 'task9b' -> '9b' (its own ledger id), used to look up
    Task N: status lines (which use the bare numeric N, e.g. 'Task 9:')."""
    m = re.match(r'task(\d+[a-z]?)', task_id, re.I)
    return m.group(1) if m else None


def unit_matches_task(unit, task_num):
    """Heuristic: a rig unit belongs to task N if its name contains 'T<N>' as a
    token (legrun-T2-m16, ddrcap-T3-sel13) or 'task<N>' (task4, seqbist-task4)."""
    u = unit.lower()
    base = re.match(r'(\d+)', str(task_num))
    n = base.group(1) if base else str(task_num)
    if re.search(rf'(^|[^0-9a-z])t{n}([^0-9a-z]|$)', u):
        return True
    if f'task{n}' in u:
        return True
    return False


def unit_running_for_task(task_num, active_units):
    return any(unit_matches_task(u, task_num) for u in active_units)


def agent_rows(ledger_text, plan_path, stale_min=5, now=None, active_units=None):
    """One row per task with a non-terminal ledger status: dict with task, title,
    status, hb_time, hb_age_min, last_action, flag (ON-TASK / STALE / PENDING / DONE)."""
    now = now or datetime.now().astimezone()
    active_units = default_active_units() if active_units is None else active_units
    tasks = plan_tasks(plan_path, ledger_text)
    state = ledger_state(ledger_text)
    heartbeats = parse_heartbeats(ledger_text)
    rows = []
    for n, title in tasks:
        status, last_line = state.get(n, ('pending', ''))
        if status in TERMINAL_STATUSES:
            continue  # only non-terminal tasks are shown, per T0d spec
        task_id = f'task{n}'
        hb = heartbeats.get(task_id)
        unit_running = unit_running_for_task(n, active_units)
        if hb is not None:
            dt, state_text, raw = hb
            age_min = (now - dt).total_seconds() / 60.0
            last_action = state_text[:200] or raw[:200]
            hb_time = dt.isoformat(timespec='seconds')
            if age_min <= stale_min or unit_running:
                flag = 'ON-TASK'
            else:
                flag = 'STALE'
        else:
            age_min = None
            hb_time = None
            last_action = (last_line or '')[:200]
            if status == 'pending':
                flag = 'PENDING'
            elif unit_running:
                flag = 'ON-TASK'
            else:
                flag = 'STALE'
        rows.append({
            'task': n, 'title': title, 'status': status, 'hb_time': hb_time,
            'hb_age_min': None if age_min is None else round(age_min, 1),
            'last_action': last_action, 'flag': flag, 'unit_running': unit_running,
        })
    return rows


def _plan_path_for_ledger(root, ledger_path, ledger_text):
    m = re.search(r'plan: (\S+)', ledger_text.splitlines()[0] if ledger_text else '')
    plan_rel = m.group(1) if m else '?'
    return os.path.join(root, plan_rel)


def newest_ledgers(root, n=2):
    ledgers = sorted(glob.glob(os.path.join(root, '.superpowers', 'sdd', '*', 'progress.md'))
                      + glob.glob(os.path.join(root, 'two_jup', 'sdd_archive', '*', 'progress.md')),
                      key=os.path.getmtime, reverse=True)
    return ledgers[:n]


def campaign_name(ledger_path):
    """'.../sdd_archive/2026-09-04-rxfix/progress.md' -> '2026-09-04-rxfix'."""
    return os.path.basename(os.path.dirname(ledger_path))


def all_agent_rows(root, stale_min=5, now=None, active_units=None, n_ledgers=2):
    """Rows across the newest N campaign ledgers, tagged with their ledger path."""
    active_units = default_active_units() if active_units is None else active_units
    out = []
    for lg in newest_ledgers(root, n=n_ledgers):
        txt = read(lg)
        if not txt:
            continue
        plan_path = _plan_path_for_ledger(root, lg, txt)
        for row in agent_rows(txt, plan_path, stale_min=stale_min, now=now, active_units=active_units):
            row['ledger'] = lg
            row['campaign'] = campaign_name(lg)
            out.append(row)
    return out


def digest_lines(root, stale_min=5, now=None, active_units=None):
    """One line per active agent in the NEWEST ledger only, for agent_digest.sh /
    the controller's 5-minute Monitor: 'task<N> hb_age=<min> unit=<running unit or -> last=<state text <=80 chars> flag=<ON-TASK|STALE>'."""
    active_units = default_active_units() if active_units is None else active_units
    ledgers = newest_ledgers(root, n=1)
    if not ledgers:
        return []
    lg = ledgers[0]
    txt = read(lg)
    plan_path = _plan_path_for_ledger(root, lg, txt)
    lines = []
    for row in agent_rows(txt, plan_path, stale_min=stale_min, now=now, active_units=active_units):
        if row['flag'] not in ('ON-TASK', 'STALE'):
            continue  # digest is for active agents; PENDING tasks have no agent running yet
        unit = next((u for u in active_units if unit_matches_task(u, row['task'])), '-')
        hb_age = 'none' if row['hb_age_min'] is None else row['hb_age_min']
        last = (row['last_action'] or '')[:80]
        lines.append(f"task{row['task']} hb_age={hb_age} unit={unit} last={last} flag={row['flag']}")
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default=REPO_ROOT)
    ap.add_argument('--digest', action='store_true', help='print the controller 5-minute digest lines')
    ap.add_argument('--stale-min', type=int, default=5)
    a = ap.parse_args()
    if a.digest:
        for line in digest_lines(a.root, stale_min=a.stale_min):
            print(line)
        return 0
    for row in all_agent_rows(a.root, stale_min=a.stale_min):
        print(row)
    return 0


if __name__ == '__main__':
    sys.exit(main())
