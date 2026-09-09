# TX_SEL8_DESK — does 148's TRANSMITTED baseband already carry the 32-frame comb?

Desk analysis, no board contact. Capture:
`two_jup/comb/runs/20260904_043231_sel8_tx148/sel8_leg.bin` (512 MiB, DDRCAP-v2
selector 8 = `Transmitter_dataOutI/Q`, the RRC-filtered modulator output) taken on
148 at 04:32 on 2026-09-04 while 148 transmitted the TGEN byte stream at GAP=45,000
(every air slot filled, no filler) — the same stream whose loss was reproduced
fabric-only at 04:03 / 04:19 (`OVERNIGHT_20260904_SEQBIST.md`).

New scripts: `two_jup/comb/tx_sel8_desk/sel8_base.py` (time base, mark census, Barker
offset scan), `sel8_frames.py` (per-frame metrics + coded bits).
Labels: **[silicon]** = measured in this capture, **[netlist]** = read from the built
Verilog, **[inferred]** = reasoning on top.

---

## VERDICT

> **TX CLEAN (bounds below) — and one RECEIVER-side 32-frame-periodic finding [silicon].**
>
> The transmitted baseband shows **no** periodic anomaly. The 13-symbol Barker preamble
> is bit-perfect on **1,312 / 1,312** evaluable frames (correlation 0.9992, min = max);
> frame power, EVM proxy, near-zero count and preamble amplitude are flat to <0.5 % with
> autocorrelation at every lag 1…128 **below** the permutation null; the coded bit stream
> shows no repeat at lag 8, 32 or anywhere else (Hamming 0.494 flat, PN baseline 0.5).
>
> The **only** 32-frame-periodic phenomenon in the capture is in the RECEIVE chain of the
> same board: the mod-12333 counter `Peak_Search.timing_Reference` (`tref`, which
> `RX_WINDOW_RTL.md` identifies as *the* free-running frame-detection epoch) **fails to
> advance for one local symbol period 48 times** in 1.5 s — a symbol-synchronizer /
> interpolator **deletion** at **1 per 31.94 frames = 2.53 ppm**, one-sided (48 events of
> `Δtref = 0`, **zero** of `Δtref = 2`). Autocorrelation of the event series: **lag 32 =
> +0.824** against a permutation null p95 of 0.136, harmonics at 64/96/128, fine
> trial-period argmax **31.94 frames**. The mission-link comb is 32.24 emitted frames
> (26 ms, 04:19).
>
> So on the brief's fork — TX fabric vs air/receiver — this capture says **not the TX
> fabric**, and points at the receiver's timing recovery.
>
> **The deletion reproduces on a second, independent capture at the same rate [silicon].**
> Re-run on `runs/20260903_192933_legA_a2/ddrcap_sel13b/sel13_leg.bin` (09-03, sel13,
> live leg A, a different day and a different selector): the same strictly one-sided
> census (39 deletions, **zero** insertions) and a drop-robust drift slope of
> **2.506 ppm = 1 symbol per 32.35 frames**, against **2.572 ppm = 1 per 31.52 frames**
> here — a 3 % agreement (§6).
>
> **It is a rig STATE, not a permanent property [silicon].** The 09-02 captures
> `beatcap/20260902_192051_sel13/{mid,onset}.bin` — the very files `SRO_SEL13_DESK.md`
> used — have **exactly zero** deletions (0 in 1,890 / 1,881 frames) *and* a perfectly
> quiet interpolator (`I[15]` = exactly 1 strobe on **all** 16,711,686 drop-free symbol
> groups). So `SRO_SEL13_DESK.md` is **confirmed, not contradicted**: on 09-02 there
> genuinely was no offset. The deletion appears between 09-02 and 09-03 and is then
> stable across 09-03 and 09-04.
>
> **Leading explanation [inferred, untested]:** 09-02 was a zero-offset state (plausibly
> the receiver on its own transmitter, `rx_input_select`/reg `0x114` = 0, which shares the
> clock exactly and would give precisely the observed zero jitter), while 09-03/09-04 were
> real two-crystal over-air legs. On that reading **2.5 ppm is the ordinary inter-node
> clock offset, not a fault** — the fault is *how the receiver absorbs it* (§6).
>
> **Stage localisation is suggestive, not conclusive [silicon].** On `legA_a2` the
> interpolator strobe nets **−30 ± 114 (0.0 ± 1.3 ppm)** over drop-free groups while
> `tref` loses 39 symbols one-sidedly (2.5 ppm) — a ~2 σ gap, so the interpolator is
> *disfavoured* as the site but not excluded.

---

## 0. Corrections to the brief's capture arithmetic [silicon]

| quantity | brief | measured |
|---|---|---|
| records | 33.5 M | **67,108,864** (8 B/record, 1 record per **sample**) |
| samples/symbol | "per sample or per symbol" | **4** (`tref` advances exactly 1 per 4-record group) |
| samples/frame | — | 12,333 × 4 = **49,332** |
| air frames spanned | ~1,600 | **1,870** (`tref` span 23,082,674 symbols) |
| wall time | 1.3 s | **~1.50 s** of air time; ~1.09 s of it captured |
| comb periods | 50 | **~58** |
| DMA record loss | "≈0.2 %" | 0.195 % of symbol steps are drop *events*, median **151 symbols** each → **27.3 % of the span missing**, in bursts (matches `SRO_SEL13_DESK.md`'s 28.0 %) |

`ddrcap2_pc.py --sel 8` re-run here: all gates PASS except `toff_range_steady` (`toff`
takes only the two values 489 and 521, 32 symbols apart — the receiver's timing offset,
unrelated to the TX tap). `tref_cadence` PASS at 0.9980.

## 1. Time base — and why it is a *receiver* clock [netlist]

The two sidecar fields are in **different clock domains**, which is the crux of this
document:

- `slot` = `ddrcap2_slot_r`, a free-running mod-4 counter incremented on every
  `ddrcap_valid_beat` under `enb_1_2_0`; for sel8 `valid_beat == enb_1_2_0`, so `slot`
  is the **local fabric sample phase** (`skidfix/ddrcap2_inject.py:238-263`).
- `tref` = `Receiver_ddrcap_dc_tref` = `Peak_Search.timing_Reference_out1`, a mod-12333
  counter (`count to value = 12332`) that advances **only on `validIn`**
  (`TxRxCompo_ip_src_Peak_Search.v:79-107`). Its valid chain is
  `Symbol_Synchronizer.validOut → Coarse_Frequency_Compensator → Carrier_Synchronizer
  → Preamble_Detector → Correlator.validOut → Peak_Search.validIn`
  (`Frequency_and_Time_Synchronizer.v:176-232`, `Preamble_Detector.v:187-201`). So `tref`
  counts **recovered symbols out of the timing-recovery interpolator**, not local symbols.

The analysis time base is `sample_time = 4·unwrapped(tref) + slot`, with a record given a
time only when its own 4-record group is intact. It is therefore a *recovered-symbol*
base, and any interpolator deletion appears in it as a 4-sample step. Record **index** is
never used (27 % of records are gone).

`mark_fec` = `Transmitter_txFrameStart` = `Bit_Packetizer_dataStart`, which fires at
`sampleCount == 26` — the first *data* bit, 13 symbols after the preamble starts
[netlist: `Bit_Packetizer.v` + `Compare_To_Constant_block1.v` `15'b…11010` = 26; `dataEnd`
at `15'b110000001011001` = 24,665 → 24,666 bits = 12,333 symbols/frame]. For sel8 the
instrument's sticky-marker latch never engages (`ddrcap_valid_beat == enb_1_2_0`), so a
mark's record index is exact [netlist: `skidfix/ddrcap_inject.py:520-550`].

## 2. Mark census and the −1-symbol steps [silicon]

- 1,340 `mark_fec` pulses, 1,338 usable. **No extra marks, no in-frame doublets.**
- Mark-to-mark gap histogram: 1×933, 2×306, 3×76, 4×17, 5×2, 6×3 frames. 532 of 1,870
  frame slots have no captured mark = 28.4 %, matching the independently measured 27.3 %
  record loss. **[inferred, from that rate agreement]** the missing marks are DMA drops,
  not missing pulses; this was not checked pulse-by-pulse (drops remove whole multiples of
  4 records, so a dropped burst leaves no local signature to test against).
- Against the `tref` base the TX mark's in-epoch residual decreases **monotonically**, in
  **exactly one step size, −4 samples (= −1 recovered symbol), 59 times over 1,869
  frames**, with **no** events at −1/−2/−3 samples and no reversals:

```
drift slope        -0.12524 samples/frame = -0.031310 symbols/frame   (1/32 = 0.031250)
1 symbol per       31.94 frames = 25.6 ms = 2.53 ppm
slip spacing hist  30×2, 31×11, 32×36, 33×7, 34×2   (modal 32)
residual range     0 -> -236 samples, monotone
```

Control: the receiver's own `mark_demod`, timed in the same base, shows **no** monotone
drift (residual bounded 0…128 samples; its jitter steps are ±128 samples = ±32 symbols,
the `toff` spread). `mark_demod` is generated downstream of the same interpolator as
`tref`, so it moves *with* `tref` — which is the first hint that the drift belongs to
`tref` and not to the transmitter.

(`mark_fec` lands on `slot == 3` in 1,340/1,340 cases and `mark_demod` on `slot == 1` in
1,364/1,364. That is expected of any once-per-symbol signal against a mod-4 sample-phase
counter and is **not** discriminating; it only says TX frame lengths are multiples of 4
samples.)

## 3. Which side slipped — the decisive test [silicon]

`tref` advances on recovered symbols; `slot` on local samples. If the two rates differ, a
4-record group will occasionally show `Δtref ≠ 1`. Census over all 16,777,215
consecutive slot-1 pairs:

| Δtref | count |
|---|---|
| **0** | **48** |
| 1 | 16,744,403 |
| **2** | **0** |
| >2 (DMA drop bursts, median 151) | 32,764 |

**One-sided: 48 deletions, zero insertions.** And the coincidence is exact:

- **48 of 48** `Δtref = 0` events fall inside a mark-residual slip interval;
- **48 of 61** slip intervals contain an observed `Δtref = 0` event — the other 13 have
  their event inside a dropped burst (27 % blind → 61 × 0.73 ≈ 44 expected observable,
  48 seen);
- the `Δtref = 0` events' mod-32 frame phase is concentrated in bins 13–18, the same
  window as the slips.

**Therefore every observed −1-symbol step is accounted for by `tref` failing to advance,
i.e. by a symbol deleted in 148's receive timing recovery. None is left over to charge to
the transmitter.** The apparently mark-independent "baseband preamble spacing"
(`{49332: 864, 49328: 30}` over adjacent frame pairs) is *not* independent — it was
measured in the same `tref` base and carries the same artefact.

Direction: `tref` runs **slow** relative to 148's local frame rate by 2.53 ppm, i.e. the
recovered symbol stream is slightly slower than local/4 and the interpolator drops one
symbol per ~32 frames. This is the deletion class in the memory note
"H-1 SRO deletion episodes", now measured directly rather than inferred.

## 4. Per-frame TX baseband metrics [silicon]

Sampling phase and modulator+RRC group delay were fixed by a 2-D scan over
(phase 0..3, offset −320…+320 samples) maximising aggregate 13-symbol Barker correlation
over 400 marks. **Positive control for the whole preamble method: a single sharp argmax at
offset −15 samples, score 0.9992, best non-adjacent runner-up 0.6921, median 0.2507.**
Preamble from `TxRxCompo_ip_src_Preamble_Bits_Store.v`: LUT bits 0…25 =
`1111111111 0000 1111 0011 0011` = Barker-13 `+++++--++-+-+`, each chip sent as a bit
*pair* (I and Q together) [netlist].

Over 1,338 frames (metrics on present samples only; per-frame present count kept as a
covariate):

| metric | mean | sd | note |
|---|---|---|---|
| preamble Barker correlation at the mark | **0.9992** | **0** (min = max, n = 1,312) | bit-perfect on every evaluable frame |
| frame mean \|z\| | 9,356.1 | 14.6 (0.16 %) | |
| EVM proxy (4th-power derotated) | 0.14151 | 0.00055 (0.4 %) | RRC/sampling-phase floor, flat |
| near-zero samples (\|z\| < 0.3·mean) | **0** | 0 | degenerate — no dropouts |
| preamble/frame amplitude ratio | 1.0022 | 0.0016 | |
| present samples per frame (covariate) | 9,075 | 906 | |

The 26 frames (1.94 %) whose Barker peak fell below 0.9 are exactly the frames whose
13-symbol preamble window contained a dropped sample; every frame with a *complete*
window scores 0.9992.

**Falsified sub-hypothesis [silicon].** `Preamble_Bits_Store` substitutes 26 constant `1`
bits for the Barker whenever `actualPreamble == 0`, i.e. when `Data_Bits_FIFO`'s
`activeFrame` is low at the previous frame's `dataEnd` [netlist] — the signature the known
~5 % TX ByteWordBuffer starvation would leave (all-ones correlates 1/13 ≈ 0.077 against
Barker-13). **Zero such frames: 0 / 1,312, 95 % upper bound 0.23 %.** TX starvation is not
malforming preambles in this stream.

Slip frames are otherwise indistinguishable from the rest: power 9,354.8 vs 9,356.2, EVM
0.14141 vs 0.14151, preamble correlation 0.9992 on all 59 evaluable slip frames — as
expected once the slip is understood to be a receiver-side counter event.

## 5. Autocorrelation, folding, and data periodicity [silicon]

Lags 1…128, mean-subtracted / zero-filled / pair-count-normalised, permutation null = 95th
percentile of the per-shuffle max |ac| over 200 shuffles (family-wise), plus a fine
trial-period scan (folded-bin variance, periods 6…40 in 0.02 steps) — needed because the
receiver comb is 32.24, not 32, and an integer-lag ACF can read null on a drifting period.

```
series       null(p95)  lag8     lag16    lag32     lag64    fine-scan argmax
slip/deletion 0.1360   -0.0438  -0.0475  +0.8243  +0.7882   31.94   <-- + 96/128 harmonics
meanabs       0.1162   +0.0153  +0.0002  -0.0147  +0.0534   32.96 (score 2.4 ~ null)
evm           0.1131   +0.0198  -0.0289  +0.0555  -0.0208   38.08
pre_amp       0.1170   +0.0241  +0.0149  -0.0173  +0.0534   32.96
pk_val        0.1804   +0.0205  +0.0261  +0.0522  -0.0165   35.16
npresent      0.1371   -0.0430  +0.0018  -0.0289  -0.0045   28.58   (DMA drop covariate)
nzero         DEGENERATE (identically 0)
MASK-CTRL              -0.0392            +0.0093            —
```

Only the deletion series exceeds its null, and by a wide margin. Both drop-pattern
controls are clean (MASK-CTRL +0.009 at lag 32; `npresent` −0.029), so the
ByteRxFifo/S2MM drop pattern is not manufacturing the peak. **No 8-frame structure exists
in any series** — the 8-frame base seen at the receiver at 04:03 has no counterpart here.

**Data content [silicon].** The TX baseband is noiseless, so hard decisions *are* the
transmitted coded bits. First 256 data symbols = 512 coded bits, 661 frames with a fully
captured window. Hamming distance between frame *k* and *k+lag*, lags 1…40, 48, 64, 96,
128: mean 0.4936, sd across lags 0.0038; **lag 8 = 0.4930, lag 32 = 0.4996** — both at the
PN baseline. Global minimum over ~9,000 pairs: 0.3906, so **no near-repeat anywhere** (the
stale-FIFO replay signature a starvation event would leave is absent). Only 4 of 512 coded
bit positions are constant across frames (0, 2, 8, 11) — the residue of the fixed
`0x51 0x4B` magic through the K=5 rate-1/2 encoder. Adjacent frames differ in 49.2 % of
coded bits, so the PN payload really is reaching the modulator (premise check: PASS).
Viterbi/descrambler decoding was not attempted and is not needed for this question.

## 6. Reproduction, the 09-02 control, and where the symbol is lost [silicon]

`comb/tx_sel8_desk/dtref_census.py` runs the census; it was applied to the only other
DDRCAP-v2 capture on this desk carrying the `tref` sidecar,
`comb/runs/20260903_192933_legA_a2/ddrcap_sel13b/sel13_leg.bin` (09-03 19:29, sel13,
live leg A forward, 512 MiB).

| | 09-04 sel8 (this capture) | 09-03 sel13 legA_a2 |
|---|---|---|
| `Δtref = 0` (deletions) observed | **48** | **39** |
| `Δtref = 2` (insertions) observed | **0** | **0** |
| `Δtref = 1` | 16,744,403 | 16,744,412 |
| span | 1,871.6 frames | 1,908.9 frames |
| DMA drop bursts / median | 32,764 / 151 sym | 32,764 / 163 sym |
| **drop-robust drift slope** | **−0.12690 samples/frame** | **−0.12365 samples/frame** |
| **rate** | **2.572 ppm = 1 per 31.52 frames** | **2.506 ppm = 1 per 32.35 frames** |
| mark-residual −4 steps | 61 over 1,869 frames | 59 over 1,907 frames |

Use the **drift slope**, not the raw deletion count, to compare rates: ~27 % of symbol
groups are inside a dropped burst, so the observed count undercounts by that factor
(48 / 0.73 ≈ 66 ≈ the 61 mark steps). The naive count ratio is what made an earlier
revision of this document report "48.95 frames" for 09-03 and conclude the period was
unstable; that conclusion is **retracted**. On the drop-robust measure the two captures
agree to 3 %, on different days and different selectors, and both sit on the comb's
32.24-frame period.

### 6a. The 09-02 control: zero offset, and `SRO_SEL13_DESK.md` confirmed [silicon]

`beatcap/20260902_192051_sel13/{mid,onset}.bin` — the files `SRO_SEL13_DESK.md` analysed —
were located and censused:

| | 09-02 mid | 09-02 onset | 09-03 legA_a2 | 09-04 sel8 |
|---|---|---|---|---|
| span (frames) | 1,890.2 | 1,881.4 | 1,908.9 | 1,871.6 |
| `Δtref = 0` | **0** | **0** | 39 | 48 |
| `Δtref = 2` | 0 | 0 | 0 | 0 |
| deletion rate | **0.000 ppm** | **0.000 ppm** | 2.506 ppm | 2.572 ppm |
| `I[15]` per drop-free group | **{1: 16,711,686}** | **{1: 16,711,686}** | {0: 6,540, 1: 16,698,558, 2: 6,510} | n/a (sel8) |
| `I[15]` net | +0 (±0.043 ppm) | +0 (±0.043 ppm) | −30 (±1.3 ppm) | n/a |

**`SRO_SEL13_DESK.md` is confirmed, not contradicted.** Its `mark_fec`-interval claim
(exactly 12,333 in 1,224 consecutive frames, |SRO| < 0.066 ppm) is exactly right *for
those files*: they contain zero deletions. The deletion is a **state the rig enters
between 09-02 and 09-03**, then holds across 09-03 and 09-04.

Two corrections to that document and to the previous revision of this one, both from the
same cause: **a DMA burst removes a whole multiple of 4 records, so record contiguity
(`rg == 4`) does not exclude a group that straddles a drop.** Filtering on it alone
manufactures balanced-looking ±1 pairs at the ~32,764 drop boundaries. The correct filter
also requires `Δtref == 1` on both sides. With it, `SRO_SEL13_DESK.md`'s "511 zeros /
477 twos" on `mid.bin` and this document's earlier "8,168 / 8,064" on `legA_a2` both
disappear: `mid.bin` has **no** ±1 strobe events at all, and `legA_a2` has 6,540 / 6,510.
(The unfiltered run reproduces 511 zeros on `mid.bin` exactly, which is what identifies
drop contamination as the shared cause.)

**Explanation — confirmed independently.** A crystal offset does not switch on. The
09-02 run was a **digital loopback** on 148, per `comb/DTREF_CENSUS_CONTROLS.md` §1,
which censused the same two files concurrently and reached the same 0.000 ppm. A loopback
shares the clock exactly, so zero offset and zero interpolator jitter are the *expected*
signature, and 09-03/09-04 were real two-crystal over-air legs. **2.5 ppm is therefore the
ordinary inter-node clock offset, not a fault** — the defect is how the receiver absorbs
it.

### 6b. Where the symbol is lost — suggestive, not settled [silicon]

sel13 carries the interpolator underflow strobe in `I[15]`, so `legA_a2` supports both
censuses on the same drop-free groups:

```
I[15] per drop-free group: {0: 6,540, 1: 16,698,558, 2: 6,510}
                           net (2s-0s) = -30, random-walk sigma 114  ->  0.0 +- 1.3 ppm
tref, same file:           {0: 39, 2: 0}  strictly one-sided        ->  2.5 ppm
```

The interpolator jitters ±1 about 13,000 times and nets **zero to within ±1.3 ppm**, while
`tref` loses symbols one-sidedly at 2.5 ppm. The two differ by ~2 σ of the `I[15]` noise,
so the interpolator is **disfavoured** as the site — the loss more likely happens
downstream, in the valid chain `Symbol_Synchronizer.validOut → Coarse_Frequency_Compensator
→ Carrier_Synchronizer → Preamble_Detector → Correlator.validOut` [netlist:
`Frequency_and_Time_Synchronizer.v:176-232`, `Preamble_Detector.v:187-201`]. **A symbol
whose valid is swallowed there is a symbol the correlator and the packet controller never
see**, shifting the frame's symbol content by one [inferred]. But ±1.3 ppm is not tight
enough to exclude the interpolator at 2.5 ppm with confidence; a longer sel13 capture, or
the ILA in step 4, is needed to settle it.

**Cross-reference: this resolves the open point flagged against the sim.**
`OVERNIGHT_20260904_SEQBIST.md` 06:1x records the −10 ppm sim reproducing the deletion and
notes as unresolved that *"the sim's deficit originates at the interpolator strobe while
the silicon sel8 census saw the strobe balanced (sensitivity-limited)"*. That tension is
now removed, from both ends:

- **The "balanced" silicon numbers were an artefact.** Both this document's earlier
  8,168/8,064 and `DTREF_CENSUS_CONTROLS.md` §1's `mid` figure of
  `{0: 511, 1: 16,749,579, 2: 2,580}` come from filtering on record contiguity alone.
  With the drop-free filter, `mid.bin` has **{1: 16,711,686}** — not a "quiet
  interpolator" but a *perfectly silent* one, zero ±1 events — and `legA_a2` has
  6,540/6,510.
- **The corrected balance does not exclude an interpolator origin.** `legA_a2`'s strobe
  nets 0.0 ± 1.3 ppm against a 2.5 ppm deletion — a ~2 σ gap. That is "disfavoured", not
  "excluded", so the sim's interpolator-origin deficit is **compatible** with the silicon.
  The two do not need reconciling; the silicon is simply not yet sensitive enough to
  arbitrate, and step 4 below is what would.

**A result that limits the causal claim [silicon].** The 09-02 run was armed and receiving
at fps = 1,247 with `errps` ≈ 100/s ≈ 8 % loss — the usual rate — while having **zero**
deletions. So the deletion **cannot** be the mechanism for the bulk 5–8 % loss. It could
still be the mechanism for the *32-frame comb component* specifically, but that is not
testable on the 09-02 files: their only loss record is `errps.csv` at **1 Hz**, far too
coarse for a 26 ms period (`SRO_SEL13_DESK.md` §5).

**Falsifiable prediction [inferred].** 2.53 ppm and 32 frames are the same number:
1 / (12,333 × 32) = 2.53e-6. If this deletion is the comb, then **the comb period must
track the inter-node clock offset** — change the offset (different reference, retune, a
different board pairing) and the comb period must move as 1/ppm/12,333 frames, not stay
at 32. That is a cheap and decisive rig test, and it is the one this document argues for.

Next steps, in order:
1. **Desk, no rig:** re-run the `--i15` census with the drop-free filter wherever the
   unfiltered one was used — `DTREF_CENSUS_CONTROLS.md` §1 carries the contaminated
   `{0: 511, 2: 2,580}` figure for `mid.bin`.
2. **Desk, no rig:** run `dtref_census.py` across every archived DDRCAP-v2 capture and
   plot rate vs the run's measured comb period — the prediction above, testable on data
   already on disk.
3. **Rig:** deliberately offset one board's reference and check that the comb period moves
   as predicted.
4. **Rig/RTL:** an ILA (or a new DDRCAP selector) on the four valids between
   `Symbol_Synchronizer.validOut` and `Correlator.validOut` to name the stage that
   swallows the beat.

## 7. Limits

- 27.3 % of the span is missing in bursts; only 1,338 of 1,870 frames have a timed mark.
  The deletion *rate* comes from the residual staircase (drop-robust); the 48 directly
  observed events are the visible ~73 %.
- **The transmitter's frame length in *local* samples was not measured directly.** The
  only available time base is `tref`, a receiver clock; `mark_fec` record-index differences
  are unusable (all 1,339 pairs straddle a dropped burst, none equals 49,332). The bound
  is instead by subtraction: **61 mark-residual steps, 48 of them carrying an observed
  `Δtref = 0`, leaves at most 13 unattributed over 1,869 frames — any TX frame-length
  anomaly is < 1 per 144 frames**, and those 13 are exactly the count expected to fall in
  the 27 % blind fraction, so 144 is a floor on the bound, not an estimate of a residual.
- `tref` unwrap assumes no drop gap ≥ 12,333 symbols; max observed 11,280. Within bounds,
  not by much.
- Two of 1,340 marks produced a ±920-sample residual outlier and were excluded (consistent
  with an unwrap miss across a long drop).
- 31.52 / 32.35 frames (deletion, two captures) vs 32.24 frames (receiver comb) agree to
  ~2 %. The 32.24 comes from a *loss-interval* histogram (`int_32` 2,458 / `int_33` 440),
  which missed detections inflate; the deletion figures are drift-slope measurements. The
  agreement is strong, but it remains an **association**: no frame-level coincidence
  between a deletion event and a lost frame has been measured (the instrument ships no
  per-frame loss marker — `SRO_SEL13_DESK.md` §5). The §6 prediction is the way to make it
  causal — but note §6b: the 09-02 run had the usual ~8 % loss with **zero** deletions, so
  at most the 32-frame comb *component* can be attributed here, never the bulk loss.
- Board 146 was not captured; only 148's TX and 148's receive timing are covered.
- Provenance-insensitive: `TxRxCompo_ip_src_Preamble_Bits_Store.v` is byte-identical
  (md5 `00c79587d51943a9d7649c64c92f8c63`) and the 26 / 24,665 frame constants are identical
  across `jupiter_byte_ddrcap2_build`, `jupiter_byte_txfixF3_build` and
  `jupiter_byte_final_build`, so the RTL claims hold for whichever of these is flashed.
