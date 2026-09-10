> Evidence ledger, moved verbatim from `two_jup/ESCALATION_ADI.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

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

## Addendum 2026-07-19 — the tick does NOT reproduce on internal RF loopback

Each unit was run in ADRV9002 near-end loopback (rx0_near_end_loopback, TX ->
own RX through the ADC path, rx_input_select=1, BBDC tracking active, Tx LO ==
Rx LO, ROM TX), and the P1D consumed-path telemetry was captured for 30 s
(~20 tick periods) and analysed for the +32 accepted-offset step.

Result: BOTH units show ZERO tick. The accepted offset is rock-stable
(148: accOff pinned at 27; 146: at 25 -- a single distinct value, 0 +32/-32
steps over 7.18M symbol records, despite 6341 preamble detections). The
modem locks and the timing never moves.

Implication: the 256-sample insertion requires the OVER-THE-AIR reception
path -- it does not appear on a clean internal loopback even with the BBDC
cal active. Combined with the cal A/B (disabling bbdc tracking stops the tick
on the OTA link), this points at the BBDC cal APPLYING a correction on the
real received signal, rather than a signal-independent cal iteration. The
capture branch (voltage0) remains metronomic through the tick (confirmed again
here: raw rx-lpc capture lag std = 0), so only the modem-consumed P1D telemetry
or decode reveals it.

> **CORRECTION (see 2026-07-20 addendum below):** an earlier version of this
> paragraph said reproduction needs "an OTA *or DC-offset-bearing* RX signal."
> The DC-injection experiment below **disproves the DC-offset half**: a loopback
> carrying a DC offset 15x the signal does NOT reproduce the tick. The trigger
> is a **time-varying** received signal, not DC presence.

## Addendum 2026-07-20 -- DC offset is NOT the trigger (loopback has 15x DC, static, no tick)

Directly testing whether adding DC to the internal loopback reproduces the tick.
Near-end loopback on 148, lean image, host seq-frame TX (byte plane), ROM-clean
control first.

Findings:
- **Clean loopback baseline (BBDC on): bit-perfect, no tick.** 150 s, ~31.8k
  frames, BER 0.0, 0 lost / 0 gaps -- at the SAME operating point as the OTA
  forward path (Rx AGC railed at 34 dB, rssi 17.8 dB). So the tick is NOT caused
  by the high-gain operating point (loopback sits at it and stays clean).
- **The loopback ALREADY carries an enormous DC offset.** With the BBDC
  correction dropped (`bbdc_rejection_tracking_en=0`), the raw uncorrected Rx DC
  is |DC| = 5504 vs signal rms 360 -- **a 15x DC/signal ratio** (Rx front-end /
  LO self-mixing DC, amplified by the railed gain). BBDC corrects this ~15x DC
  continuously on the clean baseline, and it STILL does not tick.
- **That DC is static.** Sampled over 20 s (6 bursts, BBDC off): |DC| =
  5504/5504/5503/5504/5503/5504 -- drift < 0.03%. Rock-constant.

**Conclusion -- the trigger is a TIME-VARYING received signal, not DC presence.**
A huge but *static* DC lets the BBDC tracking cal converge and apply a ~zero
correction UPDATE each iteration -> no insertion. The tick fires on OTA because
the real channel's DC/offset is continuously *changing* (independent-LO drift,
thermal, fading, AGC), so each ~1.5 s cal iteration applies a NON-ZERO correction
update -- and it is the act of loading a changed correction that inserts the 256
samples. This refines Ask #1: the mechanism to explain is **why applying a BBDC
correction UPDATE reindexes the RX SSI delivery by 256 samples**, and it tells
ADI a **static-DC bench loopback cannot reproduce the tick regardless of DC
magnitude** -- a reproduction rig needs a time-varying RX DC (a real or
emulated drifting offset), not merely a DC-offset-bearing signal.

## Addendum 2026-07-20 — the FABRIC side is definitively exhausted (why this must be fixed device-side)

Answering the "did you try everything in the FPGA fabric first?" question: yes,
and it is now closed. Every fabric-side lever against the insertion has been
applied or ruled out by construction:

1. **Deterministic acquisition wedge — FIXED.** The one design-side lock failure
   (Gardner/Rice symbol-timing loop-filter integrator wrap) was reproduced on the
   shipping netlist (`tb_timing_wedge`, WEDGED) and fixed by construction
   (`timing_hardening_overlay`: IC/integrator clamps + saturating conversion,
   TB: RECOVERED); shipped both boards.
2. **Insertion displacement — COMPENSATED as far as information theory allows.**
   The +32-symbol deinterleaver stale-grid casualty is cancelled in fabric
   (P1E-v3, splice-battery proven, shipped in the current lean image), and the
   frame-sync coast-through is at the floor: ~1.1 lost frames per episode, which
   is the physically-inserted (256-sample) window itself — information-
   theoretically unrecoverable (no valid data exists to coast to). No fabric
   change reduces this further.
3. **The last remaining fabric suspect — EXONERATED by source inspection.** The
   "single-cycle enable/valid upset inside the Carrier Synchronizer's library
   DDS/NCO" hypothesis was checked against the generated HDL (`NCO.v`): the CS
   NCO's valid path is transparent — output valid is a 5-deep shift of `validIn`,
   the phase accumulator holds (does not corrupt) on a `validIn` gap, and the
   block has no internal `validOut` pipeline (valid is handled externally). There
   is no opaque strobe-eater to harden; a valid-debounce would only fabricate
   stale symbols in place of the tick's real sample displacement (silent bit
   errors), which is why it is not a fix.

**Conclusion:** the forward BER floor (~1.4e-4 on 148) is confirmed to originate
device-side, not in the fabric. The reverse link — same fabric, same design,
clean unit 146 receiving — meets ~2e-6. Removing the BBDC insertion (Asks #1–#3
above) or replacing/RMA-ing unit 148 (the tick is unit-specific and absent on
146) is the only remaining path to forward <1e-4. This is not a fabric bug.

## Addendum 2026-07-20 — tone + tap-blind localization (the burst is a calibration sample-delivery artifact, not a signal defect)

Closing out the user's "prove the source is a transceiver calibration issue, use
simple waveforms (tones) to show it" ask. Artifacts + figure:
[`cal_proof_20260720/`](cal_proof_20260720/) (`tick_calibration_proof.png`).

Three fresh, single-session results on the live pair (lean image `dcf5c5fb29e6`),
tying the burst to the ADRV9002 BBDC rejection tracking cal and pinning *where*
the disruption lives:

1. **Positive control — the burst is NOT in the delivered IQ data.** The tick is
   metronomic and LO-driven at **0.67/s** (census: 403 episodes / 600 s, gaps at
   exactly one 1.489 s period), so ~8 cal iterations — hence ~8 insertions — must
   fall in any 12 s OTA window with the cal running, **independent of SNR**. Yet
   in a forward OTA QPSK capture (12 s / 23.04 M samples) of BOTH the
   modem-consumed AGC-out tap (rx2-lpc, 0x10C mode 0) and the raw rx-lpc branch, a
   matched detector that spikes to coherence 1.0 on a synthetic +256-sample
   duplication finds **zero coherent lag-256 repeats** in the real stream (peak
   coherence ~0.9, non-metronomic = chance QPSK near-repeats, not the tick). The
   +256 insertion is therefore a read-pointer / SSI sample-delivery jump in the
   modem's consumption index, **invisible to any raw IQ DMA snoop** (consistent
   with the capture branch being clean through the tick). This is why only the
   now-stripped P1D sync-state telemetry ever imaged it. (The link also carried
   ~5e-4 aggregate BER during the window — above the ~1.4e-4 tick-only floor, i.e.
   some thin-margin non-tick loss too; the metronomic argument above does not rely
   on that number.)

2. **The BBDC cal is unambiguously active & doing real work on 148.** |residual
   DC| at the AGC-out tap = **0.8 LSB (tracking ON) → 178 LSB (tracking OFF)**,
   ~214×. The correction is effective and continuous — which is exactly why the
   residual DC stays flat (no DC step to see); the disruptive side-effect is the
   256-sample reindex on each correction *load*, not a residual-DC excursion.

3. **Tones attempted — a tone cannot image this particular fault (the "if
   possible" answer, negative).** 146 emits a pristine hardware-DDS tone (received
   peak/median 11.4M). Two independent reasons make a tone unable to serve as a
   probe here, so **no signal-domain conclusion is drawn from it**: (a) a pure
   tone does not lock the modem, so there is no frame-loss / sync witness that the
   tick even fired during the capture; and (b) the cal state during the tone
   captures was abnormal — the AGC-out tap read |DC| = **195 LSB with BBDC
   tracking ON** (vs 0.83 on the QPSK link) and did not move with the on/off
   toggle, i.e. the BBDC was not in its normal correcting loop without the modem
   consuming the RX SSI. A clean tone under an abnormal/uncertain cal state is
   uninformative either way. Conclusion: this fault is a sample-delivery *index*
   event, not a signal-content defect, so a simple waveform provides no observable
   handle on it on the lean image; the on-chip P1D sync telemetry (stripped) was
   the only thing that ever imaged it.

**Net (shows the source by elimination + direct A/B):** the burst disruption is
the ADRV9002 **BBDC rejection tracking calibration** on unit 148 — a device
calibration issue. It is *not* fabric (fabric exhausted, addendum above) and
*not* DC magnitude (static-DC addendum); it is a sample-delivery **index** event
(result #1: metronomic ~8/12 s, zero coherent 256-repeats in the IQ), not a
data-content corruption. Mechanism: each ~1.489 s cal iteration, on the
time-varying OTA offset, loads a non-zero correction that reindexes the RX SSI by
256 samples. The load-bearing evidence is the prior single-variable A/B (disabling
`bbdc_rejection_tracking_en` stops the tick) plus result #1 (metronomic-yet-
invisible-in-IQ) and result #2 (cal active, 0.83→178). Tones were attempted per
the ask but cannot image an index-domain fault (result #3). This reinforces
Ask #1 unchanged — explain why loading a BBDC correction update reindexes the RX
SSI delivery by 256 samples on this unit.
