# Root cause of the R3 steady-state frame loss — the RX DMA batch depth

**Status: root-caused, mitigated, and the <1% gate met without ARQ.** 2026-08-09.

## The result in one line

The steady-state loss is a **periodic drop of roughly one slot per queued RX DMA batch**.
Its period tracks `-M` exactly. Setting **`-M 16` instead of the default 32 halves delivered
PER and clears the gate**: pooled **0.667%, CP95 UL 0.707% (PASS)** against **1.356% /
1.423% (FAIL)** at `-M 32`, interleaved, ARQ off.

## How it was found

### The instrument was pointed at the wrong errors for the whole campaign
Every paired capture grabbed its Tap-A IQ at **t = 8.0–8.1 s**, which sits inside a post-arm
transient holding **~84% of a run's errors**, while the acceptance PER window starts at
t ≥ 15 s. So all 3569 archived "errored frames with IQ" came from the region the PER metric
discards. That is why Workstream R never produced an attribution.

Adding `CAP_SETTLE` to `capture_r3.sh` and moving the grab to t = 28 s proved the transient
**stays at 5–15 s regardless** (errors per bin were unchanged), so `iio_readdev` does not
cause it — purely a timing mistake in what we measured.

### Three replay legs, all saying "not the signal"
1. **ADC statistics identical.** Errored vs good frames: RMS 1595.7 ± 121.1 vs 1565.2 ± 112.2
   (ratio 1.0195), DC ≈ 0 both, no clipping.
2. **Float chain decodes everything**, including every frame the hardware failed. EVM has no
   predictive power — errored median 13.65% vs population 13.98%, 31 of 49 at or below the
   median, P(fail | EVM) flat-to-decreasing. **FER is independent of EVM across captures**:
   a 1.7× EVM change (22.55% vs ~13.5%) produced no FER change.
3. **Bit-true netlist fails DIFFERENT frames** on identical samples — hardware 626/627/659/
   755/787, netlist 650/651/687/688, zero overlap, 8–24 frames apart.

If the impairment were in the samples all three legs would agree on *which* frames are bad.
They do not agree at all.

### The periodicity
Errored positions are locked to a **fixed phase modulo 32**, and **89% of inter-error gaps are
exact multiples of 32**. Over full runs gap=32 dominates (333 occurrences), and 32 is the
*fundamental*: gap-on-multiple holds at 95% through P=32 and collapses to 27% at P=64.

**32 is the RX DMA batch depth** (`-M ${RXM:-32}`, `QPSK_RX_QUEUED=1`).

### Causation, by sweep
| `-M` | fundamental period | steady-state FER |
|---|---|---|
| 16 | **16** (phase 13, 90% of gaps) | 0.34% |
| 32 | **32** (phase 23, 88% of gaps) | 0.68% |
| 64 | ~69, jittered 65–75 | 2.55% |

### Confirmation, interleaved, delivered PER, ARQ off
| `-M` | per-run | pooled | CP95 UL | gate |
|---|---|---|---|---|
| 32 | 1.486 / 1.108* / 1.253% | 1.356% | 1.423% | NOT MET |
| 16 | 0.682 / 0.717 / 0.602% | **0.667%** | **0.707%** | **PASS** |

\* wedge-truncated run. Paired deltas +0.804 / +0.391 / +0.651 — 3 of 3 favour M=16.

## Why this explains everything that didn't fit

- **Not in the samples** — it is downstream of the demod entirely.
- **Netlist fails different frames** — it has no host DMA ring to reproduce.
- **EVM uncorrelated, FER flat across a 1.7× EVM change** — signal quality is irrelevant.
- **Isolated singles** — one slot per batch.
- **Reverse-direction only** — 146 runs the queued RX path in these captures.
- **ARQ works well when it engages** — independent, well-spaced single losses are the ideal
  retransmit target.

## Not a clean "one slot per batch" law

Fraction of the 1/M ceiling rises with depth: 0.05 → 0.22 → 1.63 for M = 16/32/64. Deeper
batches lose *disproportionately* more, which fits buffer pressure / timing rather than a
fixed index bug — and matches the jitter that appears at M=64.

## Next steps

1. **Measure the cost of `-M 16` before changing the default.** Smaller batches mean more DMA
   transactions per frame; CPU load and goodput are unmeasured. `perf_ceiling.sh fwd` gives
   the throughput number and has no build path, so it is safe.
2. **Try `-M 8`.** If FER keeps halving, the trend localises the mechanism further; if it
   turns over, that bounds it.
3. **Find the actual defect** in the queued RX path (`qpsk_tun.c`, `QPSK_RX_QUEUED`) — the
   sweep proves *where* it is, not *what* it is. The phase differing per bring-up (13, 23, 0,
   7, 2…) points at a ring index initialised from something run-dependent.
4. **Re-examine ARQ on top.** With M=16 at 0.667% and ARQ typically 0.03–0.10% when it
   engages, the two together could be very good — but the ARQ engagement failure
   (peer receives zero NAKs) is still open.
5. **Retire the 148-RX-tick vs 146-TX-EVM question for R3** — this evidence says neither.

## Tools added

- `loss_period.py` — fundamental-period detector from `frames.bin` alone, no IQ needed.
  Scores the *fundamental* (largest P whose multiples capture ≥70% of gaps); naive scoring
  always picks the smallest candidate because a multiple of 32 is also a multiple of 8.
- `bigiq_hunt.sh` — 80 M-sample steady-state captures with a health gate that rejects runs
  whose steady-state bad rate exceeds 5%.
- `m_depth_ab.sh` — interleaved delivered-PER A/B on batch depth, verifying the daemon
  actually took the requested `-M` from its cmdline.
- `CAP_SETTLE` in `capture_r3.sh` — moves the IQ grab past the post-arm transient.
