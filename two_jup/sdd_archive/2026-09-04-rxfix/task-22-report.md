# Task 22 — the 146 fix candidate: W1 + R4D + R1, kit and build, BANK ONLY

Branch `per-under-1pct-2026-07`. Ledger `Task 22:` lines in `progress.md`.
Labels: **[netlist]** throughout — **no board contact occurred in this task, and no
flash was attempted.** The flash on 146 needs the operator (the permission classifier
denies flash launches to agents) and T19's witness branch.

Commits: `704bd65` (kit + kit-shaped tests), `40e5c21` (W1_REGMAP R4D words), this
report.

---

## 1. Kit provenance  [netlist]

`RXFIX_VARIANTS='W1 R4D R1' two_jup/skidfix/jupiter_byte_rxfix_kit.sh 148`

| | |
|---|---|
| source kit | `jupiter_byte_seqbist_build` (the 148 SEQ-BIST tree; same source as W1 and W1+R4B) |
| kit | `jupiter_byte_rxfixr4dr1_build` |
| variants, in order | **W1 → R4D → R1** |
| injector commit | **`10b27b737847123b7dc120ff408f0e63541496c3`** (asserted committed-clean before the copy) |
| injector md5 | `7217adc56ef75656f695be497fc952be` |
| read words | `0x214…0x230` (W1's eight) + **`0x234`** (R4D word 0, R4B's layout) + **`0x238`** (R4D word 1, `{16'b0, extras[15:0]}`) |
| verdict | `RXFIX_KIT_VERIFY_OK` / `RXFIX_KIT_DONE` |

`rxfix_inject.py` is **untouched** by this task — Task 21 owns that file tonight. The
recorded injector commit is therefore Task 21's R4E cut, which is simply the file's HEAD
when this kit ran; R4D, R1 and W1 are unchanged by it, and the md5 pins the exact bytes
executed.

### 1.1 R1 needs no `_PFX` change — checked, not assumed

The brief flagged the risk that R1, cut for the sim tree in Task 6, might not reach the
kit's prefixed modules the way R3S and R4 could not (tests 73/91). **It does reach them,
and the reason is structural:** R3S/R4 failed because their anchors match
`module <name> (` and instantiation headers, which the Vivado kit renames to
`TxRxCompo_ip_src_<name>`. R1's two anchors name no module at all:

```
PD_DECL_OLD    = "  wire Delay10_out1;\n"
PD_ASSIGN_OLD  = "  assign Delay10_out1 = Delay10_reg[49331];\n"
```

Both occur exactly once in the kit's own
`TxRxCompo_ip_src_Preamble_Detector.v` (module `TxRxCompo_ip_src_Preamble_Detector`,
the pop at **line 334**), and the nets R1's replacement reads —
`wire [13:0] FIFO_numEntries;` (line 112) and `wire Delay8_out1;` (line 106) — exist in
that lineage. So the minimal change was **no injector change at all**; what the task
added is the proof:

| test | what it pins |
|---|---|
| `test_160` | R1's anchors contain neither `module` nor `TxRxCompo_ip_src_`, so a future edit cannot quietly make R1 module-name-dependent |
| `test_161` | the real patcher runs on the kit's own prefixed `Preamble_Detector.v`: both new lines land **and** the tick-indexed `Delay10_reg[49331]` pop is **gone** (a patch that left it would be inert), and re-running returns `already` |
| `test_162` | **the Task 22 deliverable**, the analogue of test_119: W1 → R4D → R1 on the shipped kit shape, `verify_zip` green for all three markers on **both** zip members, three loose mirrors each, and R1 landing only in the file the other two do not own |
| `test_163` | the three file sets are disjoint where it matters (`VARIANT_FILES['R1'] == ['Preamble_Detector.v']`, absent from W1's and R4D's sets) |

**155/155 injector tests pass** (151 pre-existing + 4 new).

### 1.2 What the kit script gained

* `RXFIX_VARIANTS='W1 R4D R1'` → suffix `r4dr1`. The `'W1'` and `'W1 R4B'` paths are
  untouched.
* **Verification is now per variant, not per marker over one fixed list**, because R1's
  file set is one file and the others' is twelve. Each variant's own file set is checked
  for its own marker in **all three loose mirrors** and in **both** zip members.
* New gates: R4D's **two** witness words both decoded (`8'h8D` and `8'h8E`) and wired
  into `data_read`; R4D's extra-pop path present in `Rate_Handle`; and for R1 both new
  lines present **with the tick-indexed pop absent** — the check that distinguishes a
  real patch from an inert one.
* The witness status gate is variant-aware (`r4b_`/`r4d_`/`r4e_witness=on`), so a kit
  that had lost a W1 mirror still cannot build silently without its witness words.

### 1.3 Pre-build checks

| check | result |
|---|---|
| `test_rxfix_inject.py` | **155/155 pass** |
| kit verification | `RXFIX_KIT_VERIFY_OK`; `RXFIX_INJECT` `variant=W1 loose=36 zips_verified=2`, `variant=R4D loose=36 zips_verified=2 r4d_witness=on`, `variant=R1 loose=3 zips_verified=2`; six `RXFIX_KIT_ZIP_OK` lines (3 markers × 2 zips) |
| `verilator --lint-only --top-module TxRxCompo_ip` on the patched kit netlist | **0 errors**, 40 warnings, **0 on any `r4d_`, `w1_` or `Delay10_full` net** |
| R1 in the kit netlist | `wire Delay10_full;` (line 109), `assign Delay10_full = FIFO_numEntries == 14'd12333;` (349), `assign Delay10_out1 = Delay8_out1 & Delay10_full;` (351) |

---

## 2. Build  [netlist]

Launched from a local `systemd-run --user` step, running as a remote
`systemd-run --user` unit on hdl-dev-2 (never a harness background job).

| | |
|---|---|
| remote unit | `txfix-build-rxfixr4dr1_build-1788615305` |
| remote tree | `/home/tcollins/qpsk-builds/jupiter_byte_rxfixr4dr1_build` |
| started | 2026-09-05 09:35 |
| jobs / strategy | 6 / `explore` |
| preflight | 53 GB free (floor 25), no concurrent build unit |
| post-place report hook | installed (`two_jup/rxfix/add_postplace_report.sh`) |

**PENDING — filled in when the unit exits.**

| | value |
|---|---|
| elapsed | _pending_ |
| **modem-clock intra-clock routed WNS (THE GATE)** | _pending_ |
| overall routed WNS (`TXFIX_ROUTED_WNS`, the vendor IDELAYCTRL path) | _pending_ |
| post-synth `TIMING_GATE_WNS modem_dut` | _pending_ |
| **utilisation delta vs the W1+R4B build** (R1 removes the 49,332-flop `Delay10_reg`'s only reader and adds a 14-bit compare) | _pending_ |
| BOOT.BIN md5 | _pending_ |
| banked as | _pending_ |

### 2.1 The baselines, captured while the build was still running

Both comparison points were pulled off hdl-dev-2 **before** the R4DR1 build could produce
its own report, so the delta is against numbers that already existed rather than against
a memory of them (`system_top_utilization_placed.rpt` in each kit's `impl_1/`):

| | W1 `2728dab3979a` | **W1+R4B `9f13705d9fb0`** (the right baseline) |
|---|---|---|
| CLB LUTs | 47,242 (66.95 %) | **47,237** (66.95 %) |
| CLB Registers | 110,473 (78.28 %) | **110,550** (78.34 %) |
| CARRY8 | 1,583 | **1,587** |
| F7 Muxes | 1,277 | **1,245** |
| LUT as Memory | 5,671 | **5,660** |
| SRLC32E | 2,977 | **2,977** |
| Block RAM Tile | 66.5 | **66.5** |
| CLB occupancy | 100.00 % | **100.00 %** |

R4DR1 is built from the same 148 SEQ-BIST tree as R4B, so **R4B is the baseline that
isolates R1** (plus R4D's extra-pop path, a few flops). The W1 column is kept because
Task 9 published it and it shows the two are already within 5 LUTs of each other.

### 2.2 What to expect from R1 in the utilisation table, and why it is a real check

R1 deletes the **only reader** of `Delay10_reg`, a 1-bit × **49,332-deep** shift
register (`Delay10_reg[49331]` was its sole output), and replaces it with a 14-bit
equality compare against `FIFO_numEntries`. Vivado has no reason to keep storage nothing
reads, so it should **trim the whole thing**.

The baselines above make that prediction sharp rather than vague, and it is worth being
explicit because 49,332 flops cannot be discrete FFs in a design with 110,550 registers
total:

* if the shift register is inferred as **SRLs**, 49,332 ÷ 32 ≈ **1,542 SRLC32E** — more
  than **half** of the 2,977 in the baseline, so `SRLC32E` and `LUT as Memory` should
  fall by roughly that much;
* if it is inferred as **BRAM**, 49,332 bits ≈ 48 kb ≈ **1.4 RAMB36**, so
  `Block RAM Tile` should fall from 66.5 by ~1.5;
* either way `CLB Registers` should fall by at least the pipeline flops around it, and
  the 14-bit compare adds only a handful of LUTs back.

**A utilisation table that does NOT move is the finding**, not a formality: it would
mean the shift register survived — something else still reads it — and R1 did not do to
the netlist what Task 20 measured in sim. This is the only check in the whole task that
can catch that, because R1 has no witness register.

---

## 3. Banking  [pending]

`boot_known_good/BOOT.BIN.146.rxfixr4dr1.<md5>`, md5 **re-computed locally after
transfer** and compared to the remote `BYTE_BUILD_DONE` value before the banked name is
written, plus a `MD5SUMS` line and a README row.

`MD5SUMS` is **hand-appended**, not generated — the established pattern is
`md5sum <file> >> MD5SUMS` followed by `md5sum -c` on the new row (2026-09-02 task-5
brief; the k146 report re-runs the same check) — so appending is the correct action and
the new row gets verified, not assumed. Two pre-existing defects in that file are noted
and **not** silently fixed here: it covers only **14 of the 31** banked images, and one
row (`BOOT.BIN.148.rxfifo4k_v5debug.602b26c25c35`) carries a `boot_known_good/` path
prefix that makes `md5sum -c` fail from inside the directory. I add rows for images this
campaign built — the 146 candidate, and the currently-flashed 148 image
`9f13705d9fb0`, which Task 13 banked but never indexed — and retrofit nothing else.

**The name says 146 and the lineage says 148, and that is the single most important
caveat in this task.** This image is built from `jupiter_byte_seqbist_build` — the
**148** SEQ-BIST tree — and is *intended for* 146. Consequences, stated rather than
discovered later:

* 146's own lineage is `tmrfresh → TXFIX-F3 → SEQ-BIST @ ExtraNetDelay_high`
  (`3378861d30bd`), which is **not** this tree. Anything 146-specific in that
  lineage — the `ExtraNetDelay_high` place directive and the byte-plane margins it was
  chosen for, and whatever else the vendh/TMR history carries — is **not** in this
  image.
* There is a precedent banked this morning: `BOOT.BIN.146.w1x148.2728dab3979a` (08:17)
  is the 148 W1 image banked under a 146 name, with an `MD5SUMS` line but **no README
  row**. Mine gets a README row, and I note the precedent's missing one.
* Flashing 146 is an **operator** action here in any case.

---

## 4. Concerns

1. **148-lineage image for 146** (§3). This is the brief's design, but it means a 146
   flash swaps lineage as well as adding the fix, and any PER comparison against 146's
   current `3378861d30bd` confounds the two — exactly the confound the README already
   warns about for `6b4744ca73f8` ("placement alone moved 146's legs > 2 pp").
2. **0x238 is unread by every tool in this repo.** `w1_read.sh R4B=1` sweeps 0x234 only
   and `w1_score.py` has no extras column, so an R4D image read today reports skips and
   silently ignores extras. A reverse-leg task must add that before it can score the
   FULL side.
3. **R1 has no witness register at all.** Its evidence is the netlist plus the
   utilisation drop; there is no runtime counter that says "the FIFO is
   occupancy-indexed now".
4. **The sim gate is S1's, and S1 was scored on the +10 ppm leg.** Task 20 also reports
   `r4dr1_m10` at 0.48 % — R4B's number to the digit — so the composition is not a
   regression on the negative-SRO side, but 146 is the board that will exercise the
   FULL side for the first time on silicon, and `push_on_full` has never fired on any
   board.
5. **The injector commit recorded is Task 21's R4E cut** — correct as "the bytes that
   ran", but a reader should not infer R4E is in this image. It is not: the kit applied
   W1, R4D and R1 only, and the three markers are what the verification checked.
