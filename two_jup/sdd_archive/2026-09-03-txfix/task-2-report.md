# Task 2 (T0a) — injector, tests, variant trees, harness, sim builds

Plan: `/home/tcollins/.claude/plans/happy-bubbling-owl.md` (RTL facts / Fix variants /
Verilator gate / Decisions taken). Host-only; no board contact at any point.

## 1. RTL verification (done against the netlist, not the plan text)

Tree read: `jupiter_240k5_byte/rtl_sim/s1_rtl_txmark/hdlsrc/commhdlQPSKTxRxLoopback/`.

| plan claim | verified in RTL |
|---|---|
| pop-enable latch always-block at `Data_Bits_FIFO.v:272-289`, clear at `:279` | CONFIRMED — `Data_Bits_FIFO.v:272-289` is `Unit_Delay_Enabled_Resettable_Synchronous_process`; `:279` is `if (Compare_To_Constant1_out1 == 1'b1)` and `:283` the nested `if (Compare_To_Constant3_out1)`. |
| `Compare_To_Constant1_out1 = Delay3_out1 == 2'b00` at `:270` | CONFIRMED — `Data_Bits_FIFO.v:270`. |
| `Compare_To_Constant2_out1 = Delay3_out1 != 2'b00` at `:248` | CONFIRMED — `Data_Bits_FIFO.v:248`. |
| **`Compare_To_Constant2_out1 ≡ ~Compare_To_Constant1_out1`** | **CONFIRMED by inspection** — the two assigns are `==`/`!=` of the *same* net `Delay3_out1` against the *same* constant `2'b00`, with no other driver of either net in the file. So on a `sampleCount==0` tick the F1-patched nest assigns exactly what the original assigned; F1 differs from the original *only* on ticks with frameCount==0 AND sampleCount≠0, i.e. the defect. |
| `Compare_To_Constant3_out1 = HDL_Counter2_out1 == 0` (sampleCount==0) at `:220` | CONFIRMED — `Data_Bits_FIFO.v:220`. |
| unguarded `frameCount ±1` in `RAM_Frame_Status_Indicator.v` | CONFIRMED — `RAM_Frame_Status_Indicator.v:70-75` (`+2'b01` at `:71` on `pushCount == 15'b110000000111111 && push`; `-2'b01` at `:74` on the pop-wrap). `frameCount_temp` declared `:47`. |
| wrap constant | the netlist constant is `15'b110000000111111` = **24 639** (the plan text's "12,319" is the *symbol*-domain figure; the RTL counts bits). Anchors use the literal, so this does not affect the patch. |
| `MATLAB_Function1.v` uint16 `count`, `full = count_temp > 49279`, no saturation | CONFIRMED — `MATLAB_Function1.v:40` (`reg [15:0] count`), `:59-64` (unguarded `+1`/`-1`), `:65` `full_1 = count_temp > 16'b1100000001111111` (= 49279). File is 71 lines in this tree, so the plan's ":158-163" line cite is stale; the anchors are text-based. |
| `Bit_Packetizer.v` `Logical_Operator2_out1 = ~fullRAM`, `dataReady = (HDL_Counter_out1 == 1)` | CONFIRMED — `Bit_Packetizer.v:144` (`assign Logical_Operator2_out1 =  ~ Data_Bits_FIFO_fullRAM;`), `:176` (`DataReadyPaceCmp_out1`), `:178` (`assign dataReady = DataReadyPaceCmp_out1;`). |
| F3b margin constant | `16'b1100000001101111` = **49263** = 49279 − 16. CONFIRMED arithmetically (asserted in the test suite). |

### `_patcher_for` cannot reach a foreign `MATLAB_Function1.v` — confirmed
Dispatch is by *exact* basename (optionally with the `TxRxCompo_ip_src_` prefix), and it
is additionally scoped by variant. The IP kit zip
(`jupiter_byte_ddrcap2_build/.../TxRxCompo_ip_v1_0.zip`) contains seven sibling modules —
`MATLAB_Function.v`, `MATLAB_Function_block{,1,2,3}.v` — none of which match the basename.
Scanning every `.v` member of that zip for the F3 threshold anchor `16'b1100000001111111`
shows it in exactly two members: `TxRxCompo_ip_src_Data_Bits_FIFO.v` (×2, its own
sampleCount compares) and `TxRxCompo_ip_src_MATLAB_Function1.v` (×1). So the anchor is
unique inside the one file the patcher is allowed to touch, and were a differently-sourced
`MATLAB_Function1.v` ever to appear, `_sub()`'s `count == 1` assertion fires and the run
prints `TXFIX_INJECT_FAIL` rather than editing the wrong module. Covered by
`test_patcher_dispatch_is_variant_scoped_and_prefix_aware` and
`test_wrong_file_content_fails_rather_than_silently_patching`.

## 2. Deliverables

- `two_jup/skidfix/txfix_inject.py` — `<dir> F1|F2|F3 [--margin]`. ddrcap2_inject.py
  skeleton: basename PATCHERS incl. the `TxRxCompo_ip_src_` prefix, idempotent
  `TXFIX_F1/F2/F3` markers, `patch_zip`/`verify_zip` (per-variant expected members),
  `_sub()` asserting a unique anchor, `main()` asserting every variant file was found,
  summary `TXFIX_INJECT variant=… loose=… missing=[] zips=… zips_verified=…` and failure
  line `TXFIX_INJECT_FAIL`. Variants are cumulative (F2 ⊃ F1, F3 ⊃ F2).
- `two_jup/tests/test_txfix_inject.py` — **19 tests, all green** (3.4 s).
- `jupiter_240k5_byte/rtl_sim/s1_rtl_txfix_F{1,2,3}/` — `cp -a s1_rtl_txmark` + injection.
  Left untracked, matching the existing `s1_rtl_*` sim-tree convention; fully reproducible.
  The pre-existing unrelated `s1_rtl_txfix/` was not touched.
- `jupiter_240k5_byte/rtl_sim/txfix_lint.sh` — two lint passes, `TXFIX_LINT_OK_<V>_<TOP>`.
- `jupiter_240k5_byte/rtl_sim/sim_txfix_force.cpp` — copy of `sim_burst_force_tx.cpp`
  (original untouched, `git status` clean on it) + READBACK + latchforce.
- `build_txkick_sim.sh` / `build_txrate_sim.sh` — `TREE`/`OBJ`/`HARNESS` env params,
  defaults identical to today's behaviour.

### Diff review of the three trees (by hand)
`F1` 1 hunk / 1 file; `F2` 3 hunks / 2 files; `F3` **6** hunks / 4 files.
The plan predicted 1/3/5. F2 matches (1 DBF + 2 FSI: the `reg fcInc/fcDec` declaration
block and the inc/dec pair). F3 is 6 rather than 5 because `MATLAB_Function1.v` also needs
its `reg cntInc/cntDec` declarations, and those sit ~15 lines above the body edit, so the
unified diff cannot merge them into one hunk. Same four files, same edits as specified —
purely a hunk-counting artefact, no extra change.

Reviewed edits:
- `Data_Bits_FIFO.v` — clear+reload moved wholesale inside the `Compare_To_Constant3_out1`
  branch; the `else` arm still reloads from `Compare_To_Constant2_out1`.
- `RAM_Frame_Status_Indicator.v` — `fcInc/fcDec` computed first, then a saturating
  `if/else if` at both rails. Simultaneous push-wrap+pop-wrap is a no-op, which is exactly
  what the original `+1` then `−1` netted to.
- `Bit_Packetizer.v` — `assign dataReady = DataReadyPaceCmp_out1 & Logical_Operator2_out1;`
- `MATLAB_Function1.v` — `cntInc/cntDec` then a saturating `if/else if` at 0 and 65535;
  threshold unchanged unless `--margin`.

### Lint
`txfix_lint.sh F1|F2|F3` all exit 0. Pass 1 (lenient, `-Wno-lint`) elaborates six tops —
`Data_Bits_FIFO`, `Bit_Packetizer`, `QPSK_Tx`, `Transmitter`, `TxRxComposite`, and the sim
top `wrap_byte_ddrcap` (the plan said "the 5 tops"; the sim top was added because that is
what the Verilator gate actually builds). Pass 2 is strict `-Wall` on each of the four
touched files with an explicit refusal of `LATCH` / `ALWCOMBORDER` / `CASEINCOMPLETE`
(only `DECLFILENAME`/`UNUSEDSIGNAL`/`UNUSEDPARAM`/`VARHIDDEN` are waived — all pre-existing
HDL-Coder style noise, none of them classes these patches could introduce).

### Harness additions (every pre-existing `sel` byte-for-byte unchanged)
1. `popabort READBACK` — on the force tick and the 4 following ticks:
   `# popabort READBACK clk=<n> d3_post=<v> armed=<v> pop=<v>`.
   `d3_post=0` on the force tick proves the write landed, so a null on a fixed tree is
   non-vacuous.
2. `sel=latchforce` — single-shot write of
   `Unit_Delay_Enabled_Resettable_Synchronous_out1 = 0` at `sampleCount >= 12314 − 128*k`;
   no fix variant can suppress it (F1 only stops the *RTL* from clearing the latch).
   Emits its own `READBACK` lines, a `WITNESS armed reload` line and a
   `# latchforce SUMMARY … saw_armed_one= armed_one_sampleCount= clk_to_reload= max_pop_quiet=`
   line. Unlike the popabort witness this one runs to the end of the simulation, because
   the reload happens at the next `sampleCount==0` boundary — up to 197,328 clk away, far
   beyond the 64-tick `WITNESS_WINDOW`.
3. `sel=latchforce_pre` — the same write placed inside the preamble window
   (`sampleCount < 26`); expected to score offset 0.

## 3. Sim builds — ALL FOUR COMPLETE, exit 0

Launched 2026-09-03 10:06:42 as four parallel `systemd-run --user` units, working
directory `/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim`,
line-buffered logs:

| unit | what | log |
|---|---|---|
| `txfix-simbuild-F1-100642` | `obj_txkick_F1` (+`obj_txrate_F1`) from `s1_rtl_txfix_F1` | `beat_runs/txfix_build_F1.log` |
| `txfix-simbuild-F2-100642` | `obj_txkick_F2` (+`obj_txrate_F2`) from `s1_rtl_txfix_F2` | `beat_runs/txfix_build_F2.log` |
| `txfix-simbuild-F3-100642` | `obj_txkick_F3` (+`obj_txrate_F3`) from `s1_rtl_txfix_F3` | `beat_runs/txfix_build_F3.log` |
| `txfix-simbuild-U-100642` | `obj_txkick_U` from the UNFIXED `s1_rtl_txmark`, `HARNESS=sim_txfix_force.cpp` (so G1's readback line exists on the unfixed tree) | `beat_runs/txfix_build_U.log` |

Each has a controller watcher (`watch-txfix-simbuild-<V>-100642`) spawned via
`two_jup/agents/watch_unit.sh --spawn`, and all four are registered in
`two_jup/agents/lanes.json` with `max_age_min: 15`.

The gate matrix itself is Task 5's; nothing in this task ran it.

### Build results
All four units finished `Result=success`, `ExecMainStatus=0`:
`TXKICK_BUILD_EXIT 0` + `TXRATE_BUILD_EXIT 0` for F1/F2/F3, `TXKICK_BUILD_EXIT 0` for U.
Objects present: `obj_txkick_F{1,2,3}`, `obj_txrate_F{1,2,3}`, `obj_txkick_U`.

### Harness smoke evidence (unfixed tree `obj_txkick_U`, NF=2 K=1 k=0 SEL=6)
Not part of the gate matrix (Task 5 owns that) — run only to prove the two new
instruments emit and behave. All three lines below are verbatim from the run:

```
# popabort FORCE clk=148020 frame=1 sampleCount=12314 target=12314 pre_armed=1 pre_pop=1
# popabort READBACK clk=148020 d3_post=0 armed=1 pop=1
# popabort READBACK clk=148022 d3_post=1 armed=0 pop=0
# popabort SUMMARY k=0 ... saw_armed_zero=1 armed_zero_clk=148022 max_pop_quiet=63

# latchforce READBACK clk=148020 armed_post=0 d3=1 pop=1
# latchforce WITNESS armed reload: clk=197430 sampleCount=0 (49410 clk after the force)
# latchforce SUMMARY ... saw_armed_one=1 armed_one_sampleCount=0 clk_to_reload=49410 max_pop_quiet=49516

# latchforce_pre FORCE clk=98765 frame=1 sampleCount=0 ... pre_armed=0 pre_pop=0
# latchforce_pre READBACK clk=98766 armed_post=1 d3=1 pop=0
# latchforce_pre SUMMARY ... clk_to_reload=1 max_pop_quiet=107
```

Reading: `d3_post=0` on the force tick proves the write landed (the RTL reloads
`Delay3_out1` to 1 two ticks later), and `armed` falls 1→0 at clk 148022 — the
readback is doing exactly the job it was added for. `latchforce` holds the pop
strobe dead for 49,410 clk until the next `sampleCount==0` boundary reloads the
latch, i.e. the sustained-stall positive control works and no fix variant can
suppress it. `latchforce_pre` is reloaded to 1 on the very next tick (the boundary
it was written in), pop quiet only 107 clk — the intended null control.

## 4. Concerns / handover notes

1. **F3 diff is 6 hunks, not the predicted 5** — explained above; benign.
2. **The plan's `pushCount == 12,319` is not the netlist constant.** The RTL compares
   `15'b110000000111111` = 24,639 (bit domain). Anchors use the literal so nothing breaks,
   but any *reasoning* about the fill cycle that starts from 12,319 should be re-checked.
   Likewise `MATLAB_Function1.v:158-163` in the plan is stale (the file is 71 lines).
3. **F2/F3 change combinational-block structure, not just constants.** `fcInc/fcDec` and
   `cntInc/cntDec` are new combinational regs inside existing `always @(...)` blocks whose
   sensitivity lists were *not* extended (they are written before being read in the same
   block, so this is correct, and Verilator `-Wall` reports no `ALWCOMBORDER`/`LATCH`).
   Vivado/XSIM should agree, but this is the one place a synthesis/simulation mismatch
   could hide; T2 should read the synthesis log for latch inference on those two modules.
4. **`latchforce` needs `K ≥ 1`** so the arm lands on a real frame wrap, and `k` sweeps the
   same `12314 − 128k` anchor as `popabort`. `latchforce_pre` ignores `k`.
5. **`lanes.json` still carries Task 1's `selftest` lane with `max_age_min: 1`.** I appended
   to the file rather than editing it; if that self-test lane is stale it will keep firing
   `STALL` lines. Task 1 owns that entry.
6. **The three variant trees are untracked** (matching every other `s1_rtl_*`). Regenerate
   with `cp -a s1_rtl_txmark s1_rtl_txfix_F<V> && python3 two_jup/skidfix/txfix_inject.py
   s1_rtl_txfix_F<V> F<V>` if a clean checkout is ever needed.
7. **`txfix_inject.py` has not yet been run against a Vivado build kit** (that is Task 3's
   `jupiter_byte_txfixF*_build/`). The zip path is exercised only by the synthetic
   two-member zip in the test suite. The `nz not in (0, 2)` rule is inherited from
   ddrcap2_inject.py: a kit is expected to hold exactly two `TxRxCompo_ip_v1_0.zip` files.
   Note the kit also holds **three** loose copies of each touched file (hdlsrc/, ipcore/,
   vivado_ip_prj/ipcore/) — `main()` counts logical names, not paths, so `loose=` will read
   3× the variant's file count there. That is expected, not a fault.

8. **Shared git index: three of my commits swept in other tasks' staged files.**
   Tasks 2/3/4 were committing concurrently into one working tree, so `git add`
   followed by `git commit` picked up whatever the other agents had already staged.
   Affected: `4fa993c` also carries T0b's `jupiter_byte_txfix_{fetch,kit}.sh` and
   `two_jup/skidfix/txfix_build.{sh,tcl}.tmpl` + `txfix_kit_readme.md.tmpl`;
   `dfa16d3` also carries a `jupiter_byte_txfix_kit.sh` update; `8aff98b` also
   carries T0c's `task-4-report.md` and `two_jup/tests/test_txfix_rig_scripts.py`.
   Nothing is lost or altered — the content is those agents' own, just committed
   under my message. History was deliberately NOT rewritten (other agents were
   committing at the time). Later commits here use `git commit -- <paths>` instead.
9. **`two_jup/agents/lanes.json` no longer lists the four build lanes** — Task 5
   rewrote it with its gate lanes while the builds were finishing. Harmless: the
   builds had already completed and their `watch-txfix-simbuild-*` units reported.
10. **The `advisor` reviewer was unavailable for this whole task** (returned
   "temporarily overloaded" on every call, at the start and before declaring done),
   so this work has had no second-model review. Worth a scoped review before F3's
   netlist goes to Vivado.

## 5. Review round 1 (coordinator, 2026-09-03) — both items fixed

**Important #1 — `--margin` was a silent no-op on an already-F3 tree.** Confirmed:
`patch_matlab_function1`'s guard was `if 'TXFIX_F3' in s: return 'already'`, and
`TXFIX_F3` is a prefix of the F3b marker, so a second call with `margin=True`
returned `'already'` while `main()` still printed `variant=F3b` and `verify_zip`
still passed against the F3 marker. Fixed:
- the guard is now margin-aware and tests `TXFIX_F3B` *first* (prefix relation);
- `margin=True` on an F3-only tree re-patches just the threshold line (`'patched'`);
- `margin=False` on an F3b tree is **refused** with an assertion (a downgrade is
  never what the caller meant);
- `verify_zip(zpath, variant, margin=False)` swaps `MATLAB_Function1.v`'s expected
  marker to `TXFIX_F3B` under `--margin`, and `main()` passes `margin` through.

**Important #2 — uneven loose copies.** `main()` now carries
`assert nloose % len(want) == 0` after the summary line, with a message naming the
counts: a Vivado kit holds the same file set in `hdlsrc/`, `ipcore/` and
`vivado_ip_prj/ipcore/`, so a remainder means one tree is missing a file.

Regression tests added (6): `test_f3_then_margin_upgrades_the_threshold`,
`test_main_f3_then_f3_margin_on_the_same_tree` (asserts the threshold is
`16'b1100000001101111` and the summary reads `variant=F3b`),
`test_plain_f3_on_an_f3b_tree_is_refused`,
`test_verify_zip_margin_requires_the_f3b_marker`, `test_uneven_loose_copies_fail`,
`test_even_loose_copies_across_two_trees_pass`.
**pytest: 25 passed (4.5 s).**

The three `s1_rtl_txfix_F*` trees and all `obj_*` directories were NOT touched
(verified: `s1_rtl_txfix_F3/.../MATLAB_Function1.v` still carries the 49279
threshold, mtime unchanged at 10:03; `obj_txkick_F3/Vtxkick` unchanged at 10:09).
