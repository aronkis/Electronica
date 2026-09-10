# Raw per-block sample capture to DDR — design

**Date:** 2026-08-31
**Status:** draft, pending operator review
**Related:** `docs/superpowers/specs/2026-08-31-parallel-datapath-agents-design.md`,
`two_jup/SESSION_20260830_AUTONOMOUS.md`, `two_jup/chain.json`

---

## 1. Purpose

Route the raw 16-bit I/Q (or bit-domain) output of **any datapath block** into DDR, so a block's actual
samples can be compared frame-to-frame instead of only its 32-bit digest.

## 2. Why the existing instruments are not enough

Every witness built so far — DBGCAP, TXCAP, DEMODCAP, RFCAP — is a **32-bit digest of hard decisions**:
16 symbols × 2 sign bits, or 32 coded bits, captured once per frame. From a 2240-bit frame we keep 32
bits; from a 16-bit I/Q sample we keep the quadrant.

That is enough to say **that** a frame differs from golden. It cannot say **how**, by how much, or where
in the frame. In particular it cannot distinguish:

- **values changed** — the samples themselves are corrupted; from
- **position shifted** — the samples are correct but the frame marker moved.

That distinction is now the campaign's central open question. Evidence for the second reading:
`TXCAP`, anchored on the **transmitter's own** frame start, is 100 % golden through full bursts, while
every witness anchored on the **demodulator's** frame marker deviates (~46–50 % golden in bursts). A
digest cannot separate those; raw samples can.

**The ILA cannot do this job.** `beat_ila` is 4096 samples deep = 66.7 µs = **8.3 % of a single frame**.
It physically cannot span two frames, so it can never show one frame differing from another.

## 3. The opportunity: an idle capture chain already wired to DDR

`util_adc_2_pack` → `axi_adrv9001_rx2_dma` → **DDR (2 GB window on HPC0)** exists, is fully connected,
and carries nothing:

- Its data inputs come from `axi_adrv9001/adc_2_data_i0/q0` — the ADRV9002's **second** receiver.
- Packer channels 2 and 3 are tied to `GND_16`; their enables to `GND_1`.
- **Every arm script sets `in_voltage1_ensm_mode = calibrated`, never `rf_enabled`** — RX2 is never on.

Two further facts make the rewire cheap:

- **No clock-domain crossing.** `TxRxCompo_ip_0/IPCORE_CLK` is already `axi_adrv9001_adc_1_clk`, the same
  clock `util_adc_1_pack` uses. Clocking the RX2 packer from `adc_1_clk` puts it in the modem's domain.
- **Four 16-bit channels.** `NUM_OF_CHANNELS = 4`, `SAMPLE_DATA_WIDTH = 16` — enough for **two complex
  taps at once**, so one buffer can hold the same frame observed at two points in the chain.

## 4. Design

### 4.1 Data path — channel allocation (operator decision, 2026-08-31)

**ONE complex tap plus BOTH markers.** The four packer channels are allocated:

```
ch0  selected block, I          16-bit signed
ch1  selected block, Q          16-bit signed
ch2  demod frame marker         QPSK_Demodulator_startOut, one sample per packer beat
ch3  FEC frame marker           startSel (the FEC decoder's startIn), one sample per packer beat
                     |
                     +--> util_adc_2_pack --> axi_adrv9001_rx2_dma --> DDR --> libiio buffer
```

Rationale for spending two channels on markers rather than a second data tap: the alignment question is
the reason for this build (section 4.4), and it cannot be answered without the demod marker. Carrying the
FEC marker as well costs one more channel and buys a second, independent discriminator — a divergence
BETWEEN the two markers localises a shift to the span between the demodulator and the FEC decoder, which
is exactly the region the 2026-08-20 ILA finding ("value-perfect coded bits at a shifted sequence
position at/before the FEC input") already implicates. Two markers turn one measurement into three:
data-vs-demod-marker, data-vs-FEC-marker, and demod-marker-vs-FEC-marker.

A second data tap is deferred. Comparing two blocks can be done across two captures, because the beat is
phase-locked to reset and therefore reproducible; comparing a marker against data cannot be done across
captures at all, because the whole question is their relative position within one frame.

Repoint the packer's four data inputs from `adc_2_data_*` to the new mux and marker sources inside the
modem IP; move its `clk` and `reset` to the `adc_1_clk` domain; drive its four `enable` inputs from the
tap's own valid rather than `GND_1`.

**Marker encoding.** Each marker channel carries a full 16-bit word per packer beat, not a packed bit:
0x0000 when the strobe is low and 0x7FFF when high. Wasteful of bandwidth and deliberately so — a packed
or bit-stuffed marker can lose a strobe, and a missed strobe reads as a lag jump, faking the exact result
being tested (section 4.4). Sample both markers in the packer's own clock domain so their timing is
directly comparable to the data channels without reconstruction.

RX1's chain is untouched, so the link and its existing capture path keep working.

### 4.2 Tap selection
Extend the existing debug mux. `iq_debug_mux` (**0x10C**) already selects AGC out / postSymbolSync /
postCarrierSync / constellation onto `Index_Vector_out1_re/im`. Widen it to cover every block. Only ONE
selector is needed (see section 4.1 — the other two channels carry markers); blocks are compared across
successive captures, which is sound because the beat is phase-locked to reset and reproducible.

Selector map:

| sel | block | domain | encoding |
|---|---|---|---|
| 0 | RX chain input (`dataIn`) = TX output under loopback | sample, 4 sps | I/Q direct |
| 1 | AGC out | sample | I/Q direct |
| 2 | RRC receive filter out | sample | I/Q direct |
| 3 | postSymbolSync | symbol | I/Q direct |
| 4 | postCoarseFreq *(needs new port, see §6)* | symbol | I/Q direct |
| 5 | postCarrierSync | symbol | I/Q direct |
| 6 | QPSKConstellationPoints (demod in) | symbol | I/Q direct |
| 7 | QPSK_Modulator out (TX) | symbol | I/Q direct |
| 8 | TX RRC out (`Transmitter_dataOutI/Q`) | sample | I/Q direct |
| 9 | Demod coded bits (`QPSK_Demodulator_dataOut`) | bit | packed, §4.3 |
| 10 | FEC decoder input (`bitsIn`) | bit | packed, §4.3 |
| 11 | Bit_Packetizer / Scrambler out (TX) | bit | packed, §4.3 |

### 4.3 Bit-domain taps
Selectors 9–11 are single-bit streams. Pack 16 successive bits into one 16-bit word, emitting one word
per 16 valid bits, with the frame marker forced into a known bit position so frame boundaries stay
findable in the capture. Do **not** zero-extend one bit per 16-bit word — that wastes 15/16 of the
bandwidth and makes long captures needlessly large.

### 4.4 The demod frame marker is the measurement, not a parsing aid

**Corrected 2026-08-31 after operator challenge.** An earlier draft justified the marker as "so frames can
be located in the capture". That reasoning is wrong: the loopback sample stream is periodic at 49,349
samples, so frame boundaries in the DATA can be recovered by autocorrelation with no marker at all.

The real reason is that **the marker position is the variable under test.** The data is already known
good — TXCAP shows the transmitter's output is bit-identical through full bursts. Where the DEMODULATOR
believes a frame starts is an internal strobe (`QPSK_Demodulator_startOut`); it is not a property of the
sample stream and cannot be recovered from it by any post-processing. Capturing samples alone would
re-confirm something already established and say nothing about alignment.

Therefore capture the demod's own frame strobe as a channel alongside the samples, so the **lag between
the marker and the data is directly observable per frame**:

- lag CONSTANT across a burst => the marker is stable; the deviation is in values after all, and the
  position hypothesis dies.
- lag JUMPS during a burst => the marker moves relative to bit-identical data; the position hypothesis is
  confirmed, with the shift measured in samples rather than inferred.

The second outcome would explain in one mechanism why every demod-anchored witness deviates while the
TX-anchored TXCAP does not — the question open since the withdrawn section 20.

Implementation: dedicate one packer channel to the marker (and, if space allows, the FEC start `startSel`
too, since a divergence between the demod marker and the FEC marker is itself diagnostic). Using a spare
bit of a data channel is acceptable only if a full channel cannot be spared — the marker must not be
lossy, because a missed strobe reads as a lag jump and would fake the very result being tested.

## 5. Sizing

Measured: 1245 frames/s, 61.44 MSPS, 4 sps → **49,349 samples/frame**, 803 µs/frame, **197 kB/frame** raw
I/Q, 246 MB/s sustained.

| goal | frames | size |
|---|---|---|
| catch one bad frame in a burst (~50 % of frames deviate) | 4 | 0.8 MB (94 %) |
| near-certain, with good neighbours for comparison | 20 | 3.9 MB (~100 %) |
| generous burst window | 200 | 39 MB |
| expect one **quiet-floor** event (1 per 1064 frames) | 1064 | 210 MB |

Against a 2 GB window even the quiet-floor case fits. Sustained rate equals the ADC path's design rate,
so the DMAC is not being asked for anything new.

## 6. Work required

1. **BD change** — rewire `util_adc_2_pack` inputs/clock/enables. This is the only part that is not a
   source-only resynth, so the build is the full MATLAB/BD flow (~2 h) rather than `resynth_*.tcl` (~50 min).
2. **RTL** — widen the debug mux, add the second tap selector, add the `postCoarseFreq` port out of
   `Frequency_and_Time_Synchronizer` (that module already exports `postSymbolSync`/`postCarrierSync`, so
   the pattern exists), add bit-packing for selectors 9–11, add the frame-start marker.
3. **Host** — the capture enumerates as the existing `axi-adrv9002-rx2-lpc` iio device, so
   `capture_evm.sh`, `bigiq_hunt.sh` and `analyze_winiq.py` should work with little change. Confirm rather
   than assume.
4. **Scheduling** — the beat is phase-locked to reset (onsets 87/206/323 s after arm, reproduced across
   four arms on two days), so a capture can be scheduled into a predicted burst. `burst_onset_det` also
   exists in the BD as a hardware trigger. Either works; scheduling needs no new logic.

## 7. Verification — the gate this must pass

Per the standing §0 rule, **the capture path must be shown to produce a non-null before any null from it
is believed.** Specifically:

1. **Liveness** — with a known selector, confirm the DDR buffer contains data that is *not* constant and
   not a ramp.
2. **Selector proof** — capture the same frames at two different selector values and confirm the buffers
   differ. A selector that changes nothing is the `iq_debug_mux` failure repeated.
3. **Cross-check against a trusted witness** — capture at selector 6 (constellation) and confirm the hard
   decisions derived from the raw samples match DBGCAP tap 3's digest for the same frames. If raw and
   digest disagree, one of them is wrong and neither may be used until that is resolved.
4. **Frame-boundary proof** — confirm the frame-start marker appears at the expected 49,349-sample spacing.

## 8. Risks

- **The "ramp" caveat.** `boot_known_good/README.md` records the rx-lpc IQ capture tap as *"STRUCTURALLY
  a ramp on this lineage — no IQ captures possible."* That refers to RX1's ADC path, and feeding the RX2
  packer from an internal fabric signal should bypass whatever causes it — **but this must be confirmed
  before committing a 2 h build**, because if the fault is in the packer or DMAC configuration rather than
  the ADC source, this design inherits it. Cheapest check: capture RX1 on the current image and
  characterise what the ramp actually is.
- **Symbol-domain taps produce a quarter of the words.** Selectors 3-7 are symbol domain (15.36 MSPS)
  while the packer runs at the 61.44 MSPS sample rate, so those captures hold ~12,337 words per frame
  rather than ~49,349. Nothing breaks, but host analysis must know which domain it is reading or frame
  counts come out 4x wrong. The marker channels make this self-checking: marker spacing reveals the
  actual words-per-frame of whatever tap is selected.
- **Rate mismatch across domains.** Sample-domain taps produce 4× the words of symbol-domain taps.
  The DMAC captures whatever is presented with valid, so this affects only how many frames fit in a
  buffer — but the host analysis must know which domain it is reading.
- **BD change means the source-only resynth path is unavailable** for this image, and the plan's existing
  build agents assume source-only. This image needs its own build procedure.

## 9. Out of scope

- Changing the modem's datapath behaviour. This is observation only.
- Replacing the digest witnesses. They stay; raw capture complements them and is cross-checked against
  them (§7.3).
- RX1's existing IQ path and the `beat_ila`.
