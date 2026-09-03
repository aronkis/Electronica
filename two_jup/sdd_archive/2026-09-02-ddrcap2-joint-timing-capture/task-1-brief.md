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

