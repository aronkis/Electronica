# ADRV9002 escalation — BBDC tracking cal inserts 256 samples into the consumed RX stream (unit-specific)

## One-line summary

On one specific Jupiter (ADRV9002 Rev 12.0, Firmware 0.22.64, API 68.20.12,
LVDS 1.92 MSPS profile), **every iteration of the BBDC rejection tracking
cal (~1.5 s period) inserts exactly 256 samples (133 µs) into the RX sample
stream delivered to the consuming fabric path — on both RX1 and RX2, at any
LO frequency — while a second, identically configured unit is clean.**

## Affected / reference units

| | affected | reference |
|---|---|---|
| host | 10.0.0.148 ("148") | 10.0.0.146 ("146") |
| silicon | Rev 12.0 | Rev 12.0 |
| firmware / stream / API | 0.22.64 / 0.7.18.0 / 68.20.12 | identical |
| kernel | 6.12.0-ga14dd7c6dea2 (ADI) | identical |
| profile | lvds_1p92_mhz (zero-IF, rxInitChannelMask 0xC3) | identical |

## Failure signature (measured, not inferred)

- At each tick, the consumed stream gains **exactly +256 samples** (a repeat
  of the preceding block), holds displaced for ~0.165 s, then loses 256
  (returns to the original timing). Measured as a +32-symbol step of the
  8 SPS 240 kBd modem's preamble timing grid, loss-free, via per-symbol
  fabric telemetry of the sync state machine.
- Metronomic: 600 s census = 403 episodes, median period 1.489–1.495 s,
  200/206 inter-episode gaps at exactly one period (RX2 test).
- **LO-invariant** (0.9 / 2.0 / 3.4 GHz), **both RX channels** (RX1 and RX2
  paths through independent fabric route), **absent in fabric loopback**
  (internal Tx→Rx: zero displacement over 6.6 tick periods).
- **The capture branch of the same RTL net decodes bit-perfect through the
  event** (690/690 frames), while the modem-consumed branch takes the +32
  displacement — the insertion appears between the shared net and the
  consuming path's valid stream at the delivery boundary.
- Bit-true RTL replay of the captured stream does NOT reproduce the event:
  the RTL is exonerated; injecting +256 samples into a clean capture
  reproduces the full live signature exactly (content-independent).

## Trigger identification (single-variable A/B, live link)

780 s session, 180 s segments, one toggle at a time, restored between:

| toggle | tick cadence | link errors |
|---|---|---|
| baseline | 20–21 episodes / 30 s | ~150 events / 30 s |
| `rssi_tracking_en=0` | unchanged | unchanged |
| **`bbdc_rejection_tracking_en=0`** | **0–2 / 30 s — insertion stops** | DC junk storm (correction dropped) |
| `agc_tracking_en=0` | unchanged | unchanged |

- Disabling BBDC tracking is not a usable workaround: the DC correction is
  dropped immediately (junk storm ~16×). The driver's
  `in_voltage0_bbdc_rejection_en` accepts only 0/1 — the API's PAUSED state
  is not reachable from this kernel.
- Decomposition (second session): toggling `bbdc_rejection_en=0` at runtime
  is **inert** — insertion cadence and link error rates unchanged, no storm.
  The tracking iteration therefore both maintains the applied correction and
  produces the insertion; no freeze/hold path exists via the exposed attrs.
- fan-control (1.5 s temp poll) exonerated separately (service stopped,
  insertion continued). Temps at test: 61–62 °C.

## Reproduction

1. Arm the LVDS 1.92 MSPS profile, stream RX continuously into any
   sample-position-sensitive consumer (our QPSK modem's preamble tracker).
2. Observe a +256-sample insertion every ~1.5 s (per BBDC cal iteration).
3. `echo 0 > in_voltage0_bbdc_rejection_tracking_en` → insertions stop.
4. `echo 1 > …` → insertions resume at the cal period.

## Asks

1. Mechanism guidance: what in the BBDC cal iteration path can duplicate a
   256-sample block into one consumer of the RX SSI while a parallel
   capture consumer of the same fabric net sees a continuous stream?  Is
   there a firmware/profile-level mitigation for this unit?
2. Driver/API: a supported path to ADI_ADRV9001_BBDC_REJECTION_PAUSED
   ("holds the last correction value") — the kernel driver truncates
   bbdc_rejection_en to a bool (kstrtobool), so PAUSED is unreachable in
   the field.  Also: with rejection PAUSED, does the RX_BBDC tracking-cal
   iteration stop being scheduled by the ARM (i.e., would PAUSED stop the
   insertions)?
3. Observed toggle semantics worth explaining: bbdc_rejection_en=0 at
   runtime is overridden (inert) while the tracking cal runs, even across
   ENSM bounces; bbdc_rejection_tracking_en=0 produced an instant
   correction drop + DC error flood in one session but only erratic 30-60 s
   insertion pauses (no flood, cal resuming while disabled) in another —
   state/history-dependent behavior.
