import json
import os
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'agents'))
from stall_detector import run, scan_heartbeats  # noqa: E402


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


def test_lane_stall_then_clear():
    with tempfile.TemporaryDirectory() as d:
        lanes_path = os.path.join(d, 'lanes.json')
        log_path = os.path.join(d, 'lane.log')
        ledger = os.path.join(d, 'sdd', 'progress.md')
        stalls_json = os.path.join(d, 'stalls.json')
        notify_dir = os.path.join(d, 'NOTIFY')

        _write(log_path, 'x')
        old_ts = time.time() - 20 * 60  # 20 min old
        os.utime(log_path, (old_ts, old_ts))
        _write(lanes_path, json.dumps([
            {'name': 'testlane', 'unit': 'fake-unit', 'log': log_path, 'max_age_min': 10}
        ]))
        _write(ledger, "# ledger\n")

        always_active = lambda unit: True  # noqa: E731

        # Run 1: should produce exactly one STALL line.
        result1 = run(lanes_path=lanes_path, sdd_root=os.path.join(d, 'sdd'),
                       ledger=ledger, stalls_path=stalls_json, notify_dir=notify_dir,
                       is_active=always_active)
        text1 = open(ledger).read()
        stall_lines1 = [l for l in text1.splitlines() if l.startswith('STALL lane=testlane')]
        assert len(stall_lines1) == 1
        assert len(result1['new_stalls']) == 1

        # Run 2 (log still stale): no new STALL line appended.
        result2 = run(lanes_path=lanes_path, sdd_root=os.path.join(d, 'sdd'),
                       ledger=ledger, stalls_path=stalls_json, notify_dir=notify_dir,
                       is_active=always_active)
        text2 = open(ledger).read()
        stall_lines2 = [l for l in text2.splitlines() if l.startswith('STALL lane=testlane')]
        assert len(stall_lines2) == 1  # still just the one from run 1
        assert len(result2['new_stalls']) == 0

        # Touch the log fresh -> stall clears, CLEAR line appended.
        os.utime(log_path, None)
        result3 = run(lanes_path=lanes_path, sdd_root=os.path.join(d, 'sdd'),
                       ledger=ledger, stalls_path=stalls_json, notify_dir=notify_dir,
                       is_active=always_active)
        text3 = open(ledger).read()
        clear_lines = [l for l in text3.splitlines() if l.startswith('CLEAR lane=testlane')]
        assert len(clear_lines) == 1
        assert len(result3['cleared']) == 1
        assert result3['stalls'] == []


def test_lane_not_stalled_when_unit_inactive():
    with tempfile.TemporaryDirectory() as d:
        lanes_path = os.path.join(d, 'lanes.json')
        log_path = os.path.join(d, 'lane.log')
        ledger = os.path.join(d, 'sdd', 'progress.md')
        stalls_json = os.path.join(d, 'stalls.json')
        notify_dir = os.path.join(d, 'NOTIFY')

        _write(log_path, 'x')
        old_ts = time.time() - 999 * 60
        os.utime(log_path, (old_ts, old_ts))
        _write(lanes_path, json.dumps([
            {'name': 'idlelane', 'unit': 'gone-unit', 'log': log_path, 'max_age_min': 10}
        ]))
        _write(ledger, "# ledger\n")

        never_active = lambda unit: False  # noqa: E731
        result = run(lanes_path=lanes_path, sdd_root=os.path.join(d, 'sdd'),
                     ledger=ledger, stalls_path=stalls_json, notify_dir=notify_dir,
                     is_active=never_active)
        assert result['stalls'] == []


def test_heartbeat_stall_flagged_when_dispatched_and_stale():
    with tempfile.TemporaryDirectory() as d:
        sdd_root = os.path.join(d, 'sdd')
        ledger = os.path.join(sdd_root, 'progress.md')
        stale_dt = datetime.now(timezone.utc).astimezone() - timedelta(minutes=40)
        _write(ledger,
               "Task 3: dispatched\n"
               f"HEARTBEAT task3 {stale_dt.isoformat(timespec='seconds')} working\n")
        now_dt = datetime.now(timezone.utc).astimezone()
        stalls = scan_heartbeats(sdd_root, now=now_dt)
        assert 'agent:task3' in stalls
        assert stalls['agent:task3']['age_min'] > 25


def test_heartbeat_not_flagged_when_recent():
    with tempfile.TemporaryDirectory() as d:
        sdd_root = os.path.join(d, 'sdd')
        ledger = os.path.join(sdd_root, 'progress.md')
        recent_dt = datetime.now(timezone.utc).astimezone() - timedelta(minutes=2)
        _write(ledger,
               "Task 3: dispatched\n"
               f"HEARTBEAT task3 {recent_dt.isoformat(timespec='seconds')} working\n")
        stalls = scan_heartbeats(sdd_root)
        assert 'agent:task3' not in stalls


def test_heartbeat_not_flagged_when_task_complete():
    with tempfile.TemporaryDirectory() as d:
        sdd_root = os.path.join(d, 'sdd')
        ledger = os.path.join(sdd_root, 'progress.md')
        stale_dt = datetime.now(timezone.utc).astimezone() - timedelta(minutes=40)
        _write(ledger,
               "Task 3: dispatched\n"
               f"HEARTBEAT task3 {stale_dt.isoformat(timespec='seconds')} working\n"
               "Task 3: complete (all done)\n")
        stalls = scan_heartbeats(sdd_root)
        assert 'agent:task3' not in stalls
