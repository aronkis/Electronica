# MODEL-2 — clk_enable SOURCE trace + two-clock/period model + root-fix eval

**Scope:** sim/analysis only, no hardware (rig on HOLD). Traces the
clk_enable/adc_valid generation chain to file:line, builds a two-clock /
rate-reconciliation model that reproduces the coded-bit-corruption mechanism
behind the "119.75 s beat," and evaluates the two candidate root fixes in the
model. Companion to `two_jup/STAGE_LOCALIZED.md` (which localized the injection
to at/before `cap_in` = the QPSK demapper / coded-bit-formation stage).

Model files: `two_jup/model2_clken/tb_clken_beat.v`, `run.sh`.

---

## TL;DR (the four asks)

- **clk_enable source identified:** YES. `clk_enable` is **not** a pulse train —
  it is a **static held level** (`write_axi_enable`, a register that RESETS TO 1
  and is never rewritten in normal run). So `count2` in the timing controller
  **free-runs**, and `enb_1_2_0`/`enb_1_2_1` are pure clk/2 phases decoupled from
  any sample valid. This **corrects the task premise** (see "Mechanism
  correction").
- **Two-clock model:** built, **hybrid** = REAL in-tree RTL
  (`TxRxComposite_tc`, `Serializer`, `util_valid_regularizer`) + a behavioral
  two-cadence source. Not a full vendor-SSI netlist sim (that boundary is inside
  `axi_adrv9001` and is not the trigger — see below).
- **Period reproduced:** **consequence yes, absolute period NO / refuted-as-PPM.**
  The per-event corruption (one slip → sustained ~50% coded-bit error) is
  reproduced (as a stream-slip consequence; not origin-isolating). The *120 s
  period as an analog clock-PPM drift is
  quantitatively refuted* (needs ~5e-4 ppm; real oscillators are ~±10–20 ppm →
  ~ms, not 120 s). The ~149,100-frame period is a **digital** slip-event rate,
  left as a free parameter in the model.
- **Root fix — argued, not fully sim-isolated:** the already-present
  `util_valid_regularizer` (root-fix (a), single-clock elastic re-timer) **pins
  the RX valid to a fixed clk parity by construction** (`pop=phase&&fill!=0`,
  Serializer.v grid can't slip from valid jitter). BUT it is **unguarded against
  input-rate surplus** (3-bit fill over a depth-4 memory, no full flag) and it is
  **already instantiated in the beat-ILA build yet the beat persisted** — so
  as-placed it does not close the issue. Root-fix (b) "single coherent clock" is
  **already true locally** and is therefore not the lever. Verdict is from RTL
  structure + provenance; the sim quantifies the slip *consequence* but does not
  isolate the origin (see §3 falsification).

---

## 1. The clk_enable / adc_valid generation chain (file:line)

Build tree: `jupiter_byte_beatila_build/hdl_prj_jupiter_composite/`.
HDL dir `hdlsrc/commhdlQPSKTxRxLoopback/` (abbrev. `HDL/`); ADI library
`vivado_ip_prj/library/`; block design
`vivado_ip_prj/vivado_prj.srcs/sources_1/bd/system/system.bd`.

### 1a. clk_enable is a STATIC held level (not a pulse)

```
HDL/TxRxCompo_ip.v:262           .dut_enable(write_axi_enable)
HDL/TxRxCompo_ip_dut.v:189       assign enb = dut_enable;
HDL/TxRxCompo_ip_dut.v:192       ...TxRxComposite (.clk_enable(enb), .adc_validIn(adc_validIn), ...)
HDL/TxRxCompo_ip_addr_decoder.v:576  data_reg_axi_enable_1_1 <= 1'b1;   // RESET VALUE = 1
HDL/TxRxCompo_ip_addr_decoder.v:585  assign write_axi_enable = data_reg_axi_enable_1_1;
```

`write_axi_enable` resets to `1` and only changes on an AXI write to its
register. `two_jup/layerA_stage_poll.sh` never writes it (it touches only the
IIO `reg_access` debug knob). So during every beat capture, **clk_enable is a
constant 1**.

### 1b. count2 free-runs → enb_1_2_0/1 are pure clk/2 phases

```
HDL/TxRxCompo_ip_src_TxRxComposite_tc.v:72-73   if (clk_enable) count2 <= ~count2;
HDL/..._tc.v:78-80    enb_1_2_0 = (count2==1) & clk_enable
HDL/..._tc.v:98-100   enb_1_2_1 = (count2==0) & clk_enable
```

The tc module has **no `adc_valid` port** — the phases are never re-anchored to
the sample stream. With clk_enable static, `count2` toggles every cycle;
`enb_1_2_0`/`enb_1_2_1` alternate every cycle, **free-running from reset**.

### 1c. The demod valid is a hardwired constant; the RX chain is paced only by the grid

```
HDL/TxRxCompo_ip_src_TxRxComposite.v:476  assign IntValidConst_out1 = 1'b1;
HDL/...TxRxComposite.v:477                assign RxValidConst_out1  = 1'b1;
HDL/...TxRxComposite.v:480-481            MUX_RxValid_out1 = rx_input_select ? RxValidConst : IntValidConst;  // == 1'b1 either way
HDL/...TxRxComposite.v:721                ...Frequency_and_Time_Synchronizer(.validIn(MUX_RxValid_out1), ...)
```

`MUX_RxValid` (the valid into the demod/sync chain) is a **constant 1** on both
mux legs. `adc_validIn` gates only the front ADC-capture register
(`...TxRxComposite.v:611 if (enb && adc_validIn)`). Everything downstream of the
capture register — RRC decimation, demap, **serializer** — runs purely on the
free-running `enb_1_2_0/1` grid.

### 1d. The coded-bit serializer selects the bit by the physical grid phase

```
HDL/TxRxCompo_ip_src_Serializer.v:110  HDL_Counter advances on enb_1_2_0
HDL/...Serializer.v:135  Multiport_Switch = (HDL_Counter==0) ? word[0] : word[1]
HDL/TxRxCompo_ip_src_QPSK_Demodulator.v:138  Serializer instance, In2 = delayed validIn (const 1)
```

The serializer's **output bit at each `enb_1_2_0` tick is selected by
`HDL_Counter`** (Serializer.v:135), which advances on the free-running grid.
The demod presents a 2-bit symbol decision on `Delay12` (QPSK_Demodulator.v:108,
updated on `enb_1_2_0`) and `In2` (word-valid) is the delayed `validIn` = the
const-1 `MUX_RxValid`. So the mapping from **symbol coded-bits → serial output
positions is a function of the grid phase**. (I did not fully trace the demod
decimation ratio, so I do not assert the exact "2-bits-per-symbol" pairing —
only that the output-position mapping is grid-phase-locked.) This selection stage
is common to all three physical paths (FPGA-internal loopback, SSI near-end,
over-air), consistent with STAGE_LOCALIZED's **byte-identical corruption species
across all three** — a structural argument that the swap is at/after this
grid-locked selection, not a sim-proven attribution (see §3).

### 1e. Upstream valid path (BD) — where a periodic insert/drop could enter

```
system.bd: axi_adrv9001/adc_1_valid_i0  ->  valid_regularizer/in_valid          (util_valid_regularizer, adc_1_clk)
           valid_regularizer/out_valid   ->  sync_input/data_valid_in_rx_0
           sync_input/data_valid_out_rx_0 -> TxRxCompo_ip_0/dut_data_valid_in_rx (= adc_validIn)
```

- `valid_regularizer` = `vivado_ip_prj/projects/scripts/util_valid_regularizer.v`
  — a **single-clock depth-4 elastic skid FIFO** on `adc_1_clk`, re-emitting a
  clean 1-in-2 strobe (this is root-fix (a), already instantiated — see §4).
- `sync_input` contains `analog.com:user:sync_slow_to_fast` — but for the **RX**
  path both sides of `sync_input` are on `adc_1_clk` (rx_clk); the
  `sync_slow_to_fast` instance bridges the **TX** path (`tx_clk=dac_1_clk` →
  `rx_clk`). **The RX valid never crosses clock domains in `sync_input`.**

### 1f. Platform clocking topology (from BD + adrv9001 RTL, compiled ULTRASCALE branch)

```
system.bd: net axi_adrv9001_adc_1_clk drives TxRxCompo_ip_0/IPCORE_CLK, .../AXI4_Lite_ACLK,
           util_adc_1_pack/clk, sync_input/rx_clk, valid_regularizer/clk, beat_ila/clk, ...
library/axi_adrv9001/axi_adrv9001.v:431   .rx1_clk(adc_1_clk)
library/axi_adrv9001/adrv9001_rx.v:373-391 (ULTRASCALE): BUFGCE(clk_in_s)->adc_clk_in_fast;
                                            BUFGCE_DIV(/4, clk_in_s)->adc_clk_div (= adc_1_clk)
library/axi_adrv9001/adrv9001_rx.v:~404    always @(posedge adc_clk_div) adc_valid <= 1'b1;  // valid CONSTANT-1 in domain
```

**IPCORE_CLK == adc_1_clk == BUFGCE_DIV/4 of `clk_in_s`**, the recovered SSI data
clock (from `rx1_dclk_in`). The RX sample valid is generated in that **same**
`adc_1_clk` domain. So the **local receiver is a single coherent clock domain** —
there is *no* local SSI-vs-fabric PPM boundary on the RX valid. (ZynqMP part →
`sys_ps8` in BD → `FPGA_TECHNOLOGY=ULTRASCALE`; the SEVEN_SERIES BUFR/4 branch is
not compiled.)

---

## 2. Mechanism correction (vs the task's "extra clk_enable pulse flips count2")

The task states: *one extra/dropped clk_enable pulse flips count2 → swaps
enb_1_2_0↔enb_1_2_1*. The RTL shows this **cannot** be the literal path:
clk_enable is static, so count2 free-runs and cannot pick up an extra toggle
from clk_enable. (Handoff to Model-1: a count2 "flip" is only reachable by
toggling the AXI enable register — an *arm-boundary* event, aperiodic, not a
119.75 s beat candidate.)

**Corrected mechanism (same net effect, correct cause):** the corruption is a
**one-tick phase slip between the symbol/frame cadence and the free-running
`enb_1_2` grid**. Because the serializer's bit selection is locked to the grid
phase (§1d), a single inserted/dropped tick in the sample→symbol pipeline shifts
the serial coded-bit stream by one position (a **coded-bit slip**), transposing
the coded-bit pairing for **every** subsequent symbol → ~50% wrong coded bits,
**held until the next slip re-aligns it.** The QPSK *decision* is untouched →
**pristine constellation with a dirty `cap_in`**, exactly the STAGE_LOCALIZED
signature (clean soft symbols, `cap_in`/`cap_deint`/`cap_out` diverge together,
frame cadence conserved, deterministic species).

This reframing is *consistent with every STAGE_LOCALIZED discriminator* and, unlike
the count2-double-toggle story, also explains the three-path loopback invariance
(the swap site is the common serializer, §1d) and the perfectly-conserved frame
cadence (a phase slip changes no frame count).

---

## 3. Two-clock / period model and results

`two_jup/model2_clken/` — `iverilog`. Instantiates REAL `TxRxComposite_tc.v` +
REAL `Serializer.v` (SIM1) and REAL `util_valid_regularizer.v` (SIM2), driven by
a behavioral source. Run: `./run.sh`.

### SIM1 — bit-slip CONSEQUENCE model (real Serializer + real tc in the path)

| scenario | serializer-path err | raw-bypass err |
|---|---|---|
| aligned, no slip | 0% (all windows) | 0% |
| **one one-tick slip @cyc 8000** | 0% → **sustained ~50%** at the slip | 0% → **~50%** |

A single one-tick slip of the sample→symbol stream relative to the free-running
grid produces a **permanent one-position offset of the coded-bit stream** and
therefore **sustained ~50% error vs the frame-aligned reference**, with the
symbol decisions untouched. This quantifies the beat's per-event impact and
matches the STAGE_LOCALIZED signature (clean constellation, dirty caps, conserved
frame cadence, held-until-next-event).

**Honest scope of this sim (falsification run):** the ~50% appears **identically
when the serializer is bypassed** (raw source-bit compare, column 2). So the sim
demonstrates the *consequence* of a one-bit coded-stream slip — it does **not**
isolate the serializer/grid as the unique slip origin. That the slip originates
at the **grid-locked selection** (§1d) is an **RTL-structural argument**, not a
sim-proven attribution. The real Serializer + real tc are in the datapath and
behave consistently, but a TB that isolates the grid-selection from source
offset was not achieved (the two are physically coupled — both derive from the
same `enb_1_2_0`). The **beat period** = the rate of these slip events; the model
injects one slip and shows sustained corruption between events (the ~149,100-frame
spacing is a free parameter; see §3a).

### 3a. Period: PPM-drift origin is quantitatively REFUTED

Hardware data points (from the campaign): 119.75 s @1245 f/s (~149,100 frames),
6.7 s @341 f/s (~2,285 frames). Two independent refutations of an analog
clock-PPM-sample-slip origin:

1. **Absurd PPM.** One sample of slip in 119.75 s at the 15.36 MSPS interface
   (`two_jup/lvds_15p36_jupiter.json: rxInterfaceSampleRate_Hz=15360000`) needs
   `1/(119.75 × 15.36e6) ≈ 5.4e-10 = 0.00054 ppm`. Real oscillators are
   ±10–20 ppm → predicted beat ≈ a few ms, ~5 orders of magnitude off.
2. **Loopback invariance.** The identical corruption species appears in
   **FPGA-internal loopback** (STAGE_LOCALIZED §"three physical paths"), where TX
   and RX share one clock and there is **no inter-node PPM at all**.

⇒ The 120 s / ~149,100-frame period is a **deterministic digital event**
(a periodic single-sample insert/drop in the sample→symbol pipeline, or a
counter-phase rollover), **not** analog drift. The model reproduces the
*consequence* of one such event; the ~149,100-frame invariant itself is **named
but not explained** here (matches STAGE_LOCALIZED, which also leaves it open).
**Period reproduction: mechanism = yes; absolute period from first principles =
no (and the PPM hypothesis is refuted).**

---

## 4. Root-fix evaluation (in the model)

### Fix (a) — "regularize clk_enable/valid" (elastic FIFO). ALREADY IMPLEMENTED.

`util_valid_regularizer.v` is exactly this fix and is **already instantiated** in
this build's BD:

```
util_valid_regularizer.v:40-43  reg phase; wire [2:0] fill = wr_ptr-rd_ptr; wire pop = phase && (fill!=0);
util_valid_regularizer.v:62     phase <= ~phase;      // free-running clk/2 in adc_1_clk
util_valid_regularizer.v:66     out_valid = pop;       // pops ONLY on 'phase' cycles
```

It re-emits the sample valid on a **fixed `adc_1_clk` parity** (`phase`),
decoupling the downstream grid from upstream arrival jitter.

**By inspection of the RTL (not a measurement):**
`pop = phase && (fill != 0)` with `phase <= ~phase` every cycle
(`util_valid_regularizer.v:43,62`). Because `pop` can assert *only* while `phase`
is high and `phase` alternates every clock, **every pop lands on the same
`adc_1_clk` parity, for any input pattern.** The SIM2 run confirms this trivially
(100% of pops on one parity for clean, jitter, and surplus alike — as the
assignment forces). ⇒ The regularizer **structurally pins the RX valid to a fixed
clk parity**, so downstream grid alignment cannot slip *from upstream valid
jitter*. This is the sense in which fix (a) addresses the §2 parity-slip
mechanism — argued from that one line, not discriminated by measurement.

**Caveat (structural):** `fill = wr_ptr - rd_ptr` is a 3-bit quantity over a
**depth-4** memory with **no full/overflow guard** (`util_valid_regularizer.v:38,42`).
If the long-term input valid rate exceeds 1-in-2 (its stated, **unasserted**
precondition), the write pointer laps the read pointer and **samples are silently
dropped** — a *different* corruption route (data loss) that a fixed elastic buffer
cannot fix. (A quantitative overflow measurement was attempted but the naive
`fill>4` test aliases on the 3-bit wrap, so it is not reported here; the hazard is
the missing full flag, which is a code fact.)
- **Empirical caveat (cannot confirm under HOLD):** the regularizer RTL
  (mtime 2026-06-13) is in `system.bd` (mtime 2026-08-19 10:08), which built the
  beat-ILA bitstream `impl_1/system_top.bit` (mtime 2026-08-19 11:23); the beat
  was still observed 2026-08-19 21:14. Build tree is gitignored (no history) and
  the flashed image is not verifiable under rig HOLD — but the mtime chain is
  **circumstantial evidence that fix (a) was present and the beat persisted**,
  consistent with the overflow-precondition gap above, OR with the slip entering
  via a path the regularizer does not cover (e.g., the symbol/frame re-anchor,
  Model-1's `startIn` domain).

### Fix (b) — "single coherent clock (no PPM)". ALREADY TRUE locally; not the lever.

From §1f, `adc_1_clk` **is** the SSI-derived clock (BUFGCE_DIV/4 of the recovered
`clk_in_s`), and the RX valid is generated in that same domain. The local RX is
**already a single coherent clock** — there is no local PPM to remove. The only
residual two-clock boundary is **inter-node** (far-end TX oscillator vs local RX
oscillator), which (i) cannot be made coherent over the air and (ii) is refuted
as the trigger by the FPGA-internal-loopback invariance (§3a). ⇒ Fix (b) is **not
applicable / not the root lever** on this platform.

### Recommended root fix (implied by the model)

Neither (a) as-placed nor (b) closes it. The durable fix must **re-anchor the
serializer/grid phase to the frame/symbol boundary** so a one-tick pipeline slip
cannot persist (make `enb_1_2`/`HDL_Counter` reset on `startIn` per frame), and/or
**guard the regularizer** (full flag + assert on `fill` so a rate surplus is
detected rather than silently dropping samples). The per-frame re-anchor is
Model-1's `startIn`-reanchor domain — this model's result **motivates** that fix:
with a per-frame phase re-anchor, a slip self-heals at the next `startIn` instead
of persisting for a full beat.

---

## 5. Status line

- clk_enable source identified: **YES** — static held level `write_axi_enable`
  (addr_decoder.v:576/585); count2 free-runs (tc.v:72); demod valid const-1
  (TxRxComposite.v:476-481); swap site = grid-locked serializer
  (Serializer.v:135). Task's "count2 double-toggle" premise corrected to a
  **valid/symbol-vs-free-running-grid phase slip**.
- Two-clock model: **REAL-RTL hybrid** (tc + Serializer + regularizer, real;
  two-cadence source, behavioral). Vendor SSI is not the trigger, so not simulated.
- Period reproduced: **consequence YES (0%→sustained 50% at a one-tick coded-bit
  slip); absolute 120 s / 149,100-frame period NO — PPM-drift origin quantitatively
  refuted; period is a digital slip-event rate (free parameter).** Note: the sim's
  50% is a stream-slip consequence (appears with the serializer bypassed), so it
  does not by itself locate the slip origin.
- Root fix validated in model: **ARGUED, not fully sim-isolated** — regularizer
  (fix a) pins the valid to a fixed clk parity *by inspection of the RTL*, but is
  unguarded against rate surplus and was apparently already in the beat build;
  fix (b) already true locally. The RTL+provenance analysis motivates a
  **per-frame startIn re-anchor + regularizer overflow guard** as the durable fix
  (startIn re-anchor is Model-1's domain).
```
