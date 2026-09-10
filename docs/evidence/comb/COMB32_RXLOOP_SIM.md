> Evidence ledger, moved verbatim from `two_jup/comb/COMB32_RXLOOP_SIM.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# COMB32_RXLOOP — is the 32-frame comb a property of the Peak_Search / Timing_Adjust loop under noise?  [sim]

Date 2026-09-04 · **desk only, no board contact** · Verilator 5.020 on the FLASHED 148
lineage netlist snapshot
`jupiter_240k5_byte/rtl_sim/s1_rtl_txfix_F3/hdlsrc/commhdlQPSKTxRxLoopback`
(the same snapshot `sdd_archive/2026-09-03-seqbist/task-3-report.md` gates against).
**Every number in this document is [sim]** unless labelled otherwise.

> **VERDICT: NO COMB.** Over 257-449 Peak_Search epochs per leg, at Es/N0 = clean / 15 / 10 / 7 dB
> and CFO 0 / +1 / +2 / +3 kHz, the lost-frame train shows **no periodicity at any lag 1-128**
> (lag-32 rho between -0.10 and +0.06 against a permutation null95 of 0.20-0.27; silicon reads
> **+0.70** at lag 32). What impairment actually does to the Peak_Search / Timing_Adjust loop is a
> **slow monotone drift of the argmax position**: the no-impairment control's `timingOffset`
> slope is **-0.007 samples/epoch** (pinned), while **every** impaired leg -- CFO-only and
> AWGN-only alike -- runs at **-8.6 to -15.7 samples/epoch**. That is a ramp, not a limit cycle:
> `timingOffset`'s autocorrelation is a smooth lag-1 = 0.99 decay with **no local maximum at 32**
> (or 33/64/65/66). Independently, a 32-epoch CFO-epoch beat would need ~1,245k+39 Hz and none of
> the CFOs tested is near one, so the drift is not a CFO beat either. Caveat that bounds this verdict: the impaired legs lose 35-45 % of frames,
> 5-10x the silicon 3.7-8.2 %, so this simulation is not sitting at the silicon operating point (§5).

## 1. Question and why a new harness was needed

`COMB32_SRO_SIM.md` drove the RX chain from a *tiled* BIST-ROM capture: every air frame
was byte-identical, so any content-dependent mechanism was structurally invisible (its
§8.2 says so). `RX_WINDOW_RTL.md` then localised the surviving mechanism to
`Peak_Search`'s decision rule — one argmax per free-running mod-12333 epoch, applied one
epoch later — and asked whether the residual 32.4-frame comb is a **limit cycle of that
epoch-delayed timing adjustment under noise**, rather than a property of the content.

Answering that needs the full RX chain driven by (a) real, non-tiled, byte-plane TGEN
content and (b) RF-like impairment. Neither existing harness does both:
`wrap_byte_seqbist.v` has the TGEN but runs pure fabric loopback (no impairment path);
`wrap_byte_sro.v` has the impairment path but only a tiled ROM stimulus and no
`Peak_Search` taps.

## 2. What was built

| artefact | path | note |
|---|---|---|
| closed-loop wrapper + Peak_Search taps | `jupiter_240k5_byte/rtl_sim/wrap_byte_rxloop.v` | new |
| Verilator driver (impairment in the loop) | `jupiter_240k5_byte/rtl_sim/sim_rxloop.cpp` | new |
| build script (`systemd-run --user`) | `jupiter_240k5_byte/rtl_sim/build_rxloop.sh` | new |
| leg launcher (one transient unit per leg) | `jupiter_240k5_byte/rtl_sim/rxloop_launch.sh` | new |
| scorer | `jupiter_240k5_byte/rtl_sim/rxloop_score.py` | new |

**The loop.** `qpsk_traffic_gen_v2` (the real RTL generator) drives the DUT TX byte pins
(`tx_data_source=1`); the driver reads `Transmitter_dataOut{I,Q}` on every `enb_1_2_0`
beat, rotates by the CFO, adds AWGN, rounds to int16, and presents the result on
`adc_dataIn{I,Q}` with `adc_validIn=1` on the **next** clock, with
`rx_input_select=1`. Exactly one ADC sample is injected per TX sample **by construction**
— there is no rate-matching FIFO that could drift and manufacture a periodicity; the
summary line `loop_balance` is the audit (measured 1, the single in-flight sample; see
§5.6 for why the wall-capped legs have no summary of their own). Loop latency is a constant one sample, which the free-running epoch cannot see
(`RX_WINDOW_RTL.md` §3).

**Taps** (hierarchical references verified against the netlist; `Preamble_Detector.v:62-75,
148-215`, `Timing_Adjust.v:216-222`, `Frequency_and_Time_Synchronizer.v:119`):
`Peak_Search` `p1c_tref` (the free-running mod-12333 epoch counter), `timingOffset` (the
argmax position reported for the epoch), `p1c_runmax`, `p1c_heldts` (32-bit absolute
timestamp of the winning peak), `p1c_newpk`; `Timing_Adjust` `p1c_accoff`, `p1c_armed`;
`Preamble_Detector_syncPulse`; `Correlator` `dataOut` / `threshold` /
`thresholdExceeded` / `validOut`.

**Noise convention** is copied verbatim from `two_jup/comb/sro_sim/gen_sro_stim.py` so the
numbers are comparable with `COMB32_SRO_SIM.md`: `Es = mean|x|² · 4` (4 sps),
`N0 = Es/10^(EsN0/10)` spread over the full 61.44 MHz complex bandwidth,
`sigma = sqrt(N0/2)` per component. `mean|x|²` is measured over epochs 4..7 of a noiseless
warm-up and then frozen; CFO and AWGN switch on together at epoch 8.

**Out of scope: SRO.** The on-air bound is |SRO| ≤ 0.06 ppm (T3), which is ≈ 3.5 samples of
drift over a whole leg, and `COMB32_SRO_SIM.md` already showed the interpolator absorbs
slips with zero frame losses at ±0.63/±1.26/+10 ppm. A streaming fractional resampler was
not worth the implementation risk; no leg carries an SRO.

## 3. Exact commands

```sh
cd jupiter_240k5_byte/rtl_sim
./build_rxloop.sh --wait          # verilator -O3 --x-assign fast --noassert,
                                  #   -CFLAGS "-O2 -march=native"; ~68 s
./rxloop_launch.sh 1200 86        # 6 legs, one systemd --user unit each, nepochs=1200.
                                  # The in-process 86-min cap is only checked every 20 Mclk,
                                  # so the legs were in fact stopped externally at 04:57 by
                                  # `systemd-run --user --on-active` timers; none reached 1200.
# two further legs added at 04:00 once the first results showed the six-leg matrix had no
# true no-impairment control (the "clean" legs carry CFO):
#   ctl_none  = no noise, CFO 0      <- the control
#   clean_c1k = no noise, CFO +1 kHz <- CFO-dependence of the argmax drift
B=$PWD/obj_rxloop/Vwrap_byte_rxloop; O=$PWD/rxloop_runs
systemd-run --user --collect --unit=rxloop-ctl_none --working-directory=$PWD \
  $B 1200 $O/ctl_none none 0 20260904 150000 1516 52

python3 rxloop_score.py rxloop_runs/{ctl_none,clean_c1k,clean_c2k,esn15_c0,esn15_c2k,esn15_c3k,esn10_c2k,esn07_c2k}
```

Every leg uses the identical TGEN configuration — `gap=150000`, `fill=1516`, seq from 1,
`seed=20260904` — so the underlying TX byte stream is **bit-identical across legs** and
only the impairment differs. `gap=150000` is the saturating, non-over-supplying operating
point established in `task-3-report.md` (one host frame per 197,328 clks; every other
delivered byte-plane frame is an all-zero filler, the 2× `packets_out` artefact).

## 4. Legs and results  [sim]

Eight legs, all from the same bit-identical TGEN stream, launched 03:33/04:00 and stopped
together at 04:57 by `rxloop-stopper.timer` (a wall-clock cap, not a target-reached exit;
`_epochs.txt` is flushed every 64 epochs and `_frames.txt` every 16 frames, so the truncation
costs at most the last 64 epochs, the last 15 delivered frames -- which slightly shortens the
seq-span denominators -- and the `_summary.txt` of each leg). **No leg reached the 1,200-epoch
target; the stop was external**, and the achieved counts are what is reported.

`sigma` is the per-component AWGN standard deviation the driver computed from the measured
`mean|x|² = 6.703e7` (Es = 2.681e8): 2,059 at 15 dB, 3,661 at 10 dB, 5,172 at 7 dB.

| leg | Es/N0 | CFO | epochs | good | garbage | filler | seq span | lost slots | PER |
|---|---|---|---|---|---|---|---|---|---|
| `ctl_none` **control** | — | 0 | 257 | 134 | 2 | 136 | 135 | **1** | **0.74 %** |
| `clean_c1k` | — | +1 kHz | 257 | 85 | 7 | 132 | 131 | 46 | 35.1 % |
| `clean_c2k` | — | +2 kHz | 449 | 152 | 13 | 235 | 238 | 86 | 36.1 % |
| `esn15_c0` | 15 dB | 0 | 449 | 130 | 19 | 235 | 236 | 106 | 44.9 % |
| `esn15_c2k` | 15 dB | +2 kHz | 385 | 14 | 105 | 25 | 22 | 8 | 36.4 %† |
| `esn15_c3k` | 15 dB | +3 kHz | 449 | 138 | 15 | 231 | 233 | 95 | 40.8 % |
| `esn10_c2k` | 10 dB | +2 kHz | 385 | 14 | 197 | 13 | 52 | 38 | 73.1 %† |
| `esn07_c2k` | 7 dB | +2 kHz | 385 | **0** | 174 | 2 | — | — | **no lock** |

† `esn15_c2k` and `esn10_c2k` deliver almost nothing but garbage; their seq spans (22 and 52)
are too short for the loss axis to carry a lag-32 test, and they are scored as **unpowered on
the loss axis**, not as comb-free. `esn07_c2k` (per-sample SNR ≈ 1 dB) delivers **zero**
good-magic frames: that is an **acquisition failure**, not a comb result.

### 4a. The control behaves exactly as the fabric-loopback gate does
`ctl_none` — no CFO, no noise, the impairment stage a pure pass-through — loses **1 slot in
135** (0.74 %) and holds `timingOffset` **pinned at 12,264** for 255 of 257 epochs, with
`d(heldts) = 12,333` exactly on 254 of 256. That is the `RX_WINDOW_RTL.md` §6 loopback
prediction met on the nose, and the loss rate is the same order as the content-locked
~1-in-500 byte-plane framing slip that `task-3-report.md`'s G1 gate found on the pure fabric
rail. The closed loop through the ADC path therefore adds nothing of its own.

### 4b. The comb score — the pre-registered question
Loss-indicator autocorrelation on the emitted-seq (host-frame) axis, permutation null of 2,000
shuffles; `null95` is the family-wise 95th percentile of max|rho| over lags 1-128.

| leg | n | null95 | top lag | rho@2 | rho@32 | rho@33 | rho@64 |
|---|---|---|---|---|---|---|---|
| `ctl_none` | 135 | 0.010 | 1: −0.008 | −0.000 | −0.002 | −0.002 | — |
| `clean_c1k` | 131 | 0.265 | 27: −0.151 | +0.065 | −0.001 | +0.007 | — |
| `clean_c2k` | 238 | 0.204 | 68: +0.143 | −0.043 | −0.024 | +0.010 | +0.060 |
| `esn15_c0` | 236 | 0.205 | 1: +0.157 | +0.051 | **−0.102** | +0.022 | −0.029 |
| `esn15_c3k` | 233 | 0.207 | 14: −0.131 | −0.118 | +0.060 | +0.064 | +0.032 |
| `esn10_c2k` | 52 | 0.356 | 10: −0.184 | +0.061 | — | — | — |

**No leg exceeds its own family-wise null at any lag**, and no lag-32 family exists: the largest
|rho@32| is 0.102 (negative, i.e. anti-correlated) on `esn15_c0`, against a null of 0.205.
Silicon reads **+0.70 at lag 32 with harmonics at 64/96/128** (`COMB_STATE.md` T0). The comb is
not reproduced.

The scorer prints lag 2 for every series because the `gap = 150000` rail alternates a
high-entropy PN payload frame with an all-zero filler frame, which is a period-2 signal whose
harmonics would land on 32 and 64. On the loss axis rho@2 stays at −0.12…+0.07, so the
alternation is not driving the lag-32 column either way.

### 4c. What impairment actually does to the argmax — the smoking-gun tap
`timingOffset` (the argmax position Peak_Search reports for the epoch), per epoch:

| leg | first | last | least-squares slope | detrended dominant period | residual sd |
|---|---|---|---|---|---|
| `ctl_none` | 12,324 | 12,264 | **−0.007 /epoch** | (constant) | 3.8 |
| `clean_c1k` | 12,324 | 9,795 | −9.47 /epoch | 128.5 ep | 20.6 |
| `clean_c2k` | 12,324 | 7,937 | −9.92 /epoch | 149.7 ep | 101 |
| `esn15_c0` | 12,324 | 8,377 | −8.63 /epoch | 10.2 ep | 367 |
| `esn15_c3k` | 12,324 | 8,412 | −8.55 /epoch | 149.7 ep | 180 |
| `esn10_c2k` | 12,324 | 6,671 | −15.7 /epoch | 192.5 ep | 3,308 |

Three things follow, and none of them is a 32-frame limit cycle:

1. **The response is a monotone ramp, not an oscillation.** `toff`'s raw autocorrelation is a
   smooth decay — lag 1/2/3/4/5 = 0.988/0.981/0.975/0.969/0.962 on `clean_c2k` — with **no local
   maximum at 32** (the scorer's local-max test fires nowhere near it). A ramp of −9.9
   samples/epoch would wrap the 12,333-sample epoch every ≈ 1,240 epochs, not every 32.
2. **It is not a CFO beat.** `esn15_c0` (AWGN only, CFO exactly 0) drifts at −8.63/epoch, within
   15 % of the CFO-only legs. And the arithmetic rules the beat out independently: the epoch is
   49,332/61.44e6 = 8.029e-4 s, so a 32-epoch CFO-epoch beat needs ≈ 1,245·k + 39 Hz
   (39 / 1,284 / 2,530 / 3,775 …); +1,000, +2,000 and +3,000 Hz sit nowhere near one, and a
   period that appeared at both +2 k and +3 k could not be the beat anyway.
3. **The drift is real timing error, not an artefact of the epoch axis.** `psTref` advances on
   `Correlator_validOut` (symbol beats) while the driver samples it on `railEnb` (sample beats),
   so a mis-tracking symbol synchronizer could in principle fake a sliding `timingOffset`. The
   falsifier is `p1c_heldts`, the **absolute** timestamp of each winning peak: its mean spacing
   minus 12,333, over the in-band (11,000-14,000) epochs, is **-9.91 / -9.54 / -8.67 / -8.42**
   samples on `clean_c1k` / `clean_c2k` / `esn15_c0` / `esn15_c3k`, matching those legs'
   `timingOffset` slopes (**-9.47 / -9.92 / -8.63 / -8.55**) to within 5 %. Two independent taps
   agree, so successive true peaks really are arriving ~9 samples early per epoch. The control
   reads -0.23 against a slope of -0.007. (`esn10_c2k` is too disordered to cross-check: only 77
   of 384 epoch spacings are in band.)
4. **The detrended residual has no reproducible period.** 128.5 / 149.7 / 10.2 / 192.5 epochs
   across legs — inconsistent between legs run on the identical TX stream, i.e. noise, not a
   mechanism.

## 5. Scope limits bounding the NO COMB verdict

1. **Operating point.** The impaired legs lose 35-45 % of frames; silicon loses 3.7-8.2 %. The
   receiver in these legs is much further from the decision margin than the real link is, so a
   mechanism that only bites at a 4 % loss rate could be swamped here. This is the single
   largest limit on the verdict, and it is why the result is *no comb at these operating points*
   rather than *no comb, ever*.
2. **Loss-axis power.** Five legs carry 46-106 lost slots over 131-238 emitted-frame slots, so
   the lag-32 test has real power on those. Two legs (`esn15_c2k`, `esn10_c2k`) collapsed to a
   22- and 52-slot span and are unpowered; the control has one loss event and is likewise
   unpowered on the loss axis (its epoch-axis series is not).
3. **Frame axis and the clock ambiguity.** Everything above is reported in **Peak_Search epochs**
   (12,333 post-symbol-sync samples = one air frame) and, for the loss train, in **emitted host
   frames** (= 2 epochs on this rail, the 2x `packets_out` artefact). One epoch is 401.5 µs if
   the fabric clock is 245.76 MHz and 802.9 µs if it is 122.88 MHz; the silicon comb period of
   26.05 ms is therefore either 64.9 epochs or 32.4 epochs. **Both** candidate mappings were
   searched (lags 32, 33, 64, 65, 66 are printed explicitly for every series) and neither shows a
   local maximum above the null. The desk cannot settle which clock is right and does not need to.
4. **449 epochs is ~7 periods on the 64.9-epoch reading and ~14 on the 32.4-epoch reading.** A
   mechanism with a much longer period, or one needing a long lock history, would not appear.
5. **No SRO, no multipath, no AGC transient, no LO phase noise, no quantisation beyond the int16
   round.** The RX is fed a continuous stream with `byte_rx_ready` held high throughout.
6. **The legs were stopped by a wall-clock timer**, so no `_summary.txt` was written for them and
   the per-leg `loop_balance` / `clipped` audit lines are missing. The loop-balance invariant is
   structural (one ADC sample injected per railEnb beat, §2) and was measured as **1** — the single
   in-flight sample — on the smoke run of the same binary.

## 6. Raw outputs

`jupiter_240k5_byte/rtl_sim/rxloop_runs/<leg>_{epochs,frames}.txt` (per-epoch Peak_Search state;
per-delivered-frame magic/seq/all-zero flag), `<leg>.log`, and the scorer output `SCORE.txt`.
No IQ is written by this harness at all — the impaired stream exists only inside the driver.
