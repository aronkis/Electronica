> Evidence ledger, moved verbatim from `two_jup/comb/SRO_SEL13_DESK.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# SRO / sel13 desk analysis — is the residual comb a symbol-timing interpolator wrap?

Date 2026-09-03 · desk only (no board contact) · analyst: Claude Code session
Pre-registered question (COMB_STATE.md "T3/T4 pre-registration"):
> mu/countReg shows a sawtooth whose wrap period is 25.7 ms ± 5 % (32 frames) …
> Falsifier: wrap period ≠ 32 frames …

## VERDICT

**CONTRADICTS "wrap period = 32 frames".**
No sawtooth and **no wrap at any period** exists in sel13's `countReg`/`mu` on either
capture. Measured slow drift of the interpolator phase over 1.52 s:
**+0.87 counts (mid.bin) / −0.16 counts (onset.bin)** against a predicted
**15,104 counts = 14.75 mod-1024 wraps**; i.e. the observable is ~1.7 × 10⁴ below the
prediction, and the number of wraps observed is **0** in both files.
Spectral upper bound on any 25.72 ms ± 5 % component in the interpolator phase:
**0.042 % (mid) / 0.167 % (onset)** of total AC power, at/below the 0.21 % flat-spectrum
expectation for that band → no peak.

### Scope — read this before the campaign branches on the verdict

**The pre-registered falsifier does not validly fire, because the pre-registration named an
observable that cannot show the predicted behaviour under *any* SRO.** `countReg`/`mu` at
the strobe is a *locked-loop residual*: a tracking interpolator absorbs a whole-sample slip
as an extra/missing symbol **strobe**, never as a phase ramp (§4). A flat `mu` trace is the
expected outcome with or without an SRO. So the T3/T4 clause "wrap period ≠ 32 frames →
the SRO reading is wrong, move to sel5/sel14" must **not** be triggered by this result.
Treat the prediction as mis-specified, not as falsified-and-branch. §7 gives the observable
that replaces it.

**Separately, and this is the more consequential finding [silicon, RTL-confirmed]:** the
air-recovered frame-start marker did not slip by even one symbol in **1224 consecutive
frames** against 148's local time base (§4). `mark_demod` is traced through the built RTL
to the correlator/packet-detect chain, so this *is* a measurement of air timing, not a
tautology. A 0.63 ppm SRO demands ≈9.6 slips over that span. Bound: **|SRO| < 0.066 ppm**,
~10× below the hypothesised value — the SRO hypothesis is **not merely untested here, it is
in trouble**, and the cheapest next step is a same-day re-capture plus a code read, not a
sel5/sel14 rig arm.

---

## 1. What sel13 carries [silicon, from the RTL/pre-registration]

From `two_jup/TASK9_PREREG.md` lines 12-20 (selector encoding, design doc §3 lines 40-65)
— note that `two_jup/skidfix/ddrcap_inject.py:432-473` is the **v1** DDRCAP mux and only
defines sel 0-11; sel13 is a DDRCAP-**v2** selector and is not in that file. The v2 injector
is `two_jup/skidfix/ddrcap2_inject.py` (ch2/ch3 packing at :245-266) and the *built* RTL it
produced is on this desk at
`jupiter_240k5_byte/rtl_sim/s1_rtl_ddrcap2/hdlsrc/commhdlQPSKTxRxLoopback/` — used in §4:

| field | bits | meaning |
|---|---|---|
| `I[10:0]` | 11 | `Interpolation_Control.countReg[10:0]`, the interpolator phase accumulator |
| `I[15]` | 1 | `underflow_sticky` — the interpolator/symbol strobe |
| `Q[10:0]` | 11 | `mu[10:0]`, the fractional interpolation phase |
| ch2 b15 / b14 / [13:0] | | `mark_demod` / `mark_fec` (TX frame start) / `toff` |
| ch3 [15:14] / [13:0] | | `slot` / `side`; slot 1 ⇒ `tref`, a mod-12333 symbol counter |

Empirically confirmed on mid.bin [silicon]: `I[14:11]` is always 0 and `I[15]` is set on
25.000004 % of records; `Q[15:11]` is always 0; `countReg` spans 0…1023 and steps by −256
per record (4 records/symbol ⇒ −1024/symbol ⇒ it wraps **once per symbol by design** —
the per-symbol wrap is not the "wrap" the prediction is about); `mu` spans 0…1020 in
steps of 4 and is held for the 4 records of a symbol.

## 2. Time base and capture quality [silicon]

Both files are 512 MiB = 67,108,864 records; `slot` cycles 1,2,3,0 so exactly ¼ of records
(16,777,216) carry `tref`.

| quantity | mid.bin | onset.bin |
|---|---|---|
| symbols spanned (unwrapped tref) | 23,312,062 | 23,202,851 |
| duration @15.36 Msym/s | **1.5177 s** | **1.5106 s** |
| frames spanned (÷12333) | 1890.2 | 1881.4 |
| records lost at the rx2 DMA | **28.03 %** | **27.69 %** |
| drop bursts / mean burst | 32,764 / ≈199 symbols | ≈32,700 / ≈199 |
| `mark_fec` / `mark_demod` pulses | 1364 / 1340 | 1339 / 1358 |

The drop rate matches the memory note (20-40 % at the rx2 DMA), so **record index is not
used anywhere below**; every trace is indexed by unwrapped `tref` (mod-12333 accumulation
over consecutive slot-1 records), i.e. a true symbol/time base. Drop bursts land every
≈512 tref records (a DMA transfer boundary), consistent with the known S2MM behaviour.

## 3. The countReg / mu trajectory versus time [silicon] — task item (2)

Method: take `countReg` and `mu` at every slot-1 record; bin by unwrapped tref into
4096-symbol bins (0.2667 ms, 5691/5664 bins); per bin compute the **circular** mean
(`⟨e^{j2πx/1024}⟩`, so the mod-1024 arithmetic is handled exactly), unwrap the bin-to-bin
angle, and least-squares fit a line. Circular (not linear) statistics are required because
`countReg` sits near 0 and wraps to 1023 constantly.

| quantity | mid.bin | onset.bin |
|---|---|---|
| `countReg` mean resultant length R | **0.99879** | **0.99884** |
| `countReg` binned-phase peak-to-peak | **34.0 counts** (0.033 symbol = 0.13 sample) | **20.0 counts** (0.078 sample) |
| `countReg` total unwrapped drift over span | **+0.87 counts** | **−0.16 counts** |
| `countReg` implied rate | +3.7e-8 counts/symbol | −6.8e-9 counts/symbol |
| `mu` R / peak-to-peak / total drift | 0.9806 / 136.7 counts / **+3.46** | 0.9814 / 80.0 / **−0.64** |
| **mod-1024 wraps observed** | **0** | **0** |
| bin-to-bin residual scatter | 1.41 counts (countReg), 5.68 (mu) | 1.36 / 5.48 |

**Measured period of any sawtooth/wrap in `mu` or step in `countReg`: none — the
trajectory is flat and bounded.** Expressing the null as a period with uncertainty: the
drift is 0.87 ± 1.4 counts (mid) and −0.16 ± 1.4 (onset) over 1.518 s, so any real
1024-count wrap period is **> 2.2 × 10⁶ frames ( > 30 minutes)** at 1 σ, versus the
predicted 32 frames. Combining the two files the drift is **+0.36 ± 0.74 counts /
1.51 s**, i.e. a wrap period ≥ 4.3 × 10⁶ frames.

Predicted value for comparison [inferred, from COMB_STATE.md]: 0.63 ppm × 61.44 MSPS
= 38.7 samples/s ⇒ 58.8 samples over 1.518 s; at 256 counts/sample that is
**15,104 counts = 14.75 wraps**.

Spectrum of the same binned phase trace (Hann window, rfft, DC removed):

| component | mid.bin | onset.bin |
|---|---|---|
| strongest periods | 0.7927 ms (**0.987 frames**, 2.4 % of AC power) and three further 0.79 ms lines | 0.7929/0.7955/0.7959 ms (0.99 frames, 1.5-1.8 % each), plus 12.65 ms (15.75 frames, 1.1 %) |
| power in 25.72 ms ± 5 % | **0.042 %** | **0.167 %** |
| flat-spectrum expectation for that band | 0.21 % | 0.21 % |

The only reproducible structure is the **1-frame (0.793 ms) cadence** — the frame boundary
itself, present on both files. Nothing at 25.7 ms / 32 frames on either file.

## 4. Where an SRO would actually hide, and what it says [silicon] — the honest caveat

`countReg` at the strobe is a **locked-loop residual**: R = 0.9988 and a ±17-count
excursion mean the timing loop is tracking to ±0.02 symbol. Such a loop absorbs a
whole-sample slip not as phase ramp but as an **extra or missing symbol strobe**. So §3
alone cannot exclude an SRO; the strobe census can:

Grouping records into symbols by slot-1 boundaries and counting `I[15]` per group
(only groups of exactly 4 records, i.e. never straddling a DMA drop):

| strobes per symbol | mid.bin | onset.bin |
|---|---|---|
| 0 | 511 | 479 |
| 1 | 16,751,683 | 16,751,647 |
| 2 | 477 | 475 |
| **net (2's − 0's)** | **−34** | **−4** |

Net slip is a ±1 random walk over 988 / 954 events, so the endpoint noise is ±31 / ±31:
**net = 0 ± 31 symbols over 1.5 s**, and the two files' slope fits disagree in sign and
magnitude (−2.51 ppm vs +0.099 ppm) — i.e. this is noise, not a rate. Bound from this
observable alone: 31 symbols / 1.518 s = 20.4 symbols/s = 81.6 samples/s at 4 samples/symbol,
/61.44 MSPS ⇒ **|SRO| ≲ 1.33 ppm (1 σ)** — *not* sensitive enough to confirm or exclude
0.63 ppm. Recorded so the T3/T4 design does not repeat it.

Are the ±1 strobe events phase-locked to 32 frames? Rayleigh test of event time mod
32 frames: **R = 0.0274, n = 988, p ≈ 0.48 (mid)**; **R = 0.0733, n = 954, p ≈ 0.006
(onset)**. The two files disagree and the mid.bin result is null, so there is **no
reproducible 32-frame phase locking** of the slip events. (Identical numbers result for
"25.72 ms" because 32 frames *is* 25.72 ms.)

Stronger, and **no longer conditional** — the degeneracy is resolved on this desk from the
built RTL (`jupiter_240k5_byte/rtl_sim/s1_rtl_ddrcap2/hdlsrc/commhdlQPSKTxRxLoopback/`):

```
TxRxComposite.v:2164  wire ddrcap_demod_mark_now = Receiver_ddrcap_demodstart | ddrcap_demod_mark_latch;
TxRxComposite.v:2165  wire ddrcap_fec_mark_now   = Transmitter_txFrameStart   | ddrcap_fec_mark_latch;
QPSK_Rx.v:869         assign ddrcap_demodstart = QPSK_Demodulator_startOut;
QPSK_Demodulator.v:233assign startOut = Delay10_out1;          // = delayed startIn
QPSK_Rx.v:399         .startIn(Frequency_and_Time_Synchronizer_startOut)
Frequency_and_Time_Synchronizer.v:281  assign startOut = Packet_Controller_startOut;
Packet_Controller.v:158  sample_discard_controller ... .startOut(startOut)   // startIn from the
                          packet-detect / correlator path, one pulse per detected packet
```

So `mark_demod` is a **per-frame, air-derived** pulse off the correlator/packet-detect
chain (delayed, but not counter-generated), and `mark_fec` is **148's own
`Transmitter_txFrameStart`** — exactly the two independent clocks the SRO hypothesis is
about. The marker interval test is therefore a real board-to-board timing measurement.

The **frame-marker interval** test. In the local `tref` base,
the inter-arrival of `mark_demod` (recovered frame start) takes only the values

* mid.bin: **{12333, 24666} exactly**, 1224 intervals — every single one an exact multiple
  of 12333, residual 1.5e-9 symbols;
* onset.bin: {12169, **12333**, 12497, 24666} — i.e. it *can* move, but only in ±164-symbol
  jumps (re-syncs), never by ±1.

`mark_fec` (148's own TX frame start) is likewise exactly 12333 in every interval on both
files. Neither marker is reset by the other (onset shows `mark_demod` moving while
`mark_fec` does not), so `tref` is a free-running local counter: **the air-recovered frame
timing did not slip by even one symbol in 1224 consecutive frames** [silicon].
A 0.63 ppm SRO demands 1 symbol per 128 frames ⇒ ≈9.6 slips over that span.
Bound: **|SRO| < 1 symbol / 15.10 M symbols = 0.066 ppm**, ~10× below the hypothesised
value.

Residual caveats on this bound (both narrow, neither fatal): (a) the ±164-symbol jumps seen
in onset.bin show the frame-sync can re-acquire, and a re-acquisition could in principle
mask accumulated drift — but mid.bin shows **zero** such jumps across its 1224 intervals,
so nothing was masked there; (b) `sample_discard_controller` sits between the packet detect
and `startOut`, so a fixed pipeline latency is folded in — irrelevant to an *interval*
measurement. The bound is a real constraint on the 09-02 rig state; see caveat 1 for why it
does not automatically transfer to the 09-03 comb runs.

## 5. Task item (3): coincidence with loss events — **INCONCLUSIVE BY INSTRUMENT**

There is no per-frame loss marker in the sel13 record. The only loss information shipped
with the capture is `errps.csv`, which is **1 Hz** (40 samples, 51-153 err/s baseline, and
the 63,602 trigger sample at t=40 s); a 25.72 ms period cannot be tested at 1 Hz. The
`mark_demod` deficit (1340 vs 1364 `mark_fec` on mid.bin) is confounded by the 28 % DMA
drop rate and is at noise level. **No coincidence test was attempted and none is possible
from these files.** Do not read §3/§4 as having tested the "every wrap coincides with a
lost-frame onset" half of the prediction.

## 6. Blocking caveats

1. **Cross-run gap.** These captures are **2026-09-02 19:20 UTC, pre-fix beat-era**, taken
   for the §82/Task-9 beat campaign on image 638b36de3493. The 32-frame comb was measured
   on the **09-03** ballpark captures. SRO is a physical oscillator offset that drifts with
   temperature, and COMB_STATE.md itself attributes the +1 harmonic slip between runs to
   ppm drift. A same-day sel13 capture is still required; this analysis narrows but does
   not close the question.
2. Each capture is only **1.5 s** (≈59 predicted wrap cycles). Enough to see 14.75 wraps
   if they existed; not enough to characterise anything slower than ~0.5 s.
3. **Positive-control status, stated precisely.** The `pass: false` in the committed
   `mid_txmark.json` / `onset_txmark.json` (modal offset 246, modal fraction 0.872/0.892)
   is the **txmark** control — a `mark_fec`-cadence check from `ddrcap2_txmark_scan.py` —
   **not** the `ddrcap2_pc.py --sel 13` control that T3/T4 pre-registers. That sel13 PC has
   not been run on these files. However the anchor channels are demonstrably live and
   correctly decoded: §4's 1224 exact-12333 `mark_demod` intervals and the matching
   `mark_fec` intervals are themselves a positive control on ch2/ch3. And `I`/`Q` are
   demonstrably live rather than a stuck mux: `countReg` steps deterministically by −256
   per record through all 1024 codes, `mu` moves in its native 4-count quantum with
   peak-to-peak 137 counts, and the circular concentration is R = 0.9988, **not** 1.0. So
   the §3 null is a null on a *live* tap; what remains formally unproven is only the
   pre-registered PC ritual, which the new capture should still run (§7.3).
4. `sel13_mid_analysis.json` / `sel13_onset_analysis.json` (the Task-9 onset detector)
   already reported `confirmed: false`, `window_events: []` on both files — consistent
   with, and independent of, the present result.
5. CPU budget: whole analysis ≈12 min wall on this host, three full passes over each
   512 MiB file, **no sub-sampling** — every record was read; the only reduction is the
   4096-symbol binning in §3, which is a mean, not a decimation.

## 7. What the on-rig sel13 capture in T3/T4 must look for

1. **Do not score the sawtooth.** §3 shows the phase residual is pinned by the tracking
   loop; a flat `mu` trace is the *expected* outcome whether or not an SRO exists, so it
   cannot discriminate. Score the **±1 strobe census** (`I[15]` per symbol) instead, and
   its *cumulative* net, not its endpoint.
2. **Capture long enough to beat the random walk.** The ±1 events are a random walk at
   ≈650 /s; distinguishing a 0.63 ppm rate (9.7 net symbols/s) from noise at 5 σ needs
   ≈40 s of contiguous strobe record, not 1.5 s. A 512 MiB full-rate window gives 1.5 s.
   **Either capture a decimated/event-only stream, or accept that a single full-rate
   window can never settle the SRO magnitude.** This is the single most important design
   change T3/T4 needs.
3. **Get a positive control first.** `ddrcap2_pc.py --sel 13` must PASS on the new capture
   before any verdict is written; the existing sel13 files fail it (caveat 3).
4. **The coincidence half needs an instrument that does not exist yet.** A per-frame loss
   log carrying a frame index at better-than-one-frame resolution, time-aligned to the
   sel13 capture (shared trigger timestamp, or the loss index written into a DDRCAP
   channel). Without it, "every wrap coincides with a lost-frame onset" is untestable no
   matter how clean the tap is. `errps.csv` at 1 Hz will not do.
5. **The `mark_demod` degeneracy is already resolved** (§4, RTL cited): it is air-derived.
   So the marker-interval test is the cheapest and sharpest SRO probe available and should
   be the **primary** score on the new capture — it needs no new instrument, works on any
   selector (ch2/ch3 are the universal anchor), and is 20× more sensitive than the strobe
   census. Score it as: histogram of `mark_demod` inter-arrival in `tref` units; the SRO
   hypothesis requires values ≠ 12333 at a rate of one per 128 frames.
6. If T3/T4 confirms the strobe census is also flat, the falsifier fires and T4 should move
   to **sel14 (Delay8 interpolated samples)** and **sel5 (carrier sync)** at loss onsets,
   as COMB_STATE.md already pre-registers; note `20260902_193632_sel14` mid/onset captures
   already exist on this desk and were not consumed here.

## 8. Exact commands

All run from `/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup` with
`PYTHONPATH=/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup`. Scripts are in the session
scratchpad (`.../scratchpad/`), reproduced in §9.

```
# §2 capture quality + §4 frame-marker interval test
python3 mark_drift.py beatcap/20260902_192051_sel13/mid.bin \
                      beatcap/20260902_192051_sel13/onset.bin

# §3 countReg/mu circular-mean trajectory, slope fit, saved traces
python3 sro_traj.py   beatcap/20260902_192051_sel13/mid.bin \
                      beatcap/20260902_192051_sel13/onset.bin

# §3 spectrum + §4 strobe census and Rayleigh test
python3 slip.py       beatcap/20260902_192051_sel13/mid.bin \
                      beatcap/20260902_192051_sel13/onset.bin

# §4 cumulative net slip and demod-marker intervals in tref and in strobes
python3 slip2.py      beatcap/20260902_192051_sel13/mid.bin \
                      beatcap/20260902_192051_sel13/onset.bin
```

RTL read (no rig contact), used in §4:
```
grep -rn "demod_mark_now|fec_mark_now|demodstart" .
sed -n '2160,2185p' jupiter_240k5_byte/rtl_sim/s1_rtl_ddrcap2/hdlsrc/commhdlQPSKTxRxLoopback/TxRxComposite.v
grep -n "startOut" .../QPSK_Demodulator.v .../Frequency_and_Time_Synchronizer.v .../Packet_Controller.v
```

Field extraction used throughout (matching `task9_run.py:countreg_of`):
`countReg = a[:,0].astype(uint16) & 0x7FF`, `mu = a[:,1].astype(uint16) & 0x7FF`,
`strobe = (a[:,0].astype(uint16) >> 15) & 1`, decode via `ddrcap2_decode.load/decode`.

## 9. Scripts

The four scripts are short and are reproduced verbatim in
`two_jup/comb/sro_sel13_desk/` (copied out of the scratchpad alongside this file) so the
numbers above are reproducible without the session.
