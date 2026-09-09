#!/usr/bin/env python3
"""stall_detector.py -- TXFIX campaign stall detector (T4 monitoring).

Two independent checks, run every 5 min by stall-detector.timer:

1. Lane check: two_jup/agents/lanes.json is a list of
   {"name", "unit", "log", "max_age_min"}. For each lane whose unit is
   currently active (systemctl --user -q is-active <unit>), if <log>'s mtime
   is older than max_age_min minutes -> a lane stall.

2. Agent heartbeat check: every ledger under
   two_jup/sdd_archive/2026-09-03-seqbist/ (DEFAULT_SDD_ROOT) is scanned for `HEARTBEAT <agent>
   <ISO8601> ...` lines. For each agent, if its latest heartbeat is older
   than HEARTBEAT_STALE_MIN (25) minutes AND that agent's task (matched by
   `task<N>` -> `Task N:`) last had a `Task N: dispatched...` or
   `Task N: running...` status line -> an agent stall.

Findings are written to ~/modem-status/stalls.json (a list, timestamped) and
new stalls are appended to a ledger as `STALL lane=<name> age=<min>` /
`STALL agent=<name> age=<min>` lines; a stall that persists across runs is
NOT re-appended (de-duplicated via stalls.json state); a stall that
disappears gets a `CLEAR lane=<name>` / `CLEAR agent=<name>` line.

Also reports ~/modem-status/NOTIFY/*.done files (watch_unit.sh drops these
on unit exit) as pending notifications -- nothing here deletes them, so
"unacknowledged" == "still present on disk".
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
DEFAULT_LANES = os.path.join(HERE, 'lanes.json')
DEFAULT_SDD_ROOT = os.path.join(REPO_ROOT, 'two_jup', 'sdd_archive', '2026-09-04-rxfix')
DEFAULT_LEDGER = os.path.join(DEFAULT_SDD_ROOT, 'progress.md')
DEFAULT_STALLS_JSON = os.path.expanduser('~/modem-status/stalls.json')
DEFAULT_NOTIFY_DIR = os.path.expanduser('~/modem-status/NOTIFY')

# Fallback used only when STALL_STALE_MIN is unset; the RXFIX campaign (T0d, plan
# happy-bubbling-owl.md) sets STALL_STALE_MIN=5 explicitly in stall-detector.service.
HEARTBEAT_STALE_MIN = 25


def _stale_min(explicit=None):
    """Resolve the heartbeat staleness threshold: explicit arg > STALL_STALE_MIN env
    (read at call time, not import time, so tests can set/unset it) > the module
    default. A test that never sets the env still gets the historical 25 min."""
    if explicit is not None:
        return explicit
    try:
        return int(os.environ['STALL_STALE_MIN'])
    except (KeyError, ValueError):
        return HEARTBEAT_STALE_MIN

HEARTBEAT_RE = re.compile(r'^HEARTBEAT\s+(\S+)\s+(\S+)')
TASK_STATUS_RE = re.compile(r'^Task\s+(\d+[a-z]?):\s*(.*)$')


def iso_now():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec='seconds')


def parse_iso(s):
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None


def _age_minutes(ts, now):
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=now.tzinfo)
    return (now - ts).total_seconds() / 60.0


def default_is_active(unit):
    """True if `systemctl --user -q is-active <unit>` succeeds."""
    try:
        r = subprocess.run(['systemctl', '--user', '-q', 'is-active', unit],
                            capture_output=True, timeout=15)
        return r.returncode == 0
    except Exception:
        return False


def load_lanes(lanes_path):
    if not os.path.exists(lanes_path):
        return []
    try:
        with open(lanes_path, encoding='utf-8') as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    return data if isinstance(data, list) else []


def check_lanes(lanes, is_active=None, now=None):
    """Return a dict key -> stall record for lanes whose unit is active and
    whose log is stale (or missing)."""
    is_active = is_active or default_is_active
    now = now or time.time()
    out = {}
    for lane in lanes:
        name = lane.get('name')
        unit = lane.get('unit')
        log = lane.get('log')
        max_age_min = lane.get('max_age_min')
        if not name or not unit or not log or max_age_min is None:
            continue
        if not is_active(unit):
            continue
        if os.path.exists(log):
            age_min = (now - os.path.getmtime(log)) / 60.0
            missing = False
        else:
            age_min = float('inf')
            missing = True
        if age_min > max_age_min:
            key = f'lane:{name}'
            out[key] = {
                'key': key, 'type': 'lane', 'name': name, 'unit': unit,
                'log': log, 'age_min': None if missing else round(age_min, 1),
                'log_missing': missing, 'max_age_min': max_age_min,
            }
    return out


def _ledger_files(sdd_root):
    return sorted(glob.glob(os.path.join(sdd_root, '**', 'progress.md'), recursive=True))


def scan_heartbeats(sdd_root, now=None, stale_min=None):
    """Return dict key -> stall record for agents whose latest heartbeat is
    stale while their matching Task N: status is dispatched/running."""
    now = now or datetime.now().astimezone()
    stale_min = _stale_min(stale_min)
    latest_hb = {}   # agent -> (dt, ledger_path)
    latest_task = {}  # task_num(str) -> status text (last line wins, per ledger scanned)

    for ledger in _ledger_files(sdd_root):
        try:
            text = open(ledger, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        for line in text.splitlines():
            hm = HEARTBEAT_RE.match(line.strip())
            if hm:
                agent, ts = hm.group(1), hm.group(2)
                dt = parse_iso(ts)
                if dt is None:
                    continue
                if agent not in latest_hb or dt > latest_hb[agent][0]:
                    latest_hb[agent] = (dt, ledger)
                continue
            tm = TASK_STATUS_RE.match(line.strip())
            if tm:
                latest_task[tm.group(1)] = tm.group(2)

    out = {}
    for agent, (dt, ledger) in latest_hb.items():
        age_min = _age_minutes(dt, now)
        if age_min <= stale_min:
            continue
        m = re.search(r'(\d+[a-z]?)', agent)   # task8a -> '8a' (its own ledger line), not Task 8
        if not m:
            continue
        status = latest_task.get(m.group(1), '')
        low = status.lower()
        # active = anything that is not a terminal state (the ledger's free-text status lines
        # rarely start with 'dispatched'/'running' once work is under way; 02:17 miss: Task 6
        # sat at '148 flashed ...; stage 1 starting' through a 74-min heartbeat gap)
        if any(low.startswith(t) for t in ('complete', 'done', 'parked', 'blocked', 'cancel')):
            continue
        key = f'agent:{agent}'
        out[key] = {
            'key': key, 'type': 'agent', 'name': agent, 'ledger': ledger,
            'age_min': round(age_min, 1), 'last_status': status,
        }
    return out


def notify_pending(notify_dir):
    if not os.path.isdir(notify_dir):
        return []
    return sorted(os.path.basename(p) for p in glob.glob(os.path.join(notify_dir, '*.done')))


def _append_ledger(ledger, line):
    os.makedirs(os.path.dirname(ledger) or '.', exist_ok=True)
    with open(ledger, 'a', encoding='utf-8') as f:
        f.write(line + '\n')


def _load_prev_stalls(stalls_path):
    if not os.path.exists(stalls_path):
        return {}
    try:
        with open(stalls_path, encoding='utf-8') as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, list):
        return {}
    return {rec['key']: rec for rec in data if 'key' in rec}


def run(lanes_path=DEFAULT_LANES, sdd_root=DEFAULT_SDD_ROOT, ledger=DEFAULT_LEDGER,
        stalls_path=DEFAULT_STALLS_JSON, notify_dir=DEFAULT_NOTIFY_DIR,
        is_active=None, now_epoch=None, now_dt=None):
    lanes = load_lanes(lanes_path)
    lane_stalls = check_lanes(lanes, is_active=is_active, now=now_epoch)
    agent_stalls = scan_heartbeats(sdd_root, now=now_dt)

    current = {}
    current.update(lane_stalls)
    current.update(agent_stalls)

    prev = _load_prev_stalls(stalls_path)
    ts = iso_now()
    new_stalls, cleared = [], []

    for key, rec in current.items():
        if key in prev:
            rec['first_seen'] = prev[key].get('first_seen', ts)
        else:
            rec['first_seen'] = ts
            new_stalls.append(rec)
        rec['last_check'] = ts

    for key, rec in prev.items():
        if key not in current:
            cleared.append(rec)

    for rec in new_stalls:
        age = 'unknown' if rec.get('age_min') is None else rec['age_min']
        if rec['type'] == 'lane':
            _append_ledger(ledger, f"STALL lane={rec['name']} age={age} at={ts}")
        else:
            _append_ledger(rec.get('ledger', ledger), f"STALL agent={rec['name']} age={age} at={ts}")

    for rec in cleared:
        target_ledger = rec.get('ledger', ledger)
        if rec['type'] == 'lane':
            _append_ledger(ledger, f"CLEAR lane={rec['name']} at={ts}")
        else:
            _append_ledger(target_ledger, f"CLEAR agent={rec['name']} at={ts}")

    os.makedirs(os.path.dirname(stalls_path) or '.', exist_ok=True)
    tmp = stalls_path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(list(current.values()), f, indent=2, sort_keys=True)
    os.replace(tmp, stalls_path)

    return {
        'stalls': list(current.values()),
        'new_stalls': new_stalls,
        'cleared': cleared,
        'notify_pending': notify_pending(notify_dir),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--lanes', default=DEFAULT_LANES)
    ap.add_argument('--sdd-root', default=DEFAULT_SDD_ROOT)
    ap.add_argument('--ledger', default=DEFAULT_LEDGER)
    ap.add_argument('--stalls-json', default=DEFAULT_STALLS_JSON)
    ap.add_argument('--notify-dir', default=DEFAULT_NOTIFY_DIR)
    a = ap.parse_args()
    result = run(lanes_path=a.lanes, sdd_root=a.sdd_root, ledger=a.ledger,
                 stalls_path=a.stalls_json, notify_dir=a.notify_dir)
    print(f"STALL_DETECTOR active={len(result['stalls'])} new={len(result['new_stalls'])} "
          f"cleared={len(result['cleared'])} notify_pending={len(result['notify_pending'])}")
    for rec in result['new_stalls']:
        print(f"  NEW: {rec['key']} age={rec.get('age_min')}")
    for rec in result['cleared']:
        print(f"  CLEARED: {rec['key']}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
