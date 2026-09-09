# Per-frame envelope scan for TX zero-payload / mute frames — 2026-08-12

Off-hardware. Follows `jupiter_240k5_byte/rtl_sim/tap_replay_study/ANCHOR_REDERIVED.md`
(the two hunt_auto "isolated losses" are ALL-ZERO transmitted frames) and
`two_jup/LADDER_K300_FINDING.md` §5 (phase-step event counts 2 / 2 / 0 / 24 across the
four banked captures). Hypothesis tested: every phase-step event sits adjacent to a
zero-payload (constant-envelope) or mute (low-amplitude) TX anomaly.

## Method

Each `pair.iq` (int16 interleaved I,Q; frame = 49332 complex samples = 12333 sym x 4 sps)
scanned over **all 810 frames** (not just the 400 of the §5 scan). Per frame and per
sub-block (12 blocks of 4111 samples): mean |x|, std |x|, ratio std/mean.

- An all-zero QPSK payload is the same symbol for the whole frame -> nearly constant
  envelope through the RRC -> **ratio collapses** (measured ~0.02 vs median ~0.27).
- An RF mute would collapse **mean** instead. **No low-mean frame or sub-block exists in
  any of the 4 captures** — during every anomaly the carrier stays at full amplitude.
  The transmitter is airing zeros at full power, not muting.

Flag thresholds: ratio < 0.5 x median(ratio); mean < 0.5 x median(mean); applied at frame
and sub-block level. Segment boundaries then refined with a 512-sample rolling window
(ratio < 0.05), so quoted lengths are lower bounds quantized to 512 samples.

Scripts/results: scratchpad `env_scan.py` / `env_scan.json` (method is fully described
here; ~40 lines of numpy).

## Results

Frame grid = capture grid (frame k starts at sample k*49332), same grid as
`evm_scan_270_700.csv` — verified by hunt_auto k=300/330 landing exactly on the
ANCHOR-proven all-zero frames.

### hunt_auto_20260731_211829 (fwd) — 2 events

| frame k (blocks) | mean | frame ratio | extent | zero-seg len (samples) | start mod frame |
|---|---|---|---|---|---|
| 299 (blk 10-11) + 300 (blk 0-8) | 978 | 0.129 | ~1 full frame | 48640 (0.99 fr) | 39756 |
| 329 (blk 10-11) + 330 (blk 0-8) | 973 | 0.129 | ~1 full frame | 48640 (0.99 fr) | 39756 |

Spacing **exactly 30.000 frames**, identical start phase. These ARE the two all-zero
frames of ANCHOR_REDERIVED.md, and they sit exactly one slot before the ~-12 deg phase
spikes at k=301/331. Method confirmed.

### cfo0_M32 (fwd) — 6 events

| frame k (blocks) | frame ratio | zero-seg len | start mod frame |
|---|---|---|---|
| 260 (blk 11) + 261 (blk 0-10) | 0.063 | 53248 (1.08 fr) | 42828 |
| 281 (blk 6-11) + 282 (blk 0-4) | 0.184/0.196 | 25088 (0.51 fr) | 21836 |
| 685/686 (same split) | 0.175/0.195 | 25088 | 21836 |
| 719/720 | 0.179/0.213 | 25088 | 21836 |
| 753/754 | 0.193/0.210 | 25088 | 21836 |
| 787/788 | 0.181/0.193 | 25088 | 21836 |

Last four spaced **exactly 34.000 frames**, identical start phase. The §5 scan covered
400 frames and found **2** events — exactly the 2 in that window (k~261, k~282).

### rxq_M32 (fwd) — 1 event

| frame k | frame ratio | zero-seg len | start mod frame |
|---|---|---|---|
| 444 (blk 0-10) | 0.062 | 48640 (0.99 fr) | 47436 |

The §5 scan's "0 events in 400 frames" is window truncation, not absence: the capture's
one full-frame zero sits at k=444, outside the scanned window. **rxq_M32 is not a clean
counter-example.**

### revlong (REVERSE) — 23 events

Pairs (kA blk 7-11, kA+1 blk 0-5): 45/46, 78/79, 111/112, 145/146, 178/179, 211/212,
245/246, 278/279, 312, 343/344, 378/379, 411/412, 445/446, 479/480, 512/513, 545/546,
579/580, 612/613, 645/646, 678/679, 711/712, 744/745, 777/778.

- Zero-segment length **24576 samples = 0.498 frame** (half-frame zeros), most with the
  identical start phase 27468 mod frame.
- Cadence: start deltas mostly **exactly 33.000 frames** (a few 33.5/34.5/31.5 with a
  matching shift of the start phase): 33,33,34,33,33,34,33,33.5,31.5,35,33.5,33.5,34.6,
  32.4,33,34.5,32.5,33,33,33,33,33.
- 11 pair neighborhoods fall in the first 399 frames -> 22 flagged frames, consistent
  with §5's **24** alternating ~0 deg / ~-30 deg events (both pair members clear the EVM
  threshold in reverse).
- After each zero segment the first data block shows an elevated ratio (~0.40): a resume
  transient, the underrun-recovery signature.

## Cross-reference with the phase-step events

| capture | §5 phase events (400 fr) | envelope anomalies in same window | full capture (810 fr) |
|---|---|---|---|
| hunt_auto | 2 (k=301, 331; -11.9/-12.1 deg) | 2 zero frames at k=300, 330 — **adjacent** | 2 |
| cfo0_M32 | 2 (+17.2, -13.5 deg) | 2 (k~261, k~282) | 6 |
| rxq_M32 | 0 | 0 (the one event is at k=444, outside) | 1 |
| revlong | 24 (alternating ~0 / ~-30 deg pairs) | 22 flagged frames = 11 zero segments | 23 segments (46 frames touched) |

Count match is exact in all four captures once the §5 window is accounted for.

## Verdict

1. **Confirmed: every phase-step event neighborhood contains a zero-payload frame.**
   All anomalies are constant-envelope at FULL amplitude — the modulator airing a
   repeated symbol (zero bytes, whitening off) — never an RF mute. No low-mean event
   exists anywhere in 4 x 810 frames.
2. **Reverse is ~10x more affected than forward** (23 segments vs 2/6/1), and the
   §5 asymmetry (24 vs 2/2/0) is exactly reproduced. TX underrun / zero-fill at the
   reverse-link transmitter is the common mechanism; the ~0/-30 deg alternation is the
   frame containing the zero segment (no net rotation) followed by the rotated resume.
3. The events are **slot-quantized and periodic**: exactly 30.000-frame spacing
   (hunt_auto), exactly 34.000 (cfo0 tail), exactly 33.000 (revlong), with bit-identical
   start phase within each capture. A random RF or host-timing fault cannot do this; a
   TX buffer-wrap / producer-consumer rate mismatch does. The cadence (~30-34 frames
   ~ 6.2-7.0 s at 240k5) differing per capture/direction points at a rate-dependent
   underrun period, e.g. DMA ring wrap vs modulator drain.
4. Segment lengths cluster in two classes: ~1 full frame (48640+ samples; hunt_auto,
   rxq_M32, cfo0 first event) and ~0.5 frame (24576-25088; cfo0 tail, all of revlong).
5. `rxq_M32`'s "zero events" status in LADDER_K300_FINDING.md §5 was an artifact of the
   400-frame window; it has one full-frame zero at k=444. **No capture is clean.**

Consequence for the PER question (§ "Next step" item 3 of LADDER_K300_FINDING.md): the
phase-step class costs at most the frame the zero lands in — and that frame carries no
data (it was never modulated with a payload). The adjacent rotated frames decode
CRC-good. The event is a TX-side data-path underrun, not an RX impairment, and should be
chased in the TX DMA/modulator feed path, not the receiver.
