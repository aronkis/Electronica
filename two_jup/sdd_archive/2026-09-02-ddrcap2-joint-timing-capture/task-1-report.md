# Task 1 report: DDRCAP2 injector part 1 (source-module ports)

## What was implemented

Three files, exactly as named in the brief:

- `two_jup/skidfix/ddrcap2_inject.py` — `patch_interpolation_control`,
  `patch_symbol_synchronizer`, `patch_preamble_detector`, plus the shared
  helpers `add_ports`, `decl_lines`, `_insert_after`, `_insert_before_endmodule`,
  and the port tables `PD_PORTS` / `SS_PORTS`. Copied verbatim from the task
  brief's Step 3 code block — no changes were needed (see anchor verification
  below).
- `two_jup/tests/test_ddrcap2_inject.py` — the four tests from Step 1, copied
  verbatim.
- `jupiter_240k5_byte/rtl_sim/build_ddrcap2_sim.sh` — the netlist-build script
  from Step 5, copied verbatim, made executable (`chmod +x`). Per the brief,
  its `ddrcap2_inject.py`/composite-patch path is not exercised in this task
  (Task 2 adds `main` and the composite patcher); only the test suite was run.

No modifications were made to `ddrcap_inject.py` or to any netlist in place —
the tests copy `.v` files from
`jupiter_240k5_byte/rtl_sim/s1_rtl_txmark/hdlsrc/commhdlQPSKTxRxLoopback/`
into a tempdir and patch the copies.

## Anchor verification (before writing the injector)

Before trusting the brief's code verbatim, I greped the actual netlist
(`s1_rtl_txmark/hdlsrc/commhdlQPSKTxRxLoopback/`) for every anchor string used
by the three patchers:

- `Interpolation_Control.v`: port list ends `...Underflow);` (line 29),
  `output  Underflow;` (line 37), `reg signed [10:0] countReg;  // sfix11`
  (line 45) — all match.
- `Symbol_Synchronizer.v`: port list ends `...beatobsPop);` (line 37, i.e.
  the terminal-port form used by `add_ports`'s `a2` branch),
  `output  [4:0] beatobsPop;` (line 54), `wire signed [10:0] mu;` (line 95),
  `wire Underflow;` (line 82), `reg signed [18:0] Delay8_out1_re;` (line 89),
  `assign beatobsPop = Rate_Handle_beatobsPop;` (line 483), and the
  `.Underflow(Underflow)\n                                          );`
  instantiation closing (line 364-365, whitespace-for-whitespace identical,
  confirmed with `cat -A`) — all match.
- `Preamble_Detector.v`: port list has `fs_runmax,` mid-list (line 35, the
  non-terminal `a1` branch), `output  signed [31:0] fs_runmax;` (line 56),
  `assign fs_runmax = Peak_Search_p1c_runmax;` (line 477), and all five
  `wire ... Peak_Search_*` / `Correlator_*` decls (lines 62-75) — all match.

**No anchor needed correction.** Every string in the brief's Step 3 code
matched the real netlist exactly, so the injector and test files were written
verbatim from the brief with no edits to either the code or the test
expectations.

## RED

```
$ cd two_jup && python3 -m pytest tests/test_ddrcap2_inject.py -q
adi_lg_plugins: driver 'kasadriver' not registered (No module named 'kasa')

==================================== ERRORS ====================================
________________ ERROR collecting tests/test_ddrcap2_inject.py _________________
ImportError while importing test module '.../two_jup/tests/test_ddrcap2_inject.py'.
Hint: make sure your test modules/packages have valid Python names.
Traceback:
/usr/lib/python3.12/importlib/__init__.py:90: in import_module
    return _bootstrap._gcd_import(name[level:], package, level)
tests/test_ddrcap2_inject.py:6: in <module>
    import ddrcap2_inject as inj
E   ModuleNotFoundError: No module named 'ddrcap2_inject'
=========================== short test summary info ============================
ERROR tests/test_ddrcap2_inject.py
!!!!!!!!!!!!!!!!!!!! Interrupted: 1 error during collection !!!!!!!!!!!!!!!!!!!!
1 error in 1.44s
```

(Expected `ddrcap2_inject` does not exist yet — matches the brief's expected
RED.)

## GREEN

```
$ cd two_jup && python3 -m pytest tests/test_ddrcap2_inject.py -q
adi_lg_plugins: driver 'kasadriver' not registered (No module named 'kasa')
....                                                                     [100%]
4 passed in 2.81s
```

`verilator --version` used for the lint test: `Verilator 5.020 2024-01-01 rev
(Debian 5.020-1)`. `test_lint_after_source_patches` builds
`Frequency_and_Time_Synchronizer` (which instantiates `Symbol_Synchronizer`,
which instantiates `Interpolation_Control`; `Preamble_Detector` is patched but
not on this particular lint top's cone — it is still exercised by its own
dedicated port/assign test) with `--lint-only -Wno-fatal -Wno-lint` and
asserts `returncode == 0`; it passed clean.

## Files changed

- `two_jup/skidfix/ddrcap2_inject.py` (new, 136 lines)
- `two_jup/tests/test_ddrcap2_inject.py` (new, 51 lines)
- `jupiter_240k5_byte/rtl_sim/build_ddrcap2_sim.sh` (new, 21 lines, executable)

Commit: `0acd1fc` on branch `per-under-1pct-2026-07`, local only (not pushed),
signed off (`git commit -s`).

## Self-review

- `python3 -m py_compile` on both `.py` files and `bash -n` on the shell
  script all passed clean before committing.
- `git status --short` before staging showed only the three intended new
  files among the paths this task touches; all other untracked entries in the
  tree are pre-existing scratch/capture data unrelated to this task and were
  left untouched (not added to the commit).
- Confirmed idempotency implicitly via the tests: `patch_interpolation_control`
  is asserted to return `'already'` on a second call in
  `test_interpolation_control_exposes_countreg`; the other two patchers use
  the same `if <marker> in s: return 'already'` guard pattern (not
  independently re-tested here, since the brief's test list doesn't call for
  it, but the code path mirrors the first-pass injector's house style and the
  guard strings — `dc_countreg`, `dc_toff` — are each patcher's own new
  content, so a second call is a true no-op).
- Did not touch `ddrcap_inject.py` or any netlist in place, per constraints.
- Did not dispatch subagents; all work done directly in this session.

## Concerns

None. All anchors matched the brief exactly on first read, both RED and
GREEN outputs match the brief's expectations, and the lint test passed
without needing `-Wno-lint`/`-Wno-fatal` to mask a real structural problem
(both flags were already specified by the brief's test, used as given).
