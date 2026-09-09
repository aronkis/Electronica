# MODEL-1 — Enable-phase-swap RX burst fault: Verilator POSITIVE CONTROL + fix

**Sim-only.** Reproduces, in a bit-matched Verilator model of the flashed
`TxRxComposite` netlist, the hardware-observed periodic RX burst error (the
"119.75 s beat") and validates a candidate RTL fix. No hardware touched.

### Mechanism framing (CORRECTED per Model-2 coordinator, 2026-08-20)

The originally-stated trigger — "a `clk_enable` pulse flips `count2`" — is NOT
physically reachable: `clk_enable` (`write_axi_enable`) is a static held level
(resets to 1 in `TxRxCompo_ip_addr_decoder.v`, never rewritten during a run), so
`count2` FREE-RUNS and `enb_1_2_0`/`enb_1_2_1` are pure clk/2 phases. A `count2`
flip is only reachable by writing the AXI enable register (an aperiodic arm
event), which is not the 119.75 s beat. This sim CONFIRMS that non-reachability:
a direct `count2` flip is BENIGN (below).

The physically-correct candidate trigger is a **one-tick phase slip of the ADC
sample cadence vs the free-running clk/2 grid** — a dropped/inserted
`adc_validIn` at the front capture (candidate upstream source:
`util_valid_regularizer`, unguarded fill, silent drop under rate surplus).

What this sim actually establishes (all bit-matched to the flashed netlist):
1. The **held ~50 % coded-bit corruption** is reproduced by a phase slip of the
   2→1 demapper **`Serializer` counter `HDL_Counter_out1`** — the stage
   downstream of frame-sync with NO feedback correction. This is the fault SITE.
2. A **single** front-end `adc_validIn` slip is ABSORBED (per-frame preamble
   re-acquisition + Gardner loop correct a sub-symbol slip) — so a lone
   front-end slip does not, by itself, hold. Whether a *sustained/periodic*
   front-end drop holds is tested below (the Model-2 mechanism).
3. Direct `count2` flip and a dropped `clk_enable` are BENIGN uniform
   re-timings — negative controls that bound the required event class.

## Source configuration — in-fabric BIST ROM loopback (NOT IQ replay)

Unlike every pre-existing harness in `rtl_sim/` (all `rx_input_select=1`, ADC IQ
replay), this control drives the DUT from its **internal ROM/BIST source through
the on-chip TX→RX loopback**, exactly the source the hardware `stage_poll`
observation used:
- `rx_input_select = 0`  → RX fed by `Transmitter_dataOutI/Q` (internal loopback)
- `tx_data_source  = 0`  → TX fed by the in-fabric `Message_Generator` ROM
- no ADC samples; `clk_enable` free-runs (a wrapper input so it can be dropped)

## Files created (all under `jupiter_240k5_byte/rtl_sim/`)

| file | role |
|---|---|
| `wrap_byte_ce.v`            | Verilator wrapper: ROM-loopback config, exposes `cap_in` (was tied off), `cap_out`, `cnt_frame_start`; `clk_enable` as input |
| `sim_byte_ce.cpp`          | driver: run to lock, inject, per-frame settled-cap CSV |
| `build_replay_ce.sh`       | builds `obj_byte_ce_fast` (fast, no flat-rw) + `obj_byte_ce` (`--public-flat-rw`, pokeable regs) |
| `patch_serializer_anchor.sh` | FIX: emits patched netlist copy `s1_rtl_fix/` (never edits `s1_rtl`) |
| `sweep_serctr_offset.sh`   | bit-exact sweep of `--flip-serctr` offset (`PAR=` concurrency cap) |
| `_build_cefix_flat.sh`     | builds the flat-rw fix binary `obj_byte_cefix` |
| `s1_rtl_fix/…`             | patched netlist (regenerable; NOT committed) |

Injection legs (`sim_byte_ce.cpp <nclk> <pfx> [inject]`):
- `--flip-serctr CLK` LOCAL: XOR the Serializer `HDL_Counter_out1` — flat-rw build — POSITIVE (held repro)
- `--flip-count2 CLK` GLOBAL: XOR `TxRxComposite_tc.count2` — flat-rw — negative control
- `--drop-ce CLK`     hold `clk_enable=0` one clock — fast — negative control
- `--adc-loopback [C]` route TX pulse-shaped output back through the adc port (rx_input_select=1, cadence C)
- `--drop-adcvalid CLK [N]` drop N consecutive `adc_validIn` (sample-cadence slip) — fast
- `--ins-adcvalid CLK`      insert one `adc_validIn` — fast
- `--drop-periodic START STRIDE COUNT` periodic silent drop (models `util_valid_regularizer`) — fast

Per-frame CSV `<pfx>_frames.csv` samples caps `SETTLE_DELAY=70000` clk after each
`cnt_frame_start` increment (the FecCapture regs re-arm to 0 at the boundary and
only hold the settled hash mid-frame). Columns:
`frame_idx,clk,cnt_frame_start,cap_in,cap_out,bit_errors_out,golden`.

## Build + run commands

```
cd jupiter_240k5_byte/rtl_sim
./build_replay_ce.sh                       # builds obj_byte_ce_fast + obj_byte_ce
# gate-0 / clean:
./obj_byte_ce_fast/Vwrap_byte_ce 1600000 /tmp/ce_clean
# drop-ce inject at clk 700000:
./obj_byte_ce_fast/Vwrap_byte_ce 1600000 /tmp/ce_dropce --drop-ce 700000
# local serializer-counter flip (flat-rw build):
./obj_byte_ce/Vwrap_byte_ce      1600000 /tmp/ce_serctr --flip-serctr 700000
# global count2 flip:
./obj_byte_ce/Vwrap_byte_ce      1600000 /tmp/ce_count2  --flip-count2 700000
# FIX build + rerun same injection:
./patch_serializer_anchor.sh
./build_replay_ce.sh $(pwd)/s1_rtl_fix/hdlsrc/commhdlQPSKTxRxLoopback cefix
./obj_byte_cefix_fast/Vwrap_byte_ce 1600000 /tmp/fix_dropce --drop-ce 700000
```

Frame period ≈ 98 664 clk; steady lock (both caps golden) by clk ≈ 400 k.

---

## RESULTS

### Gate 0 — clean ROM loopback reaches BOTH hardware goldens  ✅
Steady state (progress + settled per-frame CSV):
`cap_in = 0x5216F3E2` (hw golden) AND `cap_out = 0x04922282` (hw golden), held
every frame. This is the bit-match precondition for the stretch goal, and it
PASSES: the sim golden `cap_in` equals the hardware golden `cap_in` exactly.

### Mechanism repro — CONFIRMED (local Serializer-counter flip)

All runs: inject at clk 700000 (mid-frame, ~300k after steady lock). Per-frame
settled CSVs in `two_jup/model1_ce/`. Frame period 98664 clk; injection lands in
the frame `fs=6` (settled row clk 789919).

**`--flip-serctr 700000` (LOCAL: XOR Serializer `HDL_Counter_out1`) — POSITIVE:**

| frame (fs) | cap_in | cap_out | bit_errors_out | golden |
|---|---|---|---|---|
| 1–5 (pre) | 5216f3e2 | 04922282 | 51 | ✅ |
| 6 (inject)| **a129f3d1** | f93c27ac | 114 | ✗ |
| 7 | **a129f3d1** | e03c1aec | 177 | ✗ |
| 8 | **a129f3d1** | e03c1aec | 240 | ✗ |
| 9–13 | **a129f3d1** | e03c1aec | 303…555 | ✗ |

- `cap_in` leaves golden and **HOLDS a constant wrong value 0xA129F3D1** for
  every post-injection frame — the hardware signature ("cap_in HOLDS a constant
  WRONG value").
- `cnt_frame_start` keeps ticking; frame spacing stays exactly 98664 and the
  frame count matches the clean run **row-for-row** — cadence CONSERVED
  (hardware discriminator 1).
- `bit_errors_out` steps 51→114 at injection and climbs monotonically ~+63/frame
  — independent BIST confirmation that ~half the coded bits are wrong, held.

This is exactly the `STAGE_LOCALIZED.md` mechanism: the `Serializer` phase
counter is NOT re-synced to `startIn`, so a one-bit phase glitch permanently
swaps the coded-bit emission order until re-aligned.

**NEGATIVE CONTROLS (all stay golden every frame, biterr flat 51):**

| leg | result |
|---|---|
| `--flip-count2 700000` (GLOBAL `TxRxComposite_tc.count2` XOR) | golden every frame; timeline shifts by exactly 1 clk |
| `--drop-ce 700000` (hold `clk_enable=0` one clock) | golden every frame; timeline shifts by exactly 1 clk |
| `--adc-loopback --drop-adcvalid 700000 N` for N=1,4,16,64 | golden every frame, biterr flat 51 — front-end slip ABSORBED |
| `--adc-loopback --ins-adcvalid 700000` (insert 1) | golden every frame — absorbed |
| `--adc-loopback --drop-periodic 700000 5000 200` (200 drops) | golden every frame — sustained/periodic slip absorbed |

### Sample-cadence slip (Model-2's physically-correct trigger) — ABSORBED in sim

Using the ADC-loopback config (`--adc-loopback`, `rx_input_select=1`, the model's
own TX pulse-shaped output routed back through the `adc_dataIn`/`adc_validIn`
FRONT capture — which reaches the SAME golden `cap_in`/`cap_out`), a dropped or
inserted `adc_validIn` is a genuine one-tick cadence slip vs the free-running
clk/2 grid. Result: **every slip tested — 1, 4, 16, 64 consecutive drops, an
insert, and a 200× periodic drop — is fully absorbed** (golden every frame,
`bit_errors_out` never leaves 51, byte-identical to the clean ADC-loopback run).

Mechanism: the receiver re-detects the preamble every frame and the Gardner
timing loop tracks sub-symbol phase, so a front-end sample slip is re-acquired
within the acquisition transient and never reaches a held state. The held
corruption requires a phase discontinuity DOWNSTREAM of frame-sync where there is
no feedback path — the 2→1 coded-bit `Serializer`.

**Tension with Model-2 (RECONCILED in "Model 3" below):** Model-2 reports ~50 %
corruption persists even with the serializer bypassed, implicating an upstream
persistent error. Model 3 injects a post-frame-sync symbol-stream slip and shows
it HEALS — bounding the mechanism to a *persistent* per-symbol transformation and
identifying QPSK 4-fold phase ambiguity as the structural fit for the 4-value
hardware species. See the Model 3 section.

Mechanistic reason: `clk_enable` gates `count2`'s own toggle AND every
enb-gated register together, and a global `count2` XOR swaps `enb_1_2_0`↔
`enb_1_2_1` for the WHOLE design at once. Both are uniform re-timings — phase
relative to the data is preserved, so nothing corrupts. **Finding: the task's
suggested "flip `count2` directly (cleanest)" does NOT reproduce the fault in
this netlist.** The required event class is a *phase discontinuity local to the
demapper serializer*, not a global stall/re-time — which is precisely why the
fix is a local Serializer re-anchor, not a global-enable change.

### Bit-exact vs hardware species-A {0x7871AA08,0x70DF4D74,0xF6A4BC60,0x63F21D7D}
Precondition PASSES: sim golden `cap_in` = `0x5216F3E2` = hardware golden exactly
(ROM content + capture arming agree). Sweep of the `--flip-serctr` injection
offset across one full frame period (12 offsets, 500000..598664) in
`two_jup/model1_ce/sweep/`.

**Result: NO bit-exact match.** All 8 completed offsets (of 12 launched) yield the
SAME held corrupt `cap_in = 0xA129F3D1` — because a held serializer-phase swap corrupts
every frame's first-32 coded bits identically, so the injection offset (the 1-bit
counter's only DOF) does not move `cap_in`. The hardware species-A set has FOUR
distinct `cap_in` values in a single burst; a static serializer-phase swap can
produce only ONE. That mismatch is itself evidence: the hardware mechanism is
**not** a simple static coded-bit-order swap — it produces frame-phase-dependent
corruption (4 values), consistent with the still-unreconciled upstream trigger.
The sim reproduces the *class* of fault (held ~50 % coded-bit corruption, cadence
conserved) but not the exact hardware words.

### Fix leg — re-anchor Serializer phase to frame start
Patch (`patch_serializer_anchor.sh`): thread `Delay6_out1` (frame `startIn`
aligned to the serializer `In2` beat) into `Serializer.v` and force
`HDL_Counter_out1 <= 0` on it, re-syncing the coded-bit phase every frame.

**Gate — patched + NO injection:** golden every frame, `bit_errors_out` flat 51,
**byte-identical row-for-row to the unpatched clean run** — the fix does not
perturb the clean datapath.

**Patched + `--flip-serctr 700000` — SELF-HEALS in 1 frame (fix VALIDATED):**

| frame (fs) | cap_in | cap_out | biterr | golden |
|---|---|---|---|---|
| 1–5 (pre)  | 5216f3e2 | 04922282 | 51 | ✅ |
| 6 (inject) | 5216f3e2 | f93c27ac | 114 | ✗ (only this frame) |
| 7 | 5216f3e2 | 04922282 | 114 | ✅ HEALED |
| 8–13 | 5216f3e2 | 04922282 | 114 (FLAT) | ✅ |

Only the single frame straddling the injection is dirty; the next `startIn`
re-anchors `HDL_Counter_out1` and every subsequent frame is golden. `biterr`
freezes at 114 (no accumulation) — vs the UNPATCHED run where `cap_in` held
0xA129F3D1 forever and `biterr` climbed +63/frame without bound. This also
proves the anchor is LIVE (the clean gate alone could pass with dead code; the
heal proves `startAnchor`=`Delay6_out1` actually fires). NOTE: the fix is
validated against an injection at the SAME register it overwrites — it is proven
for the serializer-phase fault class, not against an upstream trigger.

## Verdict

- **Gate-0 (ROM loopback reaches hardware golden):** PASS — `cap_in=0x5216F3E2`
  AND `cap_out=0x04922282`, both bit-matching hardware.
- **Held-corruption repro:** CONFIRMED via the local 2→1 `Serializer` phase flip
  (`--flip-serctr`): `cap_in` holds constant-wrong `0xA129F3D1`, cadence
  conserved row-for-row, `bit_errors_out` climbs +63/frame. This is the fault
  SITE (downstream of frame-sync, no feedback).
- **Negative controls:** direct `count2` flip, dropped `clk_enable`, and ALL
  front-end `adc_validIn` slips (1/4/16/64/insert/periodic) are BENIGN/absorbed.
  → the required event class is a phase discontinuity local to the coded-bit
  serializer, not a global re-time or a front-end sample slip.
- **Fix (re-anchor `Serializer` phase to `startIn`):** VALIDATED — patched+clean
  is byte-identical to unpatched clean (no perturbation), and patched+inject
  SELF-HEALS in 1 frame (only the injection frame dirty, biterr freezes). Proven
  for the serializer-phase fault class.
- **Physical trigger:** the front-end sample-cadence slip (Model-2's candidate)
  is absorbed in this noiseless sim; the trigger→site link is UNRECONCILED (see
  above). Recommended next: inject at the symbol-decimation/timing phase counter.
- **Bit-exact vs hardware species-A:** NO MATCH. Sim held `cap_in=0xA129F3D1`
  (offset-invariant across the 12-offset sweep); hardware species-A has 4 distinct
  values. The sim reproduces the fault CLASS, not the exact words — and the
  4-vs-1 value count is itself evidence the hardware trigger is not a static swap.

Data: per-frame CSVs in `two_jup/model1_ce/`; sweep in `two_jup/model1_ce/sweep/`.
The patched netlist `s1_rtl_fix/` is NOT committed (large, regenerable) — run
`patch_serializer_anchor.sh` to reproduce it.

---

## Model 3 — post-frame-sync symbol-stream slip; species count; fix generality

Coordinator ask: slip a post-frame-sync symbol-timing/decimation phase by one
tick, test for MULTIPLE held species (bit-exact vs hardware), and test whether the
`startIn` re-anchor fix GENERALIZES. New injection `--drop-symval CLK [N]`
(flat-rw): zero the demapper `Serializer` input `In2` (`QPSK_Demodulator.Delay5_out1`
= symbol validIn delayed) for the next N symbol cycles, dropping N symbols from the
coded-bit stream while the frame markers (`startIn`, the separate `Delay6` pipeline)
keep flowing — a post-frame-sync slip of the data vs the marker.

### Result 1 — a symbol-stream slip HEALS (not held)

`--drop-symval 700000 1` on the unpatched netlist:

| frame (fs) | cap_in | cap_out | biterr | golden |
|---|---|---|---|---|
| 1–5 (pre)  | 5216f3e2 | 04922282 | 51 | ✅ |
| 6 (inject) | 5216f3e2 | a6120484 | 95 | ✗ |
| 7 | 5216f3e2 | 04922280 | 96 | ✗ |
| 8 | 5216f3e2 | 04922282 | 96 (FLAT) | ✅ HEALED |

Only the 2 frames straddling the drop are dirty; `cap_out` returns to golden and
`bit_errors_out` freezes at 96. **A one-time symbol slip is transient**, because
each frame carries a fixed coded-bit count that refills at the next `startIn` — so
the drop corrupts only the frames it spans, then self-recovers. (Front-end
`adc_validIn` slips of every size behaved the same way; see the sample-slip
section.) `timing/decimation slip HOLDS = NO.`

### Result 2 — why only ONE species (the species-count proof)

Under the identical-ROM loopback, every frame's payload is byte-identical, so
`cap_in` is a deterministic function of the RECEIVER's PERSISTENT state:
- A one-time slip leaves no persistent state → heals → contributes 0 held species.
- The `Serializer` `HDL_Counter_out1` is 1 bit → exactly one non-trivial persistent
  state → exactly ONE held species (`0xA129F3D1`, offset-invariant across the sweep).

Hardware species-A shows FOUR distinct `cap_in` values under the same repeating ROM
source. Reproducing four values therefore REQUIRES a persistent transformation with
a state space ≥ 4 — which the 1-bit serializer counter cannot provide.
`species reproduced = 1 (0xA129F3D1); bit-exact match = NO.`

### Result 3 — the re-anchor fix does NOT generalize

`--drop-symval 700000 1` on the PATCHED (serializer re-anchored) netlist is
**byte-identical** to the unpatched run above (frames 6–8: cap_out
`a6120484 / 04922280 / 04922282`, biterr `95 / 96 / 96`) —
`two_jup/model1_ce/m3_dropsymval_{unpatched,patched}_frames.csv` diff clean.
The `startIn`→`HDL_Counter` re-anchor has ZERO effect on a symbol-stream slip: it
re-syncs the coded-bit *pair order*, not the symbol *framing*. `re-anchor
generalizes = NO` — the fix is specific to the serializer-phase (coded-bit-order)
fault class and does not immunize against an upstream symbol/phase error.

### Reconciliation with Model-2

Model-2's ~50 % with the serializer bypassed requires a PERSISTENT, upstream,
per-symbol error. This harness eliminates every TRANSIENT candidate — front-end
`adc_validIn` slips (1/4/16/64/insert/periodic) and post-demapper symbol drops are
all absorbed/heal. The serializer flip proves the HELD signature is reproducible
(cap_in constant-wrong, cadence conserved, biterr +63/frame) but yields 1 species
because its state is a single bit. Hardware's 4 species under identical ROM frames
therefore demand a ≥4-state persistent transformation upstream of / at the
serializer.

**Structural candidate (NOT injected, with reason): QPSK 4-fold phase ambiguity.**
`Phase_Ambiguity_Estimation_and_Correction` (post-frame-sync, feeds the demapper)
resolves the 90°/180°/270° ambiguity; a wrong-but-held resolution rotates every
symbol and yields ~50 % coded-bit errors, and its 4-state space matches the 4-value
species count. It is NOT injected here because the corrector is a *continuous*
derotation (`X = Xbar·conj(Z)/|Z|`), not a discrete counter with a clean one-tick
slip handle, and the estimator re-resolves against the preamble (a poke would most
likely re-lock, like the other transient slips). This is the recommended next test
for Model-2, whose bypass setup already removes the serializer from the path.

**Net:** the two models are compatible — site = a persistent phase transformation
upstream of or at the serializer; the 1-vs-4 species count says the hardware state
space is larger than the serializer's single bit (phase-ambiguity-sized).

### Model 3 verdict
- timing/decimation (symbol-stream) slip HOLDS: **NO** — transient, heals in ≤2 frames.
- species reproduced: **1** (`0xA129F3D1`); bit-exact vs hardware species-A: **NO**
  (structural argument: needs ≥4-state persistent transform).
- re-anchor fix generalizes: **NO** — patched drop-symval byte-identical to unpatched.

New files: `--drop-symval` leg in `sim_byte_ce.cpp`; CSVs
`two_jup/model1_ce/m3_dropsymval_{unpatched,patched}_frames.csv`.
Build+run: `verilator … --public-flat-rw` (foreground) then
`./obj_byte_ce/Vwrap_byte_ce 1100000 <pfx> --drop-symval 700000 1` (unpatched) and
the same on `./obj_byte_cefix/…` (patched).

---

## Model 4 — persistent ≥4-state phase elements: enumerate, inject, verdict-rule filter

**Framing (operator-directed, stated verbatim):** This is a FILTER, not an
endpoint: a green result is a SUFFICIENCY proof only (mechanism COULD produce the
species), and hardware observation is queued behind it as the confirming step.

Hardware ground truth (held `cap_in`, golden `0x5216F3E2`):
species-A {0x7871AA08, 0x70DF4D74, 0xF6A4BC60, 0x63F21D7D};
species-B {0x4210A27D, 0x917D1E97, 0xADC7BFE6} — 7 distinct wrong words + golden = 8 states.

### Candidate register inventory (file:line, flat-rw handles)

| # | candidate | register (file:line) | state space |
|---|---|---|---|
| C1 | 4-fold ambiguity resolution LATCH (the persistent element behind the continuous corrector `X·conj(Z)/|Z|`) | `Average_Estimates.Unit_Delay_Enabled_Synchronous_out1_re/im`, `Average_Estimates.v:160-171` (re-latched once per frame at estimator `endIn`; feeds `Phase_Ambiguity_Corrector.estimate_*`) | 4 quadrant rotations |
| C2 | carrier NCO phase accumulator (Costas 4-fold lock attractors) | `Carrier_Synchronizer/Direct_Digital_Synthesis/NCO.accphase_reg`, `NCO.v:52` (sfix21, 90° = 0x80000) | 4 attractors |
| C3 | interpolation/decimation fractional-timing state | `Interpolation_Control.muReg` (+`countReg`), `Interpolation_Control.v:54ff` (sfix11_En10, Gardner-loop-driven) | continuous, loop-corrected |
| C4 | compound: best candidate × Serializer `HDL_Counter_out1` parity | — | ≤ 4×2 = 8 |

Injections added to `sim_byte_ce.cpp` (flat-rw): `--rot-nco CLK Q` (+Q·90° phase
step), `--rot-avgest CLK Q` (rotate the held latch by Q·90°), `--poke-mu CLK VAL`.
All runs: 2.0M clk, inject @700000, ≥12 settled post-injection frames captured
(CSVs `two_jup/model1_ce/m4_*_frames.csv`), foreground with explicit timeout.

### Per-candidate verdict table

| candidate / state | held or healed | dirty frames (transient words) | held word | hw match |
|---|---|---|---|---|
| C1 avgEst rot 90°  | HEALED ≤1 frame | 1 (`cap_out ce25335e`) | — | n/a |
| C1 avgEst rot 180° | HEALED ≤2 frames | 2 (`594eeb4c`, `04922280`) | — | n/a |
| C1 avgEst rot 270° | symmetric to 90° (not run separately) | — | — | n/a |
| C2 NCO +90°  | HEALED ≤1 frame | 1 (`ce25335e`) | — | n/a |
| C2 NCO +180° | HEALED ≤1 frame | 1 (`594eeb4c`) | — | n/a |
| C2 NCO +270° | symmetric to +90° (not run separately) | — | — | n/a |
| C3 mu = +0.5 | ABSORBED | 0 | — | n/a |
| C4 avgEst-180° × serctr-flip | avgEst part decays in 1 frame; steady state = serializer alone | ∞ (held) | `cap_in a129f3d1` (single) | NO |

Key observation strengthening the falsification: in every C1/C2/C3 run,
**`cap_in` never left golden** — only `cap_out` was transiently dirty. The
hardware signature is `cap_in` dirty (all-three-stage `IDO` divergence). These
upstream phase rotations do not reproduce the `cap_in`-dirty signature even
transiently; only the serializer flip does.

Why the candidates heal (mechanism): the ambiguity estimator re-estimates from
EVERY frame's preamble and re-latches `avgEst` at estimator `endIn` — so a wrong
latch value or a rotated carrier lock (which the 4-fold-symmetric Costas loop
happily holds) is re-resolved one frame later. The Gardner loop pulls `mu` back
within the same frame. No enumerated element retains a wrong state.

### Verdict-rule clauses (applied mechanically)

1. **HOLDS** (≥10 consecutive constant-wrong `cap_in` frames): **FAIL for every
   candidate and state** — all heal ≤2 frames (C3: 0 dirty). FALSIFY trigger
   "every forced state re-resolves/heals ≤2 frames" is MET.
2. **CARDINALITY** (≥3 distinct held values, alone or × serializer parity):
   **FAIL** — the only holding element in the entire campaign is the 1-bit
   serializer counter (1 species, `0xA129F3D1`); the C4 compound decays to it
   (measured), so ≤1 held value is reachable. The 8-state hardware cardinality
   (7 wrong + golden) is unreachable from 4-state-transient × 2-state-held.
3. **BIT-EXACT** (≥3 of 7 hardware words): **FAIL** — zero matches (held or
   transient: `a129f3d1`, `ce25335e`, `594eeb4c`, `dd9ac152`, `04922280` ∉ hw set).

### VERDICT: **FALSIFY** (per the pre-stated rule)

All enumerated persistent-phase candidates — the ambiguity-resolution latch, the
carrier NCO attractors, the timing/decimation state, and their compound with
serializer parity — are eliminated as the species mechanism in this bit-true
noiseless loopback. Combined with Models 1–3, the sim has now eliminated every
in-model receiver state candidate: the only element that HOLDS is the 1-bit
serializer counter, and it yields exactly one species with `cap_in` dirty, while
everything upstream re-resolves per frame. The 8-state, `cap_in`-dirty,
multi-species hardware behavior is NOT reproducible by any single enumerated
receiver register in this netlist under clean loopback — pointing at either (a)
state outside this netlist model (e.g. the AXI/enable re-hosting divergence noted
in the synthesis forensic), (b) a noise/RF-conditioned re-resolution failure that
the noiseless sim cannot exhibit (the estimator heals here because its input is
clean), or (c) a compound event not expressible as a single register poke.
Sufficiency-only caveat applies in reverse: this FALSIFY binds only in-model
single-register mechanisms; hardware observation remains the confirming step.

---

## Model 5 — standing valid-train phase offset vs the free-running enable grid

**Framing (operator-directed, stated verbatim):** Green = SUFFICIENCY ONLY;
hardware confirmation remains the queued decisive step.

Operator hypothesis: the fault is the standing PHASE OFFSET between the
sample-valid train and the free-running clk/2 enable grid — a mod-4 persistent
quantity (cadence-2 clocks/sample, SPS=4 → 8 clk = 4 `enb_1_2_0` beats per
symbol) living in the RELATIONSHIP, not in any register — unreachable by
Model-4's register pokes.

**Injection semantics — drop vs DELAY (the key distinction):** drop/insert
remove/add a sample but the subsequent valid train keeps its standing
clk-parity. The new `--delay-valid CLK N` freezes the valid-train phase counter
for N clocks at CLK: NO samples lost, cadence intact afterwards, and every
subsequent valid lands N clocks later — the standing offset is stepped by N and
HELD by construction. Never previously performed. (Also `--vphase P`: initial
train phase from reset.) ADC-loopback config (the one proven to reach both
hardware goldens), inject @clk 700000 (~3 frames post-lock), ≥14 settled
post-injection frames per run, foreground with explicit timeouts.

### Per-offset verdict table

| leg / offset | held or healed | post-inj frames golden | biterr | held word | hw match |
|---|---|---|---|---|---|
| vphase 0 (control, from reset) | absorbed (steady golden) | all | 51 flat | — | n/a |
| vphase 1 (control, from reset) | absorbed (locks 1 frame earlier, same steady state) | all | 51 flat | — | n/a |
| mid-run delay +1 clk (parity flip) | **ABSORBED — zero dirty frames** | 14/14 | 51 flat | — | n/a |
| mid-run delay +2 clk (one enb beat) | **ABSORBED — zero dirty frames** | 14/14 | 51 flat | — | n/a |
| mid-run delay +3 clk (beat+parity) | **ABSORBED — zero dirty frames** | 14/14 | 51 flat | — | n/a |

Leg 3 (compound × serializer flip): NOT RUN — moot per the rule (no offset holds;
a compound of a zero-effect leg with the serializer flip is the serializer alone,
already measured in Model 4 = single species `0xA129F3D1`).

CSVs: `two_jup/model1_ce/m5_{vp0,vp1,d1,d2,d3}_frames.csv`.

### Leg 4 — structural answer (why every offset is absorbed, both paths)

Read from the netlist (`TxRxComposite.v`):

- **The receiver never sees the valid train's phase.** `Receiver.validIn` is a
  CONSTANT: `IntValidConst_out1 = 1'b1` (internal path) and
  `RxValidConst_out1 = 1'b1` (ADC path) — `TxRxComposite.v:476-481`, feeding
  `u_Receiver.validIn` at line 721. The RX chain processes one sample per
  `enb_1_2_0` beat unconditionally.
- **ADC path:** the only place `adc_validIn` exists is the front capture
  `AdcCapI/Q_reg` (`if (enb && adc_validIn)`, `TxRxComposite.v:608-614`), a
  RE-TIMER that resamples the async train onto the enable grid. The standing
  offset is erased at this seam by construction; only the sample VALUES shift by
  a fraction of a sample period, which the Gardner loop absorbs. This is why
  drop/insert/periodic/delay/vphase are ALL invisible downstream.
- **Internal ROM-loopback path (`rx_input_select=0`, where hardware ALSO shows
  the beat):** RX data = `Transmitter_dataOutI/Q` directly (line 657/713),
  valid = const 1 — there is NO `adc_validIn` seam at all. The only cross-rate
  boundaries are the TX-side `WordRT/AvailRT/FirstRT` bypass muxes
  (`enb_1_2_1` vs `enb`, lines 518-587), whose phase relationship is fixed by
  `count2` — movable only by the static `clk_enable` level (Model-4 note).

**Implication:** the hypothesized standing-phase freedom DOES NOT EXIST as a
free-running quantity anywhere in this netlist, in either path — it is
structurally pinned (constant valid + enb-grid retiming). Since hardware shows
the beat in the internal-loopback config too, the silicon mechanism cannot be an
adc valid-train standing offset; whatever slips on silicon must live in the
physical clock/enable network itself (consistent with the synthesis forensic's
re-hosted rail/enable network) — i.e. OUTSIDE the state expressible in this RTL
model.

### Verdict-rule clauses (applied mechanically)

1. HOLDS ≥10 frames: **FAIL** — every offset absorbed with ZERO dirty frames
   (stronger than "heals ≤2").
2. CARDINALITY ≥3 held values: **FAIL** — zero held values (compound moot).
3. BIT-EXACT ≥3 of 7 hw words: **FAIL** — zero.

### VERDICT: **FALSIFY** (per the pre-stated rule)

The standing valid-train phase offset is not a fault mechanism in this netlist —
and per the structural check it cannot be, in either input path. Cumulative
campaign state after Models 1–5: the ONLY in-model element that HOLDS remains
the 1-bit demapper `Serializer` counter (single species `0xA129F3D1`,
`cap_in`-dirty like hardware); every register, slip, and relationship candidate
upstream re-resolves or is structurally pinned. The multi-species, 8-state
hardware behavior remains un-reproduced in-model, sharpening the pointer at the
physical/synthesis-level enable network (out-of-model) or noise-conditioned
re-resolution failure. Sufficiency caveat applies: this FALSIFY binds in-model
mechanisms only; hardware observation is the queued decisive step.

---

## Model 6 — Rate_Handle symbol↔grid boundary: mod-4 pop pacer + FIFO pointers

**Framing (verbatim):** Green = SUFFICIENCY ONLY; hardware confirmation remains
the queued decisive step.

Travis's hypothesis: the persistent mod-4 state lives at the symbol-rate↔grid-rate
boundary. Target hardware (never injected in Models 1–5):
`Rate_Handle.v` (`u_Symbol_Synchronizer/u_Rate_Handle`): 2-bit `HDL_Counter_out1`
wrapping at 3 (mod-4, lines 50–91) paces pops (`pop = validIn & ctr==0`, line ~95)
from `FIFO_block` (5-bit free-running `Push_Counter_out1`/`Pop_Counter_out1`,
`FIFO_block.v:57-66`, never re-anchored to startIn; push = Gardner symbol strobe,
pop = grid fraction). Note: per-point constellation metrics are blind to sequence
errors, so the clean-constellation hardware evidence does not exclude this stage.
Injections: `--set-rhctr CLK V` (force pacer), `--step-pop CLK K` (pointer step),
both repeatable. ROM-loopback config; inject @~700000 (post-lock); 12+ settled
post-injection frames; foreground, explicit timeouts.

### Per-injection verdict table

| injection (pre→post @clk) | semantic | held/healed | held cap_in | held cap_out | hw match |
|---|---|---|---|---|---|
| pop ptr +1 @700000 | FIFO offset +1 (stream −1 sym) | HEALED ≤2 (trans. `dc2f4c46`) | — | — | n/a |
| pop ptr +2 @700000 | offset +2 | HEALED ≤1 (`5f4852a4`) | — | — | n/a |
| pop ptr +3 @700000 | offset +3 | HEALED ≤1 (`f1f6b7ec`) | — | — | n/a |
| pop ptr −1 @700000 | offset −1 | HEALED ≤1 (`22820178`) | — | — | n/a |
| rhctr 3→1 @700000 | pop 2 beats late | HEALED, 0 dirty | — | — | n/a |
| rhctr 3→2 @700000 | pop 1 beat late | HEALED, 0 dirty | — | — | n/a |
| rhctr 0→1 @700002 | one pop LOST | ABSORBED, 0 dirty | — | — | n/a |
| rhctr 0→0 @700002 | no-op control | golden | — | — | n/a |
| **rhctr 3→0 @700000** | **pop 1 beat EARLY (phase+1)** | **HOLDS ≥13 frames** | **`AB7A4307`** | `ABC5744E` (settles) | NO |
| **rhctr 2→0 @700006** | **pop 2 beats early (phase+2)** | **HOLDS ≥10 frames** | **`AB7A4307`** | NON-SETTLING (wanders) | NO |
| **rhctr 1→0 @700004** | **pop 3 beats early (phase+3)** | **HOLDS ≥11 frames** | **`57B5830B`** | `1FE5D060` (settles) | NO |
| compound phase+1 × serctr flip | | HOLDS (transits `a129f3d1` 1st frame) | `57B5830B` | `1FE5D060` | NO |
| compound phase+3 × serctr flip | | HOLDS (transits `a129f3d1`) | `AB7A4307` | `ABC5744E` | NO |

**THE FIRST NEW HOLDING ELEMENT SINCE THE SERIALIZER — with the hardware
signature.** Advancing the pop cadence (pop early) is a persistent phase step of
the pop train vs the push (Gardner) strobe grid: `cap_in` HOLDS constant-wrong,
cadence conserved (period 98664), `bit_errors_out` climbs ~+56/frame — the
`cap_in`-dirty signature that Models 4–5 candidates all failed to produce.
Asymmetry measured: pop-early (phase advance) HOLDS; pop-late/pop-lost and all
pointer-offset steps HEAL (they are stream delays that frame-sync re-frames).

### Cardinality and composition

Distinct HELD `cap_in` from this register: **2** ({`AB7A4307`, `57B5830B`};
phase+1 and phase+2 degenerate to the same word). Compounding with serializer
parity does NOT extend the set — it PERMUTES it (phase+1×parity → `57B5830B`,
phase+3×parity → `AB7A4307`), i.e. an odd pacer-phase step also flips the
downstream 2:1 serialization parity: the two spaces are not independent.
Campaign-wide in-model held-species set: {`A129F3D1`, `AB7A4307`, `57B5830B`} = 3
(the third from the serializer register alone).

### Staircase (leg 4)

Two successive forced steps in one run (`700000` then `~1200002`): the second
step did NOT switch the held word (`AB7A4307` before and after; frame timing
shifted +2 clk) — consistent with the phase+1/+2 degeneracy above. First attempt's
second poke (@1200000) landed pre=0 → no-op (logged). The hardware window
staircase (successive DIFFERENT held words) was NOT reproduced with this
register's state space.

### Verdict-rule clauses

1. HOLDS ≥10 frames cadence-conserved: **PASS** (three injections; transients ≤2
   frames before the hold settles).
2. CARDINALITY ≥3 distinct held values (register alone or × serializer parity):
   **2 strictly** (compound permutes, does not extend); 3 only if the
   serializer-alone species is counted (different register). Marginal FAIL by the
   strict reading.
3. BIT-EXACT ≥3/7 hw words: **FAIL** — 0/7 (`AB7A4307`, `57B5830B` ∉ hw set).

### VERDICT: **PARTIAL** (per coordinator's banked read) — holding-element CLASS
confirmed (symbol↔grid pop-cadence phase, `cap_in`-dirty, cadence-conserved,
persistent by construction), identity NOT established (no bit-exact match, strict
cardinality short, staircase not reproduced). Sufficiency caveat: even a full
green here would only prove the mechanism COULD produce the species; hardware
observation remains the decisive step.

CSVs: `two_jup/model1_ce/m6_{pop1,pop2,pop3,popm1,rh0,rh1,rh2,rh0_o2,adv1,ph2,ph3,comp,comp2,stair,stair2}_frames.csv`.

---

## Model 6b — fix positive control: per-frame re-anchor of the Rate_Handle pacer

**RESULT UP FRONT (loud, per instruction): this fix variant is KILLED — not
because it breaks nominal lock (it does not), but because it is INERT against
the fault: the frame-start anchor is causally DOWNSTREAM of the pop pacer and
the slip moves the marker with it, so the anchor's reference is slip-invariant
and the restore cannot return the pacer to the pre-slip phase. A different
anchor point is required (push-side).**

### Patch (patch_ratehandle_anchor.sh → s1_rtl_rhfix/, never edits s1_rtl)

Anchor signal chosen: `Packet_Controller_startOut` (F&TS line 103/196 — the same
per-frame start that becomes demapper `startIn` and re-arms FecCapture); plumbed
F&TS → `Symbol_Synchronizer` → `Rate_Handle` (3-file patch). Scheme:
self-calibrating — first anchor pulse after reset LATCHES the pacer's in-flight
next-value (`count_1`) as `anchor_ref`; every later anchor pulse FORCES the
counter to `anchor_ref`. By design a no-op in nominal lock (no assumed constant),
restore-on-slip otherwise. The script also supports `--also-serializer` to stack
the Model-1 serializer anchor on the same copy.

### Gate 2 — nominal lock: **PASS**

Patched + NO injection (2.0M clk) is **byte-identical** to the unpatched clean
control (`m6_rh0_o2`, the 0→0 no-op run): golden every frame, biterr 51 flat.
The anchor does not disturb nominal FIFO/pacer behavior.

### Gate 3 — fix efficacy: **FAIL (INERT)**

Patched + `--set-rhctr 700000 0` (the phase+1 hold): **still HOLDS
`cap_in=AB7A4307` / `cap_out=ABC5744E` for 11+ frames** — same species and words
as unpatched. Diff vs the unpatched hold shows only a growing frame-clk drift
(+2, +8, +10, … clk): the anchor IS firing each frame post-slip, but it restores
a phase referenced to the SLIPPED marker. Root cause of the inertness, from the
unpatched data itself: in the unpatched hold the frame boundaries shift −2 clk
(888581 vs clean 888583) — **the frame marker travels with the popped data, so
the pop-phase slip moves the marker too**; "pacer phase at frame start" is
invariant under the fault and cannot detect or correct it. ph2/ph3 and the
both-anchors compound were NOT run: the variant is already killed by mechanism
and by the rh0 measurement (their outcome is determined — the rh anchor
contributes nothing, the serializer anchor was already validated in Model 1).

### Recommended next fix variant (for a future 6c, not implemented here)

Discipline the pop side to the PUSH side, which the slip cannot move: either
(a) occupancy-based popping — pop when `FIFO numEntries > 0` at the grid beat,
replacing the free-running mod-4 pacer, or (b) re-anchor the pacer to the
Gardner push strobe (e.g. reset the mod-4 count on each push), making the
pop-train phase slaved to the symbol strobe by construction. Both remove the
free-running relative phase that Model 6 proved is the holding state.

Verdicts: nominal-lock preserved **YES**; heal ≤2 frames **NO (holds, inert)**;
compound with both anchors **NOT RUN (moot — variant killed)**.
CSVs: `two_jup/model1_ce/m6b_{clean,rh0}_frames.csv`.

---

## Model 6c — eliminating the free-running pop/push phase: BOTH variants KILLED at the nominal-lock gate; fix space now characterized

Scope: implement occupancy-based popping (a) or a push-slaved pacer (b), gate on
nominal lock, then efficacy. Both were implemented; **both are killed by
measurement at gate 1** — and each kill is itself a mechanism discovery.

### Variant (a) — occupancy pop gate (`patch_ratehandle_occupancy.sh` → `s1_rtl_rhfix2/`)

Patch: `FIFO_block` exports `notEmpty = (Push_Counter != Pop_Counter)`;
`Rate_Handle` pop gate becomes `validIn & notEmpty` (pacer left in place,
disconnected). Lint-clean; pop rate slaved to push rate by construction.

**Gate 1: HARD KILL — and the most informative negative of the campaign so
far.** The patched CLEAN run NEVER reaches golden: it settles to
`cap_in = AB7A4307` — **exactly the Model-6 phase+1 held species**
(`m6c_occ_clean_frames.csv`). Occupancy popping moves the pop BEAT phase
(pops now track pushes instead of the pacer grid), and the receiver lands in a
wrong-phase class on a clean run. **Implication: the pop beat phase mod 4 is
functionally consumed downstream** (beat-locked processing between Rate_Handle
and the demapper — the coarse-frequency/carrier derotation path advances per
GRID beat, not per symbol), golden corresponds to ONE specific pop-phase class,
and the Model-6 species ARE this phase variable. Any viable fix must be
phase-preserving.

### Variant (b) — push-slaved pacer discipline (`patch_ratehandle_pushslave.sh` → `s1_rtl_rhfix3/`)

Patch (phase-preserving by design, 6b-lesson-compliant anchor): after a 49152-
push warmup (~clk 400k, past lock), latch the pacer's next-value at a push beat
(`pushRef`); at every later push, restore the pacer if it disagrees. The push
strobe is upstream of the pacer and does not move when the pacer slips (unlike
6b's frame marker), so a slip IS visible to this anchor.

**Gate 1: HARD KILL.** The clean run is golden until the warmup expires
(~clk 505k) and then degrades chaotically (caps churn every frame, cadence
disturbed — `m6c_pushslave_clean_frames.csv`). Mechanism: **the pacer-phase-at-
push is NOT constant in steady lock** — the Gardner strobe dithers (bang-bang
timing, 3/4/5-beat intervals around the fractional offset) even in noiseless
lock, so "restore on mismatch" fires continuously against legitimate jitter.
**The FIFO + free-running pacer IS the dither absorber**: pops must stay on the
fixed grid phase precisely so that pushes can wander. Any push-referenced
discipline is structurally wrong.

### Efficacy / regression legs: MOOT (both variants dead at gate 1, per the
pre-stated hard-kill rule). Compound leg not run.

### Fix-space characterization (the actual product of 6b+6c)

The Model-6 holding state — the pacer's mod-4 grid phase — has **no valid
in-band discipline reference**:
| candidate reference | result | why it fails |
|---|---|---|
| frame-start marker (6b) | inert | marker travels with popped data — moves WITH the fault |
| FIFO occupancy (6c-a) | breaks nominal | moves the pop beat phase, which downstream consumes |
| push/Gardner strobe (6c-b) | breaks nominal | pushes legitimately dither in lock; pacer must NOT follow |

The only invariant the downstream beat-locked consumer agrees with is the **enb
grid itself** (time mod 4 since reset). Consequences:
1. **Prevention-grade hardening (recommended, minimal):** decouple the pacer
   from the data path — count every `enb_1_2_0` beat unconditionally (drop the
   `validIn` gate on the counter; `validIn` is constant-1 in this design, so
   nominal is bit-identical BY CONSTRUCTION). This makes the phase purely
   time-mod-4: no valid-gap, strobe glitch, or upstream transient can slip it.
   It does NOT self-heal a direct state upset (SEU-class); that would require
   exporting the downstream beat-phase as an explicit contract (re-architecture).
2. The hardware fault hypothesis sharpens: a slip of THIS phase (or its
   downstream beat-locked twin) explains species, hold, cadence conservation,
   and cap_in-dirtiness; the physical slip vehicle on silicon remains
   out-of-model (enable-network divergence per the synthesis forensic).

Verdicts: variant chosen = BOTH (a) then (b); nominal-lock preserved: **NO for
both (hard kill)**; efficacy: **moot**; regression: **moot**.
CSVs: `two_jup/model1_ce/m6c_occ_clean_frames.csv`,
`m6c_pushslave_clean_frames.csv`.

---

## Silicon readout refinement — READOUT A vs COHERENT-SHIFT (banked capture beatcap_20260820_221515)

Discriminator: correlate each capture's coded-bit segment (probe8 bit0 sampled at
validOut rising edges) against the bit-exact golden ROM frame cycle generated by
the BEATOBS sim harness (`--dbg1dump`; golden cycle = 12320 coded bits/frame,
frame period 98664 clk ⇒ 8 clk/bit, consistent). Analysis script:
`two_jup/m7_readout_correlate.py`.

### Results

| segment | bits | best cyclic match | offset | anchor |
|---|---|---|---|---|
| GAP (run1, cap_in golden) | 500 | **99.80 %** | 11856 | startOut pulse in-window anchors the SAME offset 11856 — method validated |
| IN-WINDOW (run2, cap_in=0x7871AA08, species-A) | 512 | **100.00 %** | 5917 | no startOut in window (pure correlation) |

- Soft-vs-decision demap (probe10/11 signs vs probe8[4:3], 8 mappings × lags
  0–3): best 27.3 % (gap) / 27.5 % (in-window) ≈ the 25 % two-bit chance floor —
  **method-inconclusive, not evidence** (the mux2 soft tap is not
  sample-aligned to the decision instants under this sampling).
- FIFO fill bits[15:8]: {0,1} in BOTH runs — no standing occupancy delta.

### VERDICT: **COHERENT SHIFT** (three-way rule, outcome (a))

During verified species-A corruption the ILA-visible coded-bit stream is
**value-perfect golden ROM bits — 512/512 — at a (shifted) sequence position**.
Combined with the banked readout (serializer faithful, pacer 0 violations, phase
contract intact), this closes the 6b relativity caveat in the direction it
predicted: the corruption is a SEQUENCE OFFSET with every in-band relationship
conserved, not value corruption. Travis's coherent pop-phase/sequence-shift
mechanism is **confirmed on silicon**. READOUT A ("fabric consumer reads a ~50 %
value-corrupt stream") is REFUTED — cap_in deviates because it frames the
correct bits at the wrong stream position, exactly as the sim's Rate_Handle
phase holds behaved (Model 6).

Caveats / open ends (stated for the record):
- The absolute shift Δ between the runs is NOT extractable from these two
  windows alone: run2's window has no frame anchor and the two captures were
  triggered at unrelated times; only run1 is absolutely anchored (offset 11856
  via its startOut).
- Bonus species→offset derivation stalled on a tap mismatch: cap_in is an
  LSB-first packing of the first-32 FEC-input bits (FecCapture.v:231-244), but
  NO cyclic offset of the probe8 bit0 stream packs (any of 5 packing variants)
  to the golden word 0x5216F3E2 — the FEC-input stream differs from the probe8
  serializer tap by an unresolved transform (pair-order or tap-point nuance).
  Resolving it would turn each species word into an exact bit offset; left as a
  follow-up.

---

## Model 7 — sim positive control for the PRIMARY fix (explicit downstream phase contract)

Implements BEATFIX_DESIGN.md PRIMARY as a netlist patch
(`patch_phase_contract.sh` → `s1_rtl_pcfix/`, Stage A checker-only /
Stage B `--consume`), wrapper `wrap_byte_pc.v` (phase-contract taps), driver
`--shift-marker CLK K` (persistent per-frame marker displacement — the
silicon-confirmed value-clean fault class, new injection).

### Pre-implementation discriminator (changes the meaning of G2)

Before building, the silicon coherent-shift correlator was run on the SIM's own
Model-6 pacer hold (BEATOBS netlist, `--set-rhctr 700000 0`, post-settle stream
dump): best cyclic match vs the golden cycle = **55.8 % at any offset (chance)**.
**The sim pacer hold is VALUE-CORRUPT, not a coherent shift** — it is NOT the
silicon mechanism's equivalent at the FEC boundary (silicon: 100 % value-clean
shifted). Consequence, stated up front: G2-as-worded (pacer holds must decode
golden under the contract) cannot pass for value corruption entering upstream of
the attach point; the contract's own fault class needed a new injection
(`--shift-marker`), which reproduces the silicon signature in sim for the first
time: unpatched, a persistent +1-beat marker displacement HOLDS
`cap_in=0xA90B79F1` (value-clean by construction, cadence conserved, new
species; ∉ hw set).

### Attach point actually used + deviations from BEATFIX_DESIGN.md

- **Attach**: `Frequency_and_Time_Synchronizer` output inside `QPSK_Rx` (symbol
  stream + `startOut`) — the earliest point the frame decision exists. DEVIATION:
  the design doc places the attach upstream of Rate_Handle; in this generation
  the frame decision does not exist there (chain: SymSync(RateHandle)→CFC→CS→
  PreambleDet→PhaseAmbig→PacketCtrl→Demod→FEC), so no FIFO widening is involved
  and transport is a 2-beat tag pipe to the demapper output.
- **Tag**: 14-bit BIT-index-in-frame (measured: F&TS validOut is 2 beats wide →
  tag ticks once per coded bit; wrap 12319; the design doc's 13 b is
  insufficient for 12320 positions — width bug found and fixed at Stage A).
- **Consumer**: `pc_start_derived = validOut-rising & (tag==0)` replaces
  `.startIn(QPSK_Demodulator_startOut)` at both consumers (FEC wrapper +
  FecCaptureCadence); continuity +1 per bit instant, `pc_violations` counter +
  `pc_delta` latch exposed via wrapper taps.
- Stage A alignment: derived start beat-exact with original (19/19 sameBeat,
  0 extras) after two measured corrections (tag hold-style windows; 14-b width).

### Gate results

| gate | leg | decode | viol / delta | verdict |
|---|---|---|---|---|
| **G1** nominal | patched clean 2.0M | **byte-identical** to unpatched | 0 / 0 | **PASS** |
| **G2** pacer rh0 3→0 | holds `AB7A4307` (as unpatched) | 0 / 0 (silent) | FAIL-as-worded (expected per discriminator) |
| **G2** pacer 1→0 | holds `57B5830B` | **1 / +1** (counted) | partial detection |
| **G2** pacer 2→0 | holds `AB7A4307` | **1 / +1** (counted) | partial detection |
| **G2′** marker shift +1, UNPATCHED | HOLDS `A90B79F1` value-clean (silicon class repro) | n/a | baseline |
| **G2′** marker shift +1, PATCHED | **GOLDEN every frame, biterr floor** | 0 / 0 (marker no longer consumed) | **PASS — the fix claim, validated** |
| **G3** pop ptr +1 | heals (2-frame transient, as unpatched) | 0 / 0 (upstream of attach, invisible) | PASS |
| **G3** drop-symval | heals (as unpatched) | **1 / +1** (counted, no miscount after) | PASS |
| **G4** marker shift × serializer flip | serializer species `A129F3D1` holds; marker component neutralized | 0 / 0 | contract does not cover intra-pair bit order |

### Interpretation

1. **The contract does exactly what it claims for the confirmed silicon fault
   class**: a persistent marker-vs-data displacement — which holds forever
   unpatched — decodes GOLDEN under tag-derived framing (G2′). G1 proves the
   change is invisible in nominal operation.
2. The sim's Rate_Handle pacer holds are a DIFFERENT class (value corruption
   upstream of the attach, moving coherently with marker+tag): not rescued, and
   only partially counted (2 of 3 legs) — the design doc's stated residual
   exposure, now measured. On silicon this class is NOT what was captured
   (silicon = value-clean shift), so this does not diminish the fix for the
   observed fault; it bounds what the fix covers.
3. The serializer pair-order flip is below tag granularity (G4) — covered by the
   already-validated Model-1 serializer re-anchor; a production fix image should
   carry BOTH patches (compound patch = follow-up).

CSVs: `two_jup/model1_ce/m7_*.csv`. Verdicts: **G1 PASS, G2 fail-as-worded /
reframed by the value-corruption discriminator with G2′ PASS on the contract's
own class, G3 PASS**.

---

## BEATFIX2 netlist gate (sim) — FLASH_GATE_FAIL at leg 2a; root cause named

Harness: `wrap_byte_bf2.v` (fixctl in, beatfix_viol_count/latch out) +
`--fixctl CLK VAL` driver writes; BEATFIX2 netlist copied read-only from
`jupiter_byte_beatfix2_build` (prefix stripped, `s1_rtl_beatfix2/`, not
committed). ROM/BIST loopback, flat-rw build.

| leg | result | verdict |
|---|---|---|
| 1. fixctl=0 clean | both legacy goldens, 13 golden frames, caps byte-identical to the flashed-netlist clean run | **PASS** |
| 2a. fixctl 0→3 @clk 700000 (post-lock) | **`cap_in` shifts to constant `A90B79F1`** (the v1 species named in the fail rule) and holds; `cnt_frame_start` double-counts (+2/frame); cap_out stays golden `04922282`, biterr floor 51 | **FAIL** |
| 2b. counter | counts ~once per BIT in CLEAN fixctl=0 operation (175,076 ≈ total bits; latch delta=0 = tag-repeat mismatch) | diagnostic |
| 2c / 3 | NOT RUN — gate already failed at 2a (2c/3 outcomes cannot change the verdict) | — |

### Root cause (from the netlist, one mechanism behind BOTH defects)

`BfContract.v` qualifies on the `vout` LEVEL (`QPSK_Demodulator_validOut`),
which is **two enb beats wide per coded bit**, while `tagd` advances once per
bit:
- **Counter (2b):** the continuity check runs on BOTH beats; the second beat
  sees unchanged `tagd` vs `expd=prev+1` → one false count per bit
  (≈1.5 M/s at the coded-bit rate — the "rail-rate" v1 symptom, now explained:
  the named-port tap is fine; the GATING is level-not-edge; latch delta=0
  proves it is the tag-repeat case).
- **startSel (2a):** `startSel_1 = (vout && kvalid) && (tagd == K)` is TRUE for
  both beats of the K-tagged bit → a 2-beat start pulse where `legacyStart` is
  1 beat. The FEC start logic (`startIn_1` arming) consequently frames one bit
  late → `cap_in` hashes the [1..32] window = `A90B79F1` (bit-identical to the
  Model-7 +1 marker-shift species) and `cnt_frame_start` counts twice per frame.
  Decode survives (cap_out golden) because the Viterbi framing tolerates the
  second pulse, but the capture/framing contract is off by one bit —
  calibration did NOT preserve alignment.

### Required v3 change (one line of intent)

Qualify BOTH the continuity check and `startSel` on the tag-advance beat only
(edge: `vout & ~vout_prev`, exactly the Model-7 `pcFirstBit` construction that
measured viol=0 nominal and 1-beat start alignment). Expected result after the
change: leg 1 unchanged, 2a caps remain at legacy goldens, counter silent in
clean operation.

**VERDICT: FLASH_GATE_FAIL** (legs 1 PASS, 2a FAIL; 2b diagnosed).
CSVs: `two_jup/model1_ce/bf2_leg1_frames.csv`, `bf2_leg2a_frames.csv`.

---

## BEATFIX3 netlist gate (sim) — FLASH_GATE_PASS

v3 change verified in the netlist (`BfContract.v`): `vEdge = vout & ~voutPrev`
now gates the K-latch (line 175), the continuity check (180), AND `startSel`
(220) — the Model-7 `pcFirstBit` construction, as recommended by the v2
diagnosis. Same harness (`wrap_byte_bf2.v`, `--fixctl`), netlist re-copied
read-only to `s1_rtl_beatfix3/` (not committed).

| leg | result | verdict |
|---|---|---|
| 1. fixctl=0 clean | legacy goldens, 13 golden frames, caps byte-identical to the v2 leg-1 baseline; **viol=0** | **PASS** |
| 2a. fixctl 0→3 @700000 | `cap_in` STAYS `5216F3E2` every frame (no A90B79F1 shift), `cnt_frame_start` +1/frame (no double-count), biterr floor | **PASS** |
| 2b. counter | **viol=0 throughout** clean operation in BOTH modes (trajectory: 0 at enable, 0 at every 200k checkpoint, 0 final) — the per-bit false counting is gone | **PASS** |
| 2c. `--shift-marker +1` @900000 with contract calibrated | **decode GOLDEN 10/10 post-shift, biterr floor** (unpatched netlists hold `A90B79F1` forever under this injection — the fix property, demonstrated at the calibrated anchor). viol=0: NOT counted — once calibrated the contract ignores the legacy marker, so a displaced marker is invisible by design; counting it would need a marker-vs-contract disagreement detector (observability add-on, not required by the rule) | **PASS (required part); counting: not present, explained** |
| 3. fixctl 3→0 @1300000 | clean return to legacy behavior (6/6 golden post-disable, biterr floor) | PASS (report-only) |

**VERDICT: FLASH_GATE_PASS** (legs 1, 2a, 2b, 2c required parts all green).
CSVs: `two_jup/model1_ce/bf3_{leg1,leg2a,leg2c,leg3}_frames.csv`.
