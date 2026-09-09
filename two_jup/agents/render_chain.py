#!/usr/bin/env python3
"""render_chain -- signal-chain dashboard.

Merges governor-owned settled knowledge (chain.json) with live per-agent
fragments. Hard gate: a block claiming MEASURED-CLEAN without a demonstrated
positive control is rendered WITNESS-DEAD. The renderer is the last line of
defence for the section 0 rule.
"""
import json, os, sys, datetime, html as _html

COLOR = {
    "UNTESTED": "#6b7280", "INSTRUMENTED": "#2563eb", "WITNESS-DEAD": "#b91c1c",
    "MEASURED-CLEAN": "#15803d", "MEASURED-DEVIATES": "#c2410c", "WITHDRAWN": "#7c3aed",
}
TASK_STATE_CLASS = {
    "queued": "task-queued", "running": "task-running", "review": "task-review",
    "blocked": "task-blocked", "complete": "task-complete",
}
ORDER = ["Bit_Packetizer", "Scrambler", "QPSK_Modulator", "TX RRC filter",
         "Transmitter output", "AGC out", "RRC receive filter", "postSymbolSync",
         "Coarse freq comp", "postCarrierSync", "Preamble delay FIFO",
         "Constellation (demod in)", "Demod slice/serialise",
         "FEC start / Viterbi reset", "BIST comparator"]


def effective_status(b):
    """MEASURED-CLEAN without a positive control is not clean."""
    if b.get("status") == "MEASURED-CLEAN" and b.get("positive_control") is not True:
        return "WITNESS-DEAD"
    return b.get("status", "UNTESTED")


def render(chain, agents, tasks=None):
    e = _html.escape
    blocks = chain.get("blocks", {})
    names = [n for n in ORDER if n in blocks] + [n for n in blocks if n not in ORDER]
    rows = []
    for n in names:
        b = blocks[n]
        st = effective_status(b)
        pc = "yes" if b.get("positive_control") is True else "NO"
        rows.append(
            f'<tr><td>{e(n)}</td>'
            f'<td><span class="pill" style="background:{COLOR.get(st, "#6b7280")}">{e(st)}</span></td>'
            f'<td>{e(b.get("provenance", ""))}</td><td class="pc-{pc}">{pc}</td>'
            f'<td>{e(b.get("note", ""))}</td><td class="run">{e(b.get("run", ""))}</td></tr>')
    arows = []
    for name in sorted(agents):
        a = agents[name]
        arows.append(
            f'<tr><td>{e(a.get("agent", name))}</td><td>{e(a.get("host", ""))}</td>'
            f'<td>{e(a.get("blocks", ""))}</td><td>{e(a.get("phase", ""))}</td>'
            f'<td>{e(str(a.get("rig_held", "")))}</td>'
            f'<td class="run">{e(a.get("last_heartbeat", ""))}</td></tr>')
    if not arows:
        arows.append('<tr><td colspan="6">no agents running</td></tr>')
    trows = []
    task_list = tasks.get("tasks") if isinstance(tasks, dict) else tasks
    if not isinstance(task_list, list):
        task_list = []
    for t in task_list:
        if not isinstance(t, dict):
            continue
        state = t.get("state", "")
        try:
            cls = TASK_STATE_CLASS.get(state, "task-unknown")
        except TypeError:
            cls = "task-unknown"          # unhashable state (e.g. a list) never crashes the page
        trows.append(
            f'<tr class="{cls}"><td>{e(str(t.get("id", "")))}</td>'
            f'<td>{e(str(t.get("title", "")))}</td>'
            f'<td><span class="pill task-pill">{e(str(state))}</span></td>'
            f'<td>{e(str(t.get("detail", "")))}</td>'
            f'<td class="run">{e(str(t.get("updated", "")))}</td></tr>')
    if not trows:
        trows.append('<tr><td colspan="5">no tasks recorded</td></tr>')
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Signal chain</title>
<meta http-equiv="refresh" content="30">
<style>
body{{font:14px system-ui,sans-serif;margin:2rem;background:#fafafa;color:#111}}
table{{border-collapse:collapse;width:100%;margin-bottom:2rem;background:#fff}}
th,td{{border:1px solid #e5e7eb;padding:.4rem .6rem;text-align:left;vertical-align:top}}
th{{background:#f3f4f6}}
.pill{{color:#fff;padding:.1rem .5rem;border-radius:.7rem;font-size:12px;white-space:nowrap}}
.run{{font-family:ui-monospace,monospace;font-size:12px;color:#555}}
.pc-NO{{color:#b91c1c;font-weight:700}} .pc-yes{{color:#15803d}}
tr.task-complete{{color:#9ca3af}}
tr.task-complete .task-pill{{background:#9ca3af}}
tr.task-running .task-pill{{background:#2563eb}}
tr.task-queued .task-pill{{background:#6b7280}}
tr.task-review .task-pill{{background:#c2410c}}
tr.task-blocked{{background:#fef2f2;font-weight:700}}
tr.task-blocked .task-pill{{background:#b91c1c}}
.task-unknown .task-pill{{background:#6b7280}}
.task-pill{{color:#fff;padding:.1rem .5rem;border-radius:.7rem;font-size:12px;white-space:nowrap}}
</style></head><body>
<h1>QPSK modem signal chain</h1>
<p>generated {datetime.datetime.now().isoformat(timespec='seconds')} &middot;
a block claiming MEASURED-CLEAN without a positive control renders WITNESS-DEAD</p>
<h2>Blocks</h2>
<table><tr><th>block</th><th>status</th><th>provenance</th><th>positive control</th><th>note</th><th>run</th></tr>
{''.join(rows)}</table>
<h2>Agents</h2>
<table><tr><th>agent</th><th>host</th><th>blocks</th><th>phase</th><th>rig held</th><th>last heartbeat</th></tr>
{''.join(arows)}</table>
<h2>Tasks in flight</h2>
<table><tr><th>id</th><th>title</th><th>state</th><th>detail</th><th>updated</th></tr>
{''.join(trows)}</table>
</body></html>
"""


def main():
    chain_path, agents_dir, out = sys.argv[1], sys.argv[2], sys.argv[3]
    tasks_path = sys.argv[4] if len(sys.argv) > 4 else None
    with open(chain_path) as f:
        chain = json.load(f)
    agents = {}
    if os.path.isdir(agents_dir):
        for fn in os.listdir(agents_dir):
            if fn.endswith(".json"):
                try:
                    with open(os.path.join(agents_dir, fn)) as f:
                        a = json.load(f)
                    agents[a.get("agent", fn)] = a
                except (json.JSONDecodeError, OSError):
                    continue      # a fragment mid-rename is skipped, never fatal
    tasks = None
    if tasks_path:
        try:
            with open(tasks_path) as f:
                tasks = json.load(f)
        except (json.JSONDecodeError, OSError):
            tasks = None          # missing or malformed tasks.json never takes the page down
    tmp = out + ".tmp"
    with open(tmp, "w") as f:
        f.write(render(chain, agents, tasks))
    os.replace(tmp, out)
    ntasks = len(tasks.get("tasks", [])) if isinstance(tasks, dict) else 0
    print(f"rendered {out}: {len(chain.get('blocks', {}))} blocks, {len(agents)} agents, {ntasks} tasks")


if __name__ == "__main__":
    main()
