#!/usr/bin/env python3
"""txfix_gate_fix_lanes.py -- point every txfix-gate-* lane in two_jup/agents/lanes.json
at its run's growing .bin output instead of the systemd unit's stdout log (which the
harness only writes to at exit -- SUMMARY/READBACK lines -- so a stall detector polling
its mtime false-positives on every run still in flight). Idempotent; safe to re-run as
the still-live txfix_gate_launch.sh (already-running instance predates this fix and still
registers lanes with the old log path) appends more lanes. Host-only.
"""
import json, re, os

HERE = os.path.dirname(os.path.abspath(__file__))
LAUNCH_LOG = os.path.join(HERE, 'beat_runs', 'txfix_gate_launch.log')
LANES = os.path.join(HERE, '..', '..', 'two_jup', 'agents', 'lanes.json')

unit_to_bin = {}
if os.path.exists(LAUNCH_LOG):
    with open(LAUNCH_LOG) as f:
        for l in f:
            m = re.match(r'LAUNCHED (\S+) -> (\S+)', l)
            if not m:
                continue
            unit, log = m.groups()
            base = re.sub(r'^.*/txfix_gate_[A-Za-z0-9]+_', '', log)
            base = re.sub(r'\.log$', '', base)
            unit_to_bin[unit] = os.path.join(HERE, 'beat_runs', base + '.bin')

with open(LANES) as f:
    lanes = json.load(f)

changed = 0
for lane in lanes:
    unit = lane.get('unit', '')
    if unit in unit_to_bin and lane.get('log') != unit_to_bin[unit]:
        lane['log'] = unit_to_bin[unit]
        lane['max_age_min'] = 20
        changed += 1
    elif unit.startswith('txfix-gate-') and unit not in unit_to_bin:
        # not resolvable from the launch log (shouldn't happen) -- fail safe, don't stall-flag
        if lane.get('max_age_min', 0) < 60:
            lane['max_age_min'] = 60
            changed += 1

with open(LANES, 'w') as f:
    json.dump(lanes, f, indent=2)

print(f"txfix_gate_fix_lanes: {changed} lane(s) updated, {len(lanes)} total")
