# Task 2 report: injector part 2 — FTS→QPSK_Rx→Receiver→Composite threading, ch2/ch3 packing, sel 12-15, zips, main

## RED (Step 1-2)

Appended `_full`, `test_full_tree_lints_and_is_idempotent`, `test_main_on_sim_tree_reports_success` to
`two_jup/tests/test_ddrcap2_inject.py`. Ran:

```
cd two_jup && python3 -m pytest tests/test_ddrcap2_inject.py -q
```

```
FAILED tests/test_ddrcap2_inject.py::test_full_tree_lints_and_is_idempotent
FAILED tests/test_ddrcap2_inject.py::test_main_on_sim_tree_reports_success
AttributeError: module 'ddrcap2_inject' has no attribute 'patch_fts'
AttributeError: module 'ddrcap2_inject' has no attribute 'main'
2 failed, 4 passed in 3.25s
```
Matches the brief's predicted failure mode exactly.

## Anchor verification against the real netlist (before writing code)

Copied `jupiter_240k5_byte/rtl_sim/s1_rtl_txmark/hdlsrc/commhdlQPSKTxRxLoopback/*.v` to a scratch dir and
checked every literal anchor string in the brief against the real files. Two were off by one leading
space; every other anchor (QPSK_Rx `fts_anchor`, Receiver `inst_tail`, all TxRxComposite anchors —
`recv_tail`, `MUX_I_OLD`/`MUX_Q_OLD`/`MUX_V_OLD`, `OLD_MARKS`, the `wire signed [15:0] ddrcap_mux_i =`
line, and the `(ddrcap_sel_r <= 4'd8) ?` count of 3) matched the brief verbatim.

1. **`patch_fts` `pd_tail`** — brief: `"                                         .pdWitB(pdWitB));"` (41
   leading spaces). Real file (`Frequency_and_Time_Synchronizer.v` line 196):
   `'                                        .pdWitB(pdWitB));\n'` — **40** leading spaces. Corrected the
   anchor constant to 40 spaces; left the replacement text's cosmetic indentation (41 spaces, matching the
   sibling connection lines added below it) untouched since Verilog whitespace is not semantically load-bearing.

2. **`patch_fts` `ss_tail`** second line — brief: `"                                                               );"`
   (63 leading spaces). Real file (line 150): `'                                                              );\n'`
   — **62** leading spaces. Corrected to 62.

Both corrections narrow the anchor to exactly what's on disk — neither loosens a check; they make the
`assert need in s` strictly more specific (the wrong string never matched anything, so before the fix the
assert would have failed with `AssertionError`, not passed loosely).

3. **`patch_receiver` count assert** — brief: `assert s.count('ddrcap_dc_rhpop') == 4`. Running the real
   construction (port-list entry, `output` decl, `QPSK_Rx_`-prefixed wire decl, the connection line
   `.ddrcap_dc_rhpop(QPSK_Rx_ddrcap_dc_rhpop)` which contains the substring twice, and the top-level
   `assign ddrcap_dc_rhpop = QPSK_Rx_ddrcap_dc_rhpop;` line which also contains it twice) yields **7**
   occurrences, confirmed by direct substring-count debugging before touching the assert. Same failure mode
   as the two step-5 line-vs-occurrence mismatches below: the brief counted sites/lines (5ish), the code
   counts substring occurrences (7). Corrected `== 4` to `== 7` — this is a correction to the true
   arithmetic fact, not a relaxation (7 is more specific than a wrong 4, and the assert still fails on any
   other value).

## GREEN (Step 4)

```
cd two_jup && python3 -m pytest tests/test_ddrcap2_inject.py -q
```
```
6 passed in 5.80s
```
All six tests pass, including the Verilator `--lint-only --top-module TxRxComposite` pass on the fully
patched tree and the idempotency checks (`patch_composite` and `patch_qpsk_rx` both return `'already'` on
a second pass).

## Sim netlist (Step 5)

```
cd jupiter_240k5_byte/rtl_sim && rm -rf s1_rtl_ddrcap2 && FORCE=1 NETLIST_ONLY=1 bash build_ddrcap2_sim.sh
```
```
DDRCAP2_INJECT loose=7 missing=[] zips=0 zips_verified=0
```
(`missing=[]` — all 7 logical modules found and patched; `zips=0` is correct for this sim tree, which has
no `TxRxCompo_ip_v1_0.zip`; the script's own `grep -q "ddrcap2_slot_r" ... || exit 1` post-check also
passed since the build didn't abort.)

`grep -c "ddrcap_dc_" TxRxComposite.v` → **45** matching *lines*, below the brief's "≥ 60" expectation.
Investigated: the brief's threshold is an *occurrence* count paired with a line-count command. Re-ran with
`grep -o "ddrcap_dc_" TxRxComposite.v | wc -l` → **61** occurrences, which does clear ≥ 60. Manually
verified the line-level breakdown accounts for exactly 45 lines: 15 `RX_PORTS` × (1 wire-decl line + 1
connection line, the latter containing the substring twice) = 30, plus the mux/PRE/POST usages (9 mux
lines, 1 PRE line, 5 POST lines) = 45. This is a documentation slip in the brief (line-count command,
occurrence-count threshold), not a shortfall in the implementation — same class of miscount as the
`rhpop == 4` fix above.

## Zip mechanics smoke test (not exercised by the given pytest tests, since `_copy()` only copies `.v`
files, and the sim tree has `zips=0`)

Verified the untouched-file constraint directly rather than inferring it from `PATCHERS`:
```
cmp -s s1_rtl_final/.../TxRxCompo_ip_dut.v s1_rtl_ddrcap2/.../TxRxCompo_ip_dut.v  # DIFFERS
cmp -s s1_rtl_final/.../TxRxCompo_ip.v     s1_rtl_ddrcap2/.../TxRxCompo_ip.v      # DIFFERS
```
Both differ between `s1_rtl_final` and `s1_rtl_ddrcap2`, but only because `build_ddrcap2_sim.sh` runs the
**v1** `ddrcap_inject.py` first (its own `patch_dut`/`patch_ip_top`, present in v1's `PATCHERS`), before
`ddrcap2_inject.py` runs. Task 2's `PATCHERS` dict contains no entry for `TxRxCompo_ip_dut.v` or
`TxRxCompo_ip.v` — grep-confirmed — so `ddrcap2_inject.py` itself never modifies them, satisfying the
constraint.

No `TxRxCompo_ip_v1_0.zip` exists inside the tested sim tree, so `patch_zip`/`verify_zip` are not exercised
by the pytest run. Built a synthetic v1-only zip (took a real `TxRxCompo_ip_v1_0.zip` found under
`jupiter_byte_lean_build/`, and replaced its 7 `TxRxCompo_ip_src_*.v` members' contents with the *same*
`s1_rtl_txmark` sources the pytest suite copies) and ran `patch_zip`/`verify_zip` on the scratch copy
directly:
```
patch_zip members patched: 7   (all 7 -> 'patched')
verify_zip: True
```
This exercises the real zip read/patch/rewrite/verify path end to end, confirming `patch_zip` and
`verify_zip` work correctly on a zip whose members are in the expected pre-v2 state. (A raw, never-v1-
patched zip found on disk correctly raised the `pdWitB` anchor `AssertionError`, as expected — it predates
even the v1 TXMARK patch.)

## Files changed

- `two_jup/skidfix/ddrcap2_inject.py` — appended `FTS_PORTS`, `RX_PORTS`, `patch_fts`, `patch_qpsk_rx`,
  `patch_receiver`, `COMPOSITE_PRE`/`COMPOSITE_POST`/`MUX_*_OLD`/`MUX_*_NEW`/`OLD_MARKS`, `patch_composite`,
  `PATCHERS`, `_patcher_for`, `EXPECTED_ZIP_MEMBERS`, `patch_zip`, `verify_zip`, `main`, `__main__` block.
- `two_jup/tests/test_ddrcap2_inject.py` — appended `_full`, `test_full_tree_lints_and_is_idempotent`,
  `test_main_on_sim_tree_reports_success`.

## Self-review

- Every anchor in the brief was checked against the real `s1_rtl_txmark` tree before code was written, not
  after a test failure — two off-by-one-space anchors and one arithmetic assert value were corrected, each
  documented above with the real line/count.
- No assert was loosened: every correction replaced a value that could never have matched/held with the
  value that actually holds, and the corrected asserts are exactly as strict (equality, not range).
- Global constraints checked directly: top-level composite ports unchanged (only `ddrcap_mark_demod` /
  `ddrcap_mark_fec` *assigns* were repacked, not the port declarations); `TxRxCompo_ip_dut.v`,
  `TxRxCompo_ip.v` untouched by `ddrcap2_inject.py` (confirmed both by `PATCHERS` dict inspection and by
  `cmp` diff-attribution); record packing matches the brief's exact bit layout (ch2 =
  `{ddrcap_demod_mark_now, ddrcap_fec_mark_now, Receiver_ddrcap_dc_toff[13:0]}`, ch3 =
  `{ddrcap2_slot_r, ddrcap2_side}` with the 4-way `heldts`/`tref`/`runmax[31:18]`/`corrthr[31:18]` mux);
  the three `(ddrcap_sel_r <= 4'd8)` conditions are all widened to `|| ddrcap_sel_r >= 4'd12` (verified
  count == 3 both before and after).
- No subagents dispatched; all work done directly in this session, entirely local (no ssh, no long sims).

## Concerns

1. The brief's Step 5 "count ≥ 60" instruction pairs a `grep -c` (line-count) command with an
   occurrence-count threshold. Real line count is 45; real occurrence count (`grep -o | wc -l`) is 61.
   Recommend the spec's Step 5 be corrected to either `grep -c` with a ~45 threshold or `grep -o | wc -l`
   with ≥ 60, so future re-runs of this exact command don't look like a regression.
2. The brief's `patch_receiver` sanity assert (`== 4`) undercounted; fixed to `== 7` with the derivation
   documented in code and above. Worth a spec-doc note in case other `.count()` sanity asserts in later
   tasks carry the same slip.
3. `patch_zip`/`verify_zip` are not exercised by the pytest suite as given (no zip in the `.v`-only
   `_copy()` fixture, and the sim tree under test has `zips=0`). I smoke-tested them manually against a
   synthetic zip (documented above) rather than adding new pytest tests, since the brief's Step 1 code
   block is exact and appending un-briefed tests would go beyond "append what's specified." If Task 3+ or
   a later spec step wants zip-path coverage inside pytest, a fixture zip should be added to the repo.
