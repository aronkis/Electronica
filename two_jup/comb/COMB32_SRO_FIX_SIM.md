# COMB32 — the death path of the valid-density hole, and the RXFIX_R1 fix  (T2 / task 6)  [sim]

Date 2026-09-04 · **desk only, no board contact, no Vivado** · Verilator.
Baseline tree `jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/` (Aug-12 gen,
txfixF3 lineage); fix tree `jupiter_240k5_byte/rtl_sim/s1_rtl_rxfix_R1/` (a copy of it
patched by `two_jup/skidfix/rxfix_inject.py … R1 --sim-tree`).
**Every number in this document is [sim].** It builds on `COMB32_SRO_SIM_TAPS.md` (T0a),
which localised the loss carrier to the Rate_Handle EMPTY edge and excluded the
Preamble_Detector FIFO guards (`pdPof = pd_pop_on_empty = 0` on all four legs).

Provenance of the RTL: `Preamble_Detector.v`, `FIFO.v`, `Validate_Input_Push_Pop.v`,
`Peak_Search.v`, `Timing_Adjust.v` in the sim tree differ from the flashed txfixF3 kit
(`jupiter_byte_txfixF3_build/…/TxRxCompo_ip_src_*.v`) only in the generated header, the
module-name prefix, and Preamble_Detector's added `dc_toff`/`dc_tref` DDRCAP export ports.
The four anchors this fix touches — `wire Delay10_out1;`, `assign Delay10_out1 =
Delay10_reg[49331];`, `wire [13:0] FIFO_numEntries;`, `assign Delay8_out1 = …` — are
present exactly once in both lineages (`test_rxfix_inject.py::test_27/28` assert it).

---

## 1. TRACE — what the valid-density hole actually kills

### 1.1 The instrument

`jupiter_240k5_byte/rtl_sim/wrap_byte_sro.v` gains 15 T2 trace taps on top of T0a's six,
and `sim_sro.cpp` writes a new `<prefix>_ep.txt` with one row per event:

| tap | netlist path (under `…u_Frequency_and_Time_Synchronizer`) |
|---|---|
| `pdPush` | `u_Preamble_Detector.Delay8_out1` — the PD FIFO push (= symbol valid) |
| `pdPopReq` | `u_Preamble_Detector.Delay10_out1` — the pop request (**the defect**) |
| `pdVPop` / `pdTAv` | `FIFO_validPop` / `Delay14_out1` (Timing_Adjust's `validIn`) |
| `psToff` / `psNewpk` / `toffVal` | `Peak_Search_timingOffset`, `Peak_Search_p1c_newpk`, `done & success` |
| `taRef` / `taAcc` / `taArmed` / `taSync` | `Timing_Adjust_p1c_taref`, `…_p1c_accoff`, `…_p1c_armed`, `synchronizedPulse` |
| `sdcAct` / `sdcStart` / `sdcEnd` | `u_Packet_Controller.u_sample_discard_controller.active`, `Delay2_out1`, `End_Generator_endOut` |
| `rhPhase` | `u_Symbol_Synchronizer.u_Rate_Handle.HDL_Counter_out1` (the mod-4 pop phase) |

`_ep.txt` columns: `kind,sidx,f,nCorr,nPop,D,pdOcc,psTref,taRef,taAcc,psToff,newpk,armed,sdcAct,rhPhase,nPE,txFS`
with `kind` 0 = Rate_Handle `pop_on_empty`, 1 = `SyncPulse`, 2 = `timingOffsetValid` latch.

**`D = nCorr − nPop` is the divergence metric**: the number of valids in flight between
Peak_Search's input (the undelayed chain) and Timing_Adjust's input (the chain delayed by
the PD FIFO). It is *by construction* the PD FIFO occupancy. The two epoch counters are in
the same phase iff `D` is constant.

### 1.2 The defect, read off the netlist

`Peak_Search.timing_Reference` (`Peak_Search.v:94`) counts valids on the **undelayed**
chain. `Timing_Adjust.timing_Reference` (`Timing_Adjust.v:126`) counts valids on the
**delayed** chain, and fires `SyncPulse` when it equals `accoff`, the `timingOffset` that
Peak_Search measured in *its* epoch (`Timing_Adjust.v:153,202`). The two epoch spaces are
therefore related by exactly the number of valids in the delay — and the delay is realised
as a **tick** delay:

```
push = Delay8_out1                        (Preamble_Detector.v:301, the symbol valid)
pop  = Delay10_out1 = Delay10_reg[49331]  (:316, that valid delayed 49,332 enb_1_2_0 TICKS)
```

49,332 ticks equal 12,333 valids only while the valid density is exactly 1-in-4. Every
Rate_Handle EMPTY-edge event removes one valid slot from that density, so for the one
epoch that hole is in flight, `D` = 12,332 and the two epoch spaces are one symbol apart.
`Delay10_reg` is the ONLY tick-counted valid in the receive chain
(`RATE_HANDLE_FIX_SURVEY.md` decision line 11); everything else counts valids.

### 1.3 What the trace shows

**The tick-vs-valid divergence is real, is exactly one symbol, lasts exactly one
epoch — and is NOT what kills the frames.**

`_ep.txt`, `D = nCorr − nPop`:

| leg | D steady | D excursions | psToff (Peak_Search argmax) | loss |
|---|---|---|---|---|
| `t_p000` (s = 0) | 12321 on 329 rows | 12306…12320 once each, only during the initial fill | **30 on all 164 epochs, never anything else** | 0.00 % |
| `t_m10` (−10 ppm) | 12321 on 397 rows | **12320 on 42 rows** — exactly 2 per `pop_on_empty`, i.e. one epoch each | **30 on 166 epochs, 62 on 43** | 23.04 % |

So the hole does move the phase between Peak_Search's epoch space and
Timing_Adjust's, by exactly one symbol, for exactly one epoch, as predicted in
§1.2. And it does not matter: see §2.1.

**What kills the frames: the frame start makes a +32 / −31-symbol round trip once per
SRO symbol-slip, and both transition frames die.** `Peak_Search.timingOffset` takes exactly
**two** values on the −10 ppm leg, **30 and 62**, 32 symbols apart. The trace around the
first event (`score_t6_ep.py t_m10`; kind 2 = the per-epoch latch, 1 = SyncPulse,
0 = `pop_on_empty`):

```
  f  kind taRef accoff psToff   D  armed sdc
 39    2     11     30     30  12321   0   1     <- steady state: argmax = 30
 39    1     31     30     30  12321   1   1
 40    2     11     30     62  12321   0   1     <- the argmax moves to 62
 40    1     63     62     62  12321   1   0        SyncPulse fires 32 symbols late
 40    0   5988     62     62  12321   0   1     <- pop_on_empty, mid-frame, AFTER the move
 41    2     11     62     62  12320   0   1     <- D dips for this one epoch
 41    1     63     62     30  12320   1   1        argmax back at 30
 42    2     11     62     30  12321   0   1
 42    1     31     30     30  12321   1   1     <- back to steady state
```

Three things are settled by those rows:

1. **The move happens at the epoch boundary at the START of frame 40, BEFORE the
   `pop_on_empty` event fires mid-frame 40.** The hole does not cause it. Both are
   consequences of the same underlying quantity — the sub-symbol timing phase walking
   under the sample-rate offset.
2. **The frame-start displacement is 32 symbols, not one.** The demod frame marks agree
   exactly: at the flip-in frame the mark arrives 128 samples (32 symbols) late and the
   mark-to-mark symbol count is 12,365 = 12,333 + 32; at the flip-back it arrives 124
   samples early with 12,302 = 12,333 − 31. Net +1 symbol per cycle — which is the SRO
   walk of the frame start. **The receiver performs a smooth one-symbol-per-cycle walk as
   a +32 / −31 round trip.**
3. **The frames that die are the two transition frames**, not the frames inside the
   excursion: at −2.5 ppm the losses are the flip-in frame and the flip-back frame of each
   32.4-frame cycle (16 of the 17 losses pair off that way), and the frames in between —
   consistently 32 symbols off — are delivered fine, because the whole frame is shifted
   coherently and the deframer's window moves with it.

### 1.3.1 It is not a competing correlation peak — the displacement is upstream of Peak_Search

A correlator dump (`sim_corr.cpp` / `wrap_corr.v` → `c_m10_corr.txt`, every
threshold-exceeding `Correlator_validOut` beat over the first 60 frames at −10 ppm) settles
what Peak_Search is actually seeing:

- **exactly ONE threshold crossing per epoch** — 60 crossings in 60 epochs. There is no
  second peak coexisting with the true one, so this is not an argmax picking a sidelobe;
- the crossing's **magnitude is smooth across the excursion**
  (…69,389,021 → **69,422,753** → **69,455,581** → 69,305,625…, `thr` moving with it),
  i.e. it is the *same* preamble correlation throughout;
- what moves is its **position**: `tref` 30 → 62 → 30, and in local sample time the
  inter-crossing spacing runs 49,332 for eight frames, then **49,460 (+128)**, then
  **49,208 (−124)** — net +4 samples = +1 symbol per 8.1-frame cycle, exactly the −10 ppm
  drift of one symbol per 1/(12333·|s|) frames.

So the preamble genuinely arrives 32 symbols late (in the symbol stream presented to the
correlator) for the length of one sample-slip period, and then 31 early. Peak_Search
reports that faithfully and Timing_Adjust applies it faithfully — **neither block is at
fault**. The defect is upstream, in what decides when symbols are emitted.

Note also that the +128 is **not** quantisation of the drift: a smooth 0.49-sample-per-
frame walk sampled on the 4-sample symbol grid would step by +4 every ~8 frames, never by
+128. And it is not the stimulus: at s = 0 the crossing sits at `tref` = 30 on all 164
epochs with no excursion at all (`t_p000`).

That leaves a latency change of exactly 32 symbols inside the receiver. The obvious
suspect — the Rate_Handle ring, which is exactly 32 entries deep — is **excluded by T0a's
own measurement**: `occTrue` runs 0…5 on both negative legs (`COMB32_SRO_SIM_TAPS.md`
§2.1), so the ring never holds anything like 32 entries and cannot swing its latency by
32 symbols. The surviving candidate is the interpolator's strobe placement
(`Interpolation_Control.v:104-196`), **unmeasured here**. **This trace does not settle the
cause**; the honest statement is that the +32 is measured and its origin is not.
What §2.2's fix does is refuse to *apply* the round trip; §3 measures whether that is the
right thing to do.

### 1.3.2 The Rate_Handle ring is exonerated at the per-beat level

`wrap_ring.v` / `sim_ring.cpp` dump **every** `enb_1_2_0` beat for ±64 beats around each
`pop_on_empty`, with the ring's data in/out, both pointers, both validated push/pop, true
occupancy, both guard flags, the correlator input, and the interpolator state
(`c_m10_ring.txt`, first event at `sidx` 1,997,338 = frame 40 of the −10 ppm leg).

| question | answer from the dump |
|---|---|
| what happens on the event beat? | `strobe = 1`, `pop = 1`, occupancy 0 → the pop is suppressed (`valid_pop = 0`) and the push is taken (`valid_push = 1`). Exactly `Validate_Input_Push_Pop_block.v:119-137`, and nothing else. |
| a repeat, or a lap replay of 32 stale symbols? | **No.** Over all 248 dumped beats `Push_Counter_out1` and `Pop_Counter_out1` step by 0 or 1 only — no pointer jump anywhere. The `MATLAB_Function_block2.v:99-101,113-115` wrap branches are never taken. |
| could the ring's latency swing by 32 symbols? | **No.** True occupancy stays in **0…2** across the whole window. |
| how big is the hole in the output stream? | The longest gap between consecutive `Rate_Handle.validOut` beats is **9** (nominal 4) — **one** missing slot. |
| what else moves at the event? | The interpolator's modulo-1 counter wraps: `mu` steps 0 → ≈1020/1024 and `countReg` 252 → 1020 (`Interpolation_Control.v:138-158`) — the ordinary one-sample slip. |

So the ring does precisely what the netlist says, the EMPTY edge is a clean single-slot
hole, and **the +128-sample (32-symbol) displacement is not born in the ring.** It remains
unlocalised; the surviving candidate is the interpolator's strobe placement, and a fix
there was not cut because the evidence to place it does not yet exist.

### 1.3.3 Bisection, and where the +32 is born

| # | measurement | source |
|---|---|---|
| **A** | **The symbol stream is uniform. No symbols are ever inserted.** Per 49,332-sample local frame, every stage — `Rate_Handle.validOut`, `Coarse_Frequency_Compensator`, `Carrier_Synchronizer`, `Preamble_Detector`, `Correlator.validOut` — delivers **12,333** symbols on 409 of 417 frames and **12,332** on the other 8 (the `pop_on_empty` holes). 12,365 never occurs at any stage; the surplus count is **0**. | `q_m2p5_frames.txt` |
| **B** | **The correlator's threshold crossing moves by +32 symbols / +128 samples** into the excursion and −31 / −124 back. | `c_m10_corr.txt` |
| **C** | **Frames extracted at the +32 offset decode correctly** (golden hash); only the flip-in and flip-back frames are CORRUPT — 2 per cycle, exactly the measured 4.11 % (−2.5 ppm) and 23.04 % (−10 ppm). | `q_m2p5_deliv.txt` × `q_m2p5_marks.txt` |
| **D** | **The peak MOVES; the threshold is flat.** Dumping the correlator magnitude and its threshold at *every* beat with `tref` ∈ [0, 90]: | `d_m10_corr.txt` |

```
 frame | 4*corr@tref=30 |  thr   | 4*corr@tref=62 | argmax
   38  |  277,556,084   | 208.4M |     79,352,948 |   30
   39  |    1,768,964   | 207.9M |    277,691,012 |   62     <- excursion
   40  |    1,764,160   | 207.9M |    277,822,324 |   62
   41  |  277,222,500   | 207.9M |     79,459,972 |   30
```

**D settles it.** This is not a competitor rising past a drifting threshold, and not a
threshold artifact: the threshold is flat to ±0.5 % throughout, the magnitude at the true
position **collapses by a factor of 157**, and the *same* full magnitude **appears 32
symbols later**. The whole correlation pattern is displaced by exactly 32 symbols. (Note in
passing that `tref` = 62 carries a genuine sub-threshold sidelobe at ≈ 79 M — 29 % of the
peak — in every normal frame; it is not what wins during the excursion.)

**So the receiver's sampling phase jumps by 32 symbols = 128 input samples** — and A and
§1.3.2 say it is not done by inserting symbols and not by the ring. The obvious remaining
suspect was the interpolant position itself: the Rice modulo-1 counter in
`Interpolation_Control.v:138-158`, where `countReg` is mod-1024 in 256-unit (quarter-sample)
steps, so 512 steps = 128 samples = 32 symbols, exactly half the field.

**That suspect is refuted by direct measurement.** `sim_ring.cpp` in window mode dumps one
row per interpolator strobe over input samples 1,825,284…2,075,282 — frames 37.00…42.07 of
the −10 ppm leg, which brackets the **entire** excursion (frames 39-40):

| quantity | measured |
|---|---|
| strobes in the window | 62,500 over 5.068 frames = **12,332.6 per frame, uniform** |
| consecutive strobe spacing | **only 3, 4 or 5 input samples** — 4 on 62,353 of them; the 3s and 5s are the ordinary fractional-timing dither |
| spacings > 8 samples | **none** |
| `countReg` half-field (512-step) jump | **none anywhere in the window** |

So the basepoint does not move by 128 samples, no strobes are lost or gained, and
`Interpolation_Control.v:138-158` (and its interaction with the T8.4 anti-wedge clamp at
`:128-137`) is **excluded**. No R3 was cut at the NCO.

### 1.3.4 State of the hunt: the displacement is measured, every proposed mechanism is excluded

| mechanism | status | excluded by |
|---|---|---|
| Rate_Handle ring lap replay / latency swing | **excluded** | per-beat pointers step 0/1 only, occupancy 0…2, wrap branches never taken (§1.3.2) |
| symbol insertion or deletion in the valid chain | **excluded** | uniform 12,333 per local frame at all five stages, surplus 0 (A) |
| Preamble_Detector realignment FIFO guards | **excluded** | `pdPof` = `pd_pop_on_empty` = 0 on every leg (T0a) |
| tick-vs-valid epoch divergence (`Delay10_reg`) | **excluded as the death path** | R1 removes it and changes nothing (§3.1) |
| correlator threshold path / a competing peak | **excluded** | threshold flat to ±0.5 %, the peak itself moves (D) |
| interpolator strobe / basepoint / NCO wrap | **excluded** | uniform 3/4/5-sample strobe spacing across the excursion |

### 1.3.5 The data-displacement probe, and where the hunt stops

`sim_ring.cpp` window mode dumping one row per `Rate_Handle.validOut` over frames
37.00-42.07 of the −10 ppm leg (62,499 output symbols), analysed as CFO-invariant
differential symbols with the mean removed and normalised:

| test | result |
|---|---|
| per-frame mean amplitude / phase across the excursion | 16,735 / 16,526 alternating, arg −1.03 / −1.00 rad — **essentially unchanged**. A gross AGC / CFO / phase content transient is **not indicated**. |
| consecutive-frame cross-correlation | **two peaks of nearly equal height**: ρ = 0.50 at lag 0/−1 and ρ = 0.50 at lag ±32; every other lag ρ = 0.02. |
| when does the double peak appear? | **in every frame pair examined, including 38→39, which is not a transition.** |

**That double peak is a binning artifact, not a receiver ambiguity — do not chase it.**
The stimulus is one TX frame tiled (`gen_sro_stim.py:64-68`), so consecutive frames are
identical by construction and a correct frame-to-frame correlation should give ρ ≈ 1.0 at
lag 0 and near zero elsewhere. Splitting into two equal 0.50 peaks with everything else at
0.02 is the signature of each "frame" slice being a mixture: the slices are cut on input
*sample* boundaries (`fr = (sidx/P)`) while the symbol stream has drifted, so each slice
contains a rotated splice of the tile and the second peak is the tile's own wrap. The TX
frame's own differential autocorrelation confirms it — ≈ 0.18 at **every** integer-symbol lag
(2, 4, 8, 16, 32, 64, 96, 128, 160, 256 samples) and 0.004 at non-integer lags, i.e. **no
lag-32 preference in the transmitted content**. The TX measurement is the trustworthy one;
the frame-to-frame result is withdrawn as a lead. An earlier version of the cross-correlation omitted
the mean removal, which made the surface flat; its lag readings were withdrawn before
anything was concluded from them.

**No R3 was cut.** Six candidate mechanisms are excluded by direct measurement, and with the
double-peak result withdrawn there is no surviving lead at all — only the measured fact of
the displacement. Both variants that *were* cut on earlier
mechanistic guesses are now gated — one null, one actively harmful — which is the strongest
available argument for not cutting a third on a guess.

---

## 2. FIXES

Two variants were cut. **R1 is a measured negative result and is not the fix; R2 is.**
They are independent (R2 does not carry R1), and the injector treats them as separate
variants with separate markers.

### 2.1 RXFIX_R1 — valid-indexed realignment-FIFO pop.  Gated: NO EFFECT [sim]

```verilog
-  assign Delay10_out1 = Delay10_reg[49331];
+  assign Delay10_full = FIFO_numEntries == 14'd12333;
+  assign Delay10_out1 = Delay8_out1 & Delay10_full;
```

This removes the tick-vs-valid divergence of §1.2 exactly: `numEntries` is the
registered occupancy (`Validate_Input_Push_Pop.v:143` → `FIFO.v:201`), the guard bounds
it to 0…12,333, so `== 12333` is "full", and popping on `push & full` makes the delay
exactly 12,333 **valids** for ever. The 49,332-stage shift register loses its only reader.
No combinational loop (`numEntries` is a register); `push_on_full_FIFO` can no longer fire
at all, since a push while full always carries its own pop.

**Gate result: the loss is unchanged, frame for frame.**

| leg | baseline | R1 | verdict |
|---|---|---|---|
| s = 0 (`r_p000` / `f_p000`) | 164 frames, 0.00 %, biterr 51 | `_deliv.txt` **byte-identical**, biterr 51, `capout` equal | s = 0 identity **PASS** |
| −10 ppm (`q_m10` / `f_m10`) | 23.04 %, OK 157 / CORRUPT 47 | **23.04 %, OK 157 / CORRUPT 47, the same lost frame indices** | **NO EFFECT** |

The only difference R1 makes to the −10 ppm leg is that some delivered frames land 4
samples (one symbol) later. R1 is therefore **not shipped as the fix**. It remains a
correct, cheap removal of a genuine latent defect (a valid chain whose delay is counted
in ticks), and it is kept in the injector as variant `R1` should a future build want it —
but it must not be presented as fixing the comb.

### 2.2 RXFIX_R2 — frame-sync flywheel on Peak_Search's argmax.  **The fix.**

One hunk in `Preamble_Detector.v`, **no new ports** (the IP interface and the Vivado kit
are unchanged), all of it in the epoch domain plus one windowed comparison:

- each epoch, find the largest threshold-exceeding correlation sample **within ±2 symbols
  of the currently applied offset** (`ps_fw_pos` / `ps_fw_max`, qualified by
  `Correlator_validOut & Relational_Operator_out1` and a wrap-aware distance from
  `Peak_Search_p1c_tref` to `ps_fw_cur`);
- if one exists, it becomes the applied offset — this follows the genuine ±1-symbol walk
  the SRO produces — and Peak_Search's **global** argmax is ignored, so the ±32-symbol
  competitor is rejected indefinitely for as long as the true peak stays above threshold,
  **at any SRO**;
- if none exists for `PS_FW_NLOST` = 3 consecutive epochs, that is a loss of lock and the
  global argmax is adopted (re-acquisition);
- cold start (`ps_fw_have` = 0) adopts the global argmax on the first epoch, so
  acquisition is bit-for-bit what it was;
- `timingOffsetValid` is **not** suppressed — Timing_Adjust must still re-arm every epoch
  (`Timing_Adjust.v:190-200`) — only the offset VALUE is held. `Delay11_out1 <= ps_fw_out`
  replaces `Delay11_out1 <= Peak_Search_timingOffset`;
- witnesses `ps_fw_reject` (epochs where the flywheel overrode the global argmax) and
  `ps_fw_reacq` (loss-of-lock re-acquisitions), as plain registers — read hierarchically
  in sim, wire to a spare AXI/DDRCAP word later if wanted.

**Why not a run-length escape.** The plan's first sketch — adopt a far candidate that has
been the argmax for N consecutive epochs — cannot work: §1.3 measures the excursion length
as one sample-slip period, 1/(4 · 12333 · |s|) frames, which **grows as the offset
shrinks** (≈ 2 epochs at −10 ppm, ≈ 8 at −2.5 ppm, ≈ 20 at 1 ppm, ≈ 32 at 0.63 ppm). Any
fixed N is adopted-through at a small enough offset. Tracking the locked peak has no such
threshold.

### 2.3 Rejected alternatives

**Re-centring the Rate_Handle ring inside the 13-symbol guard band — rejected.**
(1) It treats the wrong edge: at the losing sign the ring is *empty*, not full (T0a:
`push_on_full = 0`, `occTmax ≤ 5` on both negative legs), so "re-centring" would mean
*inserting* a repeated symbol. (2) It cannot touch the actual death path, which §1.3 shows
is the correlator peak trade — the valid-density hole is a red herring, as R1's null
result independently proves. (3) It costs a steering FSM, a guard-band qualifier and an
epoch correction, against R2's single windowed comparison. (4) The FULL edge it would
address is measured at 0.11 % loss with no comb (`COMB32_SRO_SIM_TAPS.md` §3.1).

**Making `enSlack` (the PD FIFO's push-on-full suppression) the RTL default — rejected.**
T0a measured `pdPof = 0` on every leg; there was never a push-on-full to suppress, which
is why T1's silicon `enSlack` leg was null.

**Notching or raising the threshold against the competing peak — not attempted here.**
It needs the peak's structural origin and relative magnitude (§3.3); recorded as a
possible later refinement, not a candidate for this budget.

---

## 3. SIM GATE  [sim]

Exit-gated scoring, `score_sro2.py` against the committed golden prefix `r_p000`; every leg
is the same command shape (`Vwrap_byte_sro rx <stim> <nsamp> 8400 <prefix> 2 0`) under a
transient `systemd --user` unit. Baselines `r_p000` / `q_m2p5` / `q_m10` are T0a's committed
runs; `t_*` are the same RTL re-run with the T2 trace taps (identical results, plus
`_ep.txt`).

| leg | s (ppm) | frames | **baseline** | **R1** (valid-indexed FIFO pop) | **R2** (frame-sync flywheel) |
|---|---|---|---|---|---|
| `p000` | 0 | 162 | 0.00 %, biterr 51 | **0.00 %, `_deliv.txt` byte-identical** | **0.00 %, `_deliv.txt` byte-identical** |
| `m2p5` | −2.5 | 414 | **4.11 %** (OK 397 / CORRUPT 17) | **4.11 %**, lost indices identical frame for frame | **11.84 %** (OK 365 / CORRUPT 49) — **WORSE** |
| `m10` | −10 | 204 | **23.04 %** (OK 157 / CORRUPT 47) | **23.04 %**, lost indices identical frame for frame | **34.80 %** (OK 133 / CORRUPT 71) — **WORSE** |
| `p2p5` | +2.5 | 914 | 0.11 % (OK 913 / CORRUPT 1) | **0.11 %**, same single lost frame, `push_on_full` at f = 875 and 907 unchanged | pending (leg still running) |
| `lol` | −2.5, 4.05 frames deleted at f = 200 | 410 | — | — | 12.68 % (OK 358 / CORRUPT 51 / MISSING 1) — re-acquires, no wedge |

### 3.1 Verdicts

**R1 — NO EFFECT. Not the fix.** It removes a genuine defect (the only tick-counted valid in
the receive chain) and the s = 0 leg proves it is behaviourally neutral, but on both negative
legs the loss and the *individual lost frame indices* are identical to baseline. The
tick-vs-valid divergence is real, is one symbol, lasts one epoch, and does not kill frames.

**R2 — FAILS, and makes it worse.** 34.80 % against baseline's 23.04 % at −10 ppm, and the
newly lost frames are the excursion frames themselves (lost set 38,39,40,**41**,46,**47**,48,…
against baseline 38,39,40,46,48,…). At −2.5 ppm, where the excursion is ~7 frames rather than
~2, it is **11.84 % against baseline 4.11 %** — nearly triple.

This is the **pre-registered prediction confirmed**. The ledger entry, written while the legs
were still running, said: "because the excursion frames decode correctly AT the +32 offset,
R2 — which HOLDS the applied offset near 30 through the excursion — must place the extraction
window 32 symbols wrong for all ~7 excursion frames per cycle at −2.5 ppm. PREDICTION:
g_m2p5 loss RISES well above baseline's 4.11 %… FALSIFIER: g_m2p5 at or below 4.11 % would
mean the +32 is a sync/window displacement only and R2 is right." It rose to 11.84 %.

The loss-of-lock control (`g_lol`, 4.05 air frames deleted mid-run) comes back at 12.68 %
with a single MISSING frame and no wedge, so R2's re-acquisition escape does fire and the
receiver recovers — the variant is not broken, it is aimed at the wrong thing.

**Consequence: "refuse the offset change" is a dead branch.** Both variants that treat the
symptom downstream of the correlator are now gated and neither works. The fix has to remove
the 32-symbol sampling-phase jump at its source (§1.3.3), so that the frame start walks by
the one symbol per cycle it actually needs — or make the straddling frame survive the change.

### 3.2 What the taps prove about the epoch chain

For the record, R2 *did* do what it was designed to do — the design was simply aimed at the
wrong thing. `g_m10_ep.txt`: the applied offset `accoff` is 30 on **every** epoch, including
frames 40 and 41 where Peak_Search's global argmax is 62, and `SyncPulse` keeps firing at
`taRef` = 31 instead of jumping to 63. Override histogram over the first 61 epochs
(`psToff`, `accoff`): (30, 30) × 55, (62, 30) × 6, (0, 30) × 1 at cold start. Acquisition is
unchanged (s = 0 byte-identical), so the cold-start path and the loss-of-lock escape behave
as specified.

---

## 4. Resource and timing sanity, for the build driver

All [inferred] from the netlist — **no Vivado was run for this task**. Routed WNS margin
to beat: **+0.112 ns (148 seqbist), +0.166 ns (146)**.

### 4.1 RXFIX_R2 (the shipped candidate)

| item | assessment |
|---|---|
| **added state** | `ps_fw_cur`/`ps_fw_pos` 14 b each, `ps_fw_max` 32 b, `ps_fw_have`/`ps_fw_seen` 1 b, `ps_fw_lost` 2 b, plus the two 32-bit witness counters `ps_fw_reject`/`ps_fw_reacq` — **≈ 128 FFs**, of which 64 are witnesses that can be dropped (`WITH_FW_WITNESS=0`) if utilisation or timing is tight. |
| **added logic** | two 14-bit magnitude compares + one 14-bit subtract pair for the wrap-aware window distance (≈ 12 LUTs), one **32-bit greater-than** on `Correlator_dataOut` (≈ 8-11 LUTs with carry chain), one 14-bit not-equal for the reject witness, and the epoch-strobe control. **≈ 35-45 LUTs, 0 DSP, 0 BRAM.** |
| **the one path that matters** | the 32-bit compare `Correlator_dataOut > ps_fw_max` runs on **every** `enb_1_2_0` beat, i.e. it is on the sample path, not the epoch path. This is deliberate: it is a *duplicate* of a comparator Peak_Search already runs on the same signal at the same rate (`Peak_Search.v:132` `corr > Unit_Delay_Enabled_Resettable_Synchronous_out1`), so the achievable frequency of that cone is already demonstrated by the shipped image. The new copy is **parallel** to it, not in series, and its result goes to a register, so it adds **no logic levels to any existing path**. |
| **window compare depth** | `Peak_Search_p1c_tref` (register) → subtract/compare (2 LUT6 levels for 14 b with carry) → `ps_fw_inwin` → AND → the enable of `ps_fw_seen/max/pos`. That is a *new* path of ~3 levels ending in a flip-flop; it is not in series with the correlator datapath. Expect it to be non-critical, but it is the one to look at first if WNS regresses. |
| **epoch-domain logic** | everything qualified by `Logical_Operator_out1` (one beat per 12,333 valids) — the adopt/track/relock decision and the counters — is trivially slack. |
| **`Delay11_out1` source change** | `Peak_Search_timingOffset` (a register output) → `ps_fw_out`, a 2-level mux of two registers. **+1 LUT level** on the offset path into `Delay11`, which is a per-epoch value feeding a register: not timing-critical. |
| **net** | **+~40 LUTs, +~128 FFs (or +64 without witnesses), no new critical path in series with existing logic.** This is the "few LUTs off the critical path" the plan's rails require. |
| **if WNS still fails** | drop the witnesses; then narrow the windowed max to a *first-crossing* latch (removes the 32-bit compare entirely, at the cost of up to ±2 symbols of offset jitter — **not gated in sim, do not ship without a gate**); then pipeline `ps_fw_inwin` by one enb beat and widen `PS_FW_WIN` to 3 to absorb the extra beat. |

### 4.2 RXFIX_R1 (not shipped — recorded for completeness)

Net-negative on area, net-positive on one logic level. It adds one 14-bit equality
comparator plus an AND (**≤ 4 LUTs, 0 FFs**) and it **deletes `Delay10_reg[49331:0]`**, a
49,332-stage 1-bit shift register that loses its only reader — HDL Coder emits it as a
shift register, so it maps to ≈ 1,542 SRL32E chains (or 49,332 FFs if SRL inference is
off). That is the largest single item in the Preamble_Detector, so utilisation would go
**down** measurably. Separately from that area win, the timing story is that the new
comparator sits in the `Delay_out1 → pop → pop_on_empty → valid_pop → count → Delay_out1`
cone that already exists, adding ≈ one LUT6 level (~0.10-0.13 ns plus routing) — which is
**not free against a +0.112 ns margin**. Since R1 is measured to fix nothing (§2.1), none
of this needs to be spent. If a future build does want it, the untested mitigation is to
compare against the combinational next-state occupancy (`count`) rather than the
registered `Delay_out1`.

### 4.3 Verification already done at desk

`verilator --lint-only` clean on both variant trees (no `%Error`; the only
Preamble_Detector warning is the pre-existing 49,332-bit replication in `Delay10_reg`'s
reset, present in the baseline too). `rxfix_inject.py` anchors assert exactly-once on both
the sim lineage and the flashed txfixF3 kit lineage. 39 injector tests green, including
one that asserts R2 adds **no module ports**.

---

## 5. Reproduce

```
# variant tree + injector (exactly-once anchors, marker RXFIX_R1)
rm -rf jupiter_240k5_byte/rtl_sim/s1_rtl_rxfix_R1
mkdir -p jupiter_240k5_byte/rtl_sim/s1_rtl_rxfix_R1
cp jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/*.v jupiter_240k5_byte/rtl_sim/s1_rtl_rxfix_R1/
python3 two_jup/skidfix/rxfix_inject.py jupiter_240k5_byte/rtl_sim/s1_rtl_rxfix_R1 R1 --sim-tree
python3 -m unittest discover -s two_jup/skidfix -p 'test_rxfix_inject.py'

# builds (under systemd-run --user, never a harness background job)
jupiter_240k5_byte/rtl_sim/build_sro.sh          # baseline + T2 trace taps
jupiter_240k5_byte/rtl_sim/build_sro_rxfix.sh    # RXFIX_R1 variant

# stimulus (not committed: 181 MB for the 920-frame leg) then the legs + scoring
two_jup/comb/sro_sim/gen_sro_stim.py tx5.iq s_p2p5_920.iq --ppm 2.5 --frames 920
two_jup/comb/sro_sim/runall_t6.sh                # 4 fix legs + 3 baseline trace legs
two_jup/comb/sro_sim/score_sro2.py r_p000 t_p000 t_m2p5 t_m10 f_p000 f_m2p5 f_m10 f_p2p5
two_jup/comb/sro_sim/score_t6_ep.py              # the epoch/divergence trace tables
```

---

# Task 7 (T2b) — non-repeating stimulus, the ring-lap localisation, and RXFIX_R3  [sim]

Date 2026-09-04 · desk only, no board contact · report
`two_jup/sdd_archive/2026-09-04-rxfix/task-7-report.md` · ledger `Task 7:` lines.
Every number here is **[sim]** unless labelled `[netlist]`.

## T7.1 A genuinely non-repeating stimulus now exists

`wrap_byte_sro.v` instantiates `qpsk_traffic_gen_v2` (TGEN v2 — incrementing seq, PN(seq)
payload, fill 1516) behind a `tgen_sel` mux; `tgen_sel = 0` leaves the byte pins driven by
the module ports so **every rx-mode leg is bit-identical to the task-6 harness**. New
`sim_sro txcap2` mode captures the modulated int16 output with a per-air-frame sidecar.

TGEN `gap` was **measured, not assumed** (20 air frames each): 90000 → 10 emitted frames
(one per two air slots), 60000 → 10, **20000 → 20 (seq 1..20, one per slot)**, 1000 → 30
(the G4 overrun regime). `gap = 20000` selected; the sidecar certifies `repeat_of_prev = 0`
and `allzero = 0` on every air frame, so there is no tiling and **no all-zero filler frame**
(the artefact that would have re-introduced repeating content).

`gen_sro_stim.py --no-tile` drops the frame-periodicity assert, **asserts its inverse** (no
two consecutive frames int16-identical), and resamples with edge clamping instead of modular
indexing so there is no wrap seam. `sim_sro.cpp` reconstructs the expected frame from the
delivered seq (`t7_expect()`, the TGEN model at `qpsk_traffic_gen_v2.v:61-118`) and writes
`<p>_seq.txt`; `score_t7.py` derives MISSING from the seq numbers so **lost frames are in
the denominator**.

## T7.2 The TX content carries no 32-symbol structure — H-A's cheap half, refuted

Task 6's caveat is now reconciled. Applying task 6's **exact** pipeline (decimate to one
sample per symbol, differential `s[n]·conj(s[n−1])`, mean removed, normalised, circular
correlation) to a settled frame of the tiled `tx5.iq` gives, at all four sampling phases,
ρ(32) = **0.002 … 0.007** against ρ(0) = 1.000, with lag 32 nowhere near the top of the
surface (`t7_txauto.py`). Task 6's earlier "≈0.18 at every integer-symbol lag" was a
*within-frame, 4-sps* measurement — a different pipeline; at the symbol rate the answer is
sharper and the same. **The ±32 is not in the transmitted content.**

## T7.3 The ±32 is ONE RATE_HANDLE RING LAP, taken at the pop_on_empty beat

Re-analysis of task 6's own `h_m10_ring.txt`, no new simulation:

* **Segmentation is not the artefact** — segmenting `Rate_Handle.validOut` by valid count
  (12,333/frame) and by input sample (`sidx // 49332`) agree (`t7_segcheck.py`).
* **It is not an ambiguity, it is a sharp step.** Quarter by quarter, consecutive frames
  correlate at lag 0 with ρ = 1.00 for one part of the frame and at lag +32 (or −32) with
  ρ = 0.92–0.99 for the rest, the losing lag at 0.00–0.05, with exactly ONE of ±32 active at
  a time and its sign flipping with the excursion. **Task 6's "a 32-symbol ambiguity is
  present at ALL times" is RETRACTED**: ρ = 0.50/0.50 was the whole-frame average of a
  localised step.
* **The step beat is the EMPTY-edge beat.** The 39→40 switch sits between symbol 6013
  (`sidx` 1,997,334) and 6014 (`sidx` 1,997,342); a −64…+64 lag scan gives mean |Δ| = 364 at
  lag 0 before (next-best 18,379) and 482 at lag +32 after (next-best 18,465); and the beat
  between them, `sidx = 1,997,338`, is `strobe=1, pop=1, vout=0, occ=0, popEmpty=1,
  tref=5976` — the Rate_Handle `pop_on_empty_FIFO` event.

### The read path  [netlist]

`FIFO_block.v:184-196` — `SimpleDualPortRAM_generic #(.AddrWidth(5), .DataWidth(16))`, a
**32-entry** ring (exactly the 32 that is measured); `wr_addr = Push_Counter_out1` (:191),
`wr_en = valid_push` (:192), `rd_addr = Pop_Counter_out1` (:193). Both pointers advance
**only on the validated events** (`:127-129`, `:161-163`) — which is why task 6's per-beat
pointer census looked clean, and why a clean pointer census does **not** exclude a
lap-distance read. `SimpleDualPortRAM_generic.v:57-66` registers the read inside the same
`always @(posedge clk)` that performs the **nonblocking** write, i.e. read-before-write at a
coincident address; `FIFO_block.v:198-202` emits `out_re/out_im = data_int` (one enb tick
behind the pointer) while `validPop = valid_pop` is **combinational**.

Mod-32, a lap-stale read and a lap-ahead read are the same displacement, which is why the
measurement cannot and does not distinguish +32 from −32.

**REFUTED by its own probe, and withdrawn.** `sim_sro ramwin` on `s_m10.iq` (2 pop_on_empty
windows, ±64 enb beats, `t7_ram_m10.txt`) shows (i) `(wr − rd) mod 32` **equals** the true
occupancy at every beat — no pointer/occupancy desync — and (ii) the **lap distance of every
emitted word is 0 or 1 pushes ago, never 32**, under both read-before-write and
read-after-write models. The ring emits current data; the lap-stale-read mechanism is wrong
and is withdrawn. It was labelled [inferred] and nothing was built on it.

**What survives** is the measurement: the +32-symbol content step is real, one beat wide, and
its beat is the `pop_on_empty` beat (`sidx` 1,997,338 `tref` 5976 `occ` 0 `wr = rd = 29`;
second window `sidx` 2,398,218 `tref` 7531 `occ` 0 `wr = rd = 24`). **What is open again** is
what converts one suppressed valid slot into a 32-symbol content displacement.
