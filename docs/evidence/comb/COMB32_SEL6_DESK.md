> Evidence ledger, moved verbatim from `two_jup/comb/COMB32_SEL6_DESK.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# COMB32 / sel6 desk analysis — is the 32-frame comb visible at the demodulator input on 148?

Date 2026-09-03 · desk only, no board contact · CPU ≈ 40 s of compute (well inside the 40-min budget)
Data: `two_jup/beatcap/20260902_185552_sel6/{mid,onset}.bin` (2 × 512 MiB, DDRCAP-v2 sel6).
`two_jup/beatcap/20260902_184821_sel6/` contains **no .bin at all** — that run aborted at
`ABORT mid: capTAP 0xD71F70D3 != golden` (its `run.log`), so only one capture pair exists.
Scripts written for this analysis: `two_jup/comb/comb32_sel6_desk/{frame_metrics.py,
comb32_autocorr.py,comb32_period.py,fold32_profile.py}`; outputs `*_frames.npz`, `ac_all.json`,
`period32.json`, `*_fold32.npz` in the same directory.

## VERDICT

**ABSENT at the demodulator input, with a tight sensitivity bound — and INCONCLUSIVE for
anything upstream of the RX loops.**

No periodic disturbance of period 32 frames (25.72 ms) exists in the received constellation on
either capture. Across **10,694 clean frames / 131,750,080 symbols / ≈334 comb periods**
[silicon] the strongest deviation of any single symbol from its ideal QPSK point is **0.0696**
in units where the decision boundary is at 0.7071 — a **20.1 dB margin, never approached**;
there are **zero** near-zero samples and **zero** hard-decision errors. Every per-frame metric's
period-32 spectral line is at or below the local floor and **does not reproduce between the two
captures**; the only strong periodicities present are at **14, 16 and 12 frames and their
harmonics**, which track the transmitted payload's own repetition (§5) and are the reason a
naive lag-32/64 autocorrelation looks elevated (16 divides 32, so a period-16 line folds
perfectly into any mod-32 test).

**The bound that answers the actual hypothesis.** The host-side comb is *impulsive* — singles and
doubles, one bad frame in 32, with harmonics at 64/96/128 — not a sinusoid. An impulse train
spreads its power across all 32 harmonics, so the period-32 periodogram bin is the **weakest**
place to look; the correct detector is the mod-32 epoch fold of §6, where a once-per-32 frame
class contributes to one phase row in full. Across the 32 phase rows (153–171 frames each) the
whole-frame mean symbol error varies by only **0.61 % (mid) / 0.54 % (onset) rms**, largest single
row deviation 1.56 % / 0.97 % [silicon]:

* **a once-per-32-frames disturbance that raised the affected frame's mean symbol error by
  ≳ 1.8 % (mid) / 1.6 % (onset) — 3 σ — would have been detected. None is.**
* a disturbance confined to a **short burst inside the frame** is bounded much more weakly: the
  64-symbol-smoothed profile reaches |z| = 3.9–4.1 on noise alone, so a burst of ≤64 symbols
  would need to raise the local mean error by **≈40 %** to stand out (§6). Short-burst
  sensitivity is the weak flank of this analysis; the whole-frame flank is tight.

Amplitude bounds on a *sinusoidal* period-32 modulation, for completeness [silicon,
`comb32_period.py`, worse of the two files; ~20 % optimistic because at n ≈ 5,330 period 32 lands
≈0.56 bins off-grid, so real off-bin amplitudes need to be ~1.2× larger to be seen]:

| observable | 5σ-detectable period-32 sinusoid | as a fraction of the mean |
|---|---|---|
| mean \|IQ\| (power) | 1.33 counts of 16,370 | **0.008 %** power modulation |
| EVM (rms distance to ideal) | 1.9 × 10⁻⁵ of 0.0105 | **0.18 %** of the EVM |
| 99.9-pct symbol error | 5.7 × 10⁻⁵ of 0.044 | 0.13 % |
| frame-head EVM (first 256 symbols) | 2.8 × 10⁻⁵ of 0.0086 | 0.33 % |
| intra-frame phase rate | 2.1 × 10⁻¹⁰ rad/symbol | 2.6 µrad accumulated over a frame |

(The zero near-zero samples in 131.75 M symbols is *not* an independent bound of the same
strength: on an amplitude-normalised tap it mainly confirms the AGC never lost lock. The zero
hard-decision errors and the 0.0696 worst-symbol figure are the load-bearing ones.
The `head_evm` window is not anchored to the real header position — the 2,240-bit payload's
location inside 12,333 symbols is not known from these files — but §6 scans all 12,320 symbol
positions at all 32 phases, so the head window is subsumed by it rather than relied on.)

**Scope, and why this is not closure.** sel6 is `Receiver_ddrcap_constpts_re/im` with
`valid = Receiver_ddrcap_symvalid` (`two_jup/skidfix/ddrcap_inject.py:432-473`) — the
constellation points **after** AGC, symbol sync and carrier sync, i.e. the *slicer input*, not
the raw demod input. It is amplitude-normalised (\|z\| = 16,370 ± 122, ≈2¹⁴) and phase-tracked.
This is structurally the same trap `SRO_SEL13_DESK.md` §4 diagnosed in itself: a post-loop
observable. A slow power or phase disturbance is regulated away before it reaches this tap.
What the loops **cannot** hide inside one frame is a deleted/duplicated symbol or a decision
error, and there are none of those. So:
* **ABSENT at the slicer input** is the supported claim.
* **INCONCLUSIVE for the analog/pre-loop domain** (raw ADC, AGC, RRC, symbol-sync input —
  sel0/sel1/sel2/sel3). A 32-frame disturbance that the loops absorb would be invisible here.

**The result that moves the campaign:** the air-side signal reaching the slicer is essentially
perfect (EVM 1.05 %, ≈39 dB, zero symbol errors in 131.75 M symbols), while 148's own BIST error
counter was running 51–153 err/s throughout the same arm and 63,602 err/s at the trigger sample
(`errps.csv`). Bit errors that the constellation cannot account for localise the damage
**downstream of the slicer** — deframing / alignment / delivery — which is where the
"84 % magic-bad (garbage header)" host observation already points. Nothing at the slicer input
combs at 32 frames, and nothing at the slicer input is even damaged.

---

## 1. Record layout actually found [silicon] — different from the task's assumption

```
python3 two_jup/ddrcap2_decode.py two_jup/beatcap/20260902_185552_sel6/mid.bin --summary
python3 two_jup/comb/comb32_sel6_desk/frame_metrics.py \
        two_jup/beatcap/20260902_185552_sel6/mid.bin  two_jup/comb/comb32_sel6_desk/mid_frames.npz
```

| quantity | mid.bin | onset.bin |
|---|---|---|
| records (512 MiB / 8 B) | 67,108,864 | 67,108,864 |
| records per symbol | **1** (sel6 valid = `symvalid`; slot cycles 0,1,2,3 → tref advances 1/record) | 1 |
| records per frame | **12,320** (frame = 12,333 tref units; 13 symbols are idle at the boundary) | 12,320 |
| `mark_demod` pulses | 5,446 | 5,445 |
| `mark_fec` pulses | 5,449 (incl. 4 spurious doubles at 60/12,273) | 5,450 (5 doubles) |
| frame ordinals spanned | **5,461** | 5,463 |
| clean frames (full 12,320-record body) | **5,350** | 5,344 |
| span | 67,338,180 symbols = **4.384 s ≈ 171 comb periods** | 67,362,846 = 4.386 s |
| records lost at the rx2 DMA | **≈1.4 %** (95 anomalous intervals) | ≈1.5 % (100) |
| `toff` (ch2[13:0]) | single value 12314 everywhere | 12314 |

Two corrections to the task brief, both material: the captures are **4.38 s and ~5,460 frames
each (3× the assumed 1.5 s / 1,900 frames)**, and the sel6 drop rate is **1.4 %, not the 20–40 %
of the enb-domain taps** — sel6 runs at symbol rate, so the rx2 DMA keeps up. Frame ordinals are
nevertheless derived from unwrapped `tref`, never from record position, with a hard assert that
every `mark_demod` lands on an exact multiple of 12,333 (it does, on all 10,891 marks).
`toff` carries a single value in both files: **no information available from that field** (not a
null result), consistent with the §82 finding that the `tOff` latch holds.

## 2. Per-frame QPSK metrics [silicon] — task item (1)

Per clean frame (12,320 symbols): mean \|IQ\|; within-frame amplitude sd; a per-frame phase/gain
normalisation (normalise by mean \|z\| **first**, then φ = (∠⟨z⁴⟩ − π)/4) followed by rms and max
distance to the nearest constellation point (EVM, `emax`), the 99.9-pct of that distance, the
count of symbols beyond 6 σ, the count of near-zero samples, the intra-frame phase-rotation rate
(16 blocks/frame, ∠⟨z⁴⟩ unwrapped, LS slope) and its fit residual, plus the same EVM restricted
to the **first 256 symbols** (where a magic-bad header would live) and the last 256.

| | mid.bin | onset.bin |
|---|---|---|
| mean \|IQ\| | 16,369.8 (min 16,321 max 16,384, full swing **0.38 %**) | 16,370.6 (0.35 %) |
| EVM rms | **0.010553 ± 0.000370** (max over frames 0.01111) | 0.010483 ± 0.000395 |
| worst single symbol, whole file | **0.0696** (boundary 0.7071) | 0.0696 |
| near-zero samples (\|z\| < 0.3·mean) | **0** | **0** |
| hard-decision errors | **0** | **0** |
| phase-rotation rate | −1.8 × 10⁻⁹ ± 3.6 × 10⁻⁹ rad/symbol (≈2 × 10⁻⁵ rad per frame) | −6 × 10⁻¹⁰ ± 4.3 × 10⁻⁹ |

The 120.2-s beat burst that fired the trigger (63,602 err/s) leaves **no signature at this tap**:
the largest per-frame EVM anywhere is 5 % above the mean, and the worst-EVM frames of the two
files are at unrelated ordinals (184 and 3141). "Exclude burst frames" was therefore moot — there
are no burst frames to exclude at sel6, and both the with-everything and the leave-nothing-out
analyses are the same analysis. (Caveat: `errps.csv` is 1 Hz, so the burst cannot be located to
better than a second inside a 4.38 s window; this is an absence of signature, not a proof that the
burst window was captured.)

## 3. Autocorrelation and periodograms [silicon] — task item (2)

```
python3 two_jup/comb/comb32_sel6_desk/comb32_autocorr.py \
        two_jup/comb/comb32_sel6_desk/{mid,onset}_frames.npz --out=.../ac_all.json
python3 two_jup/comb/comb32_sel6_desk/comb32_period.py \
        two_jup/comb/comb32_sel6_desk/{mid,onset}_frames.npz --out=.../period32.json
```

**Raw autocorrelation is uninformative and must not be quoted.** Every metric carries slow
(0.5–2 s) regime plateaus that lift the autocorrelation at *every* lag 1–128; that is what
produces headline numbers like `ep999` lag32 = +0.51 on mid. The discriminating fact is that
lag16 ≈ lag32 ≈ lag64 in each metric (e.g. mid `ep999`: 0.504 / 0.511 / 0.503), unlike the
host-side loss comb, where lag16 = −0.03 against lag32 = +0.70. The **validity-mask control** is
clean — mask lag32 = **+0.0165 (mid) / −0.0223 (onset)** — so gap structure is not injecting a
32-frame artefact.

After high-passing each series (centred MA-65, passes period 32 at >0.95), the periodogram peaks
are, in both files, at **small-integer and simple-rational frame periods**: 2.00, 4.00, 4.67
(=14/3), 5.33 (=16/3), 7.00, 12.00, 13.98–14.02, 15.97–16.01. **Period 32 never appears in the
top-6 peaks of any metric on either file.** The explicit period-32 bin against a local floor:

| metric | mid P32/floor (z) | onset P32/floor (z) | reproducible? |
|---|---|---|---|
| mean \|IQ\| | 4.70 (+4.3) | 2.84 (+1.7) | no |
| EVM | 2.32 (+1.7) | 0.56 (−0.6) | **no (sign flips)** |
| emax | 2.14 (+1.0) | 1.73 (+0.7) | no |
| ep999 | 3.62 (+2.4) | 4.47 (+3.1) | weak, but see below |
| nbig | 2.74 (+1.6) | 2.27 (+1.1) | no |
| head_evm (first 256 sym) | 1.55 (+0.5) | 4.48 (+3.8) | **no** |
| tail_evm | 1.62 (+0.8) | 3.89 (+2.5) | no |
| emax_pos | 4.50 (+3.0) | 1.32 (+0.3) | no |
| phrate | 18.25 (+16.5) | 19.71 (+15.1) | **yes — but see §4** |

For comparison the same table's period-16 column runs to z = +240 (`emax_pos`, mid) and z = +137
(onset): the 32-frame bin is 1–2 orders of magnitude below the structure that genuinely exists.
The mod-32 epoch-fold F-tests (F = 3–23, 31/5300 dof) are **all** explained by this: 16, 8, 4 and
2 all divide 32, so the strong short-period lines alias into every mod-32 fold. A fold test is
not a valid period-32 detector on this data and none of its p-values is quoted as evidence here.

## 4. The one reproducible line, and why it is not the comb [silicon/inferred]

`phrate` — the intra-frame residual carrier-rotation rate — is the only metric with a period-32
line that survives on both files (z = +16.5 / +15.1), together with a much larger line near
period 94.7–99.9 frames (z = +233 / +158; note the peak is **not** at 96 exactly and the two
files disagree on its position, so it is not a 32-harmonic). Its physical size settles it: the
whole series has sd 3.6 × 10⁻⁹ rad/symbol, so a period-32 component at even 1 sd would rotate the
constellation by **4 × 10⁻⁵ rad ≈ 0.0025° across an entire frame** [inferred, sd × 12,333]. That
is ~4 orders of magnitude below anything that could damage a frame, and it is exactly the kind of
residual a locked carrier loop is expected to leave. Reported for completeness, not as a finding.

## 5. Where the 14/16-frame structure comes from — the payload [silicon]

(Payload-repetition figures below are from an inline gap-aware pass over
`comb/comb32_sel6_desk/{mid,onset}_frames.npz` plus the raw `.bin`; see caveat 5.)

Hard decisions were extracted for the first 4,096 symbols of the first 1,400 clean frames of each
file and compared **gap-aware on the frame ordinal** (frame *k* against frame *k*+lag whenever
both are clean; ≈1,375 pairs per lag, lags 1–96). Symbol-decision agreement is **far above the
0.25 chance level at every lag**:

| file | overall range | top lags |
|---|---|---|
| mid | 0.442 – 0.628 | **16** (0.628), 32 (0.606), 14 (0.602), 48 (0.602), 64 (0.590), 96 (0.587) |
| onset | 0.642 – 0.751 | **26** (0.751), 52 (0.737), 78 (0.722), 12 (0.717), 42 (0.710), 14 (0.708) |

The payload is a highly repetitive test pattern whose repetition period **differs between the two
captures — a clean 16/32/48/64/80/96 family on mid, a 26/52/78 family on onset**. Note the trap
this sets: **in mid.bin the payload content itself repeats at lag 32**, so any data-dependent
metric will show lag-32 structure there for reasons that have nothing to do with a physical
disturbance — while onset.bin, whose payload repeats at 26, shows no comparable 32 structure even
though the host-side loss comb is stable at 32 across every leg and knob. Every metric periodicity in §3
follows that family, and it moves when the payload moves. This is the correct reading of the
14/16-frame lines, and it is also a warning for the host-side comb work: a metric periodicity on
the frame axis can be data content, not a physical process. The host-side comb, by contrast, sits
at exactly 32 with harmonics at 64/96/128 across every leg and knob — a different, stable object.

## 6. Localisation attempt — task item (3)

```
python3 two_jup/comb/comb32_sel6_desk/fold32_profile.py \
        two_jup/beatcap/20260902_185552_sel6/mid.bin  .../mid_frames.npz  .../mid_fold32.npz
```
Every clean frame's per-symbol error magnitude was folded by frame-ordinal mod 32 into a
32 × 12,320 profile (153–171 frames per phase row), then smoothed over 64 symbols and z-scored
across the 32 phase rows at each symbol position.

| | mid | onset |
|---|---|---|
| max \|z\| over all 394,240 (phase, symbol) cells, unsmoothed | 4.11 | 4.24 |
| max \|z\| after 64-symbol smoothing | 3.91 at (phase 14, symbol 1026) | 4.06 at (phase 21, symbol 7869) |
| per-phase whole-frame mean \|e\| — rms across the 32 rows | **0.61 %** of the mean | **0.54 %** |
| per-phase whole-frame mean \|e\| — largest single-row deviation | 1.56 % | 0.97 % |
| per-phase whole-frame mean \|e\| — full range | 2.41 % | 1.85 % |

≈6,000 independent smoothed cells give an expected extreme of ≈3.7, so 3.9–4.1 is what noise
produces, and **the two files' extrema agree in neither phase nor symbol position**. There is no
disturbed frame to characterise: no power dip, no phase jump, no timing glitch, at any symbol
index, at any phase of the 32-frame cycle.

## 7. Marker / tOff stream — task item (4)

In the unwrapped `tref` base, the `mark_demod` inter-arrival takes **only the values
{12333, 24666}** on both files — every interval an exact multiple of the nominal frame, the 24666
entries being frames whose marker record was swallowed by a DMA drop (15 on mid, 18 on onset).
Unlike sel13's `onset.bin`, **no ±164-symbol re-sync jump occurs anywhere in either file.**
Records-per-frame is exactly 12,320 for 5,350/5,445 (mid) and 5,344/5,444 (onset) intervals; all
deviations are short-by-N record shortfalls (80 short / 15 long on mid, 82 / 18 on onset), i.e.
DMA drop bookkeeping. Their frame ordinals are **not** 32-periodic:

| Rayleigh test on anomaly ordinals | mod 32 | mod 64 | mod 16 |
|---|---|---|---|
| mid (n = 95) | R = 0.026, p = 0.94 | R = 0.087, p = 0.49 | R = 0.196, p = 0.026 |
| onset (n = 100) | R = 0.016, p = 0.98 | R = 0.015, p = 0.98 | R = 0.159, p = 0.079 |

The marginal mod-16 result does not reproduce and is consistent with the known S2MM
transfer-boundary structure of the drops. `toff` is a single constant (12314) in both files and
yields nothing. **No 32-frame periodic anomaly in the marker or records-per-frame stream.**

## 8. Unexpected finding that needs an owner [silicon] — the marker offset is rigidly locked

`mark_demod` (air-recovered frame start, traced through the built RTL to the correlator /
packet-detect chain in `SRO_SEL13_DESK.md` §4) minus the preceding `mark_fec` (**148's own**
`Transmitter_txFrameStart`) is **exactly 61 symbols on 5,441/5,446 marks in mid.bin and
5,440/5,445 in onset.bin** — zero drift over 4.38 s, twice; the exceptions are the four/five
spurious doubled `mark_fec` pulses, not offset movement.

Read literally, the offset bounds any sample-rate offset between whatever 148 is demodulating and
148's own clock at **< 1 symbol in 67.3 M symbols = 0.015 ppm** [silicon] — 4× tighter than the
sel13 bound, 40× below the 0.63 ppm the SRO hypothesis requires. **But that bound is exactly as
conditional as §1–§7, and the same observation is also the strongest hint that the tap may not be
watching the link at all** — the two readings below cannot both be used. Under reading 1 the
figure is a real SRO bound on the 146→148 path; under reading 2 there is no SRO to bound (148
against itself) and the rigid offset is simply the loopback's signature, saying nothing about the
air path. Do not carry "SRO excluded on two independent taps" out of this document until the
reading is settled.

Two readings of the rigid offset, not separable at the desk, and the campaign should pick one
before spending another arm [inferred]:
1. **The boards share a reference clock.** Then the fixed offset is just an arbitrary constant
   frame phase, everything above stands as an RF-link measurement, and the SRO hypothesis is dead
   because there is no independent oscillator to offset.
2. **148 is demodulating its own transmission** (RF self-reception / leakage) rather than 146.
   Then the 61 symbols is the TX→RX loop latency (3.97 µs), and **these captures say nothing
   about the 146→148 air path at all** — the §1–§7 null would be a null on a loopback.
   The 39 dB constellation with zero symbol errors is at least suggestive of this reading.
A one-line rig check settles it (key 146's TX off, or offset its LO, and see whether 148's
`mark_demod` survives); until it is settled, treat §1–§7 as **conditional on reading 1**.

## 9. Caveats

1. Only one capture pair exists (the 18:48 run aborted with no data), and both files come from
   the **same arm** on the pre-fix beat-era image 638b36de3493, 2026-09-02 — the comb itself was
   measured on the 09-03 ballpark and T2 legs. Same cross-run gap as `SRO_SEL13_DESK.md` §6.1.
2. sel6 is post-AGC / post-symbol-sync / post-carrier-sync (§ VERDICT scope). Upstream taps
   (sel0/1/2/3) are untested here.
3. `ddrcap2_pc.py --sel 6` was not run on these files. The anchor channels are self-evidently
   live and correctly decoded (10,891 markers all on exact 12,333 multiples; `tref` unwraps with
   zero inconsistencies) and the I/Q tap is live (2,672 distinct I codes, \|z\| = 16,370 ± 122,
   R < 1), so the null is a null on a live tap — but the pre-registered PC ritual is unperformed.
4. The `head_phi` metric (frame-head ⟨z⁴⟩ phase relative to the frame) is wrapped and
   uninformative — the frame head is not pure QPSK — and no claim rests on it.
5. The payload-repetition pass (§5) was run inline rather than as a committed script; it reads
   the first 4,096 symbols of the first 1,400 clean frames and is trivially reproducible from
   `frame_metrics.py`'s `start`/`k` arrays.
6. There is no per-frame loss marker in a sel6 record and `errps.csv` is 1 Hz, so the
   "disturbance coincides with a lost frame" half of the question **remains untestable from these
   files**, exactly as in `SRO_SEL13_DESK.md` §5. Nothing here tests coincidence.

## 10. What this changes

* The 32-frame comb is **not** a power, phase, timing or constellation disturbance at the slicer
  input: no once-per-32 frame class raises the mean symbol error by even 1.8 %. Combined with the
  T2 verdicts (not host-queue locked on either board), the remaining space is a **digital process
  downstream of the slicer** — deframing, frame-start alignment, or the delivery plane — with a
  32-frame period, which is also where the 84 %-magic-bad header evidence points. **This inference
  is conditional on §8 reading 1** (the tap is watching the 146→148 link); under reading 2 it
  describes a loopback and the air path is untested. §8's SRO bound carries the same condition.
* If a next capture is armed, sel9 (demod hard bits + frame markers) or a deframer-domain tap is
  worth far more than another analog-domain selector: this file shows the analog domain is clean
  to a bound no plausible frame-killer could hide under.
* Settle §8 first. A cheap rig check decides whether this null describes the RF link or a
  loopback, and that decision costs nothing compared to re-reading it wrong.
