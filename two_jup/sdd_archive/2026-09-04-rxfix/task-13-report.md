# Task 13 — W1+R4B for 148: kit, build, bank (Phase A) → flash + silicon judges (Phase B)

Branch `per-under-1pct-2026-07`. Ledger `Task 13:` lines in `progress.md`.
Labels: **[netlist]** for anything read out of the kit or the build, **[silicon]**
only for something a board did. Commits: `39dad6a` (kit + hook + WNS gate),
`d39f1bb` (ledger), `e186fa7` (reader + scorer + regmap), plus this report.

---

## 0. Headline  [silicon]

**The fix works on the board, and every one of the seven pre-registered predictions
holds.** Steering the ring's skip into End_Generator's structural guard window turns
the same ~394-per-10 s event from a frame-killing hole into a no-op.

| quantity | W1 image `2728dab3979a` (Task 10) | **W1+R4B `9f13705d9fb0` (this task)** |
|---|---|---|
| ring occupancy | 0 or 1 on all 48 reads | **8–10** (values seen 8, 9, 10) |
| `pop_on_empty` per 10 s | **394.0** | **0** on all 47 intervals |
| `r4b_skips` per 10 s | n/a | **391.0** — the holes became steered skips |
| `push_on_full` | 0 | 0 |
| checker gap events per 10 s (decoder pins) | **656.2** | **3.1** |
| checker garbage % / crc_fail % | 5.896 / 2.023 | **0.028 / 0.022** |
| **PER** (`capture_r3`, lost frames in the denominator) | **8.309 %** (72,738 / 875,375) | **0.224 %** (1,956 / 871,805), CP95UL 0.235 % |
| lag-32 autocorrelation (ALL-LOSS) | **+0.6130** | **+0.0182** |
| 25 ms comb | `COMB_LINE=present`, P = 25.3872 ms | **`COMB_LINE=absent`** |
| singles / doubles loss bins | 37,288 / 15,731 | **18 / 1** |

The event did not go away — it moved. `r4b_skips` runs at **391 per 10 s** against the
W1 image's `pop_on_empty` of **394 per 10 s**: the same drift, the same rate, now taken
as a deliberate skip inside a 13-slot window after `pcEnd` instead of as a suppressed
pop at the EMPTY edge. **That is the whole mechanism, measured on both sides of the
fix.**

**Image on the board at the end, from a readback:** 148 = `9f13705d9fb0`; 146 =
`3378861d30bd` (never touched). Rig back in service, hold released,
`sentinel-204437` + `sentinelkeeper-204437` running, on-board rollback
`/root/BOOT.BIN.2728dab3979a.bak` verified present.

---

## 1. Kit provenance  [netlist]

`RXFIX_VARIANTS='W1 R4B' two_jup/skidfix/jupiter_byte_rxfix_kit.sh 148`

| | |
|---|---|
| source kit | `jupiter_byte_seqbist_build` (the tree that produced the flashed `a1ff3c876d91`, and the tree W1 was built on) |
| kit | `jupiter_byte_rxfixr4b_build` |
| variants, in order | **W1 then R4B** (R4B's addr_decoder hunk wraps W1's own `data_read` assign; the other order fails loudly — injector header, tests 118/119) |
| injector commit | **`7eef225ab19ab4f44ec29e9ad0553ace807af7e2`** (Task 12b's R4B cut) |
| injector md5 | `25ea6237c1272d03f832d43971c56113` |
| read words | `0x214,0x218,0x21C,0x220,0x224,0x228,0x22C,0x230,**0x234**` |
| freeze | `fixctl` bit 4 (write 0x208) — the eight W1 words only; 0x234 is outside it by design |
| verdict | `RXFIX_KIT_VERIFY_OK` / `RXFIX_KIT_DONE` |

**No later R4B fix landed before the build started.** `7eef225` was `git log -1`
for `rxfix_inject.py` when the kit was cut and the working tree was clean against
it; the kit re-checks and records both facts (below).

### 1.1 What the kit script gained, and why each piece exists

`RXFIX_VARIANTS` (default `'W1'`) — **the W1 path is byte-for-byte the Task 9
path**; with no variable in the environment the script does what it did for the
flashed `2728dab3979a`.

* **Provenance asserted, not inferred.** The kit now refuses to run on an
  uncommitted `rxfix_inject.py` and records the commit **and the md5 of the bytes
  it executed**. This is the Task 9/10 wound fixed structurally: Task 9's kit
  recorded `injector_commit=b5c39a10` while the code it ran became `2c661e6`,
  because `git log -1 -- <file>` returns the last commit that *touched* the file,
  which is the wrong answer whenever the file is dirty — and Task 10 had to correct
  the flashed image's provenance after the fact.
* **Verification is per marker.** W1 and R4B patch the **same twelve files** (R4B's
  five core files are a subset of W1's eight RTL files; its witness chain is the
  other three plus the four IP wrappers), so one loop covers both: `RXFIX_W1` and
  `RXFIX_R4B` each present in **all three loose mirrors of all twelve files** and in
  **both** `TxRxCompo_ip_v1_0.zip` members, with `verify_zip` run once per marker.
  `RXFIX_R4` is a *prefix* of `RXFIX_R4B`; only the exact strings are ever grepped,
  and the R3/R3S/R4 mutual-exclusion is left to the injector's own `_has()`.
* **The silent-degradation gate.** `patch_ip_addr_decoder_r4b` and the witness-chain
  patchers return `'skipped'` where `RXFIX_W1` is absent, and `main()` still returns
  0 — it only prints `skipped=[…] r4b_witness=off`. A kit that had lost one W1
  mirror would therefore have built **cleanly with no ninth word**. The kit now
  fails unless the R4B run prints `r4b_witness=on` and prints no `skipped=`.
* **Decoder assertions.** W1's eight-word decode (`w1_hit`, `0x85..0x8C`) intact;
  the ninth word `assign r4b_hit = (address_select_level1 == 8'h8D);` present and
  ahead of W1's mux in `data_read`; R4B's steered pop
  `r4b_pop_nom & ( ~r4b_skip_en)` and its witness
  `assign r4bWit = {r4b_locked, r4b_skips, r4b_opens};` present in the kit's own
  `TxRxCompo_ip_src_Rate_Handle.v`. The inherited Task 9 assertions (0x20C decode,
  0x208 write decode, SEQ-BIST BD patch, `rx_seq_checker`, `cnt_mux32`,
  `IMPL_STRATEGY`, `TXFIX_ROUTED_TIMING_FAIL`, `TXFIX_VARIANT`/`SEQBIST_VARIANT`
  byte-identical) all still run and all passed.

### 1.2 Pre-build checks  [netlist]

| check | result |
|---|---|
| `test_rxfix_inject.py` (incl. **test_119**, the named Task 13 deliverable: W1+R4B on a kit-shaped tree with `verify_zip` for both) | **123/123 pass** |
| `test_rxfix_rig_scripts.py` | **35/35 pass** (31 pre-existing + 4 new R4B reader tests) |
| `verilator --lint-only --top-module TxRxCompo_ip` on the patched kit netlist | **0 errors**, 40 warnings, **0 on any `r4b_` or `w1_` net** (all 40 are the pre-existing `FrameStatProbe` latch/width family) |
| injector run | `RXFIX_INJECT variant=W1 … zips_verified=2` and `variant=R4B loose=36 missing=[] zips=2 zips_verified=2 **r4b_witness=on**` |

---

## 2. Build  [netlist]

`build_txfix.sh` with `IMPL_STRATEGY=explore`, launched from a **local**
`systemd-run --user` step (`t13build`) which ssh-launches the **remote**
`systemd-run --user` unit — never a harness background job.

| | |
|---|---|
| host | hdl-dev-2 (8 cores / 61 GB; 55 GB free at preflight, floor 25 GB; no concurrent build unit) |
| remote unit | `txfix-build-rxfixr4b_build-1788558385` |
| remote tree | `/home/tcollins/qpsk-builds/jupiter_byte_rxfixr4b_build` |
| started | 2026-09-04 17:46 |
| jobs / strategy | 6 / `explore` (ExtraTimingOpt place, AggressiveExplore route + phys_opt pre/post route) |
| log | `$REMOTE_DIR/build_txfix_vivado.log` |

**Exited 20:02. GATE PASSED.**

| | value | W1 `2728dab3979a` | SEQ-BIST `a1ff3c876d91` |
|---|---|---|---|
| elapsed | **02:16** (17:46 → 20:02) | 01:55:51 | — |
| **modem-clock intra-clock routed WNS (THE GATE)** | **+0.437 ns**, TNS 0.000, **0 failing endpoints of 184,865** | +0.169 | +0.227 |
| overall routed WNS (`TXFIX_ROUTED_WNS` — the vendor IDELAYCTRL path, not a modem path) | +0.171520, TNS 0.000, WHS +0.010, THS 0.000 | +0.071224 | +0.112123 |
| Vivado's own verdict | `[Route 35-61] The design met the timing requirement.` | same | same |
| post-synth `TIMING_GATE_WNS modem_dut` | 1.544 (identical to both predecessors — R4B adds no logic depth) | 1.544 | 1.544 |
| post-place modem-clock WNS (new diagnostic) | +0.537 | not recorded | not recorded |
| BOOT.BIN md5 | **`9f13705d9fb0ea6ae6af3c4c1ab5e95d`** | | |
| banked as | **`boot_known_good/BOOT.BIN.148.rxfixr4b.9f13705d9fb0`**, 7,203,552 B, md5 **re-verified after transfer** against the remote `BYTE_BUILD_DONE` value | | |

**The margin went UP, not down, and that should not be over-read.** W1+R4B closes the
modem clock at **0.437 ns** against W1's 0.169 — 268 ps *more* headroom while adding
registered steering logic. That is the same mechanism RXFIX_W1_TIMING §4.2 identified
working in the other direction: these numbers are **placement/congestion-mediated, not
logic-depth-mediated**, and the post-synthesis `modem_dut` WNS is identical at 1.544 ns
across all three builds, which is the direct statement that no logic depth was added.
The honest reading is that this build placed better, not that R4B is faster than W1;
the useful consequence is only that the gate passed with room. As with W1, **no `r4b_`
or `w1_` net appears anywhere in the routed timing summary's ten-worst paths** (grep
count 0 over the whole report).

The **post-place hook worked on its first outing**: `RXFIX_POSTPLACE_HOOK_SET` in the
build log, `RXFIX_POSTPLACE_WNS wns=0.537`, and both
`system_top_timing_summary_postplace.rpt` (5.0 MB) and `system_top_timing_postplace.rpt`
written into `impl_1/`. Routing itself went negative mid-flight and recovered
(intermediate `[Route 35-416]` WNS ran −0.398, −0.192, then +0.171), exactly the
behaviour RXFIX_W1_TIMING §4.3 warns against gating on.

### 2.1 Two things were added to the build before it ran

**(a) A post-place timing report** (`two_jup/rxfix/add_postplace_report.sh`), which
Task 9b asked for and which no previous build had: *"the iteration-1 endpoints are
not recoverable from any artefact on disk and no post-place checkpoint was
written."* The flow is `launch_runs impl_1 -to_step write_bitstream`, i.e. a project
run in a child process, so there is no point in the parent script where the placed
design is in memory and an inline `report_timing_summary` is unreachable. The
project-run equivalent is `STEPS.PLACE_DESIGN.TCL.POST`, which Vivado sources inside
the run with the design open. The hook body is **wholly inside `catch`** and cannot
fail the implementation; the installer re-checks that the kit's own gates
(`IMPL_STRATEGY`, `TXFIX_ROUTED_TIMING_FAIL`, `rx_seq_checker`, `cnt_mux32`,
`SEQBIST_PATCH_V1`) still grep after the edit, and is idempotent.

**(b) The gate parser, calibrated before the artefact it judges existed**
(`two_jup/rxfix/modem_wns.py`). `TXFIX_ROUTED_WNS` in the build log is
`STATS.WNS`, which on this board is a **zero-logic-level Recovery check on the
ADRV9001 IDELAYCTRL reset** in the `**async_default**` group — it moves ±0.04 ns
with placement and no modem edit can influence it (RXFIX_W1_TIMING §0). The gate is
the `axi_adrv9001_adc_1_clk` **intra-clock** WNS. Run against the two banked builds'
own routed reports before this build existed:

```
SEQ-BIST a1ff3c876d91 : MODEM_CLK_WNS wns=0.227 tns=0.0 failing=0 total=183608
RXFIX_W1 2728dab3979a : MODEM_CLK_WNS wns=0.169 tns=0.0 failing=0 total=184782
```

— exactly the two documented values, so the gate is not being read for the first
time on the artefact it decides. **W1+R4B inherits 0.169 ns, not 0.227**, and adds
steering logic to the same receiver region on a part at 100.00 % CLB occupancy; if
the modem-clock WNS comes back negative the pre-scoped lever is the address decoder
(fold W1's eight words into the existing `case (address_select_level1)`, removing
the +27 F7 muxes of the `w1_reg[w1_idx]` 8:1 array read, the tail 2:1 mux on
`data_read` and the `- 3'd5` index subtract, at no cost to the register map).

---

## 3. Instrument changes for the ninth word  [netlist]

`W1_REGMAP.md` §5 already described `0x234` (Task 12b wrote it); Task 13 built it,
made the reader and scorer handle it, and corrected one figure in it.

**Bit layout, taken from the RTL and not from the brief.** The Task 12b brief asks
for `{r4b_prefilled, r4b_armed, r4b_skips[15:0], r4b_window_opens[15:0]}` = 34 bits,
which does not fit a 32-bit word; the controller's 17:07 ruling deleted the pre-fill
entirely and in this design `armed` **is** `locked`. The word actually built is

```verilog
assign r4bWit = {r4b_locked, r4b_skips, r4b_opens};   // 1 + 16 + 15 = 32
```

so bit 31 = `r4b_locked`, bits 30:15 = `r4b_skips`, bits 14:0 = `r4b_window_opens`.

**The freeze trap, and how it is avoided.** `0x234` is deliberately **not** behind
`fixctl[4]` (one word, so a single AXI read is already coherent), and
`r4b_window_opens` advances once per deframed packet — i.e. at the frame rate.
`w1_read.sh` reports `freeze_effective` true iff the two sweeps match, and Task 9's
rule is that a `freeze_effective:false` reading **must be discarded**. Folding the
ninth word into that test would have marked *every* reading of a live board
incoherent and thrown away the whole air leg. So: `freeze_effective` stays over the
**eight frozen words**; the ninth is read in both sweeps and reported separately as
`words.r4bWit` / `r4b_wit2` / `r4b_moved`, and **its movement inside the freeze
window is the liveness positive control**, not a fault. Two new tests pin both
halves. `R4B=1` is opt-in; the default path's register sequence on the wire is
unchanged and still pinned by the pre-existing test.

**Wrap horizon corrected before the first read.** §5 quoted `r4b_window_opens` as
wrapping in ≈136 s "at 240 f/s". **This rig does not run at 240 f/s**: Task 10's own
air leg measured 0x104 at ~12,600 per 10 s = **~1,260 f/s**, so the horizon is
`2^15/1260` ≈ **26 s** — the fastest-wrapping quantity in the instrument (census
279 s, edge counters 1,659 s, skips 1,663 s). At the mandated 10 s cadence a delta
is unambiguous with 2.6× to spare and one dropped read (20 s) still is; **two
consecutive dropped reads alias silently**. `w1_score.py` checks every interval
against it and names any that reaches it. `r4b_opens` is 15 bits, so its deltas use
mod 2^15 — `M16` would have corrupted every opens delta across a wrap.

**Regression.** Task 10's own air readings re-score identically after all edits:
P1 HOLDS, occ ∈ {0,1}, `pop_on_empty` 394.0 per 10 s, F2 FIRES, and no R4B section
appears (the readings have no ninth word).

---

## 4. Phase B — flash, controls, air leg  [armed, not started]

**Controller GO received (ledgered) while the build was running.** The R4B sim gate
is accepted for the 148 image: **15/17 pass**; the two failures are (a) the **+10 ppm
positive-SRO acquisition-dip skips on a full ring — a regression that makes this image
148-ONLY** — and (b) a CFO baseline band in the harmless direction. Phase B proceeds
as briefed once the build passes the modem-clock WNS gate and the image is banked.
**A STOP may still arrive before the flash** (an adversarial verification of the gate
is running in parallel); if it does, no flash happens.

**148-ONLY is structurally enforced, not just remembered:** the kit script refuses
board 146 outright (`RXFIX_KIT_REFUSE_146`), so no 146 kit of this variant can be cut,
and the flash names `FLASH_MD5`/`FLASH_BAK` for 148 with rollback `2728dab3979a`.
The reverse leg — the one that would settle the campaign's open sign question — is
therefore **still** blocked, and this image must not be the way it gets unblocked.

Planned exactly as Task 10 ran it
(keeper hold first; `txfix_flash_go.sh FLASH_MD5=<r4b md5> FLASH_BAK=2728dab3979a
FLASH_TAG=rxfixr4b`; two-pass gate; auto-rollback; one re-arm allowed; never
interrupted mid-flash/arm; rollback = the W1 image `2728dab3979a`).

### 4.1 The pre-registration, quoted verbatim from the brief

> PRE-REGISTERED [silicon] (from Task 10's numbers): occupancy 8–10 on every
> in-window read; pop_on_empty delta 0 (≤ 3 per 10 s); r4b_skips ≈ 394 ± 60 per
> 10 s (the holes become skips); push_on_full 0; checker gap events per 10 s < 100
> (was 656); PER ≤ 3 % (was 8.309 %; hole-aligned share ≈ 6.3 pp); lag-32 < 0.1
> (was +0.613); no 25 ms comb.

> FALSIFIERS: (F-A) r4b_skips ≈ 394 but PER unchanged and lag-32 comb present → the
> skip position does not matter on silicon (sim/silicon divergence; dump the checker
> interval series and stop); (F-B) r4b_skips ≈ 0 and pop_on_empty ≈ 394 → steering
> never engaged on silicon (lock/window logic; read r4b_armed/window_opens and
> stop); (F-C) PER improves but a NEW loss class appears (e.g. long gaps, re-lock
> events) → report the class with the checker's interval histogram; do not iterate
> on the board.

Verdicts: **all seven hold — see §4.8.** The register-side rows (occupancy, pop_on_empty,
r4b_skips, push_on_full, and the register half of F-B) are scored by
`w1_score.py --mode air`, which now prints them as the *operative* verdicts and
states that Task 10's P1 is **expected to fail** on this image because lifting the
ring off the EMPTY edge is what the fix does. The host-side rows (gap events, PER
with lost frames in the denominator, lag-32, comb period) come from the leg's own
artefacts.

### 4.2 Fail-closed pairing of R4B with the image gate

`w1leg_go.sh`'s `EXP` defaults to **`2728dab3979a` — the W1 image**. A leg run with
`R4B=1` against that default would have **passed** the image gate with the W1-only
image on the board, read `const_0` at 0x234, and scored the Task 13 pre-registration
against silicon that has no R4B in it: T13-P1 would "fail" and F-B would "fire" on a
leg that never contained the fix. `R4B=1` now **requires an explicit `EXP`** and
refuses the W1 md5 outright (`W1LEG_REFUSED`), with a test covering both refusals and
the accepted case.

### 4.3 Steps still owed on the build's exit (recorded so they are not skipped)

1. `RXFIX_POSTPLACE_HOOK_SET` must appear in `build_txfix_vivado.log` and
   `system_top_timing_summary_postplace.rpt` must exist in `impl_1/` — the
   `set_property` line being present in the tcl is not proof the child run armed it.
   A missing `RXFIX_POSTPLACE_WNS` line is a hook diagnostic, **not** a timing result.
2. `modem_wns.py` on the new routed report → record the **modem-clock intra-clock
   WNS** (the gate, with its `failing=` count as the independent second read) **and**
   `TXFIX_ROUTED_WNS`.
3. Bank `boot_known_good/BOOT.BIN.148.rxfixr4b.<md5>` with the md5 **re-computed
   locally after transfer** and compared against the remote `BYTE_BUILD_DONE md5=`
   before the banked name is written — a banked name that disagrees with its contents
   would silently mis-target `FLASH_MD5`.

### 4.4 G14: the post-arm acquisition window is reported separately

The controller's addition: right after each arm the acquisition dip can fire a few
skips **while the ring is momentarily full**, costing ~1 frame each. Acquisition-phase
`push_on_full` and any losses in the first ~30 frames after arm are reported apart from
the steady-state window.

**The register-side separation is exact and needed no new instrument.** The arm's
`0x000` soft reset zeroes the edge counters — measured on silicon, not assumed: Task 10
§3.1 saw `pop_on_empty` read 44, then **10** after arm #1, then **44** after arm #2,
each value being that acquisition's own transient. So the **first reading's cumulative**
`push_on_full` / `pop_on_empty` / `r4b_skips` **is** the post-arm transient, while every
steady-state verdict in this task is built from deltas *between* readings, which cannot
contain it. A delta could never have resolved it anyway: ~30 frames at ~1,250 f/s is
**24 ms**, far inside one 10 s read. `w1_score.py` now prints an acquisition-window
section saying exactly this, and `--acq-intervals N` can additionally exclude the first
N intervals from the verdicts and report them there instead (the CSV always keeps every
interval).

A non-zero `push_on_full` in that window would also be **the first silicon exercise of
that counter at all** (Task 9 concern 2, Task 10 concern 1: it read 0 on every reading
of every set), so it is evidence about the counter as well as about the dip — but on an
*acquisition* transient, not on the FULL-edge question a reverse leg would answer.

The host-side half — losses in the first ~30 frames after arm — comes from the leg's own
frame series and is reported separately from the steady-state PER.

### 4.5 Step 1 — the flash  [silicon]

Keeper hold taken first (`DRY=0 keeper_hold.sh hold`): `SENTINEL_STOP` and `RIG_LOCK`
both **created by this task** (marker `SENTINEL RIGLOCK`), `sentinel-172940` +
`sentinelkeeper-172940` stopped, `lock_watchdog` killed on both boards. Unit
`flash148-r4b` via `launch_rig_unit.sh`; never interrupted.

```
20:05:19  148 current image: 2728dab3979a (expect 2728dab3979a)
20:05:23  FLASHED 9f13705d9fb0
20:06:32  booted image: 9f13705d9fb0 (expect 9f13705d9fb0)
          gate 1: ARM_OK profile=lvds_61p44_fdd_jupiter fps=1248 capTAP=0xBCF94856
          gate 2: ARM_OK profile=lvds_61p44_fdd_jupiter fps=1248 capTAP=0xBCF94856
20:09:33  GATE_PASS x2
20:09:36  FLASH_DDRCAP2_OK 9f13705d9fb0
```

Tier-2 witness: 524,288 records, 43 demod marks, `toff` mode 12314, distinct 1 —
identical in shape to the W1 flash. `postflash_check.sh`: **POSTFLASH_OK**,
`mux_select=distinct responds_to_traffic=yes` — the SEQ-BIST checker, `cnt_mux32` and
the 0x9D4x GPIOs all survived the W1+R4B build. No rollback was needed or performed.

**Operator error worth recording:** the first `postflash_check.sh` invocation was run
with `SINK=tgenrx`, which arms GPIO bit 0 — and the script's step [3] requires bit 0
clear, so it correctly reported `PF_FAIL_TGENMODE` and disarmed the sink on exit. That
is my mistake, not a board or image fault; the immediate re-run with the default
`SINK=none` gave `POSTFLASH_OK`. The only lasting effect was one extra arm/disarm cycle
of the tgen sink before the control leg.

### 4.6 Step 2 — the control table  [silicon]

Run `two_jup/comb/runs/20260904_201203_w1_ctrl` (banked as
`t13_evidence/ctrl_control_table.txt`). 148 in mode-1 digital loopback, `SINK=tgenrx`,
three reads → one 10 s freeze-hold read → **exactly one** re-arm → three more reads.

| tap | verdict | control and evidence |
|---|---|---|
| freeze path (0x208 bit 4) | **PASS** | freeze **held 10 s**; all eight shadowed words identical across the two sweeps |
| `cSS` `cRH` `cCFC` `cCS` `cPD` | **PASS** | each advances ~1.70e8 / 10 s and the five are equal within the measured ±4 band |
| `cPC` | **PASS** | advances, short by the designed 13/frame guard drop |
| `witA` occupancy | **PASS** | 8–9 |
| `witA` pointers | **PASS** | 5 distinct (push,pop) pairs, advancing mod 32 |
| `push_on_full` | **NOT EXERCISED** | 0 throughout (unchanged from Task 10; a forward/loopback leg cannot reach the FULL edge) |
| edge counters NULL | **PASS** | `pop_on_empty` and `push_on_full` deltas both 0 on every steady interval |
| **`r4b_locked` / `r4b_armed`** | **PASS** | 1 on 6/6 readings |
| **`r4b_window_opens`** | **PASS** | 13,824 / 13,821 / 13,835 / 13,859 per 10 s = the frame rate. **This is the liveness control** that separates "steering idle because the ring is healthy" from "steering dead" |
| **`r4b_skips`** | **PASS** | cumulative **8** on every reading, per-interval delta **0** — exactly the sim's self-centring picture: ~8 skips after lock ratchet the ring 1→9, then `occ ≤ 8` goes false and the skipping stops |
| **occupancy after lock** | **PASS** | 8–9 (the W1 image sat at 0–1) |
| **0x234 outside the freeze shadow** | **PASS** | the ninth word advanced between the two frozen sweeps on 6/6 readings |
| **stuck-at sweep (nine words)** | **PASS** | all nine differ between at least two reads |

**One row's automated label is wrong, and the correction is evidence-backed.**
`pop_on_empty` read **44 before and 44 after** the re-arm, so `w1_ctl.py`'s
arm-transient liveness test (which needs a jump across the re-arm) did not fire and it
printed `FAIL (DEAD — air leg cannot use it)`. **The correct label is NOT EXERCISED**,
the same class as `push_on_full`, and the reason is a netlist fact rather than an
opinion:

* diffing the two kits, R4B's **only** change to
  `TxRxCompo_ip_src_Validate_Input_Push_Pop_block.v` is an added `r4bOcc` output
  assigned from the already-existing `Delay_out1`; `pop_on_empty_FIFO` (:145) and W1's
  tap `w1PopEmpty` (:168) are untouched;
* in `TxRxCompo_ip_src_Frequency_and_Time_Synchronizer.v` **no changed line mentions the
  census or the edge counters** — R4B adds only the `pcEnd` routing and the witness
  pass-through.

So this is byte-for-byte the same instrument, read through the same address by the same
script, that counted **394 per 10 s** on the air two hours earlier and moved **34**
across an arm in Task 10. Its silence now is a property of the ring, not of the counter.
What it means for the leg, stated rather than glossed: **T13-P2 is consistent with the
fix but is not decisive on its own**, and the decisive rows are occupancy (`witA`) and
`r4b_skips` (0x234) — different fields, different registers, both positive.

**Note on the brief's wording:** "stuck-at check on all nine words" is implemented as a
*movement* check on the ninth (it must differ between readings), not a freeze-hold
check — see §3.

### 4.7 Step 3 — the forward air leg  [silicon]

Run `two_jup/comb/runs/20260904_201814_w1_air`. `w1leg_go.sh MODE=air R4B=1
EXP=9f13705d9fb0 DUR=600 RATE_GATE=900 FIXCTL_BASE=0x0`. **Leg gate PASSED**:
`capture_r3_exit=0`, `deliver_rate_pre=1038 deliver_rate_post=1038
deliver_rate_gate_pass=1`, `watchdog_relaunch_rx=0 watchdog_relaunch_peer=0`,
`wedge_verdict=healthy crc=100%`. Reader window 480 s, **48 readings, 47 intervals,
spacing 10.0 s**. No re-run was needed.

#### The table (cumulative AND delta, per read) — full CSV in `t13_evidence/air_w1_reads.csv`

| # | t | occ | poe cum/Δ | pof cum/Δ | 0x104 Δ | r4b_locked | r4b_skips cum | **r4b_skips Δ** | r4b_opens cum | r4b_opens Δ |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 20:20:33 | 9 | 53 / — | 0 / — | — | 1 | 1,668 | — | 20,897 | — |
| 2 | 20:20:43 | 10 | 53 / **0** | 0 / 0 | 12,680 | 1 | 2,064 | **396** | 810 | 12,681 |
| 3 | 20:20:53 | 8 | 53 / **0** | 0 / 0 | 12,720 | 1 | 2,461 | **397** | 13,529 | 12,719 |
| 24 | 20:24:23 | 9 | 53 / **0** | 0 / 0 | 12,647 | 1 | 10,660 | **397** | 12,859 | 12,650 |
| 46 | 20:28:03 | 9 | 53 / **0** | 0 / 0 | 12,603 | 1 | 19,257 | **397** | 23,990 | 12,597 |
| 47 | 20:28:13 | 9 | 53 / **0** | 0 / 0 | 12,585 | 1 | 19,653 | **396** | 3,802 | 12,580 |

Over 47 intervals: **occ ∈ {8, 9, 10}**; `pop_on_empty` Δ **0 on every interval**;
`push_on_full` Δ **0 on every interval**; `r4b_skips` Δ mean **391.0** (min 355, max
398 — the 355–360 rows are the intervals where the board delivered ~11,4xx frames
instead of ~12,6xx, so the *rate* is unchanged); `r4b_opens` Δ ≈ 12,600 per 10 s = the
frame rate; `r4b_locked` = 1 on all 48.

**Wrap accounting.** Read spacing min = max = 10.0 s. `r4b_opens` is 15-bit and wrapped
**17.86 times** over the window (total 585,279) — its 26 s horizon is the tightest in
the instrument and no interval came near it; `r4b_skips` 0.28 × 2¹⁶; census counters
~1.7 × 2³² each. Every figure is accumulated from consecutive 10 s reads, never
leg-end minus leg-start.

**Checker at the decoder pins** (48 samples, 47 intervals): `chk_frames` 12,452 per
10 s, **`chk_gap_events` 3.1 per 10 s** (gap1 0.3 / gap2 2.0 / gap3plus 0.7),
garbage **0.028 %**, crc_fail **0.022 %**. Task 10's W1 leg: 656.2 gap events per 10 s,
5.896 % garbage, 2.023 % crc_fail.

**Host-side PER** (`accept_analyze.py`, lost frames in the denominator, live window
715/721 s, one wedge, truncated as Task 10's was):

```
PER=0.224% (1956/871805)  CP95UL=0.235%  lag33=-0.000
bins={'1': 18, '2': 1, '3-4': 33, '5-20': 161, '21-100': 0, '>100': 0}
GATE (<1% at CP95 upper limit, live-link): PASS
```

`comb_autocorr.py --live-window`: **lag32 = +0.0182**, lag33 +0.0203, lag64 +0.0029
(singles-only: 18 events, lag32 = −0.0000). `comb_period_ms.py`: band
R = 0.1851 against a random-event null of 0.2499 → **`COMB_LINE=absent`**.

#### Is the 8.309 % → 0.224 % comparison like-for-like? Yes, and here is the arithmetic

The meta lines invite a fair objection: this leg's `deliver_rate` gated at **1038 f/s**
while Task 10's gated at **1900 f/s**, so a reader could suspect the two PERs were
measured under different offered loads. They were not. `deliver_rate` is the health
probe's host-side delivery measure, not the frame rate through the modem, and the two
instruments that *do* measure the modem's frame rate agree across the two legs:

| | Task 10 (W1) | this leg (R4B) |
|---|---|---|
| checker `chk_frames` per 10 s (decoder pins) | 12,419 | 12,452 |
| 0x104 delta per 10 s (`d_frames`) | ~12,6xx | ~12,6xx |
| **PER denominator ÷ live seconds** | 875,375 / 718 s = **1,219.2 slots/s** | 871,805 / 715 s = **1,219.3 slots/s** |

The PER denominators per second agree to **1.0001**. The offered load was the same to
four significant figures, both legs lost one wedge from a ~720 s window, and both PERs
come from the same tool and invocation — so 8.309 % and 0.224 % are directly
comparable, and `deliver_rate` is not the quantity to compare them on.

### 4.8 Verdicts — each prediction quoted verbatim

> occupancy 8–10 on every in-window read

**T13-P1 HOLDS.** occ ∈ {8, 9, 10} on all 48 readings.

> pop_on_empty delta 0 (≤ 3 per 10 s)

**T13-P2 HOLDS** — delta 0 on all 47 intervals. Qualified by §4.6: this counter's own
liveness control did not fire in this session, so the row is *consistent with* the fix
rather than independently decisive.

> r4b_skips ≈ 394 ± 60 per 10 s (the holes become skips)

**T13-P3 HOLDS.** Mean **391.0** per 10 s against the W1 image's `pop_on_empty` 394.0
per 10 s. This is the single most informative number in the task: the drift event is
conserved and only its *position* changed.

> push_on_full 0

**T13-P4 HOLDS.** 0 on every interval, and 0 cumulative since the arm.

> checker gap events per 10 s < 100 (was 656)

**T13-P5 HOLDS.** **3.1** per 10 s — 210× down.

> PER ≤ 3 % (was 8.309 %; hole-aligned share ≈ 6.3 pp)

**T13-P6 HOLDS, and by more than predicted.** **0.224 %** (CP95UL 0.235 %). The
prediction reasoned 8.309 − ~6.3 pp ≈ 2 %; the measured residual is **an order of
magnitude below that**, i.e. the comb was carrying substantially more than its
hole-aligned share, and what remains is close to the 0.058 % loopback floor.

> lag-32 < 0.1 (was +0.613); no 25 ms comb

**T13-P7 HOLDS, both clauses.** lag32 **+0.0182**; `COMB_LINE=absent`, with the 25–27 ms
band's R below its own random-event null.

**Falsifiers.**

> (F-A) r4b_skips ≈ 394 but PER unchanged and lag-32 comb present → the skip position
> does not matter on silicon (sim/silicon divergence; dump the checker interval series
> and stop)

**Does not fire.** `r4b_skips` is at the predicted rate *and* PER fell 37×, lag-32
collapsed and the comb is absent. The skip position is exactly what matters.

> (F-B) r4b_skips ≈ 0 and pop_on_empty ≈ 394 → steering never engaged on silicon
> (lock/window logic; read r4b_armed/window_opens and stop)

**Does not fire.** skips 391/10 s, `pop_on_empty` 0, `r4b_locked` = 1, `r4b_window_opens`
advancing at the frame rate on every interval.

> (F-C) PER improves but a NEW loss class appears (e.g. long gaps, re-lock events) →
> report the class with the checker's interval histogram; do not iterate on the board

**Does not fire — every bin went down**, which is the only honest way to test "new":

| burst bin | Task 10 (W1) | this leg (R4B) |
|---|---|---|
| 1 (singles) | 37,288 | **18** |
| 2 | 15,731 | **1** |
| 3–4 | 500 | **33** |
| 5–20 | 220 | **161** |
| 21–100 | 1 | **0** |

The residual 1,956 lost frames are now dominated by the 5–20 bin (161 events), i.e. the
pre-existing burst/RF class the campaign already knew about — and even that is lower
than before. One wedge occurred during the capture, as in Task 10's leg.

### 4.9 G14 — the acquisition window  [silicon]

**No acquisition-dip regression appeared on this leg, and both halves say so.**

* **Register side (covers the whole post-arm period, including before the capture
  started):** the first reading's counters, cumulative since the arm's `0x000` soft
  reset, are `push_on_full` = **0**, `pop_on_empty` = 53, `r4b_skips` = 1,668,
  `r4b_locked` = 1, occupancy 9. **`push_on_full` = 0 means the acquisition dip never
  reached the FULL edge**, which is the precondition for G14's mechanism.
* **Host side:** losses in the first 30 good-frame intervals = **0**; first 1,000
  intervals = **0**; 2 lost slots in the first 5 s and none added out to 30 s.

That is consistent with the sim finding being a **positive-SRO** phenomenon: this
forward leg's receiver sits on the negative-SRO side, where the ring drains rather than
fills. It is the +10 ppm side that regressed in the gate, and that is exactly why the
image is 148-only. **`push_on_full` therefore remains unexercised on silicon** (Task 9
concern 2 / Task 10 concern 1) — a reverse leg with W1 on 146 is still the only way to
close it.

### 4.10 Step 4 — hand-back  [silicon]

* Plain daemons restored with `bringup_r2r3.sh r3` via `restore-t13b`: **ARM GATE PASS
  on try 1** — 148 rx **1246 f/s**, 146 rx **1247 f/s**, daemons and watchdogs up on
  both boards, `r3 BRING-UP COMPLETE`. No re-run was needed. (Task 10's first restore
  failed its gate 6/6 and needed its one re-run; this one passed first time, which is a
  small additional data point against an image effect.)
* **A launcher mistake that cost nothing, recorded because it looks like a failed
  restore in the unit list:** the first attempt, `launch_rig_unit.sh restore-t13
  bringup_r2r3.sh r3`, failed instantly — `launch_rig_unit.sh`'s signature is
  `<unit> <script> [env=val …]`, so `r3` became a `--setenv`, not an argument, and the
  bring-up died on its own usage check **before touching either board**. No arm was
  started and the rails' one-re-run allowance was not consumed. Fixed with
  `two_jup/rxfix/restore_r3_go.sh`, the same wrapper pattern `txfix_flash_go.sh` uses
  for the same reason.
* Daemon binaries unchanged from Task 10: 148 `1f834433` with the NAK-stat
  instrumentation present in the binary, 146 `3349df8f` without it (its normal state);
  one `qpsk_tun` running on each board. *(Task 10 reported this as "nakstat=4"; I report
  what I actually measured — the instrumentation string is present — rather than
  reproduce a number whose derivation I could not reconstruct.)*
* Hold released (`keeper_hold.sh release` removed only the two files this task created);
  keeper relaunched and the sentinel came back as **`sentinel-204437` +
  `sentinelkeeper-204437`**.
* **Images from a readback:** 148 = **`9f13705d9fb0`**, 146 = **`3378861d30bd`**.
  On-board rollback `/root/BOOT.BIN.2728dab3979a.bak` verified to be `2728dab3979a`, and
  `boot_known_good/BOOT.BIN.148.rxfixw1.2728dab3979a` remains banked in-repo. **The R4B
  image stays on 148**: the leg passed its gate and the link is up.

---

## 4.11 What this means for the campaign

The Task 10 finding was that the ring's empty-edge event and the PER comb are the same
event, and that the event **deletes nothing** — so the frames die from *where the skipped
time slot lands*, not from a missing symbol. Task 13 is the controlled experiment on that
claim: hold the event rate fixed (394 → 391 per 10 s) and change only **where** the skip
lands (EMPTY edge → the 13 slots after `pcEnd`). The comb disappears, the checker's gap
events fall 210×, and PER falls from 8.309 % to 0.224 %.

That closes the loop the campaign has been chasing since the 6 pp steady comb was first
decomposed: **the forward leg's dominant loss class was the position of the SRO skip, and
it is now fixed in fabric.** What remains on the forward leg — 0.224 %, burst-shaped, one
wedge in 12 minutes — is the non-comb residual the 08-29 decomposition attributed to RF
margin, and it is now the whole story rather than a footnote.

Two things this does **not** settle, stated so they are not quietly assumed:

1. **The reverse leg is untouched and the sign question is still open.** 146 still runs
   `3378861d30bd`, has no W1, and this image must never go on it (§4, the +10 ppm
   regression). RXFIX_STATE §2(a) — the forward leg losing *more* than the reverse — was
   the campaign's standing anomaly; the forward leg has now dropped below the reverse
   leg's 1.39 %, which inverts the comparison but does not explain the original asymmetry.
2. **`push_on_full` has still never fired**, in sim or on silicon, so the FULL-edge half
   of the mechanism remains uninstrumented in practice.

## 5. Concerns

1. **`r4b_window_opens` wraps in ~26 s on this rig**, not the ~136 s the register
   map claimed. 10 s reads are now load-bearing rather than merely tidy, and two
   consecutive dropped readings alias the counter silently. The scorer flags it;
   nothing else can.
2. **The modem-clock margin is the real risk of this build.** W1+R4B starts from
   0.169 ns (not the SEQ-BIST 0.227) and adds registered steering logic to the same
   receiver region on a part at 100.00 % CLB occupancy. The lever is pre-scoped but
   costs a second ~2 h build.
3. **The ninth word's AXI decode is not exercised in simulation** — the Verilator
   lineage has no `TxRxCompo_ip_*` wrapper, exactly as for W1's eight (Task 9
   concern 3). The first real proof that `0x234` returns `r4bWit` will be the first
   board read, and `const_0` there is indistinguishable from "no R4B in the image"
   without the kit/verify evidence in §1.
4. **`push_on_full` remains unexercised on silicon and in sim** (Task 9 concern 2,
   Task 10 concern 1). R4B does nothing on the FULL side, so this task cannot close
   it either.
5. **The R4B sim gate had not returned when Phase A's build was launched.** That is
   the brief's design — the build is cheap to discard and the flash is what waits —
   and the gate was subsequently accepted 15/17 before the flash, so nothing was
   built on a faulted cut. The kit records the exact injector commit and md5.
6. **`pop_on_empty`'s Step-2 control did not fire this session** (§4.6). The netlist
   identity argument is strong and checkable, but it is an *argument*, not a measurement:
   nothing in this task independently proved that counter still counts. The next leg
   that reaches an EMPTY edge — e.g. R4B deliberately disarmed, or a reverse leg — would
   settle it in one reading.
7. **This image is 148-ONLY** and nothing on the board enforces that. The kit script
   refuses a 146 kit, but a human with `flash_146_*.sh` and the banked BOOT.BIN could
   still put it on 146, where the +10 ppm positive-SRO acquisition-dip regression lives.
   The banked filename says `148` and this report says it twice; that is the whole
   guard.
8. **The leg's live window was truncated by one wedge** (715/721 s), as Task 10's was
   (718/723 s). The comparison is therefore like-for-like, but neither leg is a pristine
   link, and the residual 5–20 burst class is exactly what a wedge contributes.
9. **PER came in 10× better than the prediction** (0.224 % against "≤ 3 %, expect ~2 %").
   Under this campaign's own rule — when a metric looks suspiciously good, check the
   measurement before the DSP — I re-ran nothing and changed no scorer: the number comes
   from `accept_analyze.py` with lost frames in the denominator, the same tool and the
   same invocation Task 10 used for 8.309 %, on a capture whose gate passed at 1038 f/s
   pre and post. The corroboration that it is real and not a measurement artefact is
   that **three independent instruments moved together**: the fabric checker at the
   decoder pins (656 → 3.1 gap events per 10 s), the host PER (8.309 → 0.224 %), and the
   register witnesses (occupancy 0/1 → 9, `pop_on_empty` 394 → 0). A measurement fault
   would have had to move all three consistently.


---

## 6. Evidence

Banked under `two_jup/sdd_archive/2026-09-04-rxfix/t13_evidence/`: the air leg's 48
readings (`air_readings.jsonl`), its per-reading CSV (`air_w1_reads.csv`), the scored
verdict (`air_verdict.txt`), the checker series (`air_checker.jsonl`), both run metas,
the Step-2 control table (`ctrl_control_table.txt`) and the first nine-word board read
(`first_read_readings.jsonl`). The flash chain's own log is tracked at its original
path, `two_jup/skidfix/txfix_flash_20260904_200518.log` (the evidence directory's copy
is not, because `*.log` is git-ignored there). The raw captures — `frames.bin` (43 MB),
`txlog.bin`, `failhdr.bin` and their peer copies — stay on local disk under
`two_jup/comb/runs/20260904_201814_w1_air/cap/` per the repo's precommit rule; every
number in §4.7 is reproducible from them with the commands quoted there.
