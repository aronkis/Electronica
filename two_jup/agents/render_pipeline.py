#!/usr/bin/env python3
"""render_pipeline.py -- render the SDD task pipeline + results to a static HTML page for the LAN dashboard.
Sources: .superpowers/sdd/*/progress.md (ledgers), docs/superpowers/plans/<plan>.md (task titles),
two_jup/SESSION_20260830_AUTONOMOUS.md (result sections), git log, ~/modem-status/sentinel.log.
Usage: render_pipeline.py [--root REPO] [--out FILE]   (defaults: repo root of this file, ~/modem-status/pipeline.html)"""
import argparse, glob, html, json, os, re, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agent_watch import (plan_tasks, ledger_state, all_agent_rows, newest_ledgers,
                          campaign_name, default_active_units)

def read(p):
    try: return open(p, encoding='utf-8', errors='replace').read()
    except OSError: return ''

def read_json(p):
    try:
        with open(p, encoding='utf-8') as f: return json.load(f)
    except (OSError, ValueError): return None

def lane_is_active(unit):
    try:
        r = subprocess.run(['systemctl', '--user', '-q', 'is-active', unit], capture_output=True, timeout=10)
        return r.returncode == 0
    except Exception: return False

def lanes_rows(root, is_active=lane_is_active):
    """Lane rows from two_jup/agents/lanes.json: (name, unit, active?, log age str, max_age_min)."""
    lanes = read_json(os.path.join(root, 'two_jup', 'agents', 'lanes.json')) or []
    rows = []
    for lane in lanes:
        name, unit, log, max_age = lane.get('name'), lane.get('unit'), lane.get('log'), lane.get('max_age_min')
        active = is_active(unit) if unit else False
        if log and os.path.exists(log):
            age = f"{(time.time() - os.path.getmtime(log)) / 60.0:.1f} min"
        else:
            age = 'no log'
        rows.append((name or '?', unit or '?', active, age, max_age))
    return rows

def notify_done_list(notify_dir):
    try: return sorted(os.path.basename(p) for p in glob.glob(os.path.join(notify_dir, '*.done')))
    except OSError: return []

def lanes_block(root, stalls_path=os.path.expanduser('~/modem-status/stalls.json'),
                 notify_dir=os.path.expanduser('~/modem-status/NOTIFY'), is_active=lane_is_active):
    parts = ["<h2>Lanes / stalls</h2>"]
    rows = lanes_rows(root, is_active=is_active)
    if rows:
        parts.append("<table><tr><th>lane</th><th>unit</th><th>state</th><th>log age</th><th>max age (min)</th></tr>")
        for name, unit, active, age, max_age in rows:
            tag = ('#1565c0', 'active') if active else ('#9e9e9e', 'inactive')
            parts.append(f"<tr><td>{html.escape(name)}</td><td><code>{html.escape(unit)}</code></td>"
                         f"<td><span class='tag' style='background:{tag[0]}'>{tag[1]}</span></td>"
                         f"<td>{html.escape(age)}</td><td>{html.escape(str(max_age))}</td></tr>")
        parts.append("</table>")
    else:
        parts.append("<p><small>no lanes registered</small></p>")
    stalls = read_json(stalls_path)
    if stalls:
        parts.append(f"<details open><summary>Stalls ({len(stalls)})</summary><ul>")
        for s in stalls:
            key = s.get('key', '?'); age = s.get('age_min', '?')
            parts.append(f"<li><span class='tag' style='background:#c62828'>{html.escape(str(key))}</span> age={html.escape(str(age))}</li>")
        parts.append("</ul></details>")
    else:
        parts.append("<p><small>stalls.json: none</small></p>")
    notify = notify_done_list(notify_dir)
    if notify:
        parts.append(f"<details><summary>NOTIFY .done ({len(notify)})</summary><ul>" +
                     "".join(f"<li><code>{html.escape(n)}</code></li>" for n in notify) + "</ul></details>")
    else:
        parts.append("<p><small>NOTIFY: none pending</small></p>")
    return "".join(parts)


def legs_block(root):
    """Rig-leg diagram (inline SVG) + a table of every comb leg run parsed from
    two_jup/comb/runs/*/meta.txt (legrun_go.sh / loopfloor_go.sh output)."""
    runs = sorted(glob.glob(os.path.join(root, 'two_jup', 'comb', 'runs', '*', 'meta.txt')))
    rows = []; nA = nB = nL = 0
    for m in runs:
        d = os.path.dirname(m); txt = read(m); kv = {}
        for line in txt.splitlines():
            for k, v in re.findall(r'(\w+)=("[^"]*"|\S*)', line):
                kv.setdefault(k, v)
        leg = kv.get('leg', '')
        if leg not in ('A', 'B', 'loopfloor'): continue
        name = os.path.basename(d)
        if leg == 'A': nA += 1; arrow = '146 → 148 (forward)'
        elif leg == 'B': nB += 1; arrow = '148 → 146 (reverse)'
        else: nL += 1; arrow = '148 internal loopback'
        knobs = ' '.join(f"{k}={kv[k]}" for k in ('rxm_148', 'rxm_146', 'drain_148', 'drain_146') if kv.get(k))
        wm = re.search(r'MID_CAPTURE_WEDGE after (\d+)s', txt)
        if wm: verdict, col = f"wedge @{wm.group(1)} s", '#c62828'
        elif kv.get('capture_r3_exit', '0') != '0': verdict, col = f"capture_r3 exit {kv['capture_r3_exit']}", '#c62828'
        elif leg == 'loopfloor': verdict, col = ('dry run', '#999') if kv.get('dry') == '1' else ('done', '#2e7d32')
        else: verdict, col = 'clean', '#2e7d32'
        gate = kv.get('deliver_rate_gate_pass', '')
        rate = kv.get('deliver_rate_pre', kv.get('rate_fps', ''))
        caps = []
        for cm in sorted(glob.glob(os.path.join(d, 'ddrcap_*', 'meta.txt'))):
            ct = read(cm); sel = re.search(r'sel=(\d+)', ct); cr = re.search(r'credited=(\w+)', ct)
            caps.append(f"sel{sel.group(1) if sel else '?'}:{cr.group(1) if cr else '?'}")
        rows.append((name, arrow, knobs or '—', verdict, col, gate, rate, ' '.join(caps) or '—'))
    svg = ("<svg viewBox='0 0 760 200' width='760' height='200' style='max-width:100%;font:13px system-ui,sans-serif'>"
           "<rect x='20' y='40' width='200' height='120' rx='10' fill='#e3f2fd' stroke='#1565c0'/>"
           "<text x='120' y='66' text-anchor='middle' font-weight='bold'>146 (10.0.0.146)</text>"
           "<text x='120' y='86' text-anchor='middle'>tmr lineage · txfixF3vendh</text>"
           "<text x='120' y='106' text-anchor='middle'>host: frames / failhdr / txlog</text>"
           "<text x='120' y='126' text-anchor='middle'>RX queue -M (default 16)</text>"
           "<rect x='540' y='40' width='200' height='120' rx='10' fill='#fff3e0' stroke='#ef6c00'/>"
           "<text x='640' y='66' text-anchor='middle' font-weight='bold'>148 (10.0.0.148)</text>"
           "<text x='640' y='86' text-anchor='middle'>byte lineage · txfixF3 (DDRCAP-v2)</text>"
           "<text x='640' y='106' text-anchor='middle'>host: frames / failhdr / txlog</text>"
           "<text x='640' y='126' text-anchor='middle'>taps: sel6 IQ · sel9 bits · sel13 mu</text>"
           "<defs><marker id='ah' markerWidth='10' markerHeight='10' refX='9' refY='5' orient='auto'><path d='M0,0 L10,5 L0,10 z' fill='#333'/></marker></defs>"
           "<line x1='225' y1='75' x2='535' y2='75' stroke='#333' stroke-width='2' marker-end='url(#ah)'/>"
           f"<text x='380' y='66' text-anchor='middle'>leg A · forward · 146 TX → 148 RX · {nA} run(s)</text>"
           "<line x1='535' y1='125' x2='225' y2='125' stroke='#333' stroke-width='2' marker-end='url(#ah)'/>"
           f"<text x='380' y='145' text-anchor='middle'>leg B · reverse · 148 TX → 146 RX · {nB} run(s)</text>"
           "<path d='M700,160 q40,30 -20,30' fill='none' stroke='#999' stroke-dasharray='4 3' marker-end='url(#ah)'/>"
           f"<text x='600' y='188' text-anchor='middle' fill='#666'>T1 loopback (MM2S → mod → demod → checker) · {nL} run(s)</text>"
           "<text x='380' y='100' text-anchor='middle' fill='#666'>RF over the air · loss scored at the RX host (lost frames in the denominator)</text>"
           "</svg>")
    parts = ["<h2>Rig legs (COMB campaign)</h2>", svg,
             "<table><tr><th>run</th><th>leg</th><th>knobs</th><th>outcome</th><th>rate gate</th><th>deliver f/s</th><th>DDRCAP captures</th></tr>"]
    for name, arrow, knobs, verdict, col, gate, rate, caps in rows[::-1]:
        parts.append(f"<tr><td><code>{html.escape(name)}</code></td><td>{html.escape(arrow)}</td><td><code>{html.escape(knobs)}</code></td>"
                     f"<td><span class='tag' style='background:{col}'>{html.escape(verdict)}</span></td><td>{html.escape(gate)}</td><td>{html.escape(rate)}</td><td><code>{html.escape(caps)}</code></td></tr>")
    parts.append("</table><small>outcome = capture_r3.sh wedge verdict / exit; captures = DDRCAP-v2 selector : credited (bytes + capTAP or SKIP_GOLD positive control)</small>")
    return "\n".join(parts)

def plan_status(ledger_text):
    m = re.search(r'^PLAN STATUS:\s*(.+)$', ledger_text, re.M)
    return m.group(1).strip() if m else ''

def rulings(ledger_text):
    return [l.strip('- ').strip() for l in ledger_text.splitlines() if 'Ruling' in l]

def sections(session_path, first=76):
    out = []
    for m in re.finditer(r'^## (§(\d+)[^\n]*)$', read(session_path), re.M):
        if int(m.group(2)) >= first: out.append(m.group(1))
    return out

def gitlog(root, n=12):
    try: return subprocess.run(['git', '-C', root, 'log', '--oneline', f'-{n}'], capture_output=True, text=True, timeout=10).stdout.splitlines()
    except Exception: return []

COLOR = {'complete': '#2e7d32', 'running': '#1565c0', 'in review': '#6a1b9a', 'fix round': '#ef6c00',
         'needs fixes': '#ef6c00', 'parked': '#795548', 'blocked': '#c62828', 'pending': '#9e9e9e'}

AGENT_FLAG_COLOR = {'ON-TASK': '#2e7d32', 'STALE': '#c62828', 'PENDING': '#9e9e9e', 'DONE': '#795548'}

def agents_block(root, stale_min=5, active_units=None, now=None):
    """Agent status block: every task in the newest ledger (and the previous one)
    with a non-terminal status, its last heartbeat age and action, and an
    ON-TASK / STALE / PENDING flag (T0d, plan happy-bubbling-owl.md)."""
    active_units = default_active_units() if active_units is None else active_units
    rows = all_agent_rows(root, stale_min=stale_min, active_units=active_units, now=now, n_ledgers=2)
    parts = ["<h2>Agents (5-min heartbeat check)</h2>"]
    if not rows:
        parts.append("<p><small>no non-terminal tasks in the newest two ledgers</small></p>")
        return "".join(parts)
    parts.append("<table><tr><th>campaign</th><th>task</th><th>title</th><th>ledger status</th>"
                 "<th>last heartbeat</th><th>age (min)</th><th>last action</th><th>flag</th></tr>")
    for r in rows:
        col = AGENT_FLAG_COLOR.get(r['flag'], '#999')
        hb = r['hb_time'] or '—'
        age = '—' if r['hb_age_min'] is None else f"{r['hb_age_min']:.1f}"
        parts.append(f"<tr><td><code>{html.escape(r['campaign'])}</code></td><td>task{r['task']}</td>"
                     f"<td>{html.escape(r['title'])}</td><td>{html.escape(r['status'])}</td>"
                     f"<td>{html.escape(hb)}</td><td>{age}</td>"
                     f"<td><code>{html.escape(r['last_action'][:180])}</code></td>"
                     f"<td><span class='tag' style='background:{col}'>{html.escape(r['flag'])}</span></td></tr>")
    parts.append("</table>")
    return "".join(parts)

def _grep_state_md5(root, pattern):
    """Text lookup of a `<board> image md5 <hex>`-shaped line in RXFIX_STATE.md,
    falling back to SEQBIST_STATE.md (RXFIX_STATE.md does not exist until T4 lands)."""
    for name in ('RXFIX_STATE.md', 'SEQBIST_STATE.md'):
        txt = read(os.path.join(root, 'two_jup', name))
        if not txt: continue
        m = re.search(pattern, txt)
        if m: return m.group(1), name
    return None, None

def rig_hold_block(root):
    """Hold-file presence + per-board image md5 (text lookup only, no board contact)."""
    parts = ["<h3>Hold files / image state</h3><table>"]
    for fname in ('SENTINEL_STOP', 'RIG_LOCK'):
        p = os.path.expanduser(f'~/modem-status/{fname}')
        present = os.path.exists(p)
        col = '#c62828' if present else '#2e7d32'
        state = 'present (rig held)' if present else 'absent'
        parts.append(f"<tr><td><code>{fname}</code></td><td><span class='tag' style='background:{col}'>{html.escape(state)}</span></td></tr>")
    for board, pattern in (('148', r'148[^\n]*?image[^\n]*?md5[^\n]*?`([0-9a-f]{8,32})`'),
                           ('146', r'146[^\n]*?image[^\n]*?md5[^\n]*?`([0-9a-f]{8,32})`')):
        md5, src = _grep_state_md5(root, pattern)
        val = f"{html.escape(md5)} ({html.escape(src)})" if md5 else 'unknown'
        parts.append(f"<tr><td>{board} image md5</td><td><code>{val}</code></td></tr>")
    parts.append("</table>")
    return "".join(parts)

def render(root, out, sentinel='/home/tcollins/modem-status/sentinel.log',
           stalls_path=os.path.expanduser('~/modem-status/stalls.json'),
           notify_dir=os.path.expanduser('~/modem-status/NOTIFY'), is_active=lane_is_active):
    now = time.strftime('%Y-%m-%d %H:%M:%S %Z')
    ledgers = sorted(glob.glob(os.path.join(root, '.superpowers', 'sdd', '*', 'progress.md'))
                     + glob.glob(os.path.join(root, 'two_jup', 'sdd_archive', '*', 'progress.md')),  # closed plans, archived in git
                     key=os.path.getmtime, reverse=True)
    campaign = campaign_name(ledgers[0]) if ledgers else 'qpsk-jupiter-modem'
    parts = [f"<!doctype html><html><head><meta charset='utf-8'><meta http-equiv='refresh' content='300'>"
             f"<title>Pipeline — {html.escape(campaign)}</title><style>body{{font:14px/1.4 system-ui,sans-serif;margin:20px;background:#fafafa;color:#222}}"
             "table{border-collapse:collapse;margin:8px 0 18px}td,th{border:1px solid #ddd;padding:4px 8px;text-align:left;vertical-align:top}"
             "th{background:#eee}.tag{color:#fff;padding:1px 7px;border-radius:9px;font-size:12px}h2{margin-top:26px}code{font-size:12px}"
             f"small{{color:#666}}</style></head><body><h1>Task pipeline — {html.escape(campaign)}</h1>"
             f"<small>rendered {html.escape(now)} · auto-refresh 5 min · regenerated every 5 min (render-pipeline.timer) and on task completion</small>"]
    parts.append(agents_block(root))
    for lg in ledgers:
        txt = read(lg); m = re.search(r'plan: (\S+)', txt.splitlines()[0] if txt else '')
        plan_rel = m.group(1) if m else '?'; plan_path = os.path.join(root, plan_rel)
        tasks = plan_tasks(plan_path, txt); state = ledger_state(txt)
        current = [n for n, (s, _) in state.items() if s in ('running', 'in review', 'fix round', 'needs fixes')]
        pst = plan_status(txt) or ('ACTIVE (newest ledger)' if lg == ledgers[0] else 'older plan')
        base = os.path.basename(plan_rel).replace('.md', '')
        tag = (base[11:] if re.match(r'\d{4}-\d{2}-\d{2}-', base) else base)[:18]   # strip a YYYY-MM-DD- prefix only when present
        parts.append(f"<h2>{html.escape(os.path.basename(plan_rel))} <span class='tag' style='background:{'#2e7d32' if pst.startswith('ACTIVE') else '#795548'}'>{html.escape(pst)}</span></h2><small>ledger {html.escape(os.path.relpath(lg, root))} · "
                     f"updated {time.strftime('%H:%M', time.localtime(os.path.getmtime(lg)))}"
                     f"{' · <b>active: Task ' + ', '.join(map(str, sorted(current))) + '</b>' if current else ''}</small>")
        parts.append("<table><tr><th>#</th><th>Task</th><th>Status</th><th>Last ledger line</th></tr>")
        for n, title in tasks:
            s, last = state.get(n, ('pending', ''))
            col = '#c62828' if s.startswith('REOPENED') else COLOR.get(s, '#999')
            parts.append(f"<tr><td>{html.escape(tag)}·T{n}</td><td>{html.escape(title)}</td><td><span class='tag' style='background:{col}'>{html.escape(s)}</span></td>"
                         f"<td><code>{html.escape(last[:220])}</code></td></tr>")
        parts.append("</table>")
        rl = rulings(txt)
        if rl:
            parts.append("<details><summary>Rulings (" + str(len(rl)) + ")</summary><ul>" + "".join(f"<li>{html.escape(r[:400])}</li>" for r in rl) + "</ul></details>")
    ns_idx = 2
    ns = os.path.join(root, 'two_jup', 'NEXT_STEPS.md')
    if os.path.exists(ns):
        parts.insert(ns_idx, "<h2>Next steps</h2><pre style='white-space:pre-wrap'>" + html.escape(read(ns)) + "</pre>")
        ns_idx += 1
    parts.insert(ns_idx, lanes_block(root, stalls_path=stalls_path, notify_dir=notify_dir, is_active=is_active))
    parts.insert(ns_idx + 1, legs_block(root))
    parts.append("<h2>Results (session log sections §76+)</h2><ul>")
    for s in sections(os.path.join(root, 'two_jup', 'SESSION_20260830_AUTONOMOUS.md')):
        parts.append(f"<li>{html.escape(s)}</li>")
    parts.append("</ul><h2>Recent commits</h2><pre>" + html.escape("\n".join(gitlog(root))) + "</pre>")
    sl = read(sentinel).splitlines()
    parts.append("<h2>Rig</h2>" + rig_hold_block(root) +
                 "<h3>Sentinel log tail</h3><pre>" + html.escape("\n".join(sl[-3:]) if sl else 'no sentinel log') + "</pre>")
    parts.append("<p><a href='index.html'>← dashboard index</a></p></body></html>")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + '.tmp'; open(tmp, 'w').write("\n".join(parts)); os.replace(tmp, out)
    return out

def main():
    here = os.path.dirname(os.path.abspath(__file__)); default_root = os.path.abspath(os.path.join(here, '..', '..'))
    ap = argparse.ArgumentParser(); ap.add_argument('--root', default=default_root); ap.add_argument('--out', default=os.path.expanduser('~/modem-status/pipeline.html'))
    a = ap.parse_args(); print(render(a.root, a.out)); return 0

if __name__ == '__main__':
    sys.exit(main())
