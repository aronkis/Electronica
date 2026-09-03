#!/usr/bin/env python3
"""render_pipeline.py -- render the SDD task pipeline + results to a static HTML page for the LAN dashboard.
Sources: .superpowers/sdd/*/progress.md (ledgers), docs/superpowers/plans/<plan>.md (task titles),
two_jup/SESSION_20260830_AUTONOMOUS.md (result sections), git log, ~/modem-status/sentinel.log.
Usage: render_pipeline.py [--root REPO] [--out FILE]   (defaults: repo root of this file, ~/modem-status/pipeline.html)"""
import argparse, glob, html, os, re, subprocess, sys, time

def read(p):
    try: return open(p, encoding='utf-8', errors='replace').read()
    except OSError: return ''

def plan_tasks(plan_path):
    return [(int(m.group(1)), m.group(2).strip()) for m in re.finditer(r'^### Task (\d+): (.+)$', read(plan_path), re.M)]

def ledger_state(ledger_text):
    """Per task number: (status, last line). Status precedence by the LAST matching line."""
    st = {}
    for line in ledger_text.splitlines():
        m = re.match(r'^Task (\d+): (.*)$', line.strip())
        if not m: continue
        n, rest = int(m.group(1)), m.group(2)
        low = rest.lower()
        if low.startswith('complete'): s = 'complete'
        elif 'parked' in low: s = 'parked'
        elif low.startswith('fix round'): s = 'fix round'
        elif 'review' in low and 'needs fixes' in low: s = 'needs fixes'
        elif 'reviewer dispatched' in low or 'implementer done' in low: s = 'in review'
        elif low.startswith('dispatched') or 'dispatched implementer' in low: s = 'running'
        elif low.startswith('blocked'): s = 'blocked'
        else: s = st.get(n, ('pending', ''))[0]
        if st.get(n, ('', ''))[0] == 'complete' and s != 'complete':
            s = 'REOPENED: ' + s            # a task that left 'complete' is flagged, never silently downgraded
        st[n] = (s, rest)
    return st

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

def render(root, out, sentinel='/home/tcollins/modem-status/sentinel.log'):
    now = time.strftime('%Y-%m-%d %H:%M:%S %Z')
    parts = [f"<!doctype html><html><head><meta charset='utf-8'><meta http-equiv='refresh' content='300'>"
             f"<title>Pipeline — qpsk-jupiter-modem</title><style>body{{font:14px/1.4 system-ui,sans-serif;margin:20px;background:#fafafa;color:#222}}"
             "table{border-collapse:collapse;margin:8px 0 18px}td,th{border:1px solid #ddd;padding:4px 8px;text-align:left;vertical-align:top}"
             "th{background:#eee}.tag{color:#fff;padding:1px 7px;border-radius:9px;font-size:12px}h2{margin-top:26px}code{font-size:12px}"
             f"small{{color:#666}}</style></head><body><h1>Task pipeline</h1><small>rendered {html.escape(now)} · auto-refresh 5 min · regenerated every 30 min and on task completion</small>"]
    ledgers = sorted(glob.glob(os.path.join(root, '.superpowers', 'sdd', '*', 'progress.md'))
                     + glob.glob(os.path.join(root, 'two_jup', 'sdd_archive', '*', 'progress.md')),  # closed plans, archived in git
                     key=os.path.getmtime, reverse=True)
    for lg in ledgers:
        txt = read(lg); m = re.search(r'plan: (\S+)', txt.splitlines()[0] if txt else '')
        plan_rel = m.group(1) if m else '?'; plan_path = os.path.join(root, plan_rel)
        tasks = plan_tasks(plan_path); state = ledger_state(txt)
        current = [n for n, (s, _) in state.items() if s in ('running', 'in review', 'fix round', 'needs fixes')]
        pst = plan_status(txt) or ('ACTIVE (newest ledger)' if lg == ledgers[0] else 'older plan')
        tag = os.path.basename(plan_rel).replace('.md', '')[11:][:14]
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
    parts.append("<h2>Results (session log sections §76+)</h2><ul>")
    for s in sections(os.path.join(root, 'two_jup', 'SESSION_20260830_AUTONOMOUS.md')):
        parts.append(f"<li>{html.escape(s)}</li>")
    parts.append("</ul><h2>Recent commits</h2><pre>" + html.escape("\n".join(gitlog(root))) + "</pre>")
    sl = read(sentinel).splitlines()
    parts.append("<h2>Rig</h2><pre>" + html.escape("\n".join(sl[-3:]) if sl else 'no sentinel log') + "</pre>")
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
