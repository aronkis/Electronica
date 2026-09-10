# Parallel Datapath-Block Investigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the orchestration machinery that lets multiple subagents instrument datapath blocks in parallel while every hardware access is serialised through one arbiter, and every finding passes a positive-control gate before it can be believed.

**Architecture:** A directory-mutex rig arbiter (`mkdir` is atomic on POSIX) with a global halt flag guards the single flashable board. One-shot worker agents each run a fixed contract — sim-gate, sim positive control, acquire, flash with full rails, silicon positive control, measure, restore, release, report — and write atomic JSON state fragments that serve as both liveness heartbeat and dashboard data. The governor (the interactive session) is the sole writer of settled knowledge in `chain.json`, sweeps agent liveness every 10 minutes, and renders a live signal-chain page on nemo:8090.

**Tech Stack:** Bash (arbiter, agent helpers, sweep), Python 3 + pytest 9.0.3 (chain validator, renderer), `python3 -m http.server` (dashboard serving, the existing modem-status pattern), Verilator (sim gates), Vivado 2025.1 on nemo and hdl-dev-2 (builds).

**Spec:** `docs/superpowers/specs/2026-08-31-parallel-datapath-agents-design.md`

## Global Constraints

- **Board 148 only may be flashed. 146 is never flashed or touched**, except by the standard gated restore (`bringup_r2r3.sh r3`).
- **No retry loop.** A flash that fails *after touching the board* ⇒ roll back, write `RIG_HALT`, stop. A refusal at the pre-flash precondition (nothing staged) is not a failed flash.
- **Full flash rails every time:** restore point banked and named, readback verify, two-pass reset-aware health gate, auto-rollback.
- **§0 positive control:** no witness may produce a null result until demonstrated capable of a non-null. A clean-run health gate is NOT a positive control.
- **Closed topics, not to be reopened:** the 0.24 % vs 0.09 % header discrepancy (dissolved, spec §2); the start-pulse hypothesis (dead, spec §2).
- **Source-only resynth only.** No BD changes, no MATLAB regeneration.
- Paths: repo `/mnt/onetb/scratch/qpsk-jupiter-modem`, rig state `/home/tcollins/modem-status`, build hosts nemo (local, `/tools/Xilinx/2025.1`) and hdl-dev-2 = 10.0.0.11 (`/opt/Xilinx/2025.1/Vivado`, `~/qpsk-builds/`).
- Every patched RTL file must be written to **all 4 loose HDL copies AND both packaged zips** — Vivado synthesises the zip/ipshared copy.
- Commit with `git commit -s`.

---

### Task 1: Rig arbiter library

**Files:**
- Create: `two_jup/agents/rigmutex.sh`
- Test: `tests/agents/test_rigmutex.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: sourceable shell functions — `rig_halt_active()` → 0 if halted; `rig_halt_set(reason)`; `rig_halt_clear()`; `rig_acquire(agent, budget_seconds)` → 0 acquired, 2 halted, 3 timeout, 4 stale-held; `rig_heartbeat()`; `rig_phase(phase)`; `rig_release()` → 0 released, 1 not owner. Honours `RIG_DIR` (default `/home/tcollins/modem-status`) and `RIG_STALE_S` (default 600) for testing.

- [ ] **Step 1: Write the failing test**

Create `tests/agents/test_rigmutex.sh`:

```bash
#!/bin/bash
# Positive control for the rig arbiter: an exclusion mechanism that has never
# been observed to exclude is exactly a counter never seen to increment.
set -u
LIB=$(cd "$(dirname "$0")/../../two_jup/agents" && pwd)/rigmutex.sh
export RIG_DIR=$(mktemp -d); export RIG_STALE_S=2
fail(){ echo "FAIL: $1"; exit 1; }

# 1. exclusion: second acquire must fail while the first holds
( . "$LIB"; rig_acquire A 0 ) || fail "first acquire should succeed"
( . "$LIB"; rig_acquire B 0 ); [ $? -eq 3 ] || fail "second acquire should time out (3)"
echo "  ok: exclusion"

# 2. legacy files written for the sentinel and existing scripts
[ -e "$RIG_DIR/RIG_LOCK" ] || fail "legacy RIG_LOCK not written"
[ -e "$RIG_DIR/SENTINEL_STOP" ] || fail "SENTINEL_STOP not written"
echo "  ok: legacy compatibility files"

# 3. stale lock is REPORTED, not stolen
sleep 3   # exceeds RIG_STALE_S
out=$( . "$LIB"; rig_acquire C 0 ); rc=$?
[ $rc -eq 4 ] || fail "stale lock should return 4, got $rc"
echo "$out" | grep -q "NOT stealing" || fail "stale path must say it is not stealing"
[ -d "$RIG_DIR/RIG_MUTEX.d" ] || fail "stale lock must still exist (not stolen)"
echo "  ok: stale lock reported, not stolen"

# 4. release only by the owner, and it cleans up
rm -rf "$RIG_DIR/RIG_MUTEX.d" "$RIG_DIR/RIG_LOCK" "$RIG_DIR/SENTINEL_STOP"
( . "$LIB"; rig_acquire D 0 && rig_release ) || fail "owner release should succeed"
[ -d "$RIG_DIR/RIG_MUTEX.d" ] && fail "release must remove the mutex dir"
[ -e "$RIG_DIR/RIG_LOCK" ] && fail "release must remove legacy RIG_LOCK"
[ -e "$RIG_DIR/SENTINEL_STOP" ] && fail "release must remove SENTINEL_STOP"
echo "  ok: release cleans up"

# 5. RIG_HALT beats everything
( . "$LIB"; rig_halt_set "test halt" )
( . "$LIB"; rig_acquire E 0 ); [ $? -eq 2 ] || fail "acquire under RIG_HALT should return 2"
echo "  ok: RIG_HALT blocks acquisition"

rm -rf "$RIG_DIR"
echo "ALL RIGMUTEX TESTS PASS"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
mkdir -p tests/agents && chmod +x tests/agents/test_rigmutex.sh
bash tests/agents/test_rigmutex.sh
```
Expected: FAIL — `rigmutex.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

Create `two_jup/agents/rigmutex.sh`:

```bash
# rigmutex.sh -- rig arbiter for multiple actors. Source it.
# Replaces sim_repro/riglock.sh, which check-then-writes a plain file (TOCTOU)
# and exits the loser instead of queueing. mkdir is atomic on POSIX.
RIG_DIR="${RIG_DIR:-/home/tcollins/modem-status}"
RIG_MUTEX="$RIG_DIR/RIG_MUTEX.d"
RIG_HALT_F="$RIG_DIR/RIG_HALT"
RIG_LEGACY="$RIG_DIR/RIG_LOCK"
RIG_SENT_STOP="$RIG_DIR/SENTINEL_STOP"
RIG_STALE_S="${RIG_STALE_S:-600}"

rig_halt_active(){ [ -e "$RIG_HALT_F" ]; }
rig_halt_set(){ mkdir -p "$RIG_DIR"; printf '%s at=%s pid=%s\n' "$1" "$(date -Is)" "$$" > "$RIG_HALT_F"; }
rig_halt_clear(){ rm -f "$RIG_HALT_F"; }

rig_acquire(){            # $1 agent, $2 budget seconds (0 = try once)
  local agent="$1" budget="${2:-0}" waited=0 hb age
  mkdir -p "$RIG_DIR"
  while :; do
    if rig_halt_active; then echo "RIG_HALT: $(cat "$RIG_HALT_F")"; return 2; fi
    if mkdir "$RIG_MUTEX" 2>/dev/null; then
      RIG_AGENT="$agent"
      printf 'agent=%s pid=%s phase=acquired at=%s\n' "$agent" "$$" "$(date -Is)" > "$RIG_MUTEX/owner"
      : > "$RIG_MUTEX/heartbeat"
      printf 'owner=%s pid=%s since=%s\n' "$agent" "$$" "$(date +%F_%T)" > "$RIG_LEGACY"
      : > "$RIG_SENT_STOP"
      return 0
    fi
    hb=$(stat -c %Y "$RIG_MUTEX/heartbeat" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - hb ))
    if [ "$age" -gt "$RIG_STALE_S" ]; then
      echo "RIG_STALE owner='$(cat "$RIG_MUTEX/owner" 2>/dev/null)' heartbeat ${age}s old -- NOT stealing"
      return 4
    fi
    [ "$budget" -le 0 ] && return 3
    sleep 5; waited=$(( waited + 5 ))
    [ "$waited" -ge "$budget" ] && return 3
  done
}

rig_heartbeat(){ : > "$RIG_MUTEX/heartbeat" 2>/dev/null; }
rig_phase(){ printf 'agent=%s pid=%s phase=%s at=%s\n' "${RIG_AGENT:-?}" "$$" "$1" "$(date -Is)" > "$RIG_MUTEX/owner" 2>/dev/null; }
rig_release(){
  grep -q "pid=$$ " "$RIG_MUTEX/owner" 2>/dev/null || return 1
  rm -rf "$RIG_MUTEX"; rm -f "$RIG_LEGACY" "$RIG_SENT_STOP"; return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/agents/test_rigmutex.sh
```
Expected: five `ok:` lines then `ALL RIGMUTEX TESTS PASS`.

- [ ] **Step 5: Commit**

```bash
git add two_jup/agents/rigmutex.sh tests/agents/test_rigmutex.sh
git commit -s -m "Rig arbiter: directory mutex with global halt, stale-report-not-steal, legacy lock compatibility"
```

---

### Task 2: Agent state fragment helper

**Files:**
- Create: `two_jup/agents/agentstate.sh`
- Test: `tests/agents/test_agentstate.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `agent_state_init(agent, host, blocks)`; `agent_state_set(key, value)` for scalar keys; `agent_state_step(n, status)`; `agent_state_finding(text)`; `agent_state_flush()`. Writes `$RIG_DIR/agents/<agent>.json` atomically (temp + `mv`). Reader never sees a partial file.

- [ ] **Step 1: Write the failing test**

Create `tests/agents/test_agentstate.sh`:

```bash
#!/bin/bash
set -u
LIB=$(cd "$(dirname "$0")/../../two_jup/agents" && pwd)/agentstate.sh
export RIG_DIR=$(mktemp -d)
fail(){ echo "FAIL: $1"; exit 1; }
. "$LIB"

agent_state_init MEASURE nemo "TXCAP,DEMODCAP"
agent_state_set phase measuring
agent_state_set rig_held true
agent_state_step 6 pass
agent_state_finding "TXCAP golden 0xF00003FF"
agent_state_flush

F="$RIG_DIR/agents/MEASURE.json"
[ -f "$F" ] || fail "fragment not written"
python3 - "$F" <<'PY' || exit 1
import json,sys
d=json.load(open(sys.argv[1]))
assert d["agent"]=="MEASURE", d
assert d["host"]=="nemo", d
assert d["blocks"]=="TXCAP,DEMODCAP", d
assert d["phase"]=="measuring", d
assert d["rig_held"]=="true", d
assert d["step_status"]["6"]=="pass", d
assert "TXCAP golden 0xF00003FF" in d["findings"], d
assert d["last_heartbeat"], d
print("  ok: fragment is valid JSON with all fields")
PY

# atomicity: no temp file left behind, and every observed state parses
for i in $(seq 1 20); do agent_state_set phase "p$i"; agent_state_flush; done
ls "$RIG_DIR/agents/" | grep -q '\.tmp' && fail "temp file left behind"
python3 -c "import json;json.load(open('$F'))" || fail "fragment not parseable after rewrites"
echo "  ok: atomic rewrite leaves no temp and always parses"

rm -rf "$RIG_DIR"
echo "ALL AGENTSTATE TESTS PASS"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/agents/test_agentstate.sh
```
Expected: FAIL — `agentstate.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

Create `two_jup/agents/agentstate.sh`:

```bash
# agentstate.sh -- per-agent JSON state fragment. One file per agent, so there
# is no shared-file write race. Atomic (temp + mv): a reader never sees a
# partial write. Serves both liveness heartbeat and dashboard data.
RIG_DIR="${RIG_DIR:-/home/tcollins/modem-status}"
AGENT_DIR="$RIG_DIR/agents"

agent_state_init(){
  AS_AGENT="$1"; AS_HOST="$2"; AS_BLOCKS="$3"
  AS_STARTED="$(date -Is)"; AS_PHASE="init"; AS_RIG="false"
  AS_STEPS=""; AS_FINDINGS=""
  mkdir -p "$AGENT_DIR"
}
agent_state_set(){
  case "$1" in
    phase)    AS_PHASE="$2" ;;
    rig_held) AS_RIG="$2" ;;
    *)        AS_STEPS="$AS_STEPS\n" ;;
  esac
}
agent_state_step(){ AS_STEPS="${AS_STEPS}${AS_STEPS:+,}\"$1\":\"$2\""; }
agent_state_finding(){ AS_FINDINGS="${AS_FINDINGS}${AS_FINDINGS:+,}$(printf '%s' "$2$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"; }
agent_state_flush(){
  local f="$AGENT_DIR/$AS_AGENT.json" t="$AGENT_DIR/.$AS_AGENT.tmp"
  cat > "$t" <<JSON
{
  "agent": "$AS_AGENT",
  "host": "$AS_HOST",
  "blocks": "$AS_BLOCKS",
  "phase": "$AS_PHASE",
  "rig_held": "$AS_RIG",
  "started": "$AS_STARTED",
  "last_heartbeat": "$(date -Is)",
  "step_status": {$(printf '%b' "$AS_STEPS")},
  "findings": [$AS_FINDINGS]
}
JSON
  mv -f "$t" "$f"
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/agents/test_agentstate.sh
```
Expected: two `ok:` lines then `ALL AGENTSTATE TESTS PASS`.

- [ ] **Step 5: Commit**

```bash
git add two_jup/agents/agentstate.sh tests/agents/test_agentstate.sh
git commit -s -m "Agent state fragments: one atomic JSON file per agent, serving both liveness and dashboard"
```

---

### Task 3: Chain ledger with the hard positive-control gate

**Files:**
- Create: `two_jup/agents/chainctl.py`
- Create: `two_jup/chain.json`
- Test: `tests/agents/test_chainctl.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `load(path) -> dict`; `validate(chain) -> list[str]` returning error strings; `set_block(chain, name, status, provenance, run, positive_control, note) -> None`. Valid statuses: `UNTESTED`, `INSTRUMENTED`, `WITNESS-DEAD`, `MEASURED-CLEAN`, `MEASURED-DEVIATES`, `WITHDRAWN`. **`MEASURED-CLEAN` with `positive_control` not `true` is a validation error** — the §0 rule made structural.

- [ ] **Step 1: Write the failing test**

Create `tests/agents/test_chainctl.py`:

```python
import json, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "two_jup" / "agents"))
import chainctl

def _block(**kw):
    b = {"status": "UNTESTED", "provenance": "", "run": "", "positive_control": False, "note": ""}
    b.update(kw); return b

def test_measured_clean_requires_positive_control():
    chain = {"blocks": {"AGC out": _block(status="MEASURED-CLEAN", positive_control=False)}}
    errs = chainctl.validate(chain)
    assert any("positive_control" in e for e in errs), errs

def test_measured_clean_with_positive_control_is_valid():
    chain = {"blocks": {"AGC out": _block(status="MEASURED-CLEAN", positive_control=True,
                                          provenance="[SILICON]", run="two_jup/multitap/x")}}
    assert chainctl.validate(chain) == []

def test_deviates_does_not_require_positive_control_to_parse_but_is_flagged():
    chain = {"blocks": {"X": _block(status="MEASURED-DEVIATES", positive_control=False)}}
    errs = chainctl.validate(chain)
    assert any("positive_control" in e for e in errs), errs

def test_unknown_status_rejected():
    chain = {"blocks": {"X": _block(status="PROBABLY-FINE")}}
    assert any("status" in e for e in chainctl.validate(chain))

def test_set_block_roundtrip(tmp_path):
    p = tmp_path / "chain.json"
    chain = {"blocks": {}}
    chainctl.set_block(chain, "AGC out", "MEASURED-DEVIATES", "[SILICON]",
                       "two_jup/multitap/20260831_074947", True, "100.0 -> 50.0 % golden")
    p.write_text(json.dumps(chain))
    back = chainctl.load(str(p))
    assert back["blocks"]["AGC out"]["positive_control"] is True
    assert chainctl.validate(back) == []
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
python3 -m pytest tests/agents/test_chainctl.py -v
```
Expected: FAIL — `ModuleNotFoundError: No module named 'chainctl'`.

- [ ] **Step 3: Write minimal implementation**

Create `two_jup/agents/chainctl.py`:

```python
#!/usr/bin/env python3
"""chainctl -- governor-only reader/writer/validator for two_jup/chain.json.

The hard gate: a block may not be published MEASURED-CLEAN unless its witness
was demonstrated capable of a non-null (positive_control true). A witness never
seen to move renders WITNESS-DEAD, not clean. This is the section 0 rule made
structural rather than remembered -- it is the check that would have prevented
the withdrawn section 20 result.
"""
import json

STATUSES = {"UNTESTED", "INSTRUMENTED", "WITNESS-DEAD",
            "MEASURED-CLEAN", "MEASURED-DEVIATES", "WITHDRAWN"}
NEEDS_PC = {"MEASURED-CLEAN", "MEASURED-DEVIATES"}


def load(path):
    with open(path) as f:
        return json.load(f)


def save(chain, path):
    errs = validate(chain)
    if errs:
        raise ValueError("refusing to save an invalid chain: " + "; ".join(errs))
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(chain, f, indent=2, sort_keys=True)
        f.write("\n")
    import os
    os.replace(tmp, path)


def validate(chain):
    errs = []
    for name, b in chain.get("blocks", {}).items():
        st = b.get("status")
        if st not in STATUSES:
            errs.append(f"{name}: unknown status {st!r}")
            continue
        if st in NEEDS_PC and b.get("positive_control") is not True:
            errs.append(f"{name}: status {st} requires positive_control true "
                        f"(section 0) -- publish WITNESS-DEAD instead")
        if st.startswith("MEASURED") and not b.get("run"):
            errs.append(f"{name}: status {st} requires a run directory")
        if st.startswith("MEASURED") and not b.get("provenance"):
            errs.append(f"{name}: status {st} requires a provenance label")
    return errs


def set_block(chain, name, status, provenance, run, positive_control, note):
    chain.setdefault("blocks", {})[name] = {
        "status": status, "provenance": provenance, "run": run,
        "positive_control": bool(positive_control), "note": note,
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
python3 -m pytest tests/agents/test_chainctl.py -v
```
Expected: 5 passed.

- [ ] **Step 5: Seed `chain.json` from established results and verify it validates**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
python3 - <<'PY'
import sys; sys.path.insert(0, "two_jup/agents")
import chainctl
c = {"blocks": {}}
S = chainctl.set_block
M = "two_jup/multitap/20260831_074947"
S(c, "Bit_Packetizer",      "UNTESTED", "", "", False, "")
S(c, "Scrambler",           "UNTESTED", "", "", False, "")
S(c, "QPSK_Modulator",      "UNTESTED", "", "", False, "agent TX-INT")
S(c, "TX RRC filter",       "UNTESTED", "", "", False, "agent TX-INT")
S(c, "Transmitter output",  "INSTRUMENTED", "", "", False, "TXCAP in image; agent MEASURE")
S(c, "AGC out",             "MEASURED-DEVIATES", "[SILICON]", M, True, "100.0 -> 50.0 % golden")
S(c, "RRC receive filter",  "UNTESTED", "", "", False, "agent RX-FE")
S(c, "postSymbolSync",      "MEASURED-DEVIATES", "[SILICON]", M, True, "99.7 -> 48.0 % golden")
S(c, "Coarse freq comp",    "UNTESTED", "", "", False, "agent RX-FE")
S(c, "postCarrierSync",     "MEASURED-DEVIATES", "[SILICON]", M, True, "100.0 -> 47.4 % golden")
S(c, "Preamble delay FIFO", "MEASURED-CLEAN", "[SILICON]", "two_jup/SINGLES_CAMPAIGN.md#20260830-0022", True,
    "displacement / push-on-full falsified across 7 bursts")
S(c, "Constellation (demod in)", "MEASURED-DEVIATES", "[SILICON]", M, True, "99.7 -> 46.2 % golden")
S(c, "Demod slice/serialise", "INSTRUMENTED", "", "", False, "DEMODCAP in image; agent MEASURE")
S(c, "FEC start / Viterbi reset", "MEASURED-CLEAN", "[SILICON]", "two_jup/startcnt/20260830_152844", True,
    "1.0000 startIn/vitReset/startOut per frame through 801k bit errors")
S(c, "BIST comparator",     "MEASURED-CLEAN", "[SILICON]", "two_jup/SESSION_20260830_AUTONOMOUS.md#5", True,
    "120-bit window characterised; scores only first 120 of 2240 bits")
chainctl.save(c, "two_jup/chain.json")
print("chain.json written, blocks:", len(c["blocks"]))
PY
python3 -c "import sys;sys.path.insert(0,'two_jup/agents');import chainctl;print('validate:', chainctl.validate(chainctl.load('two_jup/chain.json')) or 'OK')"
```
Expected: `chain.json written, blocks: 15` then `validate: OK`.

- [ ] **Step 6: Commit**

```bash
git add two_jup/agents/chainctl.py two_jup/chain.json tests/agents/test_chainctl.py
git commit -s -m "Chain ledger with hard positive-control gate; seeded from established silicon results"
```

---

### Task 4: Dashboard renderer and server

**Files:**
- Create: `two_jup/agents/render_chain.py`
- Create: `two_jup/agents/serve_dashboard.sh`
- Test: `tests/agents/test_render_chain.py`

**Interfaces:**
- Consumes: `chainctl.load` from Task 3; agent fragments from Task 2.
- Produces: `render(chain, agents) -> str` (HTML); CLI `python3 two_jup/agents/render_chain.py <chain.json> <agents_dir> <out.html>`.

- [ ] **Step 1: Write the failing test**

Create `tests/agents/test_render_chain.py`:

```python
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "two_jup" / "agents"))
import render_chain

CHAIN = {"blocks": {
    "AGC out": {"status": "MEASURED-DEVIATES", "provenance": "[SILICON]",
                "run": "r1", "positive_control": True, "note": "100 -> 50 %"},
    "Sneaky":  {"status": "MEASURED-CLEAN", "provenance": "[SILICON]",
                "run": "r2", "positive_control": False, "note": "no PC"},
}}

def test_deviating_block_rendered():
    html = render_chain.render(CHAIN, {})
    assert "AGC out" in html and "MEASURED-DEVIATES" in html

def test_clean_without_positive_control_is_downgraded_not_shown_clean():
    html = render_chain.render(CHAIN, {})
    assert "WITNESS-DEAD" in html, "clean-without-PC must render as WITNESS-DEAD"
    assert ">MEASURED-CLEAN<" not in html, "must never display MEASURED-CLEAN without a positive control"

def test_agent_fragments_shown():
    agents = {"MEASURE": {"agent": "MEASURE", "phase": "measuring", "rig_held": "true",
                          "last_heartbeat": "2026-08-31T09:00:00-04:00", "host": "nemo",
                          "blocks": "TXCAP", "findings": []}}
    html = render_chain.render(CHAIN, agents)
    assert "MEASURE" in html and "measuring" in html

def test_html_is_selfcontained():
    html = render_chain.render(CHAIN, {})
    assert html.strip().startswith("<!doctype html>")
    assert "<style>" in html
```

- [ ] **Step 2: Run test to verify it fails**

```bash
python3 -m pytest tests/agents/test_render_chain.py -v
```
Expected: FAIL — `ModuleNotFoundError: No module named 'render_chain'`.

- [ ] **Step 3: Write minimal implementation**

Create `two_jup/agents/render_chain.py`:

```python
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


def render(chain, agents):
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
</body></html>
"""


def main():
    chain_path, agents_dir, out = sys.argv[1], sys.argv[2], sys.argv[3]
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
    tmp = out + ".tmp"
    with open(tmp, "w") as f:
        f.write(render(chain, agents))
    os.replace(tmp, out)
    print(f"rendered {out}: {len(chain.get('blocks', {}))} blocks, {len(agents)} agents")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

```bash
python3 -m pytest tests/agents/test_render_chain.py -v
```
Expected: 4 passed.

- [ ] **Step 5: Create the serving script and start it**

Create `two_jup/agents/serve_dashboard.sh`:

```bash
#!/bin/bash
# serve_dashboard.sh -- regenerate chain.html every 30 s and serve modem-status
# on 8090, matching the existing dashboard pattern (python3 -m http.server).
set -u
R=/mnt/onetb/scratch/qpsk-jupiter-modem
D=/home/tcollins/modem-status
mkdir -p "$D/agents"
if ! (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ':8090 '; then
  ( cd "$D" && nohup python3 -m http.server 8090 >> "$D/server.log" 2>&1 & )
  echo "started http.server on 8090"
else
  echo "8090 already listening"
fi
while true; do
  python3 "$R/two_jup/agents/render_chain.py" "$R/two_jup/chain.json" "$D/agents" "$D/chain.html" >/dev/null 2>&1
  sleep 30
done
```

```bash
chmod +x two_jup/agents/serve_dashboard.sh
systemd-run --user --unit=chaindash --collect /bin/bash /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/agents/serve_dashboard.sh
sleep 35
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8090/chain.html
```
Expected: `200`.

- [ ] **Step 6: Commit**

```bash
git add two_jup/agents/render_chain.py two_jup/agents/serve_dashboard.sh tests/agents/test_render_chain.py
git commit -s -m "Signal-chain dashboard: renderer with hard positive-control gate, served on nemo:8090"
```

---

### Task 5: Governor liveness sweep

**Files:**
- Create: `two_jup/agents/sweep.sh`
- Test: `tests/agents/test_sweep.sh`

**Interfaces:**
- Consumes: `rigmutex.sh` (Task 1), agent fragments (Task 2).
- Produces: `sweep.sh` — one pass, prints nothing when healthy, prints `SWEEP_ALERT <reason>` lines on anomalies, exit 0 healthy / 1 alert. The governor runs it on a 10-minute Monitor loop.

- [ ] **Step 1: Write the failing test**

Create `tests/agents/test_sweep.sh`:

```bash
#!/bin/bash
set -u
S=$(cd "$(dirname "$0")/../../two_jup/agents" && pwd)/sweep.sh
export RIG_DIR=$(mktemp -d); export RIG_STALE_S=600; export SWEEP_NO_PING=1
mkdir -p "$RIG_DIR/agents"
fail(){ echo "FAIL: $1"; exit 1; }
frag(){ # $1 agent, $2 rig_held, $3 heartbeat-age-seconds
  printf '{"agent":"%s","host":"h","blocks":"b","phase":"measuring","rig_held":"%s","started":"x","last_heartbeat":"%s","step_status":{},"findings":[]}\n' \
    "$1" "$2" "$(date -Is -d "-$3 seconds")" > "$RIG_DIR/agents/$1.json"; }

frag ALIVE false 30
bash "$S" >/dev/null || fail "healthy sweep should exit 0"
[ -z "$(bash "$S")" ] || fail "healthy sweep should be silent"
echo "  ok: silent when healthy"

frag DEADNORIG false 1200
out=$(bash "$S"); [ $? -eq 1 ] || fail "stale agent should exit 1"
echo "$out" | grep -q "SWEEP_ALERT stale-no-rig DEADNORIG" || fail "expected stale-no-rig alert, got: $out"
[ -e "$RIG_DIR/RIG_HALT" ] && fail "stale agent NOT holding the rig must not halt the rig"
echo "  ok: stale agent without rig -> alert, no halt"

rm -f "$RIG_DIR/agents/DEADNORIG.json"
mkdir -p "$RIG_DIR/RIG_MUTEX.d"; echo "agent=DEADHOLDER pid=1 phase=flashing" > "$RIG_DIR/RIG_MUTEX.d/owner"
touch -d "-1200 seconds" "$RIG_DIR/RIG_MUTEX.d/heartbeat"
frag DEADHOLDER true 1200
out=$(bash "$S"); [ $? -eq 1 ] || fail "stale holder should exit 1"
echo "$out" | grep -q "SWEEP_ALERT stale-holder DEADHOLDER" || fail "expected stale-holder alert, got: $out"
[ -e "$RIG_DIR/RIG_HALT" ] || fail "stale HOLDER must write RIG_HALT"
echo "  ok: stale holder -> RIG_HALT written"

rm -rf "$RIG_DIR"
echo "ALL SWEEP TESTS PASS"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/agents/test_sweep.sh
```
Expected: FAIL — `sweep.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

Create `two_jup/agents/sweep.sh`:

```bash
#!/bin/bash
# sweep.sh -- one governor liveness pass. Silent when healthy; prints
# SWEEP_ALERT lines otherwise. Exit 0 healthy, 1 alert.
# A stale agent that HOLDS the rig is the dangerous case: it means something
# died mid-cycle, which is exactly when a second actor must not start flashing,
# so it writes RIG_HALT.
set -u
RIG_DIR="${RIG_DIR:-/home/tcollins/modem-status}"
RIG_STALE_S="${RIG_STALE_S:-600}"
AGENTS="$RIG_DIR/agents"
ALERT=0
now=$(date +%s)

if [ -e "$RIG_DIR/RIG_HALT" ]; then
  echo "SWEEP_ALERT rig-halted $(cat "$RIG_DIR/RIG_HALT")"; ALERT=1
fi

for f in "$AGENTS"/*.json; do
  [ -e "$f" ] || continue
  a=$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d['agent'],d.get('rig_held','false'),d.get('last_heartbeat',''))" "$f" 2>/dev/null) || continue
  set -- $a; name="$1"; held="$2"; hb="$3"
  hbs=$(date -d "$hb" +%s 2>/dev/null || echo 0)
  age=$(( now - hbs ))
  [ "$age" -le "$RIG_STALE_S" ] && continue
  if [ "$held" = "true" ]; then
    echo "SWEEP_ALERT stale-holder $name heartbeat ${age}s old -- writing RIG_HALT"
    printf 'stale holder %s at=%s\n' "$name" "$(date -Is)" > "$RIG_DIR/RIG_HALT"
    if [ -z "${SWEEP_NO_PING:-}" ]; then
      ping -c1 -W2 10.0.0.148 >/dev/null 2>&1 \
        && echo "SWEEP_ALERT board-148 still reachable" \
        || echo "SWEEP_ALERT board-148 UNREACHABLE -- dark-board case, operator attention"
    fi
    ALERT=1
  else
    echo "SWEEP_ALERT stale-no-rig $name heartbeat ${age}s old -- requeue as a fresh agent"
    ALERT=1
  fi
done
exit $ALERT
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/agents/test_sweep.sh
```
Expected: three `ok:` lines then `ALL SWEEP TESTS PASS`.

- [ ] **Step 5: Commit**

```bash
git add two_jup/agents/sweep.sh tests/agents/test_sweep.sh
git commit -s -m "Governor liveness sweep: silent when healthy, RIG_HALT on a stale rig holder"
```

---

### Task 6: Agent runbook

**Files:**
- Create: `two_jup/agents/AGENT_RUNBOOK.md`

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: the document pasted into every worker agent's prompt. No code.

- [ ] **Step 1: Write the runbook**

Create `two_jup/agents/AGENT_RUNBOOK.md` containing, verbatim:

```markdown
# Worker agent runbook

You are a ONE-SHOT worker. Run your cycle once, report, exit. Do not iterate;
a second attempt is a fresh agent dispatched by the governor.

## Absolute rules
1. Board 148 only. **146 is never flashed or touched.**
2. **No retry loop.** A flash that fails after touching the board: roll back,
   `rig_halt_set "<agent>: flash failed"`, release, report, exit.
3. **Positive control before any null.** If your witness has not been shown to
   produce a non-null, you may not report a null. Report WITNESS-DEAD instead.
4. Never steal a stale rig lock. Report it and exit.
5. Source-only resynth. No BD changes, no MATLAB regeneration.

## Cycle
```bash
. two_jup/agents/rigmutex.sh
. two_jup/agents/agentstate.sh
agent_state_init "<AGENT>" "<host>" "<blocks>"; agent_state_flush
```
1. **Design** the instrument: bounded capture, armed by a frame marker, scored
   by golden-constancy. No rolling signatures. No on-chip reference latch --
   the frame-8 reference latches during acquisition and is a bad baseline.
2. **Sim-gate**: Verilator, clean loopback, every witness frame-invariant.
   Fail => `agent_state_step 2 fail`, report, exit. No flash.
3. **Positive control in sim**: force a non-null. Fail => report, exit. No rig.
4. **Acquire**: `rig_acquire "<AGENT>" 5400` -- 0 ok, 2 halted, 3 timeout,
   4 stale (report, exit). Set `rig_held true`, heartbeat every 60 s.
5. **Flash** via `two_jup/skidfix/flash_148_stagesig.sh` with an **absolute**
   `BB` path and `BAK_MD5` = the image currently on 148. Full rails.
6. **Positive control on silicon** before the real measurement.
7. **Measure**, then restore: `RXM=16 RXQ=1 GATE_TRIES=12 two_jup/bringup_r2r3.sh r3`,
   restart both watchdogs, then `rig_release`.
8. **Report**: for each block -- status (UNTESTED / INSTRUMENTED / WITNESS-DEAD /
   MEASURED-CLEAN / MEASURED-DEVIATES), provenance ([SILICON] / [SIM] / [INFERRED]),
   run directory, whether the positive control passed, and the numbers.

## Report format (return this verbatim as your final message)
```
AGENT: <name>
BLOCKS: <comma-separated>
POSITIVE_CONTROL_SIM: pass|fail  <evidence>
POSITIVE_CONTROL_SILICON: pass|fail|n/a  <evidence>
FLASH: none|md5 <md5>  RAILS: green|rolled-back
RESULTS:
  <block>: <status> <provenance> quiet=<x>% burst=<y>% run=<dir>
RIG: released|halted
NOTES: <anything the governor must know>
```
```

- [ ] **Step 2: Verify it is complete and committed**

```bash
grep -c "^" two_jup/agents/AGENT_RUNBOOK.md
grep -q "No retry loop" two_jup/agents/AGENT_RUNBOOK.md && echo "runbook has the no-retry rule"
grep -q "Positive control before any null" two_jup/agents/AGENT_RUNBOOK.md && echo "runbook has the section 0 rule"
git add two_jup/agents/AGENT_RUNBOOK.md
git commit -s -m "Worker agent runbook: one-shot contract, absolute rules, report format"
```
Expected: both `runbook has ...` lines print.

---

### Task 7: Live arbiter dry-run — the gate before any worker

**Files:**
- Create: `tests/agents/dryrun_arbiter.sh`

**Interfaces:**
- Consumes: `rigmutex.sh`, `agentstate.sh`, `sweep.sh`.
- Produces: nothing durable — a pass/fail gate. **If this fails, no worker agent runs.**

- [ ] **Step 1: Write the dry-run**

Create `tests/agents/dryrun_arbiter.sh`:

```bash
#!/bin/bash
# Live arbiter dry-run against the REAL rig-state directory, with two
# contending no-op agents. This is the arbiter's own positive control: an
# exclusion mechanism never observed to exclude is a counter never seen to move.
# Touches NO hardware -- it only takes and releases the lock.
set -u
R=/mnt/onetb/scratch/qpsk-jupiter-modem
. "$R/two_jup/agents/rigmutex.sh"
fail(){ echo "DRYRUN FAIL: $1"; exit 1; }

rig_halt_active && fail "RIG_HALT already present -- clear it before the dry-run"
[ -d "$RIG_MUTEX" ] && fail "rig already held by $(cat "$RIG_MUTEX/owner" 2>/dev/null)"

rig_acquire DRYRUN_A 0 || fail "A could not acquire a free rig"
echo "  A acquired"
( . "$R/two_jup/agents/rigmutex.sh"; rig_acquire DRYRUN_B 0 ); rc=$?
[ $rc -eq 3 ] || fail "B should have been excluded (3), got $rc"
echo "  B correctly excluded while A holds"
grep -q "SENTINEL_STOP" /dev/null; [ -e "$RIG_SENT_STOP" ] || fail "SENTINEL_STOP not written"
rig_release || fail "A could not release"
[ -d "$RIG_MUTEX" ] && fail "release left the mutex behind"
[ -e "$RIG_LEGACY" ] && fail "release left RIG_LOCK behind"
echo "  A released and cleaned up"

rig_halt_set "dryrun halt test"
( . "$R/two_jup/agents/rigmutex.sh"; rig_acquire DRYRUN_C 0 ); [ $? -eq 2 ] || fail "RIG_HALT did not block"
rig_halt_clear
echo "  RIG_HALT blocks acquisition, then clears"

echo "ARBITER DRY-RUN PASS -- workers may be dispatched"
```

- [ ] **Step 2: Run it and confirm the rig is free first**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
chmod +x tests/agents/dryrun_arbiter.sh
ls /home/tcollins/modem-status/RIG_LOCK /home/tcollins/modem-status/RIG_MUTEX.d 2>&1 | tail -2
bash tests/agents/dryrun_arbiter.sh
```
Expected: four `ok`-style lines then `ARBITER DRY-RUN PASS -- workers may be dispatched`.

- [ ] **Step 3: Confirm the sentinel recovers after the dry-run**

```bash
sleep 150
pgrep -af "[d]elivery_sentinel.sh" || echo "SENTINEL NOT BACK -- investigate before dispatching workers"
```
Expected: a `delivery_sentinel.sh` process (the keeper relaunches within 2 min of `SENTINEL_STOP` clearing). Use the bracket idiom — a plain pattern self-matches.

- [ ] **Step 4: Commit**

```bash
git add tests/agents/dryrun_arbiter.sh
git commit -s -m "Live arbiter dry-run: the gate that must pass before any worker agent is dispatched"
```

---

### Task 8: Dispatch agent MEASURE — first real use, end to end

**Files:**
- Modify: `two_jup/chain.json` (governor writes the result)

**Interfaces:**
- Consumes: everything above; the FINAL image `0f203cf887d3` currently on 148.
- Produces: `MEASURED-CLEAN` or `MEASURED-DEVIATES` (or `WITNESS-DEAD`) for `Transmitter output` and `Demod slice/serialise`.

- [ ] **Step 1: Confirm preconditions**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
two_jup/anyssh.sh 10.0.0.148 'md5sum /boot/BOOT.BIN | cut -c1-12'
ls /home/tcollins/modem-status/RIG_MUTEX.d /home/tcollins/modem-status/RIG_HALT 2>&1 | tail -2
```
Expected: `0f203cf887d3`, and both rig-state paths absent.

- [ ] **Step 2: Dispatch MEASURE with the runbook**

Dispatch one agent whose prompt is the contents of `two_jup/agents/AGENT_RUNBOOK.md` plus:

```
AGENT: MEASURE   HOST: none (no build, no flash)
BLOCKS: Transmitter output (TXCAP), Demod slice/serialise (DEMODCAP)
You run the REDUCED contract: steps 4, 6, 7, 8 only.
Image 0f203cf887d3 is already on 148 and carries DBGCAP, TXCAP and DEMODCAP.
Registers: 0x208 fixctl (bit12 = TXCAP readout, bit13 = DEMODCAP readout),
0x20C capture, 0x210 mismatch counter (DO NOT USE -- its frame-8 reference
latches during acquisition and is a bad baseline; score 0x20C by
golden-constancy instead), 0x13C/0x140/0x144 cap_in/cap_deint/cap_out,
0x10C iq_debug_mux, 0x114 rx_input_select (0 = internal loopback).
Arm mode 1 exactly as two_jup/multitap_run.sh does, and set any mux AFTER the
0x000 soft reset -- the reset clears the AXI write registers.
POSITIVE CONTROL (step 6, mandatory): with fixctl[13] selected, park and confirm
the DEMODCAP capture is constant; then change what it observes and confirm the
capture value changes. If it never changes, report WITNESS-DEAD and collect
nothing.
Then hold fixctl[12]=1 for a full 400 s poll logging 0x20C once per second
alongside 0x104/0x108 and cap_in, and repeat for fixctl[13]=1.
Restore with RXM=16 RXQ=1 GATE_TRIES=12 two_jup/bringup_r2r3.sh r3, restart both
watchdogs, release the rig, and report in the runbook format.
```

- [ ] **Step 3: Run the sweep while it works**

```bash
bash two_jup/agents/sweep.sh; echo "sweep exit=$?"
```
Expected: silent, exit 0 (repeat every 10 minutes via a Monitor loop).

- [ ] **Step 4: Apply the §0 gate to the report, then write the ledger**

Only if `POSITIVE_CONTROL_SILICON: pass`. Otherwise set the blocks `WITNESS-DEAD`.

```bash
python3 - <<'PY'
import sys; sys.path.insert(0, "two_jup/agents")
import chainctl
c = chainctl.load("two_jup/chain.json")
# REPLACE the placeholders below with the agent's reported values before running.
chainctl.set_block(c, "Transmitter output", "<STATUS>", "[SILICON]", "<RUNDIR>", True, "<quiet>% -> <burst>% golden")
chainctl.set_block(c, "Demod slice/serialise", "<STATUS>", "[SILICON]", "<RUNDIR>", True, "<quiet>% -> <burst>% golden")
chainctl.save(c, "two_jup/chain.json")
print("ledger updated")
PY
curl -s http://localhost:8090/chain.html | grep -c "Transmitter output"
```
Expected: `ledger updated`, then `1`. `chainctl.save` refuses to write if the positive-control gate is violated.

- [ ] **Step 5: Verify the rig came back**

```bash
two_jup/anyssh.sh 10.0.0.148 'pgrep -c -x qpsk_tun; pgrep -c -f "[l]ock_watchdog"'
two_jup/anyssh.sh 10.0.0.146 'pgrep -c -x qpsk_tun; pgrep -c -f "[l]ock_watchdog"'
ls /home/tcollins/modem-status/RIG_MUTEX.d /home/tcollins/modem-status/RIG_LOCK 2>&1 | tail -2
```
Expected: `1` and `1` for both boards; both rig-state paths absent.

- [ ] **Step 6: Commit**

```bash
git add two_jup/chain.json
git commit -s -m "Agent MEASURE: TXCAP and DEMODCAP capture-constancy on image 0f203cf887d3"
```

---

## Self-Review

**Spec coverage:** §4.1 topology → Tasks 6, 8. §4.2 arbiter → Task 1. §4.3 agent contract → Task 6 (+ reduced contract for MEASURE in Task 8). §4.4 liveness → Tasks 2, 5. §5 dashboard and hard gate → Tasks 3, 4. §6 execution order → Task 8 (MEASURE first; TX-INT and RX-FE follow as later dispatches once MEASURE reports). §7 arbiter validation → Task 7. §8 error handling → Tasks 1, 5, 6. §9 testing → Tasks 1–5 tests plus Task 7.

**Gap accepted deliberately:** TX-INT and RX-FE are not tasks in this plan. They are *uses* of the machinery, each dispatched by the governor with the Task 6 runbook once MEASURE reports and the rig frees; their instruments cannot be specified until MEASURE says whether the transmitter itself deviates. Adding them now would be writing tasks against an unknown.

**Placeholder scan:** one intentional placeholder remains, in Task 8 Step 4 (`<STATUS>`, `<RUNDIR>`, `<quiet>`, `<burst>`), because those values do not exist until the agent reports. The step says so explicitly and `chainctl.save` validates before writing.

**Type consistency:** `rig_acquire` return codes (0/2/3/4) are used identically in Tasks 1, 6, 7. `agent_state_*` names match between Tasks 2, 5, 6. `chainctl.set_block(chain, name, status, provenance, run, positive_control, note)` has the same seven-argument signature in Tasks 3 and 8. `render_chain.render(chain, agents)` matches between Task 4's test and its CLI. Status strings are identical across `chainctl.STATUSES`, `render_chain.COLOR`, the runbook and the spec.
