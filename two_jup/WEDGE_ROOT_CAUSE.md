# WEDGE + TX ZERO-FILL ROOT CAUSE — host RX drain starves the TX feeder
## (2026-08-12; causally confirmed in loopback; on-air A/B in flight)

After weeks of circling, one mechanism explains the wedge, the periodic TX
zero-payload frames, the "11.7° phase step", the loss-A/B "isolated losses",
`-S` never framing on air, and the reverse-direction asymmetry.

## The mechanism

The daemon is single-threaded. `rx_pump_queued()` drains ALL `rx_multi` (32)
slices of a completed area in ONE call; the TX queue is only `max_inflight=2`
transfers (~1.6 ms of air at F1536) deep. Any drain longer than ~1.6 ms starves
the transmitter. Junk slices are expensive to score, so:

```
junk at RX -> slow drain (up to ~84 ms measured) -> TX starves ->
empty air slots -> more junk at RX -> ...           (self-sustaining)
```

Two severities of TX starvation, both observed:

| starvation | modulator behaviour | RX sees | shows up as |
|---|---|---|---|
| short (~2–25 ms) | frame cadence intact, airs **valid frames with ZERO payload** | zero-payload frames, framesync fine | the periodic production zero-fill (`TX_ANOMALY_SCAN.md`), 0.25–3 % of frames, exact 30/33/34-frame limit-cycle cadence; the "phase step" pair is the resume transient |
| long (~84 ms) | loses cadence entirely | slicer noise, framesync ~254/s false-syncs | **the WEDGE** (`WEDGE_JUNK_CLASS.md`: junk = demod noise, zero transmitted content) |

## The evidence chain (all 2026-08-12, all committed)

1. **RX seam exonerated:** CP2/CP3 checkpoints (`QPSK_CKPT`) clean in 7/7 wedge
   reps — cp2 advancing, cp2==cp3, zero mismatches (`wedgeck_095205/_102044`).
2. **Junk classified:** PN9 circular-correlation detector — real frame scores
   0.949, all 379 junk slices ≤ 0.047. No shifted/stale PN. The RX is slicing
   non-signal (`WEDGE_JUNK_CLASS.md`).
3. **Feeder caught in the act:** `QPSK_TXLOG` submit ring — bursts separated by
   ~84 ms gaps ~7/s from t=0, `inflight_after=0` at every gap end (fabric fully
   drained), `spins=0` across all 67k submits (TX DMA never lacked capacity —
   **fabric TX path exonerated**). Gap length == `pump_us_max` == one all-junk
   32-slice drain at ~2.6 ms/slice (`wedgeck_102044`, `txlog_gaps.py`).
4. **Causal confirmation:** `QPSK_RX_DRAIN_BUDGET=4` (cap slices per pump call
   so TX is fed between chunks): **0/3 wedges vs 6/7 unbounded**, framesync at
   the full 1246/s in-run vs 254/s (`wedgeck_103138`). Instrument A/B passed
   (ckpt on/off pump_us_max ×1.04–1.10).
5. **Production tie-in (prior evidence, reinterpreted):** loss A's 25.7 ms host
   read gap; the TX seq skips (53878, 53899–53900 never aired); the zero-payload
   frames at k=300/330 (`ANCHOR_REDERIVED.md`); the exact-period zero-fill in
   all 4 banked captures with the reverse (RX-heavy) direction ~10× worse
   (`TX_ANOMALY_SCAN.md`) — the drain is heavier there, exactly as the
   `seq_tx_fill` MMIO-cost comment measured (604 vs 1186 f/s).

## The fix

- **Shipped instrument/env:** `QPSK_RX_DRAIN_BUDGET=N` caps slices drained per
  pump call (0 = historical unbounded). `N=4` ends the wedge in loopback.
- **Production candidate:** budget=4 on both `-G` daemons; on-air interleaved
  A/B (`rx_config_sweep.sh` 4th rotation field, `bud4:1:16:4` vs `bud0:1:16:0`)
  scoring zero-fill events per capture (`zerofill_score.py`) — RUNNING as of
  this writing.
- **Deeper (not yet needed):** raise polled `max_inflight` toward `TX_SLOTS=8`
  for more air-time buffer; cheapen junk scoring in the `-S` scorer (instrument
  CPU saturation, not a product path).

## What this does NOT explain

The **26-frame RX burst** (26/26 seqs decode clean from the same samples;
25 garbage host reads in <1 ms with `reg_packets` frozen). That is an RX-side
delivery stall, still open — CP1/framestat instrument image is built and gated
(`FRAMESTAT_NOTES.md`) if host-side evidence stays insufficient.

## Flash implications

The wedge needs NO flash. The staged instrument image (framestat CP1 + f1536
tap netlist + `rx_byte_dma` CYCLIC, all gated, `b6bc60d`) remains staged for
the burst investigation and future cyclic work.
