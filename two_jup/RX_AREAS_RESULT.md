# Task 1: 4-area RX ring vs the 2-area default — a clean NULL

**2026-08-10.** Host-side only, no flash. Data `r3cap/areas_20260810_132021/`.

## Result

**Deepening the ring does not help.** Four areas at M=16 measures the same as two areas
at M=16, to within 0.002 pp across seven runs.

| config | runs | pooled PER | CP95UL | gate | fundamental period |
|---|---|---|---|---|---|
| 2 areas x M=32 (today's default) | 2 | 1.550% | 1.625% | NOT MET | 32 |
| **4 areas x M=16** | 3 | **0.693%** | **0.734%** | **PASS** | 16 (3/3) |
| 2 areas x M=16 *(2026-08-09)* | 4 | 0.695% | 0.730% | PASS | 16 (4/4) |

Paired against the control: **+0.845 pp, 2/2 cycles** (one control run wedged).

The headline "0.693% vs 1.550%" is real but **entirely attributable to M**, not to the
areas. The A/B as specified varies two things at once; the 2-area/M=16 arm from the
previous session is what makes the attribution possible.

## Cost: goodput and CPU (saturating, rev direction, 146 = RX)

| config | goodput Mbit/s | delivered % | CPU % |
|---|---|---|---|
| 2 areas x M=32 | 13.92 | 92.83 | 13.4 |
| **4 areas x M=16** | **14.03** | 93.56 | 13.5 |
| 2 areas x M=16 *(2026-08-09)* | 14.04 | 93.60 | 13.5 |

The null holds on every axis: 4 areas matches 2 areas at M=16 in goodput (14.03 vs
14.04), CPU (13.5 vs 13.5) and PER (0.693 vs 0.695). `delivered %` is saturation-limited
(15 Mbit offered into a ~13.9 Mbit/s link) and is not a PER figure.

## Two independent confirmations that ring depth is irrelevant here

1. **The loss periodicity still tracks M, not the ring.** 4 areas x M=16 gives
   fundamental period **16** in 3/3 runs (92 / 91 / 93% of gaps exact multiples of 16),
   identical to 2 areas x M=16. Quadrupling the ring did not shift the signature at all.
2. **Occupancy is unchanged** — `backlog_max` stays at M and `full_eager` stays ~18%.

## Why this was worth doing anyway

It falsifies a specific, well-motivated hypothesis — mine. The reasoning was:

> forcing the drain slower raised PER 1.324% -> 5.945%, so drain latency is causally on
> the critical path to re-arming the engine; with 2 areas the re-arm is *structurally*
> gated on the drain; therefore decoupling them should help.

The flaw: showing a variable **can** dominate when pushed to 48 ms does not show it is
the **binding constraint** at its natural ~1 ms. At M=16 the re-arm is already fast
enough, so removing the coupling buys nothing.

It also answers the ring-full-vs-timing question directly and empirically. The ring never
approaches full occupancy, and giving it 2x the areas changes nothing — consistent with
the structural argument that overflow is unreachable (an area is resubmitted only after
its drain completes, so the DMA can never overwrite an undrained slot) and with the
failed slices reading back as the `carve_zero` pattern rather than as newer valid data.

**More memory is not the fix. Neither is more areas.**

## What is deployed, and the safety property

`QPSK_RX_AREAS` (default 2) selects 2..4 areas. Area stride is `CARVE / nareas`, which at
`nareas=2` is exactly the historical `RX_MULTI_MAX * SLOT_BYTES`, and with 2 areas the
"submit a clean area now" branch can never fire because the clean mask is always empty —
so the legacy drain-then-submit order is preserved.

**That property was verified on hardware, not assumed:** the 2-area/M=32 arm reproduced
**1.331%** against the sweep's 1.362% baseline (per-run 1.202–1.614%). Had it not, the
whole comparison would have been void.

A real bug was caught during the build by `-Wall`: `rxq_queued_flag[2]` was still sized 2
while the new code indexes up to 4 — an out-of-bounds write that would have silently
corrupted adjacent statics. Fixed by hoisting `RX_AREAS_MAX` above both declarations.

## Recommendation

**Keep `RXM=16` on the stock 2-area ring.** No code, no flash, no extra memory. Retain
the N-area code as a validated-neutral option (it costs nothing and `nareas=2` is
hardware-proven equivalent), but do not deploy `nareas=4` — it buys nothing.

## Caveat on today's data

The rig is markedly less stable today than during the overnight sweep: one control run
wedged outright and the surviving controls spread 1.331–1.770% (the sweep's range was
1.202–1.614%). The 4-area arm was clean in 3/3. The null result does not depend on this —
0.693 vs 0.695 is far inside any plausible spread — but the *control* numbers should be
read as noisier than last night's.

## Open, and not explained by any of this

The residual ~0.69% still traces to multi-ms host stalls at batch boundaries whose source
is unidentified. Eliminated so far: `carve_zero` (71 us measured, ~50x too small), the
nap (`nap_n=0`, never executes), and now drain-coupling. Still unexplained: the main loop
runs at only ~2160 iterations/s (~460 us each) while never sleeping and polling with
timeout 0, with 188 iterations/minute exceeding 2 ms.
