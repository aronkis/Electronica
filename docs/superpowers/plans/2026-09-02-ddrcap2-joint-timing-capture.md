# DDRCAP-v2 Joint Timing-Plane Capture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, gate, flash (148 only) and run the DDRCAP-v2 instrument: every DDR record carries the selected tap's I/Q, the full 14-bit Peak_Search `timingOffset`, both sticky frame markers, and a 4-slot correlator-plane sidecar, plus four new full-rate upstream taps (sel 12–15); every channel positive-controlled in sim and on silicon; then the pre-registered sel-6 burst capture decides marker-moves (P1) vs data-moves (P2).

**Architecture:** A second-pass netlist injector (`ddrcap2_inject.py`) runs after the existing `ddrcap_inject.py` and threads the timing/correlator/interpolator signals from `Peak_Search`/`Correlator`/`Symbol_Synchronizer` up through FTS → QPSK_Rx → Receiver → TxRxComposite, repacks the two existing marker ports (ch2/ch3) and adds sel 12–15 to the existing mux. The five top-level ports, the packer, the DMA and the BD are unchanged (Option A). A Verilator gate with register forcing proves each field readable before the build; a 148-only flash chain with rollback to the banked TXMARK image flashes it; a decoder makes v2 captures v1-compatible for the existing scorers; the pre-registered analysis script issues the P1/P2 verdict.

**Tech Stack:** Python 3 (injector, decoder, analysis, pytest), Verilator 5.020 (C++ gate driver, `--public-flat-rw`), bash (build launcher to hdl-dev-2, flash chain, captures), Vivado 2025.1 on hdl-dev-2, 148 via `two_jup/anyssh.sh`.

**Spec:** `docs/superpowers/specs/2026-09-02-ddrcap2-joint-timing-capture-design.md` — §6 predictions are FROZEN; nothing in this plan reinterprets them.

## Global Constraints

- Boards: **148 only. 146 is never touched, never armed, never flashed.** Bring-up and health gate for this campaign are `two_jup/arm148_mode1.sh` (148-only, mode-1 loopback) — NOT `restore_known_good.sh`/`bringup_r2r3.sh` (both-board). Health criterion in mode 1 = `ARM_OK` with `capTAP=0xBCF94856` and `fps >= 1120`, passed TWICE (two-pass gate).
- Flash rails: restore point = the running image `boot_known_good/BOOT.BIN.148.txmark.1cd0cd752aa6` (banked, md5-named); on-board rollback copy `/root/BOOT.BIN.1cd0cd752aa6.bak` verified BEFORE flashing; readback md5 verify; two-pass gate; auto-rollback on any failure; **NO retry loop**; sentinel stopped for the flash (`touch ~/modem-status/SENTINEL_STOP`) and released after. Tier-2 witness capture is read BEFORE any rollback. One flash event per session unless the operator re-gates.
- Record layout (spec §2, exact): ch0=I, ch1=Q, ch2=`{mark_demod(1), mark_fec(1), timingOffset[13:0]}`, ch3=`{slot[1:0], side[13:0]}` with slot 0=`heldTs[13:0]`, 1=`timing_Reference_out1[13:0]`, 2=`runMax[31:18]`, 3=`Correlator.threshold[31:18]`. Little-endian int16 ×4 per record, one record per `ddrcap_valid` beat (the selected tap's own valid, AND `enb_1_2_0`). Sticky-latch marker semantics preserved per bit.
- New selectors (spec §3, exact): 12 = `{Correlator.dataOut[31:16], [15:0]}` valid `Correlator.validOut`; 13 = `I={underflow_sticky,4'b0,countReg[10:0]} Q={5'b0,mu[10:0]}` valid `enb_1_2_0`; 14 = `Symbol_Synchronizer.Delay8_out1_re/im[18:3]` valid `enb_1_2_0`; 15 = `I={beatobsRhCtr[7:0],beatobsPush[4:0],3'b0} Q={beatobsPop[4:0],11'b0}` valid `enb_1_2_0`. Selectors 0–11 unchanged (7 dead, 10 dup, untouched).
- Top-level IP ports unchanged: `ddrcap_i, ddrcap_q, ddrcap_mark_demod, ddrcap_mark_fec, ddrcap_valid`. `TxRxCompo_ip_dut.v`, `TxRxCompo_ip.v`, `component.xml`, `system.bd` are NOT modified.
- Netlist lineage: `s1_rtl_final` → `TXMARK=1 two_jup/skidfix/ddrcap_inject.py` → `two_jup/skidfix/ddrcap2_inject.py`. Sim gate must PASS byte-exact before `build_ddrcap.sh` starts.
- §0 positive-control rule: every channel has a Tier-1 (sim forced non-null + liveness) and Tier-2 (silicon) control (spec §4). A channel failing either is DEAD and reports nothing. "tOff held steady" may be reported only after its forced non-null and its silicon non-null (d0 differs across arms) have been seen.
- Geometry: 12,320 symbols/frame, 12,333 marker slots, 197,328 clks/frame (driver constant; a packet every 98,664 clks), 49,332 records/frame sample-domain, 12,333 symbol-domain. Rungs (symbols): 6176, 6240, 6299, 6363, 6432, 6489, 6548. Frame length is 12,320 so all offsets are modulo that (ROM plays identical frames); the three-way frame count (spec §6) is the guard.
- Commits: `git commit -s`, message ends with `Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq`. Local only, branch `per-under-1pct-2026-07`.
- Long jobs run under `systemd-run --user` (sim gate, build); rig-holding scripts start via `two_jup/launch_rig_unit.sh`; polls 1 s; one register per poll; host-side `stat` before any board-side `rm`; never re-run a transfer into an existing path.
- Provenance labels on every reported number: [silicon] / [sim] / [inferred].

---

## File map

| Path | Responsibility |
|---|---|
| `two_jup/skidfix/ddrcap2_inject.py` | Second-pass injector: source-module ports (IC/SS/PD), threading (FTS/QPSK_Rx/Receiver), composite ch2/ch3 packing + sel 12–15, zip patching + verification, idempotent |
| `two_jup/tests/test_ddrcap2_inject.py` | Unit tests on a scratch copy of the sim netlist + Verilator lint |
| `jupiter_240k5_byte/rtl_sim/build_ddrcap2_sim.sh` | Makes `s1_rtl_ddrcap2` and builds `obj_ddrcap2` (fast) and `obj_ddrcap2_flat` (flat-rw, for forcing) |
| `jupiter_240k5_byte/rtl_sim/sim_ddrcap2.cpp` | Tier-1 gate: PART A liveness/markers/slots for sel 0–15, PART B forced non-null per field, PART C tx-perturbation for sel 14 |
| `two_jup/ddrcap2_decode.py` + `two_jup/tests/test_ddrcap2_decode.py` | Record decoder (`decode()` API) and `--v1compat` writer |
| `jupiter_byte_ddrcap2_build/` (copy of `jupiter_byte_txmark_build/`) + `build_ddrcap.sh` | Vivado build tree and launcher (hdl-dev-2) |
| `two_jup/skidfix/flash_148_ddrcap2.sh` | 148-only flash chain with rails (Global Constraints) |
| `two_jup/ddrcap2_capture.sh` | One-shot capture of one selector on the current arm (Tier-2 + secondary arms) |
| `two_jup/ddrcap2_pc.py` + tests | Tier-2 per-channel silicon positive controls |
| `two_jup/beat_tap_capture.sh` + `two_jup/tests/fake_anyssh.sh`, `fake_arm.sh` | Burst-phased capture (mid + predicted onset) — from the beat plan, unchanged |
| `two_jup/ddrcap2_beat_analysis.py` + tests | Pre-registered §6 verdict: per-frame d_data, per-beat tOff, onset beats, three-way frame count, P1/P2 |
| `two_jup/SESSION_20260830_AUTONOMOUS.md` | §80 (gate), §81 (flash + Tier-2), §82 (verdict) |

---

### Task 1: Injector part 1 — source-module ports (Interpolation_Control, Symbol_Synchronizer, Preamble_Detector) + lint test

**Files:**
- Create: `two_jup/skidfix/ddrcap2_inject.py`
- Create: `two_jup/tests/test_ddrcap2_inject.py`
- Create: `jupiter_240k5_byte/rtl_sim/build_ddrcap2_sim.sh` (netlist step only in this task)

**Interfaces:**
- Consumes: `jupiter_240k5_byte/rtl_sim/s1_rtl_final/hdlsrc/commhdlQPSKTxRxLoopback/` (unpatched), `two_jup/skidfix/ddrcap_inject.py` (v1, run first with `TXMARK=1`).
- Produces: `ddrcap2_inject.py` with `patch_interpolation_control(path)`, `patch_symbol_synchronizer(path)`, `patch_preamble_detector(path)` returning `'patched'|'already'`, the port tables `PD_PORTS`, `SS_PORTS` (name, width, tag), and helpers `add_ports(s, after, names)`, `decl_lines(ports, kind, prefix='')`. Task 2 adds the remaining patchers and `main`.

- [ ] **Step 1: Write the failing test (netlist copy + lint harness)**

```python
# two_jup/tests/test_ddrcap2_inject.py
import os, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
SRC = os.path.join(ROOT, 'jupiter_240k5_byte/rtl_sim/s1_rtl_txmark/hdlsrc/commhdlQPSKTxRxLoopback')
sys.path.insert(0, os.path.join(ROOT, 'two_jup', 'skidfix'))
import ddrcap2_inject as inj

def _copy():
    d = tempfile.mkdtemp(prefix='ddrcap2_')
    for f in os.listdir(SRC):
        if f.endswith('.v'):
            shutil.copy(os.path.join(SRC, f), d)
    return d

def test_interpolation_control_exposes_countreg():
    d = _copy(); p = os.path.join(d, 'Interpolation_Control.v')
    assert inj.patch_interpolation_control(p) == 'patched'
    s = open(p).read()
    assert '           countRegOut);' in s and 'output  signed [10:0] countRegOut;' in s
    assert 'assign countRegOut = countReg;' in s
    assert inj.patch_interpolation_control(p) == 'already'

def test_symbol_synchronizer_exposes_dc_ports():
    d = _copy()
    inj.patch_interpolation_control(os.path.join(d, 'Interpolation_Control.v'))
    p = os.path.join(d, 'Symbol_Synchronizer.v')
    assert inj.patch_symbol_synchronizer(p) == 'patched'
    s = open(p).read()
    for n in ('dc_countreg', 'dc_mu', 'dc_underflow', 'dc_interp_re', 'dc_interp_im'):
        assert s.count(n) >= 3, n            # port list + decl + assign
    assert '.countRegOut(Interpolation_Control_countRegOut)' in s
    assert 'assign dc_interp_re = Delay8_out1_re;' in s

def test_preamble_detector_exposes_dc_ports():
    d = _copy(); p = os.path.join(d, 'Preamble_Detector.v')
    assert inj.patch_preamble_detector(p) == 'patched'
    s = open(p).read()
    assert 'assign dc_toff = Peak_Search_timingOffset;' in s
    assert 'assign dc_corr = Correlator_dataOut;' in s
    assert 'output  [13:0] dc_toff;' in s

def test_lint_after_source_patches():
    d = _copy()
    inj.patch_interpolation_control(os.path.join(d, 'Interpolation_Control.v'))
    inj.patch_symbol_synchronizer(os.path.join(d, 'Symbol_Synchronizer.v'))
    inj.patch_preamble_detector(os.path.join(d, 'Preamble_Detector.v'))
    r = subprocess.run(['verilator', '--lint-only', '-Wno-fatal', '-Wno-lint', '--top-module',
                        'Frequency_and_Time_Synchronizer', '-y', d,
                        os.path.join(d, 'Frequency_and_Time_Synchronizer.v')],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[-2000:]
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd two_jup && python3 -m pytest tests/test_ddrcap2_inject.py -q`
Expected: ImportError (`ddrcap2_inject` does not exist).

- [ ] **Step 3: Write the injector (part 1)**

```python
#!/usr/bin/env python3
"""ddrcap2_inject.py <netlist_dir> -- DDRCAP-v2 second-pass injector (spec
docs/superpowers/specs/2026-09-02-ddrcap2-joint-timing-capture-design.md).
Run AFTER `TXMARK=1 ddrcap_inject.py <dir>`. Threads the timing/correlator/
interpolator signals up to TxRxComposite, repacks the two marker ports as
ch2 = {mark_demod, mark_fec, timingOffset[13:0]} and ch3 = {slot, side[13:0]},
and adds selectors 12-15. Top-level IP ports, packer, DMA and BD are UNCHANGED.
Idempotent: every patcher returns 'already' on a patched file.
"""
import sys, os, io, re, zipfile

# (name, width-string ('' = 1 bit), tag)
PD_PORTS = [
    ("dc_toff", "[13:0]", "ufix14"),
    ("dc_tref", "[13:0]", "ufix14"),
    ("dc_heldts", "[31:0]", "uint32"),
    ("dc_corr", "signed [31:0]", "sfix32_En26"),
    ("dc_corrthr", "signed [31:0]", "sfix32_En28"),
    ("dc_corrvalid", "", ""),
]
SS_PORTS = [
    ("dc_countreg", "signed [10:0]", "sfix11"),
    ("dc_mu", "signed [10:0]", "sfix11_En10"),
    ("dc_underflow", "", ""),
    ("dc_interp_re", "signed [18:0]", "sfix19_En12"),
    ("dc_interp_im", "signed [18:0]", "sfix19_En12"),
]


def add_ports(s, after, names):
    """Insert port names into a module header after port `after` (handles both
    '           after,' and the terminal '           after);')."""
    a1 = f"           {after},\n"
    a2 = f"           {after});"
    ins = "".join(f"           {n},\n" for n in names)
    if a1 in s:
        return s.replace(a1, a1 + ins, 1)
    assert a2 in s, f"port anchor '{after}' not found"
    return s.replace(a2, f"           {after},\n" + ins.rstrip().rstrip(',') + ");", 1)


def decl_lines(ports, kind, prefix=''):
    """kind='output' -> port decls; kind='wire' -> local wires named prefix+name."""
    out = ""
    for n, w, tag in ports:
        nm = prefix + n
        if kind == 'output':
            out += f"  output  {w} {nm};  // {tag}\n" if w else f"  output  {nm};\n"
        else:
            out += f"  wire {w} {nm};  // {tag}\n" if w else f"  wire {nm};\n"
    return out


def _insert_after(s, anchor, text):
    assert anchor in s, f"anchor missing: {anchor[:60]!r}"
    return s.replace(anchor, anchor + text, 1)


def _insert_before_endmodule(s, text):
    assert '\nendmodule' in s
    j = s.rindex('\nendmodule')
    return s[:j] + '\n' + text.rstrip('\n') + '\n' + s[j:]


# ---------------------------------------------------------------- Interpolation_Control.v
def patch_interpolation_control(path):
    s = open(path).read()
    if 'countRegOut' in s:
        return 'already'
    assert 'reg signed [10:0] countReg;  // sfix11' in s, 'countReg decl anchor missing'
    s = add_ports(s, 'Underflow', ['countRegOut'])
    s = _insert_after(s, "  output  Underflow;\n", "  output  signed [10:0] countRegOut;  // sfix11\n")
    s = _insert_before_endmodule(s, "  assign countRegOut = countReg;  // DDRCAP2: raw NCO phase accumulator\n")
    assert s.count('countRegOut') == 3
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- Symbol_Synchronizer.v
def patch_symbol_synchronizer(path):
    s = open(path).read()
    if 'dc_countreg' in s:
        return 'already'
    for need in ("  wire signed [10:0] mu;  // sfix11_En10\n", "  wire Underflow;\n",
                 "  reg signed [18:0] Delay8_out1_re;  // sfix19_En12\n",
                 "  assign beatobsPop = Rate_Handle_beatobsPop;\n",
                 ".Underflow(Underflow)\n                                                                  );"):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    s = add_ports(s, 'beatobsPop', [n for n, _, _ in SS_PORTS])
    s = _insert_after(s, "  output  [4:0] beatobsPop;  // ufix5\n", decl_lines(SS_PORTS, 'output'))
    s = _insert_after(s, "  wire signed [10:0] mu;  // sfix11_En10\n",
                      "  wire signed [10:0] Interpolation_Control_countRegOut;  // sfix11\n")
    s = s.replace(".Underflow(Underflow)\n                                                                  );",
                  ".Underflow(Underflow),\n"
                  "                                                                  .countRegOut(Interpolation_Control_countRegOut)\n"
                  "                                                                  );", 1)
    s = _insert_after(s, "  assign beatobsPop = Rate_Handle_beatobsPop;\n",
                      "\n  // DDRCAP2 interpolator phase/buffer exposure\n"
                      "  assign dc_countreg = Interpolation_Control_countRegOut;\n"
                      "  assign dc_mu = mu;\n"
                      "  assign dc_underflow = Underflow;\n"
                      "  assign dc_interp_re = Delay8_out1_re;\n"
                      "  assign dc_interp_im = Delay8_out1_im;\n")
    assert '.countRegOut(Interpolation_Control_countRegOut)' in s
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- Preamble_Detector.v
def patch_preamble_detector(path):
    s = open(path).read()
    if 'dc_toff' in s:
        return 'already'
    for need in ("  wire [13:0] Peak_Search_timingOffset;  // ufix14\n",
                 "  wire [13:0] Peak_Search_p1c_tref;  // ufix14\n",
                 "  wire [31:0] Peak_Search_p1c_heldts;  // uint32\n",
                 "  wire signed [31:0] Correlator_dataOut;  // sfix32_En26\n",
                 "  wire signed [31:0] Correlator_threshold;  // sfix32_En28\n",
                 "  wire Correlator_validOut;\n",
                 "  assign fs_runmax = Peak_Search_p1c_runmax;\n",
                 "  output  signed [31:0] fs_runmax;  // sfix32_En26\n"):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    s = add_ports(s, 'fs_runmax', [n for n, _, _ in PD_PORTS])
    s = _insert_after(s, "  output  signed [31:0] fs_runmax;  // sfix32_En26\n", decl_lines(PD_PORTS, 'output'))
    s = _insert_after(s, "  assign fs_runmax = Peak_Search_p1c_runmax;\n",
                      "\n  // DDRCAP2 timing/correlator-plane exposure (full 14-bit timingOffset,\n"
                      "  // NOT PdTelemetry's 11-bit tOff)\n"
                      "  assign dc_toff = Peak_Search_timingOffset;\n"
                      "  assign dc_tref = Peak_Search_p1c_tref;\n"
                      "  assign dc_heldts = Peak_Search_p1c_heldts;\n"
                      "  assign dc_corr = Correlator_dataOut;\n"
                      "  assign dc_corrthr = Correlator_threshold;\n"
                      "  assign dc_corrvalid = Correlator_validOut;\n")
    assert s.count('dc_corrvalid') == 3
    open(path, 'w').write(s)
    return 'patched'
```

- [ ] **Step 4: Run the tests**

Run: `cd two_jup && python3 -m pytest tests/test_ddrcap2_inject.py -q`
Expected: 4 passed. If `test_preamble_detector_exposes_dc_ports` fails on `add_ports`, the PD header ends the list with a different port than `fs_runmax`; read the header (`sed -n 22,40p Preamble_Detector.v`), set `after` to the actual last port, and update the test's expectation accordingly — do not loosen the assert.

- [ ] **Step 5: Netlist step of the sim build script**

```bash
#!/bin/bash
# build_ddrcap2_sim.sh -- s1_rtl_ddrcap2 = s1_rtl_final + TXMARK=1 ddrcap_inject + ddrcap2_inject,
# then obj_ddrcap2 (ports only, threads) and obj_ddrcap2_flat (--public-flat-rw, for forcing).
set -eu
cd "$(dirname "$0")"
VD=s1_rtl_ddrcap2/hdlsrc/commhdlQPSKTxRxLoopback
if [ ! -d s1_rtl_ddrcap2 ] || [ "${FORCE:-0}" = 1 ]; then
  rm -rf s1_rtl_ddrcap2 && cp -a s1_rtl_final s1_rtl_ddrcap2
  TXMARK=1 python3 ../../two_jup/skidfix/ddrcap_inject.py s1_rtl_ddrcap2 | tail -2
  python3 ../../two_jup/skidfix/ddrcap2_inject.py s1_rtl_ddrcap2 | tail -3
  grep -q "ddrcap2_slot_r" "$VD/TxRxComposite.v" || { echo "ddrcap2 not injected"; exit 1; }
fi
COMMON="-O2 -Wno-fatal --cc --exe --build --top-module wrap_byte_ddrcap -y $VD -y . wrap_byte_ddrcap.v"
if [ "${NETLIST_ONLY:-0}" = 1 ]; then exit 0; fi
if [ ! -x obj_ddrcap2/Vwrap_byte_ddrcap ] || [ "${FORCE:-0}" = 1 ]; then
  verilator $COMMON --threads 4 -CFLAGS "-O2" -Mdir obj_ddrcap2 sim_ddrcap2.cpp -o Vwrap_byte_ddrcap 2>&1 | tail -3
fi
if [ ! -x obj_ddrcap2_flat/Vwrap_byte_ddrcap ] || [ "${FORCE:-0}" = 1 ]; then
  verilator $COMMON --public-flat-rw -CFLAGS "-O2 -DDDRCAP2_FLAT" -Mdir obj_ddrcap2_flat sim_ddrcap2.cpp -o Vwrap_byte_ddrcap 2>&1 | tail -3
fi
ls -la obj_ddrcap2/Vwrap_byte_ddrcap obj_ddrcap2_flat/Vwrap_byte_ddrcap
```
(The `python3 ddrcap2_inject.py` call and the `ddrcap2_slot_r` grep will not succeed until Task 2 adds `main` and the composite patch; in this task run only the tests. The script is committed now so Task 2 has it.)

- [ ] **Step 6: Commit**

```bash
git add two_jup/skidfix/ddrcap2_inject.py two_jup/tests/test_ddrcap2_inject.py jupiter_240k5_byte/rtl_sim/build_ddrcap2_sim.sh
git commit -s -m "DDRCAP2 injector part 1: expose countReg, interpolator buffer, timingOffset/tref/heldTs/correlator at their source modules; lint-tested

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

### Task 2: Injector part 2 — threading FTS → QPSK_Rx → Receiver → Composite, ch2/ch3 packing, sel 12–15, zips, main

**Files:**
- Modify: `two_jup/skidfix/ddrcap2_inject.py` (append)
- Modify: `two_jup/tests/test_ddrcap2_inject.py` (append)
- Test: full-tree patch on a scratch copy + Verilator lint of `TxRxComposite`; idempotency; zip verify on a copy of one `TxRxCompo_ip_v1_0.zip`

**Interfaces:**
- Consumes: Task 1 tables/helpers.
- Produces: `FTS_PORTS`, `RX_PORTS` (= `ddrcap_`+FTS names), `patch_fts`, `patch_qpsk_rx`, `patch_receiver`, `patch_composite`, `patch_zip`, `verify_zip`, `main(dir)`; CLI `ddrcap2_inject.py <dir>` printing `DDRCAP2_INJECT ...` and exit 0/1. Composite guard string `ddrcap2_slot_r`. Wire names at Composite: `Receiver_ddrcap_dc_<x>`.

- [ ] **Step 1: Append the failing tests**

```python
def _full(d):
    inj.patch_interpolation_control(os.path.join(d, 'Interpolation_Control.v'))
    inj.patch_symbol_synchronizer(os.path.join(d, 'Symbol_Synchronizer.v'))
    inj.patch_preamble_detector(os.path.join(d, 'Preamble_Detector.v'))
    inj.patch_fts(os.path.join(d, 'Frequency_and_Time_Synchronizer.v'))
    inj.patch_qpsk_rx(os.path.join(d, 'QPSK_Rx.v'))
    inj.patch_receiver(os.path.join(d, 'Receiver.v'))
    inj.patch_composite(os.path.join(d, 'TxRxComposite.v'))

def test_full_tree_lints_and_is_idempotent():
    d = _copy(); _full(d)
    s = open(os.path.join(d, 'TxRxComposite.v')).read()
    assert 'ddrcap2_slot_r' in s and "(ddrcap_sel_r == 4'd12) ? Receiver_ddrcap_dc_corr[31:16]" in s
    assert s.count("ddrcap_sel_r <= 4'd8 || ddrcap_sel_r >= 4'd12") == 3
    assert 'assign ddrcap_mark_demod = {ddrcap_demod_mark_now, ddrcap_fec_mark_now, Receiver_ddrcap_dc_toff[13:0]};' in s
    assert "16'h7FFF" not in s.split('ddrcap2_slot_r')[-1]    # old full-word marker assigns gone
    r = subprocess.run(['verilator', '--lint-only', '-Wno-fatal', '-Wno-lint', '--top-module', 'TxRxComposite',
                        '-y', d, os.path.join(d, 'TxRxComposite.v')], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[-3000:]
    # idempotent
    assert inj.patch_composite(os.path.join(d, 'TxRxComposite.v')) == 'already'
    assert inj.patch_qpsk_rx(os.path.join(d, 'QPSK_Rx.v')) == 'already'

def test_main_on_sim_tree_reports_success():
    d = _copy()
    assert inj.main(d) == 0
```

- [ ] **Step 2: Run → the two new tests fail (`patch_fts` undefined).**

- [ ] **Step 3: Append the threading, composite, zip and main code**

```python
FTS_PORTS = PD_PORTS + [("dc_runmax", "signed [31:0]", "sfix32_En26")] + SS_PORTS + [
    ("dc_rhctr", "[7:0]", "uint8"), ("dc_rhpush", "[4:0]", "ufix5"), ("dc_rhpop", "[4:0]", "ufix5")]
RX_PORTS = [("ddrcap_" + n, w, t) for n, w, t in FTS_PORTS]


# ---------------------------------------------------------------- Frequency_and_Time_Synchronizer.v
def patch_fts(path):
    s = open(path).read()
    if 'dc_toff' in s:
        return 'already'
    pd_tail = ("                                         .pdWitB(pdWitB));")
    ss_tail = (".beatobsPop(Symbol_Synchronizer_beatobsPop)  // ufix5\n"
               "                                                               );")
    for need in (pd_tail, ss_tail, "  assign p1c_telQ = Preamble_Detector_p1c_telQ;\n",
                 "  output  signed [31:0] fs_runmax;  // sfix32_En26\n",
                 "  wire signed [31:0] Preamble_Detector_fs_runmax;  // sfix32_En26\n",
                 "  wire [7:0] Symbol_Synchronizer_beatobsRhCtr;  // uint8\n"):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    s = add_ports(s, 'pdWitB', [n for n, _, _ in FTS_PORTS])
    s = _insert_after(s, "  output  signed [31:0] fs_runmax;  // sfix32_En26\n", decl_lines(FTS_PORTS, 'output'))
    # local wires for the two child instances
    s = _insert_after(s, "  wire signed [31:0] Preamble_Detector_fs_runmax;  // sfix32_En26\n",
                      decl_lines(PD_PORTS, 'wire', 'Preamble_Detector_'))
    s = _insert_after(s, "  wire [7:0] Symbol_Synchronizer_beatobsRhCtr;  // uint8\n",
                      decl_lines(SS_PORTS, 'wire', 'Symbol_Synchronizer_'))
    pd_conn = "".join(f"                                         .{n}(Preamble_Detector_{n}),\n" for n, _, _ in PD_PORTS)
    s = s.replace(pd_tail, "                                         .pdWitB(pdWitB),\n" + pd_conn.rstrip().rstrip(',') + ");", 1)
    ss_conn = "".join(f"                                                               .{n}(Symbol_Synchronizer_{n}),\n" for n, _, _ in SS_PORTS)
    s = s.replace(ss_tail, ".beatobsPop(Symbol_Synchronizer_beatobsPop),  // ufix5\n" + ss_conn.rstrip().rstrip(',') +
                  "\n                                                               );", 1)
    assigns = "\n  // DDRCAP2 pass-through\n"
    for n, _, _ in PD_PORTS:
        assigns += f"  assign {n} = Preamble_Detector_{n};\n"
    assigns += "  assign dc_runmax = Preamble_Detector_fs_runmax;\n"
    for n, _, _ in SS_PORTS:
        assigns += f"  assign {n} = Symbol_Synchronizer_{n};\n"
    assigns += ("  assign dc_rhctr = Symbol_Synchronizer_beatobsRhCtr;\n"
                "  assign dc_rhpush = Symbol_Synchronizer_beatobsPush;\n"
                "  assign dc_rhpop = Symbol_Synchronizer_beatobsPop;\n")
    s = _insert_after(s, "  assign p1c_telQ = Preamble_Detector_p1c_telQ;\n", assigns)
    assert '.dc_toff(Preamble_Detector_dc_toff)' in s and '.dc_mu(Symbol_Synchronizer_dc_mu)' in s
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- QPSK_Rx.v
def patch_qpsk_rx(path):
    s = open(path).read()
    if 'ddrcap_dc_toff' in s:
        return 'already'
    fts_anchor = "                                                                                      .p1c_telQ(Frequency_and_Time_Synchronizer_p1c_telQ),  // int16\n"
    for need in ("           ddrcap_fecstart);", "  output  ddrcap_fecstart;\n", fts_anchor,
                 "  wire signed [15:0] Frequency_and_Time_Synchronizer_p1c_telQ;  // int16\n"):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    s = add_ports(s, 'ddrcap_fecstart', [n for n, _, _ in RX_PORTS])
    s = _insert_after(s, "  output  ddrcap_fecstart;\n", decl_lines(RX_PORTS, 'output'))
    s = _insert_after(s, "  wire signed [15:0] Frequency_and_Time_Synchronizer_p1c_telQ;  // int16\n",
                      decl_lines(FTS_PORTS, 'wire', 'Frequency_and_Time_Synchronizer_'))
    conn = "".join(f"                                                                                      .{n}(Frequency_and_Time_Synchronizer_{n}),\n"
                   for n, _, _ in FTS_PORTS)
    s = s.replace(fts_anchor, fts_anchor + conn, 1)
    assigns = "\n  // DDRCAP2 pass-through\n" + "".join(
        f"  assign ddrcap_{n} = Frequency_and_Time_Synchronizer_{n};\n" for n, _, _ in FTS_PORTS)
    s = _insert_before_endmodule(s, assigns)
    assert 'assign ddrcap_dc_rhpop = Frequency_and_Time_Synchronizer_dc_rhpop;' in s
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- Receiver.v
def patch_receiver(path):
    s = open(path).read()
    if 'ddrcap_dc_toff' in s:
        return 'already'
    inst_tail = ".ddrcap_fecstart(QPSK_Rx_ddrcap_fecstart)\n                                      );"
    for need in ("           ddrcap_fecstart);", "  output  ddrcap_fecstart;\n", "  wire QPSK_Rx_ddrcap_fecstart;\n", inst_tail):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    s = add_ports(s, 'ddrcap_fecstart', [n for n, _, _ in RX_PORTS])
    s = _insert_after(s, "  output  ddrcap_fecstart;\n", decl_lines(RX_PORTS, 'output'))
    s = _insert_after(s, "  wire QPSK_Rx_ddrcap_fecstart;\n", decl_lines(RX_PORTS, 'wire', 'QPSK_Rx_'))
    conn = "".join(f"                                      .{n}(QPSK_Rx_{n}),\n" for n, _, _ in RX_PORTS)
    s = s.replace(inst_tail, ".ddrcap_fecstart(QPSK_Rx_ddrcap_fecstart),\n" + conn.rstrip().rstrip(',') +
                  "\n                                      );", 1)
    s = _insert_before_endmodule(s, "".join(f"  assign {n} = QPSK_Rx_{n};\n" for n, _, _ in RX_PORTS))
    assert s.count('ddrcap_dc_rhpop') == 4
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- TxRxComposite.v
COMPOSITE_PRE = """
  // DDRCAP2 (ddrcap2_inject.py): sidecar slot counter + sticky interpolator-underflow
  // latch, declared BEFORE the mux that reads ddrcap2_uf_now (Verilog use-before-declare).
  reg  [1:0] ddrcap2_slot_r;
  reg        ddrcap2_uf_latch;
  wire       ddrcap2_uf_now = Receiver_ddrcap_dc_underflow | ddrcap2_uf_latch;
"""
COMPOSITE_POST = """
  // DDRCAP2 ch2/ch3 packing (spec sec 2). Sticky-latch marker semantics unchanged:
  // ddrcap_demod_mark_now / ddrcap_fec_mark_now are the same nets as before, now one bit each.
  always @(posedge clk or posedge reset)
    begin : ddrcap2_slot_process
      if (reset == 1'b1) begin
        ddrcap2_slot_r <= 2'd0;
        ddrcap2_uf_latch <= 1'b0;
      end
      else if (enb_1_2_0) begin
        if (ddrcap_valid_beat) begin
          ddrcap2_slot_r <= ddrcap2_slot_r + 2'd1;
        end
        ddrcap2_uf_latch <= ddrcap_valid_beat ? 1'b0 : ddrcap2_uf_now;
      end
    end

  wire [13:0] ddrcap2_side =
      (ddrcap2_slot_r == 2'd0) ? Receiver_ddrcap_dc_heldts[13:0] :
      (ddrcap2_slot_r == 2'd1) ? Receiver_ddrcap_dc_tref[13:0] :
      (ddrcap2_slot_r == 2'd2) ? Receiver_ddrcap_dc_runmax[31:18] :
                                 Receiver_ddrcap_dc_corrthr[31:18];

  assign ddrcap_mark_demod = {ddrcap_demod_mark_now, ddrcap_fec_mark_now, Receiver_ddrcap_dc_toff[13:0]};
  assign ddrcap_mark_fec   = {ddrcap2_slot_r, ddrcap2_side};
"""
MUX_I_OLD = "      (ddrcap_sel_r == 4'd8) ? Transmitter_dataOutI :\n      16'sd0;"
MUX_I_NEW = ("      (ddrcap_sel_r == 4'd8) ? Transmitter_dataOutI :\n"
             "      (ddrcap_sel_r == 4'd12) ? Receiver_ddrcap_dc_corr[31:16] :\n"
             "      (ddrcap_sel_r == 4'd13) ? {ddrcap2_uf_now, 4'b0000, Receiver_ddrcap_dc_countreg[10:0]} :\n"
             "      (ddrcap_sel_r == 4'd14) ? Receiver_ddrcap_dc_interp_re[18:3] :\n"
             "      (ddrcap_sel_r == 4'd15) ? {Receiver_ddrcap_dc_rhctr[7:0], Receiver_ddrcap_dc_rhpush[4:0], 3'b000} :\n"
             "      16'sd0;")
MUX_Q_OLD = "      (ddrcap_sel_r == 4'd8) ? Transmitter_dataOutQ :\n      16'sd0;"
MUX_Q_NEW = ("      (ddrcap_sel_r == 4'd8) ? Transmitter_dataOutQ :\n"
             "      (ddrcap_sel_r == 4'd12) ? Receiver_ddrcap_dc_corr[15:0] :\n"
             "      (ddrcap_sel_r == 4'd13) ? {5'b00000, Receiver_ddrcap_dc_mu[10:0]} :\n"
             "      (ddrcap_sel_r == 4'd14) ? Receiver_ddrcap_dc_interp_im[18:3] :\n"
             "      (ddrcap_sel_r == 4'd15) ? {Receiver_ddrcap_dc_rhpop[4:0], 11'b00000000000} :\n"
             "      16'sd0;")
MUX_V_OLD = "      (ddrcap_sel_r == 4'd8) ? enb_1_2_0 :\n      1'b0;"
MUX_V_NEW = ("      (ddrcap_sel_r == 4'd8) ? enb_1_2_0 :\n"
             "      (ddrcap_sel_r == 4'd12) ? Receiver_ddrcap_dc_corrvalid :\n"
             "      (ddrcap_sel_r == 4'd13) ? enb_1_2_0 :\n"
             "      (ddrcap_sel_r == 4'd14) ? enb_1_2_0 :\n"
             "      (ddrcap_sel_r == 4'd15) ? enb_1_2_0 :\n"
             "      1'b0;")
OLD_MARKS = ("  assign ddrcap_mark_demod = ddrcap_demod_mark_now ? 16'h7FFF : 16'h0000;\n"
             "  assign ddrcap_mark_fec   = ddrcap_fec_mark_now   ? 16'h7FFF : 16'h0000;\n")


def patch_composite(path):
    s = open(path).read()
    if 'ddrcap2_slot_r' in s:
        return 'already'
    recv_tail = ".ddrcap_fecstart(Receiver_ddrcap_fecstart)\n                                        );"
    for need in ("  wire Receiver_ddrcap_fecstart;\n", recv_tail, MUX_I_OLD, MUX_Q_OLD, MUX_V_OLD, OLD_MARKS,
                 "  wire signed [15:0] ddrcap_mux_i =\n"):
        assert need in s, f'anchor missing in {path}: {need[:50]!r}'
    assert s.count("(ddrcap_sel_r <= 4'd8) ?") == 3, 'expected exactly 3 sel<=8 conditions'
    s = _insert_after(s, "  wire Receiver_ddrcap_fecstart;\n", decl_lines(RX_PORTS, 'wire', 'Receiver_'))
    conn = "".join(f"                                        .{n}(Receiver_{n}),\n" for n, _, _ in RX_PORTS)
    s = s.replace(recv_tail, ".ddrcap_fecstart(Receiver_ddrcap_fecstart),\n" + conn.rstrip().rstrip(',') +
                  "\n                                        );", 1)
    s = s.replace("  wire signed [15:0] ddrcap_mux_i =\n", COMPOSITE_PRE + "\n  wire signed [15:0] ddrcap_mux_i =\n", 1)
    s = s.replace(MUX_I_OLD, MUX_I_NEW, 1).replace(MUX_Q_OLD, MUX_Q_NEW, 1).replace(MUX_V_OLD, MUX_V_NEW, 1)
    s = s.replace("(ddrcap_sel_r <= 4'd8) ?", "(ddrcap_sel_r <= 4'd8 || ddrcap_sel_r >= 4'd12) ?")
    s = s.replace(OLD_MARKS, COMPOSITE_POST.lstrip('\n'), 1)
    assert s.count("ddrcap_sel_r <= 4'd8 || ddrcap_sel_r >= 4'd12") == 3
    assert '.ddrcap_dc_toff(Receiver_ddrcap_dc_toff)' in s and 'ddrcap2_slot_process' in s
    open(path, 'w').write(s)
    return 'patched'


# ---------------------------------------------------------------- dispatch / zip / main (mirrors ddrcap_inject.py)
PATCHERS = {
    'Interpolation_Control.v': patch_interpolation_control,
    'Symbol_Synchronizer.v': patch_symbol_synchronizer,
    'Preamble_Detector.v': patch_preamble_detector,
    'Frequency_and_Time_Synchronizer.v': patch_fts,
    'QPSK_Rx.v': patch_qpsk_rx,
    'Receiver.v': patch_receiver,
    'TxRxComposite.v': patch_composite,
}


def _patcher_for(base):
    if base in PATCHERS:
        return PATCHERS[base]
    if base.startswith('TxRxCompo_ip_src_') and base[len('TxRxCompo_ip_src_'):] in PATCHERS:
        return PATCHERS[base[len('TxRxCompo_ip_src_'):]]
    return None


EXPECTED_ZIP_MEMBERS = {
    'TxRxCompo_ip_src_Interpolation_Control.v': 'countRegOut',
    'TxRxCompo_ip_src_Symbol_Synchronizer.v': 'dc_countreg',
    'TxRxCompo_ip_src_Preamble_Detector.v': 'dc_toff',
    'TxRxCompo_ip_src_Frequency_and_Time_Synchronizer.v': 'dc_rhpop',
    'TxRxCompo_ip_src_QPSK_Rx.v': 'ddrcap_dc_toff',
    'TxRxCompo_ip_src_Receiver.v': 'ddrcap_dc_toff',
    'TxRxCompo_ip_src_TxRxComposite.v': 'ddrcap2_slot_r',
}


def patch_zip(zpath):
    buf = io.BytesIO(open(zpath, 'rb').read())
    zin = zipfile.ZipFile(buf, 'r'); entries = []; n = 0
    for item in zin.infolist():
        data = zin.read(item.filename)
        fn = _patcher_for(os.path.basename(item.filename))
        if fn is not None:
            tmp = zpath + '.ddrcap2_tmp'; os.makedirs(tmp, exist_ok=True)
            tp = os.path.join(tmp, os.path.basename(item.filename))
            open(tp, 'wb').write(data); status = fn(tp); data = open(tp, 'rb').read()
            os.remove(tp); os.rmdir(tmp); n += 1
            print(f"    zip member {os.path.basename(item.filename):50s} {status:8s}")
        entries.append((item, data))
    zin.close()
    out = io.BytesIO(); zout = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
    for item, data in entries:
        zout.writestr(item, data)
    zout.close(); open(zpath, 'wb').write(out.getvalue())
    return n


def verify_zip(zpath):
    zin = zipfile.ZipFile(zpath, 'r'); found = {}
    for item in zin.infolist():
        b = os.path.basename(item.filename)
        if b in EXPECTED_ZIP_MEMBERS:
            found[b] = zin.read(item.filename).decode()
    zin.close()
    ok = True
    for b, marker in EXPECTED_ZIP_MEMBERS.items():
        if b not in found or marker not in found[b]:
            print(f"    VERIFY_FAIL {zpath}: {b} missing or lacks {marker}"); ok = False
    return ok


def main(d):
    found = set()
    for root, _, files in os.walk(d):
        if root.endswith('.ddrcap2_tmp'):
            continue
        for f in files:
            fn = _patcher_for(f)
            if fn is None:
                continue
            p = os.path.join(root, f)
            print(f"  {f:45s} {fn.__name__:28s} -> {fn(p):8s} {p}")
            found.add(f)
    nz = nv = 0
    for root, _, files in os.walk(d):
        for f in files:
            if f == 'TxRxCompo_ip_v1_0.zip':
                zp = os.path.join(root, f); nz += 1
                print(f"  zip {zp}"); patch_zip(zp)
                if verify_zip(zp):
                    nv += 1; print(f"    VERIFY_OK {zp}")
    logical = {'Interpolation_Control', 'Symbol_Synchronizer', 'Preamble_Detector',
               'Frequency_and_Time_Synchronizer', 'QPSK_Rx', 'Receiver', 'TxRxComposite'}
    got = {f.replace('TxRxCompo_ip_src_', '').replace('.v', '') for f in found}
    missing = sorted(logical - got)
    build_tree = any(os.path.basename(r) in ('ipcore', 'vivado_ip_prj') or any(x.endswith('.xpr') for x in fs)
                     for r, _, fs in os.walk(d))
    print(f"DDRCAP2_INJECT loose={len(found)} missing={missing} zips={nz} zips_verified={nv}")
    if missing or (build_tree and nz == 0) or (nz and nv != nz) or (nz not in (0, 2)):
        print("DDRCAP2_INJECT_FAIL"); return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
```

- [ ] **Step 4: Run the tests**

Run: `cd two_jup && python3 -m pytest tests/test_ddrcap2_inject.py -q`
Expected: 6 passed. Lint failures name the exact port/width mismatch; fix the anchor or width in the table, never the assert.

- [ ] **Step 5: Produce the sim netlist**

```bash
cd jupiter_240k5_byte/rtl_sim && NETLIST_ONLY=1 bash build_ddrcap2_sim.sh && \
grep -c "ddrcap_dc_" s1_rtl_ddrcap2/hdlsrc/commhdlQPSKTxRxLoopback/TxRxComposite.v
```
Expected: `DDRCAP2_INJECT ... missing=[] zips=0 zips_verified=0` and a count ≥ 60.

- [ ] **Step 6: Commit**

```bash
git add two_jup/skidfix/ddrcap2_inject.py two_jup/tests/test_ddrcap2_inject.py
git commit -s -m "DDRCAP2 injector part 2: thread timing/correlator/interpolator signals to TxRxComposite, ch2/ch3 packing, sel 12-15, zip patching

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

### Task 3: Record decoder

**Files:**
- Create: `two_jup/ddrcap2_decode.py`, `two_jup/tests/test_ddrcap2_decode.py`

**Interfaces:**
- `decode(a: np.ndarray) -> dict` with keys `I, Q` (int16 arrays), `mark_demod, mark_fec` (bool), `toff` (uint16, 0..16383), `slot` (uint8), `side` (uint16) — all length N — plus `heldts_lo, tref, runmax_hi, corrthr_hi` (each a masked array: value where `slot==k`, `-1` elsewhere, int32).
- CLI: `ddrcap2_decode.py IN.bin --v1compat OUT.bin` writes a 4×int16 file `[I, Q, 0x7FFF|0, 0x7FFF|0]` so `t6_score_large.py` and `ddrcap_pc_large.py` work unchanged; `--summary` prints record count, marker counts, toff min/max/mode, slot histogram.

- [ ] **Step 1: Failing tests**

```python
# two_jup/tests/test_ddrcap2_decode.py
import numpy as np, os, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.join(HERE, '..'))
from ddrcap2_decode import decode

def rec(I, Q, md, mf, toff, slot, side):
    c2 = (md << 15) | (mf << 14) | (toff & 0x3FFF)
    c3 = (slot << 14) | (side & 0x3FFF)
    return [I, Q, np.int16(np.uint16(c2).astype(np.int16)), np.int16(np.uint16(c3).astype(np.int16))]

def test_fields_unpack():
    a = np.array([rec(100, -200, 1, 0, 6363, 0, 4095), rec(1, 2, 0, 1, 12332, 1, 12000),
                  rec(3, 4, 0, 0, 0, 2, 0x3FFF), rec(5, 6, 1, 1, 8191, 3, 7)], dtype=np.int16)
    d = decode(a)
    assert d['toff'].tolist() == [6363, 12332, 0, 8191]
    assert d['mark_demod'].tolist() == [True, False, False, True]
    assert d['mark_fec'].tolist() == [False, True, False, True]
    assert d['slot'].tolist() == [0, 1, 2, 3]
    assert d['heldts_lo'].tolist() == [4095, -1, -1, -1]
    assert d['tref'].tolist() == [-1, 12000, -1, -1]
    assert d['runmax_hi'].tolist() == [-1, -1, 0x3FFF, -1]
    assert d['corrthr_hi'].tolist() == [-1, -1, -1, 7]

def test_v1compat_roundtrip_markers():
    a = np.array([rec(9, 8, 1, 0, 5, 0, 0), rec(7, 6, 0, 1, 5, 1, 0)], dtype=np.int16)
    with tempfile.TemporaryDirectory() as t:
        src, dst = os.path.join(t, 'in.bin'), os.path.join(t, 'out.bin')
        a.tofile(src)
        subprocess.check_call([sys.executable, os.path.join(HERE, '..', 'ddrcap2_decode.py'), src, '--v1compat', dst])
        o = np.fromfile(dst, dtype='<i2').reshape(-1, 4)
        assert o[:, 0].tolist() == [9, 7] and o[:, 2].tolist() == [0x7FFF, 0] and o[:, 3].tolist() == [0, 0x7FFF]
```

- [ ] **Step 2: Run → ImportError.**

- [ ] **Step 3: Write the decoder**

```python
#!/usr/bin/env python3
"""ddrcap2_decode.py -- DDRCAP-v2 record decoder (spec sec 2).
ch2 = {mark_demod, mark_fec, timingOffset[13:0]}, ch3 = {slot[1:0], side[13:0]}.
--v1compat writes [I, Q, 0x7FFF|0, 0x7FFF|0] so the v1 scorers run unchanged."""
import argparse, sys
import numpy as np

SLOTS = ('heldts_lo', 'tref', 'runmax_hi', 'corrthr_hi')

def load(path):
    a = np.fromfile(path, dtype='<i2')
    return a[:(len(a) // 4) * 4].reshape(-1, 4)

def decode(a):
    c2 = a[:, 2].astype(np.uint16); c3 = a[:, 3].astype(np.uint16)
    d = {'I': a[:, 0], 'Q': a[:, 1],
         'mark_demod': (c2 >> 15) & 1 == 1, 'mark_fec': (c2 >> 14) & 1 == 1,
         'toff': c2 & 0x3FFF, 'slot': (c3 >> 14).astype(np.uint8), 'side': c3 & 0x3FFF}
    for k, name in enumerate(SLOTS):
        v = np.full(len(a), -1, dtype=np.int32)
        m = d['slot'] == k
        v[m] = d['side'][m]
        d[name] = v
    return d

def v1compat(a):
    d = decode(a)
    o = np.zeros_like(a)
    o[:, 0] = a[:, 0]; o[:, 1] = a[:, 1]
    o[:, 2] = np.where(d['mark_demod'], 0x7FFF, 0).astype(np.int16)
    o[:, 3] = np.where(d['mark_fec'], 0x7FFF, 0).astype(np.int16)
    return o

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('src'); ap.add_argument('--v1compat'); ap.add_argument('--summary', action='store_true')
    x = ap.parse_args(); a = load(x.src)
    if x.v1compat:
        v1compat(a).astype('<i2').tofile(x.v1compat); print(f"wrote {len(a)} v1-compat records")
    if x.summary or not x.v1compat:
        d = decode(a); t = d['toff']
        vals, cnts = np.unique(t, return_counts=True)
        print(f"records {len(a)}  demod_marks {int(d['mark_demod'].sum())}  tx_marks {int(d['mark_fec'].sum())}")
        print(f"toff min {int(t.min())} max {int(t.max())} mode {int(vals[cnts.argmax()])} ({cnts.max()/len(t):.3f})  distinct {len(vals)}")
        print(f"slot histogram {np.bincount(d['slot'], minlength=4).tolist()}")
    return 0

if __name__ == '__main__':
    sys.exit(main())
```

- [ ] **Step 4: Run → 2 passed.**

- [ ] **Step 5: Commit**

```bash
git add two_jup/ddrcap2_decode.py two_jup/tests/test_ddrcap2_decode.py
git commit -s -m "DDRCAP2 decoder: unpack tOff/markers/sidecar, v1-compatible writer for the existing scorers

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

### Task 4: Tier-1 sim gate (positive controls for every channel) — MUST PASS before the build

**Files:**
- Create: `jupiter_240k5_byte/rtl_sim/sim_ddrcap2.cpp`
- Output: `jupiter_240k5_byte/rtl_sim/beat_runs/ddrcap2_gate.log`; §80 appended to the session log

**Interfaces:**
- Consumes: `s1_rtl_ddrcap2` (Task 2), `wrap_byte_ddrcap.v` (unchanged), `build_ddrcap2_sim.sh` (Task 1). Flat build defines `DDRCAP2_FLAT`.
- Produces: a binary printing per-check `PASS|FAIL` lines and a final `DDRCAP2_GATE PASS|FAIL`; the log is the Tier-1 evidence.

- [ ] **Step 1: Write the gate driver**

```cpp
// sim_ddrcap2.cpp -- DDRCAP-v2 Tier-1 gate (spec sec 4). Mode-1 ROM loopback.
// PART A (both builds): for sel 0..15 (7 skipped=dead, 9-11 bit-domain): I/Q not all-zero (where expected),
//   exactly one demod + one TX marker bit per frame, slot cycles 0,1,2,3 on consecutive captured beats,
//   toff in [0,12332] and steady (one modal value >= 95% after frame 20) in clean loopback,
//   tref slot increments mod 12333, sel12 shows one dominant peak per frame.
// PART B (flat build only): hold-force each field for 128 clks and require the exact readback.
// PART C (both builds): sel14 differs between golden and perturbed TX word files (tx_data_source=1).
#include "Vwrap_byte_ddrcap.h"
#include "verilated.h"
#ifdef DDRCAP2_FLAT
#include "Vwrap_byte_ddrcap___024root.h"
#define FTS wrap_byte_ddrcap__DOT__dut__DOT__u_Receiver__DOT__u_QPSK_Rx__DOT__u_Frequency_and_Time_Synchronizer__DOT__
#define CAT2(a,b) a##b
#define CAT(a,b) CAT2(a,b)
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>
#include <map>
static const long CPF = 197328;
struct Rec { short i, q; unsigned short c2, c3; };
struct Run { std::vector<Rec> r; std::vector<unsigned> frame_of; unsigned frames = 0; };

static void init(Vwrap_byte_ddrcap* t, unsigned sel, unsigned txsrc){
    t->reset=1; t->clk_enable=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0; t->rstCS=0;
    t->rx_input_select=0; t->skip_count=0; t->tx_data_source=txsrc; t->fixctl=0;
    t->iq_debug_mux=((sel&0xF)<<16)|3; t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
}
static std::vector<unsigned long long> words(const char* p){ std::vector<unsigned long long> w; FILE* f=fopen(p,"r"); char l[128];
    while(f && fgets(l,sizeof l,f)) if(l[0]!='\n') w.push_back(strtoull(l,nullptr,16)); if(f) fclose(f); return w; }

// Runs NF frames; optional TX word feed; optional force callback per clk (flat only).
template<class F> static Run run(unsigned sel, int NF, const std::vector<unsigned long long>* wf, F force){
    const std::unique_ptr<VerilatedContext> ctx{new VerilatedContext};
    Vwrap_byte_ddrcap* t = new Vwrap_byte_ddrcap{ctx.get()}; init(t, sel, wf?1:0);
    unsigned idx=0; long clk=0; auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick(); t->reset=0;
    Run R; long total=100+(long)(NF+4)*CPF;
    while(clk<total){
        if(wf){ if(t->byte_ready && t->byte_valid) idx=(idx+1)%wf->size(); t->byte_data=(*wf)[idx]; t->byte_first=(idx==0); t->byte_valid=1; }
        t->adc_validIn=(clk&1)?0:1;
        force(t, clk, t->cnt_frame_start);
        tick();
        if(t->ddrcap_valid && t->cnt_frame_start>=20){
            R.r.push_back({(short)t->ddrcap_i,(short)t->ddrcap_q,(unsigned short)t->ddrcap_mark_demod,(unsigned short)t->ddrcap_mark_fec});
            R.frame_of.push_back(t->cnt_frame_start);
        }
    }
    R.frames=t->cnt_frame_start; delete t; return R;
}
static bool pr(const char* what, bool ok, const char* detail=""){ printf("  %-58s %s %s\n", what, ok?"PASS":"FAIL", detail); return ok; }

static bool partA(unsigned sel, const Run& R){
    char nm[96]; bool ok=true; unsigned n=R.r.size();
    snprintf(nm,sizeof nm,"sel%u records>0",sel); ok&=pr(nm,n>1000);
    if(n<1000) return false;
    unsigned nz=0, md=0, mf=0, slotok=0; std::map<unsigned,unsigned> toffh; int prevslot=-1; unsigned trefok=0, trefn=0; int prevtref=-1;
    for(unsigned k=0;k<n;k++){ const Rec& x=R.r[k]; if(x.i||x.q) nz++; if(x.c2>>15) md++; if((x.c2>>14)&1) mf++;
        toffh[x.c2&0x3FFF]++; int s=x.c3>>14; if(prevslot>=0 && s==((prevslot+1)&3)) slotok++; prevslot=s;
        if(s==1){ int tr=x.c3&0x3FFF; if(prevtref>=0){ trefn++; if(tr>prevtref || (prevtref>12000 && tr<400)) trefok++; } prevtref=tr; } }
    unsigned fr=R.frame_of.back()-R.frame_of.front();
    snprintf(nm,sizeof nm,"sel%u I/Q not all zero",sel); ok&=pr(nm, sel==7 ? true : nz>n/100);
    snprintf(nm,sizeof nm,"sel%u demod marks per frame ~1",sel); ok&=pr(nm, md+1>=fr && md<=fr+1);
    snprintf(nm,sizeof nm,"sel%u tx marks per frame ~1",sel);    ok&=pr(nm, mf+1>=fr && mf<=fr+1);
    snprintf(nm,sizeof nm,"sel%u slot cycles 0..3",sel);          ok&=pr(nm, slotok>=n-2);
    unsigned best=0,bestc=0; for(auto& kv:toffh) if(kv.second>bestc){best=kv.first;bestc=kv.second;}
    char d[64]; snprintf(d,sizeof d,"mode=%u frac=%.3f",best,(double)bestc/n);
    snprintf(nm,sizeof nm,"sel%u toff in range and steady",sel);  ok&=pr(nm, best<=12332 && bestc>=n*95/100, d);
    snprintf(nm,sizeof nm,"sel%u tref slot monotone mod 12333",sel); ok&=pr(nm, trefn>0 && trefok>=trefn*95/100);
    return ok;
}
static bool peakA(const Run& R){ // sel12: one dominant magnitude peak per frame
    unsigned n=R.r.size(); std::vector<unsigned> mag(n); unsigned mx=0;
    for(unsigned k=0;k<n;k++){ mag[k]=((unsigned)(unsigned short)R.r[k].i<<16)|(unsigned short)R.r[k].q; if(mag[k]>mx) mx=mag[k]; }
    unsigned peaks=0; for(unsigned k=0;k<n;k++) if(mag[k]>mx/2) peaks++;
    unsigned fr=R.frame_of.back()-R.frame_of.front();
    char d[64]; snprintf(d,sizeof d,"peaks>half-max=%u frames=%u",peaks,fr);
    return pr("sel12 one dominant correlator peak per frame", peaks>=fr/2 && peaks<=fr*3, d);
}

int main(int argc, char** argv){
    int NF = argc>1 ? atoi(argv[1]) : 40; bool all=true;
    auto nof=[](Vwrap_byte_ddrcap*, long, unsigned){};
    printf("=== PART A: liveness / markers / slots / toff / tref (NF=%d) ===\n",NF);
    for(unsigned sel=0; sel<16; sel++){ if(sel==7||sel==9||sel==10||sel==11) continue;   // 7 dead; 9-11 bit-domain covered by v1 gate
        Run R=run(sel,NF,nullptr,nof); all&=partA(sel,R); if(sel==12) all&=peakA(R); }
#ifdef DDRCAP2_FLAT
    printf("=== PART B: forced non-null per field (flat build) ===\n");
    struct FC { const char* name; unsigned sel; int chan; unsigned expect; int slot; };
    // chan: 2 = ch2[13:0], 3 = ch3 side at slot, 0 = I, 1 = Q
    // hold the force for the first 128 clks after cnt_frame_start reaches 30 (frame edges are not CPF-aligned)
    auto hold=[&](auto setter){ auto st=std::make_shared<long>(-1); return [=](Vwrap_byte_ddrcap* t, long clk, unsigned f){ if(f==30 && *st<0) *st=clk; if(*st>=0 && clk<*st+128) setter(t); }; };
    auto check=[&](const char* name, const Run& R, int chan, unsigned expect, int slot){
        bool seen=false; for(unsigned k=0;k<R.r.size();k++){ if(R.frame_of[k]<30||R.frame_of[k]>31) continue; const Rec& x=R.r[k];
            unsigned v = chan==2 ? (x.c2&0x3FFF) : chan==3 ? ((int)(x.c3>>14)==slot ? (x.c3&0x3FFF) : 0xFFFFFFFF) : chan==0 ? (unsigned short)x.i : (unsigned short)x.q;
            if(v==expect){ seen=true; break; } }
        char d[64]; snprintf(d,sizeof d,"expect=0x%X",expect); return pr(name, seen, d); };
    { Run R=run(6,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__Unit_Delay_Enabled_Synchronous_out1)=0x2ABC; }));
      all&=check("force timingOffset=0x2ABC -> ch2[13:0]",R,2,0x2ABC,-1); }
    { Run R=run(6,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__Unit_Delay_Enabled_Synchronous1_out1)=0x12345; }));
      all&=check("force heldTs=0x12345 -> slot0 = 0x2345",R,3,0x2345,0); }
    { Run R=run(6,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__timing_Reference_out1)=0x1234; }));
      all&=check("force tref=0x1234 -> slot1",R,3,0x1234,1); }
    { Run R=run(6,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Peak_Search__DOT__Unit_Delay_Enabled_Resettable_Synchronous_out1)=0x2AAC0000u; }));
      all&=check("force runMax=0x2AAC0000 -> slot2 = 0x0AAB",R,3,0x0AAB,2); }
    { Run R=run(6,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Correlator__DOT__Delay5_out1)=0x15540000u; }));
      all&=check("force threshold=0x15540000 -> slot3 = 0x0555",R,3,0x0555,3); }
    { Run R=run(12,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Preamble_Detector__DOT__u_Correlator__DOT__Delay2_out1)=0x01234567u; }));
      all&=check("force corr=0x01234567 -> sel12 I=0x0123",R,0,0x0123,-1); all&=check("... sel12 Q=0x4567",R,1,0x4567,-1); }
    { Run R=run(13,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,u_Symbol_Synchronizer__DOT__u_Interpolation_Control__DOT__muReg)=0x155; }));
      all&=check("force muReg=0x155 -> sel13 Q",R,1,0x0155,-1); }
    { Run R=run(15,34,nullptr,hold([](Vwrap_byte_ddrcap* t){ t->rootp->CAT(FTS,RHCTR_REG)=0xA5; }));
      all&=check("force Rate_Handle ctr=0xA5 -> sel15 I[15:8]",R,0,0xA500,-1); }
#endif
    printf("=== PART C: sel14 differs golden vs perturbed TX words ===\n");
    { auto g=words("tx_words_golden.hex"), p=words("tx_words_perturbed.hex");
      Run A=run(14,30,&g,nof), B=run(14,30,&p,nof); unsigned diff=0, n=std::min(A.r.size(),B.r.size());
      for(unsigned k=0;k<n;k++) if(A.r[k].i!=B.r[k].i||A.r[k].q!=B.r[k].q) diff++;
      char d[64]; snprintf(d,sizeof d,"diff=%u/%u",diff,n); all&=pr("sel14 golden vs perturbed differ",diff>n/50,d); }
    printf("DDRCAP2_GATE %s\n", all?"PASS":"FAIL"); return all?0:1;
}
```
`RHCTR_REG` is the Rate_Handle occupancy register; it is discovered in Step 2 and defined with `-DRHCTR_REG=...` (the plan does not guess its name).

- [ ] **Step 2: Discover the Rate_Handle occupancy register name and build**

```bash
cd jupiter_240k5_byte/rtl_sim
grep -n "assign beatobsRhCtr" s1_rtl_ddrcap2/hdlsrc/commhdlQPSKTxRxLoopback/Rate_Handle.v     # names the driving reg, e.g. "assign beatobsRhCtr = occ_reg;"
bash build_ddrcap2_sim.sh 2>&1 | tail -4      # first build attempt; the flat build fails on RHCTR_REG until defined:
REG=$(grep -o "u_Symbol_Synchronizer__DOT__u_Rate_Handle__DOT__<the reg name from the grep above>" obj_ddrcap2_flat/Vwrap_byte_ddrcap___024root.h | head -1)
# then rebuild the flat object with the define:
sed -i 's|-DDDRCAP2_FLAT"|-DDDRCAP2_FLAT -DRHCTR_REG='"$REG"'"|' build_ddrcap2_sim.sh
FORCE=1 bash build_ddrcap2_sim.sh 2>&1 | tail -3
```
Expected: both binaries exist; record the reg name in the report.

- [ ] **Step 3: Run the gate (under systemd-run; ~40 min flat)**

```bash
cd jupiter_240k5_byte/rtl_sim && mkdir -p beat_runs
systemd-run --user --unit=ddrcap2-gate-$(date +%H%M%S) --collect -p WorkingDirectory=$PWD \
  bash -c './obj_ddrcap2_flat/Vwrap_byte_ddrcap 40 > beat_runs/ddrcap2_gate.log 2>&1'
# poll: sleep 240 between `tail -3 beat_runs/ddrcap2_gate.log`
```
Expected: every line `PASS`, final `DDRCAP2_GATE PASS`. A FAIL on any line is a build blocker: fix the injector or the check (the check only if the expectation itself is wrong and you can say why from the RTL), re-run, and report both the failure and the fix. Two revisions maximum.

- [ ] **Step 4: Record §80 and commit**

Append to `two_jup/SESSION_20260830_AUTONOMOUS.md`: `## §80 DDRCAP-v2 Tier-1 gate [sim]` with the full PASS table and the Rate_Handle register name.
```bash
git add jupiter_240k5_byte/rtl_sim/sim_ddrcap2.cpp jupiter_240k5_byte/rtl_sim/build_ddrcap2_sim.sh jupiter_240k5_byte/rtl_sim/beat_runs/ddrcap2_gate.log two_jup/SESSION_20260830_AUTONOMOUS.md
git commit -s -m "DDRCAP2 Tier-1 gate: forced non-null for every field, liveness/markers/slots for sel 0-15 (§80)

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

### Task 5: Build the image on hdl-dev-2 and bank it

**Files:**
- Create: `jupiter_byte_ddrcap2_build/` (from `jupiter_byte_txmark_build/`), its `build_ddrcap.sh` (REMOTE_DIR renamed)
- Output: `boot_known_good/BOOT.BIN.148.ddrcap2.<md5-12>`, `boot_known_good/MD5SUMS` updated, README row

- [ ] **Step 1: Make the build tree and inject**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
rsync -a --exclude 'hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.runs/' --exclude '*.log' --exclude '*.jou' \
      jupiter_byte_txmark_build/ jupiter_byte_ddrcap2_build/
sed -i "s|jupiter_byte_ddrcap_build|jupiter_byte_ddrcap2_build|g" jupiter_byte_ddrcap2_build/build_ddrcap.sh
grep -n "REMOTE_DIR" jupiter_byte_ddrcap2_build/build_ddrcap.sh | head -3
TXMARK=1 python3 two_jup/skidfix/ddrcap_inject.py jupiter_byte_ddrcap2_build | tail -2     # expect all 'already' + VERIFY_OK x2
python3 two_jup/skidfix/ddrcap2_inject.py jupiter_byte_ddrcap2_build | tail -12            # expect zips=2 zips_verified=2, exit 0
```
Expected: `DDRCAP2_INJECT ... missing=[] zips=2 zips_verified=2`. Anything else stops the task.

- [ ] **Step 2: Launch the build (from nemo) and watch it**

```bash
bash jupiter_byte_ddrcap2_build/build_ddrcap.sh | tee jupiter_byte_ddrcap2_build/launch.log
# The unit name is printed. Check every ~10 min (bounded): 
ssh hdl-dev-2 "tail -3 ~/qpsk-builds/jupiter_byte_ddrcap2_build/build_ddrcap_vivado.log; ls -la ~/qpsk-builds/jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN 2>/dev/null"
```
Expected after ~50 min: `BOOT.BIN` present, size 7,203,552; the vivado log ends without `ERROR`, timing met (`grep -i "all user specified timing constraints are met\|WNS" build_ddrcap_vivado.log`). A timing violation or synthesis error = report, do not flash.

- [ ] **Step 3: Fetch, verify, bank**

```bash
scp hdl-dev-2:~/qpsk-builds/jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN
M=$(md5sum jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN | cut -c1-12)
cp jupiter_byte_ddrcap2_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN boot_known_good/BOOT.BIN.148.ddrcap2.$M
(cd boot_known_good && md5sum BOOT.BIN.148.ddrcap2.$M >> MD5SUMS && md5sum -c MD5SUMS | tail -2)
echo "| \`BOOT.BIN.148.ddrcap2.$M\` | \`$M\` | DDRCAP-v2: joint tOff/markers/sidecar record + sel12-15 (spec 2026-09-02). Built from txmark tree + ddrcap2_inject. NOT yet flashed. |" >> boot_known_good/README.md
git add boot_known_good/MD5SUMS boot_known_good/README.md jupiter_byte_ddrcap2_build/build_ddrcap.sh
git commit -s -m "DDRCAP2 image built and banked: BOOT.BIN.148.ddrcap2.$M

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```
(BOOT.BIN files are not committed; the bank directory holds them.)

---

### Task 6: 148-only flash chain with rails — script, dry-run, then the flash (operator go at Step 4)

**Files:**
- Create: `two_jup/skidfix/flash_148_ddrcap2.sh`
- Modify: `two_jup/tests/fake_anyssh.sh` (add the cases the chain uses)

**Interfaces:**
- `flash_148_ddrcap2.sh <md5-12>` with env `DRY=1` (echo every board command instead of running it). Rails per Global Constraints. Rollback target `1cd0cd752aa6`.

- [ ] **Step 1: Write the chain**

```bash
#!/bin/bash
# flash_148_ddrcap2.sh <md5-12> -- flash 148 with the DDRCAP-v2 image under the standing rails,
# adapted to the 148-ONLY mode-1 campaign (146 is never touched): bring-up + gate = arm148_mode1.sh x2.
#   [1] preconditions: sentinel stopped; current image = 1cd0cd752aa6; on-board rollback copy verified
#   [2] stage + flash (size-checked), reboot, wait back
#   [3] readback md5 == expected, else ROLLBACK
#   [4] two-pass gate: arm148_mode1.sh ARM_OK with fps>=1120 and golden capTAP, twice; else ROLLBACK
#   [5] Tier-2 witness: one 4 MB sel-6 capture decoded with ddrcap2_decode.py --summary, read BEFORE any rollback
#   NO retry loop. Rollback = restore /boot from the on-board copy, reboot, arm148_mode1.sh once, stop.
set -u
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem; D=$ROOT/two_jup; W=$D/anyssh.sh; A=10.0.0.148
EXP=${1:?usage: flash_148_ddrcap2.sh <md5-12>}; BAK=1cd0cd752aa6
BB=$ROOT/boot_known_good/BOOT.BIN.148.ddrcap2.$EXP
DRY=${DRY:-0}; LOG=$D/skidfix/ddrcap2_flash_$(date +%Y%m%d_%H%M%S).log
say(){ echo "$(date +%T) $*" | tee -a "$LOG"; }
brd(){ if [ "$DRY" = 1 ]; then echo "[dry] $*"; else $W $A "$@" 2>/dev/null | tr -d '\r'; fi; }
scpput(){ if [ "$DRY" = 1 ]; then echo "[dry] scp $*"; return 0; fi
  SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
wait_back(){ [ "$DRY" = 1 ] && return 0; sleep 45; local n=0; until ping -c1 -W2 $A >/dev/null 2>&1; do sleep 5; n=$((n+5)); [ $n -gt 240 ] && return 1; done; sleep 20; return 0; }
gate(){ local o; o=$(bash $D/arm148_mode1.sh 2>&1); echo "$o" | tail -2 | tee -a "$LOG"
  echo "$o" | grep -q ARM_OK || return 1; local f; f=$(echo "$o" | sed -n 's/.*fps=\([0-9]*\).*/\1/p' | tail -1); [ "${f:-0}" -ge 1120 ]; }
rollback(){ say "=== ROLLBACK to $BAK (rail: no retry) ==="
  brd "cp -f /root/BOOT.BIN.$BAK.bak /boot/BOOT.BIN && sync && md5sum /boot/BOOT.BIN | cut -c1-12"
  brd 'sync; (sleep 1; reboot) &'; wait_back || { say "FLASH_DDRCAP2_FATAL: 148 not back after rollback -- PHYSICAL ATTENTION"; exit 2; }
  say "  rollback booted: $(brd 'md5sum /boot/BOOT.BIN | cut -c1-12') (expect $BAK)"; gate || say "  WARN: post-rollback arm not ARM_OK -- operator"
  rm -f ~/modem-status/SENTINEL_STOP; say "FLASH_DDRCAP2_ROLLED_BACK"; exit 1; }

say "=== [1/5] preconditions ==="
[ -f "$BB" ] && [ "$(md5sum "$BB" | cut -c1-12)" = "$EXP" ] || { say "FATAL: $BB missing or md5 != $EXP"; exit 1; }
touch ~/modem-status/SENTINEL_STOP; say "  sentinel stopped (SENTINEL_STOP)"
CUR=$(brd 'md5sum /boot/BOOT.BIN | cut -c1-12'); say "  148 current image: $CUR (expect $BAK)"
[ "$DRY" = 1 ] || [ "$CUR" = "$BAK" ] || { say "FATAL: current image is not the banked restore point"; rm -f ~/modem-status/SENTINEL_STOP; exit 1; }
brd "[ -f /root/BOOT.BIN.$BAK.bak ] || cp -f /boot/BOOT.BIN /root/BOOT.BIN.$BAK.bak; md5sum /root/BOOT.BIN.$BAK.bak | cut -c1-12" | tee -a "$LOG" | grep -q "$BAK" || [ "$DRY" = 1 ] || { say "FATAL: on-board rollback copy bad"; rm -f ~/modem-status/SENTINEL_STOP; exit 1; }
say "=== [2/5] stage + flash ==="
scpput "$BB" root@$A:/root/BOOT.BIN.staged
FL=$(brd 'NB=$(stat -c %s /root/BOOT.BIN.staged 2>/dev/null||echo 0); if [ "$NB" -gt 6000000 ]; then cp -f /root/BOOT.BIN.staged /boot/BOOT.BIN && sync && echo "FLASHED $(md5sum /boot/BOOT.BIN|cut -c1-12)"; else echo "ABORT staged=$NB"; fi')
say "  $FL"; echo "$FL" | grep -q FLASHED || [ "$DRY" = 1 ] || { say "FATAL: flash did not complete; /boot untouched"; rm -f ~/modem-status/SENTINEL_STOP; exit 1; }
brd 'sync; (sleep 1; reboot) &'; wait_back || rollback
say "=== [3/5] readback verify ==="
BOOT=$(brd 'md5sum /boot/BOOT.BIN | cut -c1-12'); say "  booted image: $BOOT (expect $EXP)"; [ "$DRY" = 1 ] || [ "$BOOT" = "$EXP" ] || rollback
say "=== [4/5] two-pass gate (arm148_mode1: ARM_OK, fps>=1120, capTAP golden) ==="
gate || rollback; gate || rollback; say "  GATE_PASS x2"
say "=== [5/5] Tier-2 witness (read BEFORE any rollback): sel6 4 MB, decoded ==="
brd "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; echo '0x10C 0x60003' > /sys/kernel/debug/iio/iio:device0/direct_reg_access; sleep 1; cd /tmp && rm -f w.bin && iio_readdev -b 4096 -s 1048576 axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /tmp/w.bin 2>/dev/null; stat -c %s /tmp/w.bin"
[ "$DRY" = 1 ] || { $W $A 'cat /tmp/w.bin' > "$D/skidfix/ddrcap2_witness_$EXP.bin" 2>/dev/null; python3 "$D/ddrcap2_decode.py" "$D/skidfix/ddrcap2_witness_$EXP.bin" --summary | tee -a "$LOG"; }
rm -f ~/modem-status/SENTINEL_STOP; say "FLASH_DDRCAP2_OK $EXP (sentinel released)"
```

- [ ] **Step 2: Dry run + lint**

```bash
cd two_jup && bash -n skidfix/flash_148_ddrcap2.sh && shellcheck -S warning skidfix/flash_148_ddrcap2.sh || true
DRY=1 bash skidfix/flash_148_ddrcap2.sh $(ls boot_known_good/ 2>/dev/null | sed -n 's/BOOT.BIN.148.ddrcap2.\(.*\)/\1/p' | head -1) 2>&1 | tail -20
```
Expected: every board action printed as `[dry] ...`, the sequence [1]..[5] in order, no FATAL (DRY skips the md5 equality checks by design, printed as such), `FLASH_DDRCAP2_OK`. `SENTINEL_STOP` must not remain afterwards (`ls ~/modem-status/SENTINEL_STOP` → absent).

- [ ] **Step 3: Commit the chain**

```bash
git add two_jup/skidfix/flash_148_ddrcap2.sh
git commit -s -m "DDRCAP2 148-only flash chain with rails (readback, two-pass mode-1 gate, Tier-2 witness before rollback, no retry)

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

- [ ] **Step 4: OPERATOR GO, then flash (rig-holding unit)**

Stop here and confirm with the operator that (a) the Tier-1 gate PASSED (§80), (b) the image is banked, (c) 148 is idle on the golden arm and 146 is untouched. Then:
```bash
cd two_jup && bash launch_rig_unit.sh ddrcap2-flash-$(date +%H%M%S) skidfix/flash_148_ddrcap2.sh <md5-12>
# monitor by reading skidfix/ddrcap2_flash_*.log every 60 s; do NOT intervene mid-flash; total ≈ 8-10 min
```
Expected: `FLASH_DDRCAP2_OK`. On `FLASH_DDRCAP2_ROLLED_BACK`, the campaign stops for the operator (no second attempt this session). Append §81 (flash result + the witness summary) to the session log and commit.

---

### Task 7: Tier-2 silicon positive controls (one arm, five captures) + one-shot capture script

**Files:**
- Create: `two_jup/ddrcap2_capture.sh`, `two_jup/ddrcap2_pc.py`, `two_jup/tests/test_ddrcap2_pc.py`
- Output: `two_jup/ddrcap2_pc/<ts>/sel{6,12,13,14,15}.bin` + `pc.log`; §81 addendum

**Interfaces:**
- `ddrcap2_capture.sh SEL NAME` (env `B`, `SZ` default 134217728, `OUT`): sets `0x10C=(SEL<<16)|3`, verifies `0x20C` golden, captures, host-stat-before-delete, records pre/post capTAP in `OUT/meta.txt`. No arm inside (runs on the current arm).
- `ddrcap2_pc.py FILE --sel N` → per-channel PASS/FAIL lines and `TIER2 sel<N> PASS|FAIL`. Rules: liveness (not constant, not a counter: ddrcap_pc_large parts 1 & 4 via `--v1compat`), marker cadence 1/frame, slot cycling ≥ 99 %, toff ∈ [0,12332] steady ≥ 95 %; sel12: ≥ 0.5 peaks/frame above half-max; sel13: countReg not constant and underflow bit mean 0.25±0.03 (4 records/symbol); sel14: not constant, not ramp; sel15: RhCtr < 32 and nonzero, push/pop advance. Records `toff mode` as `d0` for the cross-arm non-null.

- [ ] **Step 1: Failing test for the PC scorer (synthetic)**

```python
# two_jup/tests/test_ddrcap2_pc.py
import numpy as np, os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.join(HERE, '..'))
from ddrcap2_pc import check_common, check_sel
P = 12333
def synth(nfr=30, toff=6000, slot_ok=True):
    n = nfr * P; rng = np.random.default_rng(0)
    a = np.zeros((n, 4), dtype=np.int16); a[:, 0] = rng.integers(-8000, 8000, n); a[:, 1] = rng.integers(-8000, 8000, n)
    c2 = np.full(n, toff, dtype=np.uint16); c2[::P] |= 1 << 15; c2[7::P] |= 1 << 14
    slot = (np.arange(n) % 4) if slot_ok else np.zeros(n, dtype=int)
    side = np.where(slot == 1, np.arange(n) % P, 100)
    a[:, 2] = c2.astype(np.int16); a[:, 3] = ((slot << 14) | side).astype(np.uint16).astype(np.int16)
    return a
def test_common_passes_on_good_synthetic():
    r = check_common(synth()); assert all(v for k, v in r.items() if k != 'd0'), r; assert r['d0'] == 6000
def test_common_fails_when_slots_do_not_cycle():
    r = check_common(synth(slot_ok=False)); assert r['slots_cycle'] is False
def test_sel13_underflow_rate():
    a = synth(); a[:, 0] = 0; a[::4, 0] = np.int16(-32768)   # underflow bit every 4th record = 1/symbol at 4 records/symbol
    assert check_sel(a, 13)['underflow_per_symbol'] is True
```

- [ ] **Step 2: Run → ImportError.**

- [ ] **Step 3: Write the PC scorer and the capture script**

```python
#!/usr/bin/env python3
"""ddrcap2_pc.py FILE --sel N -- Tier-2 silicon positive controls (spec sec 4). Prints PASS/FAIL per rule."""
import argparse, sys
import numpy as np
from ddrcap2_decode import load, decode

def _ramp(x):
    d = np.diff(x[:200000].astype(np.int32)); v, c = np.unique(d, return_counts=True); return c.max() / len(d) >= 0.95

def check_common(a):
    d = decode(a); n = len(a); r = {}
    r['not_constant_IQ'] = len(np.unique(a[:200000, 0])) > 100
    r['not_ramp_IQ'] = not _ramp(a[:, 0])
    md = np.flatnonzero(d['mark_demod']); g = np.diff(md)
    r['demod_marks_periodic'] = len(md) > 10 and (np.abs(g - np.median(g)) <= 2).mean() >= 0.95
    r['slots_cycle'] = (np.diff(d['slot'].astype(int)) % 4 == 1).mean() >= 0.99
    t = d['toff']; v, c = np.unique(t, return_counts=True); r['d0'] = int(v[c.argmax()])
    r['toff_range_steady'] = r['d0'] <= 12332 and c.max() / n >= 0.95
    tr = d['tref'][d['tref'] >= 0]; dt = np.diff(tr.astype(int))
    r['tref_monotone'] = len(tr) > 100 and ((dt > 0) | (dt < -12000)).mean() >= 0.95
    return r

def check_sel(a, sel):
    d = decode(a); r = {}
    if sel == 12:
        mag = (a[:, 0].astype(np.uint16).astype(np.uint32) << 16) | a[:, 1].astype(np.uint16)
        fr = max(1, int(d['mark_demod'].sum())); r['peaks_per_frame_ok'] = 0.5 <= (mag > mag.max() / 2).sum() / fr <= 3
    elif sel == 13:
        uf = (a[:, 0].astype(np.uint16) >> 15) & 1; cnt = a[:, 0].astype(np.uint16) & 0x7FF
        r['countreg_not_constant'] = len(np.unique(cnt[:200000])) > 8
        r['underflow_per_symbol'] = abs(uf.mean() - 0.25) <= 0.03       # 4 records/symbol at enb_1_2_0 -> one underflow per 4 records (Task 4 §80)
    elif sel == 14:
        r['not_constant'] = len(np.unique(a[:200000, 0])) > 100; r['not_ramp'] = not _ramp(a[:, 0])
    elif sel == 15:
        ctr = a[:, 0].astype(np.uint16) >> 8; push = (a[:, 0].astype(np.uint16) >> 3) & 0x1F; pop = a[:, 1].astype(np.uint16) >> 11
        r['rhctr_bounded_nonzero'] = 0 < ctr.max() < 32; r['push_pop_advance'] = len(np.unique(push)) > 4 and len(np.unique(pop)) > 4
    return r

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('file'); ap.add_argument('--sel', type=int, required=True)
    x = ap.parse_args(); a = load(x.file)
    r = check_common(a); r.update(check_sel(a, x.sel)); ok = True
    for k, v in r.items():
        if k == 'd0': print(f"  d0 (toff mode) = {v}"); continue
        print(f"  {k:28s} {'PASS' if v else 'FAIL'}"); ok &= bool(v)
    print(f"TIER2 sel{x.sel} {'PASS' if ok else 'FAIL'}"); return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main())
```

```bash
#!/bin/bash
# ddrcap2_capture.sh SEL NAME -- one 512 MB capture of one selector on the CURRENT arm (no arm inside).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=${W:-$D/anyssh.sh}; B=${B:-10.0.0.148}; SEL=${1:?SEL}; NAME=${2:?NAME}
SZ=${SZ:-134217728}; GOLD=BCF94856; OUT=${OUT:-$D/ddrcap2_pc/$(date +%Y%m%d_%H%M%S)}; mkdir -p "$OUT"
log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }; norm(){ printf %s "$1" | sed -E 's/^0[xX]//' | tr 'a-f' 'A-F'; }
DRA='/sys/kernel/debug/iio/iio:device0/direct_reg_access'
rd(){ $W $B "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo $1 > $DRA; cat $DRA" 2>/dev/null | tr -d '\r' | tail -1; }
wr(){ $W $B "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo '$1 $2' > $DRA" >/dev/null 2>&1; }
[ -e "$OUT/$NAME.bin" ] && { log "REFUSE: $OUT/$NAME.bin exists"; exit 5; }
wr 0x10C "0x$(printf %X $(( (SEL<<16) | 3 )))"; sleep 2
C0=$(rd 0x20C); [ "$(norm "$C0")" = "$GOLD" ] || { log "ABORT: capTAP $C0 != golden"; exit 4; }
$W $B "cd /tmp && rm -f g.bin && iio_readdev -b 4096 -s $SZ axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /tmp/g.bin 2>/dev/null; stat -c 'BOARD %s' /tmp/g.bin" 2>/dev/null | tail -1 | tee -a "$OUT/run.log"
$W $B "cat /tmp/g.bin" > "$OUT/$NAME.bin" 2>/dev/null; GOT=$(stat -c %s "$OUT/$NAME.bin" 2>/dev/null || echo 0)
[ "$GOT" -ge $(( SZ*4*9/10 )) ] && $W $B "rm -f /tmp/g.bin" >/dev/null 2>&1 || log "SHORT: $GOT bytes, board file kept"
C1=$(rd 0x20C); log "$NAME sel$SEL bytes=$GOT pre=$C0 post=$C1"; echo "$NAME sel=$SEL bytes=$GOT pre=$C0 post=$C1" >> "$OUT/meta.txt"
[ "$(norm "$C1")" = "$GOLD" ] || log "WARN: post capTAP not golden -- capture not credited"
```

- [ ] **Step 4: Run the unit tests → 3 passed. Then the five captures on the post-flash arm (one rig unit)**

```bash
cd two_jup && OUT=$PWD/ddrcap2_pc/$(date +%Y%m%d_%H%M%S) && export OUT
bash launch_rig_unit.sh ddrcap2-pc-$(date +%H%M%S) /bin/bash -c "for s in 6 12 13 14 15; do OUT=$OUT bash $PWD/ddrcap2_capture.sh \$s sel\$s || exit \$?; sleep 2; done"
# after it finishes (~15 min): 
for s in 6 12 13 14 15; do python3 ddrcap2_pc.py $OUT/sel$s.bin --sel $s | tee -a $OUT/pc.log; done
```
Expected: `TIER2 sel6 PASS` … `TIER2 sel15 PASS`. Record `d0` from sel6; the cross-arm non-null for tOff is satisfied when `d0` differs from the sim gate's tOff mode (§80) OR from the next arm's `d0` (Task 8's arm). A FAIL marks that channel DEAD for the campaign (it may not report), and is written up, not fixed on the rig.

- [ ] **Step 5: §81 addendum + commit**

```bash
git add two_jup/ddrcap2_capture.sh two_jup/ddrcap2_pc.py two_jup/tests/test_ddrcap2_pc.py two_jup/ddrcap2_pc/*/pc.log two_jup/ddrcap2_pc/*/meta.txt two_jup/SESSION_20260830_AUTONOMOUS.md
git commit -s -m "DDRCAP2 Tier-2 silicon positive controls: five selectors on one arm, per-channel verdicts (§81)

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

### Task 8: The pre-registered burst capture (sel 6) and the §6 verdict

**Files:**
- Create: `two_jup/beat_tap_capture.sh`, `two_jup/tests/fake_anyssh.sh`, `two_jup/tests/fake_arm.sh` (from the beat plan Task 7, verbatim below)
- Create: `two_jup/ddrcap2_beat_analysis.py`, `two_jup/tests/test_ddrcap2_beat_analysis.py`
- Output: `two_jup/beatcap/<ts>_sel6/{mid,onset}.bin`, `verdict.json`; §82

**Interfaces:**
- `ddrcap2_beat_analysis.py CAPTURE.bin --out PREFIX` → `PREFIX.json` with `d0`, `onset_beat_data`, `onset_beat_toff`, `delta_beats`, `toff_after` (value), `toff_delta_is_rung` (bool, ±rung within 4 symbols), `frames_by_marker`, `frames_by_tref`, `frames_by_index`, `verdict` ∈ `P1|P2|NEITHER|UNINFORMATIVE`, and prints the same.
- API for tests: `analyse(a: np.ndarray, offsetmap: dict) -> dict`.

- [ ] **Step 1: Capture script + fakes (verbatim from the beat plan)**

Write `two_jup/beat_tap_capture.sh`, `two_jup/tests/fake_anyssh.sh`, `two_jup/tests/fake_arm.sh` exactly as given in `docs/superpowers/plans/2026-09-01-beat-tap-compare.md` Task 7 Steps 1–2 (the script sets `0x10C=(SEL<<16)|3` after the arm, triggers `mid.bin` on `0x108` delta > THRESH, then `onset.bin` at `T_trigger + PERIOD − LEAD`). Run its dry run (that plan's Step 3) and confirm `TRIGGER`, both `.bin`, and `REFUSE` on re-run.

- [ ] **Step 2: Failing analysis tests (synthetic v2 records)**

```python
# two_jup/tests/test_ddrcap2_beat_analysis.py
import numpy as np, os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.join(HERE, '..'))
from ddrcap2_beat_analysis import analyse
P = 12333
def frame_words(offset, seed=3):
    rng = np.random.default_rng(seed); base = rng.integers(-8000, 8000, size=(P, 2)).astype(np.int16)
    return np.roll(base, offset, axis=0)
def synth(nfr, onset_frame, rung, toff0, toff_move_at=None, toff_delta=0):
    base = frame_words(0); rows = []
    for f in range(nfr):
        w = frame_words(rung) if f >= onset_frame else base
        rec = np.zeros((P, 4), dtype=np.int16); rec[:, :2] = w
        toff = toff0 + (toff_delta if (toff_move_at is not None and f >= toff_move_at) else 0)
        c2 = np.full(P, toff, dtype=np.uint16); c2[0] |= 1 << 15; c2[5] |= 1 << 14
        rec[:, 2] = c2.astype(np.int16); slot = np.arange(P) % 4; side = np.where(slot == 1, np.arange(P), 0)
        rec[:, 3] = ((slot << 14) | side).astype(np.uint16).astype(np.int16); rows.append(rec)
    return np.vstack(rows)
def omap():   # injective map for the synthetic base frame: 16 hard decisions at marker+1 -> offset
    base = frame_words(0); m = {}
    for off in range(P):
        w = 0; s = np.roll(base, off, axis=0)
        for k in range(16): w |= ((int(s[1+k, 0] < 0) << 1) | int(s[1+k, 1] < 0)) << (30 - 2*k)
        m[w] = off
    return m
def test_P1_when_toff_moves_with_data():
    r = analyse(synth(40, 20, 6363, 5000, toff_move_at=20, toff_delta=6363), omap())
    assert r['verdict'] == 'P1' and r['onset_beat_data'] // P == 20 and abs(r['delta_beats']) <= 1
def test_P2_when_toff_holds():
    r = analyse(synth(40, 20, 6240, 5000), omap())
    assert r['verdict'] == 'P2' and r['toff_after'] == 5000
def test_NEITHER_when_toff_moves_non_rung():
    r = analyse(synth(40, 20, 6299, 5000, toff_move_at=20, toff_delta=777), omap())
    assert r['verdict'] == 'NEITHER'
def test_three_way_frame_count_agrees():
    r = analyse(synth(40, 20, 6363, 5000, toff_move_at=20, toff_delta=6363), omap())
    assert abs(r['frames_by_marker'] - r['frames_by_index']) <= 1 and abs(r['frames_by_tref'] - r['frames_by_index']) <= 1
```

- [ ] **Step 3: Run → ImportError. Then write the analysis**

```python
#!/usr/bin/env python3
"""ddrcap2_beat_analysis.py -- the pre-registered spec sec 6 verdict on a DDRCAP-v2 sel-6 burst capture.
Per frame: d_data = injective offset-map lookup of the 16 hard decisions at demod-marker+1 (the sec 57/69
instrument; map two_jup/offsetmap/tap3_word_to_offset.tsv). Per beat: tOff (ch2[13:0]).
onset_beat_data = first record of the first frame with d_data != 0 after >=3 frames at 0.
onset_beat_toff = first record where tOff != d0 (d0 = modal tOff before onset_beat_data).
P1: tOff steps to d0 +/- rung (|.|<=4 symbols) and |delta_beats| <= 1 and holds >= 3 frames.
P2: tOff == d0 on every beat while d_data is on a rung for >= 3 frames.
NEITHER: tOff moves but not to d0 +/- rung. UNINFORMATIVE: no 0->rung transition in the capture.
Frame ordinality: frames_by_marker (demod marks), frames_by_tref (slot-1 wraps), frames_by_index (records/12333)."""
import argparse, json, os, sys
import numpy as np
from ddrcap2_decode import load, decode
HERE = os.path.dirname(os.path.abspath(__file__))
RUNGS = (6176, 6240, 6299, 6363, 6432, 6489, 6548); P = 12333

def load_map():
    m = {}
    for l in open(os.path.join(HERE, 'offsetmap', 'tap3_word_to_offset.tsv')):
        if not l.startswith('#'):
            w, o = l.split(); m[int(w, 16)] = int(o)
    return m

def per_frame_offsets(a, d, m, skew=1):
    sign = ((a[:, 0] < 0).astype(np.uint32) << 1) | (a[:, 1] < 0).astype(np.uint32)
    mk = np.flatnonzero(d['mark_demod']); out = []
    for i in mk:
        s = i + skew
        if s + 16 > len(a): break
        w = 0
        for k in range(16): w |= int(sign[s + k]) << (30 - 2 * k)
        out.append((int(i), m.get(w)))
    return out

def analyse(a, m):
    d = decode(a); fr = per_frame_offsets(a, d, m); r = {}
    offs = [o for _, o in fr]
    zero_run = 0; onset_idx = None
    for k, (rec, o) in enumerate(fr):
        if o == 0: zero_run += 1
        elif o is not None and o in RUNGS and zero_run >= 3:
            onset_idx = k; break
        elif o is None: pass
        else: zero_run = 0
    r['frames_by_marker'] = len(fr); r['frames_by_index'] = int(len(a) // P)
    tr = d['tref']; trv = tr[tr >= 0]; r['frames_by_tref'] = int((np.diff(trv.astype(int)) < -12000).sum()) + 1 if len(trv) else 0
    if onset_idx is None:
        r.update(verdict='UNINFORMATIVE', onset_beat_data=None, onset_beat_toff=None, delta_beats=None, d0=None, toff_after=None, toff_delta_is_rung=False)
        return r
    onset_rec = fr[onset_idx][0]; r['onset_beat_data'] = onset_rec
    toff = d['toff'].astype(int); pre = toff[:onset_rec]; v, c = np.unique(pre, return_counts=True); d0 = int(v[c.argmax()]); r['d0'] = d0
    moved = np.flatnonzero(toff != d0); moved = moved[moved >= max(0, onset_rec - 3 * P)]
    if len(moved) == 0:
        after_rung = sum(1 for _, o in fr[onset_idx:onset_idx + 3] if o in RUNGS) >= 3
        r.update(onset_beat_toff=None, delta_beats=None, toff_after=d0, toff_delta_is_rung=False, verdict='P2' if after_rung else 'UNINFORMATIVE'); return r
    ob = int(moved[0]); r['onset_beat_toff'] = ob; r['delta_beats'] = ob - onset_rec
    after = int(np.bincount(toff[ob:ob + 3 * P]).argmax()); r['toff_after'] = after
    delta = (after - d0) % 12320; delta = min(delta, 12320 - delta)
    is_rung = any(abs(delta - g) <= 4 for g in RUNGS); r['toff_delta_is_rung'] = bool(is_rung)
    held = (toff[ob:ob + 3 * P] == after).mean() >= 0.95
    r['verdict'] = 'P1' if (is_rung and abs(r['delta_beats']) <= 1 and held) else 'NEITHER'
    return r

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('capture'); ap.add_argument('--out', required=True)
    x = ap.parse_args(); r = analyse(load(x.capture), load_map())
    json.dump(r, open(x.out + '.json', 'w'), indent=1); print(json.dumps(r, indent=1)); return 0

if __name__ == '__main__':
    sys.exit(main())
```

- [ ] **Step 4: Run → 4 passed.**

- [ ] **Step 5: The arm (rig unit), then the verdict**

```bash
cd two_jup && bash launch_rig_unit.sh beatcap2-sel6-$(date +%H%M%S) beat_tap_capture.sh SEL=6 OUT=$PWD/beatcap/$(date +%Y%m%d_%H%M%S)_sel6
# ~8 min. Then:
C=beatcap/<ts>_sel6
python3 ddrcap2_decode.py $C/onset.bin --summary; python3 ddrcap2_pc.py $C/onset.bin --sel 6      # Tier-2 must PASS on THIS capture too
python3 ddrcap2_beat_analysis.py $C/onset.bin --out $C/onset_verdict
python3 ddrcap2_beat_analysis.py $C/mid.bin   --out $C/mid_verdict
```
Read-out rules (spec §6, frozen): the verdict field is the answer. If `onset.bin` is UNINFORMATIVE (window missed the onset) but `mid.bin` shows the displaced state, report the tOff behaviour in the displaced state (P2-style "holds at d0 while displaced" is still decisive; P1 needs the transition). Cross-arm tOff non-null: this arm's `d0` vs Task 7's `d0` — record both. If the two `d0` are equal AND the sim mode is equal, the tOff non-null on silicon is NOT yet demonstrated and a "held steady" result is reported as **provisional** pending a third arm (say so explicitly; do not upgrade it).

- [ ] **Step 6: §82 and commit**

Append `## §82 DDRCAP-v2 burst capture: <P1|P2|NEITHER> [silicon]` with: d0, onset beats, delta_beats, toff_after, the three frame counts, the sidecar readings at onset (heldts/tref/runmax/threshold in the 8 records around `onset_beat_toff`), and the label. Then:
```bash
git add two_jup/beat_tap_capture.sh two_jup/tests/fake_anyssh.sh two_jup/tests/fake_arm.sh two_jup/ddrcap2_beat_analysis.py two_jup/tests/test_ddrcap2_beat_analysis.py two_jup/beatcap/*/{run.log,meta.txt,errps.csv,*_verdict.json} two_jup/SESSION_20260830_AUTONOMOUS.md
git commit -s -m "DDRCAP2 §82: pre-registered sel6 burst capture verdict (marker-moves vs data-moves)

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq"
```

---

### Task 9: Secondary arms in operator priority order (sel 12, then 13/14, then 15) — each pre-registered on the §82 outcome

**Files:**
- Output: `two_jup/beatcap/<ts>_sel{12,13,14,15}/`, §83+

- [ ] **Step 1: Pre-register per §82 outcome (write before arming)**

- If **P1**: sel 12 burst capture. Prediction: in the 12,333 beats before `onset_beat_toff`, the correlator magnitude shows a SECOND peak at ≈ d0 ± rung whose slot-2 `runMax`/slot-3 `threshold` readings show it crossing threshold (correlator-sidelobe origin); falsifier: no second above-threshold peak (latch origin). Then sel 13/14 to confirm the interpolator did NOT change phase at that beat.
- If **P2**: sel 13 burst capture. Prediction: `countReg`/`mu` (or the underflow cadence) show a discontinuity at `onset_beat_data` ± 2 beats; falsifier: interpolator phase continuous → sel 14 (buffer) then sel 15 (Rate_Handle occupancy step at onset).
- If **NEITHER/UNINFORMATIVE**: no secondary arm; report and return to the operator.

- [ ] **Step 2: Run the chosen arm(s) with `beat_tap_capture.sh SEL=<n>` under `launch_rig_unit.sh`, decode with `ddrcap2_decode.py`, score liveness with `ddrcap2_pc.py --sel <n>`, and extract the ±16-beat window around `onset_beat_toff`/`onset_beat_data` (from §82) with a 12-line numpy snippet in the report, comparing against the pre-registered prediction.**

- [ ] **Step 3: §83+ and commit, one section per arm, each labelled [silicon].**

---

## Ordering

1 → 2 → 3 (decoder can parallel 2) → 4 (gate, blocks the build) → 5 (build) → 6 (chain; flash needs operator go) → 7 → 8 → 9. Tasks 7's scripts and 8's analysis can be written and unit-tested while the build runs (Task 5 Step 2), but no capture runs before the flash.
