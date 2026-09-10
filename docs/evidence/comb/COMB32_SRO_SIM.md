> Evidence ledger, moved verbatim from `two_jup/comb/COMB32_SRO_SIM.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# COMB32 — desk RTL simulation of the SRO hypothesis  [sim]

Date 2026-09-03 · **desk only, no board contact** · Verilator 5.020 on the built 148
netlist `jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/` (Aug-12 gen, the
txfixF3 lineage `COMB32_RTL_HUNT.md` cites; every module byte-identical in 146's tree).
**Every number in this document is [sim]** unless explicitly labelled otherwise.

> **UPDATE 2026-09-04 — the open question in this report is now settled.**
> `COMB32_SRO_SIM_2p5.md` runs the SRO the hardware actually has (2.5 ppm, measured in
> `TX_SEL8_DESK.md`) and **REPRODUCES** the comb at a period of **32.375 frames**. The
> "whether a wrap corrupts anything is untested" caveat below is now answered: **a wrap
> does corrupt, one frame per wrap.** The verdict below remains correct *as scoped* — at
> ±0.63/1.26 ppm nothing is lost, because those legs never reach a FIFO edge. The
> 128.7-frame figure is the drift period at 0.63 ppm; the same law at 2.5 ppm gives 32.4.

## Verdict

> **NOT REPRODUCED (at ±0.63 / +1.26 ppm only — see the update above).** At s = ±0.63 ppm and +1.26 ppm, over 159 scored air frames, the
> receiver RTL loses **zero** frames — no missing frames, no garbage headers, no CRC
> failures, no comb of any period. The s = 0 control is also zero, so the null is not a
> harness that cannot see losses. What the RTL does with a sample slip instead: the
> interpolator absorbs it (mu adjusts; one strobe interval goes 3 or 5 instead of 4) and
> `Rate_Handle`'s FIFO carries the residual push/pop imbalance as **monotone occupancy
> drift** of `12333·s` entries per frame — measured at 8.0 frames/entry at 10 ppm against
> 8.11 predicted. **`FIFO_block`'s mod-32 is the right period for the wrong reason: at
> 0.63 ppm its occupancy period is 128.7 frames, not 32.**

Untested and stated as such: **whether a FIFO wrap corrupts anything at all.** No leg
reached one — the best was occupancy 25 of 32 (see §6).

## 1. What was built

| artefact | path | note |
|---|---|---|
| RTL wrapper with SRO taps | `jupiter_240k5_byte/rtl_sim/wrap_byte_sro.v` | new |
| Verilator driver (`txcap` + `rx` modes) | `jupiter_240k5_byte/rtl_sim/sim_sro.cpp` | new |
| build script | `jupiter_240k5_byte/rtl_sim/build_sro.sh` | new |
| stimulus generator (numpy; MATLAB unavailable) | `two_jup/comb/sro_sim/gen_sro_stim.py` | new |
| scorer | `two_jup/comb/sro_sim/score_sro.py` | new |
| run driver | `two_jup/comb/sro_sim/runall.sh`, `genall.sh` | new |

Taps added in `wrap_byte_sro.v`, all hierarchical references verified against the netlist:
`Symbol_Synchronizer.mu` and `.Underflow` (`Symbol_Synchronizer.v:74,87`);
`Rate_Handle.strobe` / `.validIn` / `.Logical_Operator_out1` / `.validOut`
(`Rate_Handle.v:91,99-108`); `FIFO_block.Push_Counter_out1` / `.Pop_Counter_out1` /
`.Validate_Input_Push_Pop_valid_{push,pop}` (`FIFO_block.v:113,148`); plus
`Transmitter_dataOut{I,Q}` so the stimulus comes out of the TX RTL itself.

`obj_rxfe_*` could **not** be reused: they were built against `s1_rtl_rxfe/hdlsrc`, which
no longer exists on this desk, and they expose none of the taps this test needs. The
build was therefore run fresh, under `systemd-run --user` per the standing rule.

## 2. Exact commands

```sh
# build (systemd-run --user, not a harness background task)
systemd-run --user --unit=srobuild1 --collect \
  -p WorkingDirectory=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim \
  /mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/rtl_sim/build_sro.sh
# -> verilator -O2 -Wno-fatal --cc wrap_byte_sro.v -y $VD --exe sim_sro.cpp \
#      -Mdir obj_byte_sro --top-module wrap_byte_sro ; make -j12

cd two_jup/comb/sro_sim
B=../../../jupiter_240k5_byte/rtl_sim/obj_byte_sro/Vwrap_byte_sro

# 1. legal modulated stimulus, straight out of the TX RTL (5 frames, BIST ROM payload)
$B txcap 246660 tx5.iq

# 2. resample to each SRO point (165 frames = 8,139,780 samples each)
python3 gen_sro_stim.py tx5.iq s_p000.iq --ppm 0     --frames 165
python3 gen_sro_stim.py tx5.iq s_p063.iq --ppm 0.63  --frames 165
python3 gen_sro_stim.py tx5.iq s_m063.iq --ppm -0.63 --frames 165
python3 gen_sro_stim.py tx5.iq s_p126.iq --ppm 1.26  --frames 165
python3 gen_sro_stim.py tx5.iq s_n063.iq --ppm 0.63  --frames 165 --esn0 15 --cfo 1260
python3 gen_sro_stim.py tx5.iq s_p10.iq  --ppm 10.0  --frames 165

# 3. replay each through the RX RTL (cadence 2, vphase 0 -- see the caveat in section 5)
for tag in p000 p063 m063 p126 n063 p10; do
  $B rx s_$tag.iq 8139780 8400 r_$tag 2 0
done          # actually run six-up in parallel via runall.sh under systemd-run --unit=srorun1

# 4. score
python3 score_sro.py r_p000 r_p063 r_m063 r_p126 r_n063 r_p10
```

Wall time: build ~4 min; `txcap` 30 s; stimulus generation ~4 min; the six replay legs
~18 min six-up on 12 cores.

## 3. Stimulus provenance and the two controls on it

**The modulator is the TX RTL, not Python.** `sim_sro txcap` runs the design in internal
loopback (`rx_input_select=0`, `tx_data_source=0` = BIST ROM) and dumps
`Transmitter_dataOut{I,Q}` on every `enb_1_2_0` beat — exactly the sample stream the RX
consumes in loopback. That capture is **int16-exactly frame-periodic from frame 2**
(`max|x[f·P] − x[(f+1)·P]| = 0` over P = 49,332 samples), so one period is tiled to build
an arbitrarily long legal stream. Python's only job is the fractional resample.

**Control A — the resampler is transparent at s = 0.** `gen_sro_stim.py` uses a 32-tap
Kaiser(β=8)-windowed sinc with modular source indexing. `s = 0` traverses the identical
code path and reproduces the source to `max|y−x| = 6.4e-13` LSB (asserted in the script).
Any SRO-leg loss therefore cannot be the kernel.

**Control B — s = 0 must lose nothing.** It does not (§4).

Noise convention for the one impaired leg: `Es = mean|y|² · 4` (energy per QPSK symbol at
4 sps), N0 spread over the full 61.44 MHz complex bandwidth, AWGN added after the CFO
rotation. CFO +1.26 kHz is the physically coupled partner of +0.63 ppm at Fc = 2 GHz.

## 4. Per-run results

165 frames fed; 159 scored (3-frame warm-up skipped at the head, the final partial slot at
the tail). "OK" = byte-plane frame is 191 words and hashes exactly to the golden frame
(the modal frame of the s = 0 run, `(191, 35774ce5)`). Occupancy = `(Push_Counter_out1 −
Pop_Counter_out1) mod 32`, sampled every `enb_1_2_0` beat.

| leg | s (ppm) | packets | OK | CORRUPT | MISSING | loss | excess pushes over the scored window | occupancy 5 → | occ steps |
|---|---|---|---|---|---|---|---|---|---|
| `r_p000` | 0 (control) | 164 | **159** | 0 | **0** | **0.00 %** | 0 | 5 | 0 |
| `r_p063` | +0.63 | 164 | 159 | 0 | 0 | 0.00 % | +1 | 6 | 1 (@95) |
| `r_m063` | −0.63 | 164 | 159 | 0 | 0 | 0.00 % | −1 | 3 | 2 (@30,160) |
| `r_p126` | +1.26 | 164 | 159 | 0 | 0 | 0.00 % | +3 | 7 | 2 (@47,111) |
| `r_n063` | +0.63, 15 dB Es/N0, +1.26 kHz CFO | 163 | 158 | 0 | 1 | 0.63 % | +1 | 6 | 1 (@97) |
| `r_p10` | +10 (accelerated) | 164 | 159 | 0 | 0 | 0.00 % | **+20** | **25** | **20** |

"Excess pushes" = `Σ pushes/frame − 12333·159` over the scored window; it equals the
number of occupancy steps, as it must. (The whole-run totals in `r_*_res.txt` are larger —
+1/+7/+4/+8/+7/+26 — because they include the warm-up and the 200k-clock drain tail; the
scored-window figure is the meaningful one.)

`biterr=51` and `capout=04922282` on every leg, matching the earlier campaign's golden
decoder-output hash. Loss autocorrelation is undefined on five legs (the loss series is
identically zero) and flat (`|ρ| < 0.001` at every lag 1–64) on `r_n063`.

**`r_n063`'s single missing frame is at index 161**, which is the last scored slot
(`nslots = 163`, scored range 3..161) — a run-end drain artefact, not a loss event. It is
reported rather than suppressed.

### The comb score, stated against the pre-registration
- **Expected 32 at ±0.63 ppm** — **not observed**: zero lost frames, so no period exists.
- **Expected 16 at +1.26 ppm** — **not observed**: zero lost frames.
- **Expected none at 0** — **confirmed**: zero lost frames. Control passes.
- **Coincidence of losses with ±1 strobe events** — **not scoreable**: there are no losses.
- **FIFO address/occupancy at the loss** — **not scoreable**: there are no losses.
- **Period must scale as 1/|s|** — the *loss* comb does not exist, but the *occupancy*
  period does scale as 1/|s|, exactly (§6).

## 5. Method caveat: cadence — the existing IQ-replay harnesses feed every sample twice

`TxRxComposite.v:480` ties `MUX_RxValid_out1 = 1'b1` in **both** input modes:

```verilog
assign IntValidConst_out1 = 1'b1;
assign RxValidConst_out1  = 1'b1;
assign MUX_RxValid_out1 = (rx_input_select == 1'b0 ? IntValidConst_out1 : RxValidConst_out1);
```

The receiver therefore consumes one sample per `enb_1_2_0` beat (clk/2) regardless of
`adc_validIn`; the ADC port is a rate-adapting capture register, not a valid-gated stream.
`cadence = 4` — used by `sim_byte_taps.cpp` and by `two_jup/rtl_cfo_repro` — presents each
ADC sample to the DSP chain **twice**. Measured on this desk with a 4-sps stimulus:

| cadence | FIFO pushes/frame | pops/frame | occupancy | packets decoded |
|---|---|---|---|---|
| 4 (as used by the earlier repro) | 23,895 | 23,895 | 0↔1, unstable | **0** |
| **2 (used here)** | **12,333** | **12,333** | **flat at 5** | locks, 164/165 |

12,333 pushes = 12,333 pops per frame at cadence 2 is the arithmetic the design is meant
to satisfy (12,333 symbols/frame, 4 samples/symbol). Consequence: **`two_jup/rtl_cfo_repro`'s
absolute numbers were produced with sample duplication and should not be reused without a
cadence-2 re-run.** A dated caveat is filed at `two_jup/rtl_cfo_repro/CAVEAT_CADENCE.md`;
that campaign's existing files are left untouched.

## 6. Where the slip actually goes — and why mod-32 is the right period for the wrong reason

**Measured.** Pushes exceed pops by exactly `12333·s` per frame, so occupancy steps once
every `1/(12333·s)` frames:

| leg | s (ppm) | predicted frames/occupancy step | measured steps in 159 frames | measured mean spacing |
|---|---|---|---|---|
| `r_p000` | 0 | ∞ | 0 | — |
| `r_p063` | +0.63 | 128.7 | 1 | — (too few) |
| `r_p126` | +1.26 | 64.4 | 2 | 64 |
| `r_p10` | +10 | **8.11** | **20** | **8.105** |

`r_p10`'s step spacings are `8,8,8,8,8,8,8,8,9,8,8,8,8,8,8,8,8,9,8` — the occupancy model
is confirmed to the frame, and the scaling across legs is linear in s.

**Therefore, at 0.63 ppm the `Rate_Handle` ring's own period is 128.7 frames, not 32.**
`COMB32_RTL_HUNT.md` §2 #1 derived 32 from the beat rule `12333 ≡ 13 (mod 32)`, which
tracks the **pointer phase**. The pointer phase does return every 32 frames — that part of
the arithmetic is correct. But pushes and pops advance in lockstep (12,333 each per frame,
measured), so both pointers sweep the ring together and **[inferred]** only the
*difference* — occupancy — can cause a push to overwrite an unpopped entry or a pop to read
an unwritten one. Occupancy beats at `1/(12333·s)` = 128.7 frames at 0.63 ppm. The mod-32
structure is real, unique in the design, and unguarded, but the 32-frame period it
generates is a phase that does not corrupt anything.

**What remains untested.** No leg reached a wrap. Extrapolating the measured drift rate:
`(32−5)/0.0078 ≈ 3,500` frames to overflow at +0.63 ppm; `5/0.0078 ≈ 640` frames to
underflow at −0.63 ppm (`r_m063` is already trending the right way, 5 → 3). Neither is 32,
but neither was reached, so *what the unguarded ring does at a wrap* is an open question
this simulation does not answer.

**Not pursued.** A ±40 ppm accelerated leg would cross ~3 wraps inside 165 frames and
settle it cheaply. It is **not run**, on operator direction: the on-air T3 measurement
bounds |SRO| ≤ 0.06 ppm and puts the comb period at 26.0 ms = 32.4 frames, which closes
the SRO → symbol-sync path on silicon [silicon, per the T3 report — relayed to this desk,
not independently verified here]. At ≤ 0.06 ppm the occupancy period would be ≥ 1,350
frames and the first wrap ≥ 36,000 frames away, so the ring cannot produce a 32-frame comb
at the SRO the hardware actually has.

## 7. Labelled observation, mechanism not established

The strobe-interval-≠4 count is **777.7/frame at s = 0** but only ~27/frame on every
offset leg (89/frame on the noisy leg), i.e. the control dithers ~29× *more* than the
offset legs. Whatever drives this, it is not the interpolator ±1 slip event, so this
metric is not the clean coincidence observable it was intended to be — the occupancy step
is. **No explanation is offered here**; it is recorded so the next reader does not mistake
the anomaly count for a slip census.

## 8. Scope limits bounding the NOT REPRODUCED verdict

1. **159 scored frames ≈ 5 comb periods.** A mechanism with a period much longer than 32
   frames, or one that needs a long lock history, would not appear.
2. **Every air frame is byte-identical** — one tiled 49,332-sample BIST ROM period. Any
   loss mechanism that depends on payload content, or on frame-to-frame variation in the
   preamble correlation, **cannot** appear in this simulation.
3. **Only one leg carried RF-like impairment** (15 dB Es/N0 + 1.26 kHz CFO); the other
   five are noiseless and CFO-free. No multipath, no AGC transients, no LO phase noise.
4. **The FIFO wrap is untested** (§6).
5. The RX is fed a perfectly continuous stream with no gaps; the delivery plane
   (`byte_rx_ready` back-pressure) was held asserted throughout.

These bounds are why the silicon 32-frame comb remains an **open question** rather than a
contradiction: this run rules out the SRO → symbol-synchronizer path at ±0.63/±1.26 ppm,
it does not rule out the comb. With the T3 on-air bound in §6, the SRO reading is closed
from both ends — desk and silicon — and the campaign should return to the surviving
candidates in `COMB_STATE.md` §"Where are the frames dropped?".

## 9. Raw outputs

`two_jup/comb/sro_sim/r_<tag>_{deliv,frames,anom,res}.txt` — per delivered frame
(`sidx,nwords,hash,user`), per air-frame bucket
(`f,pushes,pops,occ_start,occ_end,n_strobe_anom,mu_min,mu_max,und`), per strobe-interval
anomaly (`sidx,interval,frame`), and the final register summary. The `.iq` stimulus files
and `tx5.iq` are regenerable from §2 and are **not** committed.
