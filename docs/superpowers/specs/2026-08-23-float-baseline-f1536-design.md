# Float baseline on over-the-air data (f1536 geometry) — design

**Date:** 2026-08-23
**Branch:** `per-under-1pct-2026-07`
**Status:** design approved (operator, 2026-08-23)

## Goal

Measure what an **ideal float receiver** achieves on **real over-the-air samples** from the
R3/f1536 link, as a full chain (deinterleave + Viterbi + bit scoring) — so the result is
directly comparable to the hardware's own numbers on the same signal.

This separates *algorithmic/channel limited* from *implementation limited*. Whatever float
cannot recover is a property of the samples; whatever float recovers but the hardware lost
is implementation gap.

## Why this is needed

The campaign has two hardware numbers from the forward air path and they disagree in kind:

| measurement | value | source |
|---|---|---|
| forward delivered PER | **13.107 %** (10181/77674, CP95UL 13.347 %) | `accept_analyze.py`, `r3cap/fwdbase_20260823_080537` |
| forward air BER, reference-scored | **~8.2e-5** (315 errors / 156 frames, rstcs=0) | on-board BIST vs ROM, `r3cap/romair_20260823_115206` |
| batched DMA at line rate, radio removed | **0.62 %** | Task 3b, `tgen_sweep` with `KEEPM=1` |

Bits on air are fine; frames are not; and the fabric/DMA/host path is clean. A float
baseline on the same samples is the missing measurement.

**Three offline oracles have already failed on current-lineage captures** (see
`two_jup/SINGLES_CAMPAIGN.md`), so this design is built around not repeating that:

1. `float_oracle_r3` — front-end only, and **its EVM is input-independent**: two entirely
   different captures returned EVM median 58.81 / p95 58.91 and preCorr 0.637 identical to
   4 significant figures. Broken, not marginal. **Retired for this purpose.**
2. `perframe_f1536` via `tap_replay_study` — links the **Jul-25 cadence-4 archive** while
   `CAPGOLD=0x04922282` is the **v3** golden; all 8 rot×vphase quadrants null.
3. `decode_seq_k5` / `decode_ref_k5` — proven, but **K5 geometry** (`sps=8`, `Rsym=240e3`);
   cannot read R3 captures. **This design ports it.**

## Two findings that make the port small

**1. The f1536 back end already exists.** `k5_240/packet_f1536.m` is not just a contract
document — it *implements* the receive-side back end to verify that contract:

```matlab
trellis = poly2trellis(5,[35 23]); TB = 25;    % IDENTICAL to K5
COLS = 16; ROWS = 1537;
dec = vitdec(deil, trellis, TB, 'term', 'hard');
function deint = legacy_deinterleave(rxbits, ROWS, COLS, CODED)
```

and exports `words, payload, coded, info, msgBits, capOut, trellis, TB, ROWS, COLS`. So the
deinterleave, the Viterbi call, and the **reference bits** are all already written and
already validated at f1536. The port does not re-derive the back end.

**2. `decode_ref_k5.m` is self-contained.** All seven helpers are local functions in the
same 276-line file: `demodDecode`, `framePeaks`, `fourthPowerCFO`, `coarseCFO`,
`deintIndex`, `viterbiDecode`, `refineStarts`. Copying the file carries the whole chain.

So the work is: **join `decode_ref_k5`'s front end (re-geometried) to `packet_f1536`'s
existing back end.**

## Architecture

One new MATLAB function, `k5_240/float_baseline_f1536.m`, derived from `decode_ref_k5.m`.

**Input:** a ROM/BIST-on-air capture from `two_jup/capture_rom_air.sh` (built 2026-08-23),
which holds the link on the ROM source so **every transmitted frame is the reference**.
This is what both earlier attempts lacked — `capture_r3` flips to the byte source, so its
captures carry arbitrary tun payload with nothing to score against.

**Output:**
- per-frame table: frame index, symbol start, bit errors, pass/fail, EVM, preamble corr
- aggregate float BER and frame-recovery fraction
- a comparison block against the hardware numbers from the same capture

### What changes from `decode_ref_k5.m`

| | K5 (current) | f1536 (ported) |
|---|---|---|
| `sps` | 8 | **4** |
| `Fs` | 1.92e6 | **61.44e6** |
| `Rsym` | 240e3 | **15.36e6** |
| `INFO` | 1084 | **12292** |
| `TAIL` | 4 | 4 |
| `CODED` | 2176 | **24592** |
| `ROWS` × `COLS` | 136 × 16 | **1537** × 16 |
| `trellis`, `TB` | `poly2trellis(5,[35 23])`, 25 | **unchanged** |
| `frameLenSym` | `nPre + DBPP/2` | **12333** |
| reference bits | `packet_k5` | **`packet_f1536`** |

The contract assert is updated to the f1536 constants and **kept** — it is what catches a
half-applied port.

Everything else — RRC matched filter, Gardner `comm.SymbolSynchronizer`, 4th-power CFO,
Barker frame peaks, `refineStarts`, per-frame preamble derotation, deinterleave index,
Viterbi — is inherited unchanged.

## Validation gates

**All four pass before any air number is reported.** Every instrument that failed in this
campaign failed by emitting a confident number it had no basis for; these gates exist
specifically to make that impossible.

**G1 — synthetic positive control.** Generate a clean f1536 waveform in MATLAB
(`packet_f1536` info bits → convenc → legacy interleave → QPSK → RRC → sps=4), decode it.
**Must be exactly 0 bit errors.** If not, the port is wrong and **no air number is
computed.** This is the gate that a broken front end cannot pass.

**G2 — AWGN ladder.** Decode the synthetic waveform at a set of known Es/N0 values;
measured BER must track theory. Catches a decoder that runs and produces plausible-looking
output but is mis-scaled — precisely `bs_front_end`'s failure mode, where EVM came out
input-independent.

**G3 — planted fault.** Flip N known bits in the synthetic stream; the scorer must report
exactly those N, at those positions, with zero false positives on the clean leg. An
instrument that has never caught a planted fault is not trusted with a zero.

**G4 — hardware cross-check.** On the ROM-on-air capture, **float BER must be ≤ the
hardware's 8.2e-5.** Float is the algorithmic ceiling: it cannot legitimately be worse than
the fixed-point silicon on that silicon's own samples. A float result *worse* than hardware
means the port is wrong, full stop. This single check would have caught both failed oracles
immediately — `float_oracle_r3` implied 58.8 % EVM on samples the DUT decoded at 86.9 %
clean, and `perframe_f1536` reported ~30× the silicon's error rate.

## Interpretation rules (stated before the run)

- **float BER ≈ 0, well below 8.2e-5** → the air samples are algorithmically clean; the
  13.107 % frame loss is implementation gap, not channel. Directs the campaign at the
  ADC→demod ingress stage, which internal loopback bypasses (it injects at the modulator)
  and offline replay bypasses (external-ADC port).
- **float BER ≈ hardware's 8.2e-5** → the fixed-point receiver is already at the
  algorithmic ceiling for bit recovery; the frame loss is elsewhere entirely.
- **float BER ≫ 8.2e-5** → G4 fails; the port is wrong. Not a channel finding.

Report BER and frame recovery separately. Do not collapse them into one number: the whole
point is that this link has good bits and bad frames.

## Non-goals

- **Not** repairing `bs_front_end` / `float_oracle_r3`. Its EVM is input-independent; it is
  retired for this purpose rather than debugged.
- **Not** the fixed-point leg. A valid one needs an IQ-fed wrapper built against the **v3**
  netlist — `wrap_byte_bf2.v` (the only wrapper proven to build against v3) is BIST-ROM
  driven and takes no IQ, and the IQ wrappers are K5 geometry. Separate work.
- **Not** `-S` sequence captures. ROM-on-air already supplies a known reference.
- **Not** a fix for anything. This is a measurement.

## Risks and honest limits

1. **Hidden K5 assumptions** in the inherited helpers (e.g. `findpeaks` thresholds tuned at
   `sps=8`, RRC span behaviour at `sps=4`). G1 is the detector: a clean synthetic waveform
   that will not decode to 0 errors localises this immediately.
2. **Viterbi runtime.** `CODED=24592` is 11× the K5 load per frame, over ~80 frames. May
   need windowing or a reduced frame count; a slow gate is acceptable, a skipped gate is
   not.
3. **Sample clipping.** The ROM capture has `max=7968`, `p99=7967` — ~1 % of samples pinned
   at the ceiling. Cannot be catastrophic (the DUT decodes 86.9 %), but it may cost float
   some margin. Record the clipped fraction alongside the BER rather than silently
   absorbing it.
4. **Capture is short.** 4 M complex samples ≈ 65 ms ≈ 81 frames. Fine for a BER floor
   measurement; too small to resolve a 13 % frame-loss rate with tight bounds. State the
   sample count with every number.
5. **MATLAB trial licence** — functional, emits a banner; not a blocker.

## Definition of done

`float_baseline_f1536.m` passes G1–G4, and produces, for a named ROM-on-air capture: float
BER, float frame-recovery fraction, the clipped-sample fraction, the frame count, and the
side-by-side comparison against that capture's hardware BER — with the interpretation rule
that fired stated explicitly.
