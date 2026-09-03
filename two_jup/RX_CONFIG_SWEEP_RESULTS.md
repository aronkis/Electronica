# RX configuration sweep — ranked results and recommendation

**Overnight 2026-08-09/10.** Host-side only; no FPGA flashed. Board 148 untouched
throughout (verified). Raw data `r3cap/sweep_20260809_214536/`, report `REPORT.txt`.

---

## Recommendation

### Ship now: `RXM=16` on the stock 2-area ring

**Free, immediate, and under the gate.** 0.695% delivered PER, CP95UL 0.730% (PASS),
against 1.362% at the M=32 default — beaten in 4 of 4 paired cycles, median +0.715 pp.
No code change, no flash, no extra memory, and **no measurable cost**: goodput 14.04 vs
13.94 Mbit/s and CPU 13.5% vs 13.4%, both inside run-to-run variation. Applying it is one
variable: `RXM=16`.

`-M 8` is statistically indistinguishable (0.660% / 0.691%, 5/5 paired). M=16 is preferred
only because it has independent replication across two sessions; **do not treat the
M8-vs-M16 difference as real**. Do not use `-M 64` (wedged the link outright), and do not
revert to the legacy path (`RXQ=0` is 2-4x worse and degrades over hours).

This is a **mitigation**: it shortens the exposure window, it does not remove the
mechanism.

### Permanent fix: cyclic-mode HDL rebuild (removes the re-arm entirely)

The loss mechanism is a multi-millisecond host stall at the batch boundary that leaves
the DMA engine un-armed while frames keep arriving. Every host-side lever only shrinks
that window; **cyclic mode deletes it**. `rx_arm_cyclic()` arms once and the engine
re-issues forever with no host action in the transfer gap — there is no re-arm to be late
for, at any M.

Requires `CONFIG.CYCLIC=1` on the `axi_dmac` instance (a base-platform rebuild; the
deployed bitstream is CYCLIC=0, probed). Staged, **not flashed** — register map, build
inputs and trade-offs in `STAGED_CYCLIC_RX.md`.

**Two things to weigh before flashing, stated because they cut against this plan:**

1. **The benefit is predicted, not measured.** Cyclic has never delivered a single frame
   on this rig (`dma_rx_ok=0` on the CYCLIC-0 probe), so "removes the re-arm" is an
   argument from the code path, not an observation.
2. **It makes true overflow possible for the first time.** Today overflow is structurally
   unreachable — an area is resubmitted only after its drain completes, so the DMA can
   never overwrite an undrained slot. Under cyclic the engine writes regardless of host
   progress, guarded only by `seq_gaps` lap-detection in `rx_pump_cyclic` that has never
   executed. It trades a well-characterised starvation failure for an untested overflow
   failure.

Also unresolved: the stall's *source* is still unidentified. `carve_zero` (71 us
measured, ~50x too small), the nap (`nap_n=0`, never executes) and drain-coupling
(4-area ring: clean null) are all eliminated. Cyclic makes the link immune to the stall
without explaining it — which is a legitimate engineering fix, but not a diagnosis.

### Sequence
1. `RXM=16` today — free, gets under 1%.
2. Cyclic rebuild reviewed and flashed deliberately, with the overflow path exercised
   before it carries production traffic.

---


## Ranked table

Delivered PER, interleaved, ARQ off, f1536/R3, 146 = RX.

| cfg | RXQ | M | runs | PER% | CP95UL | gate | med PER | runs >2% | CPU% | backlog/cmp | period | wedges |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **q8**  | 1 |  8 | 5 | **0.660** | **0.691** | **PASS** | 0.648 | 0/5 | 14.5 | 1.73 / 8 = 22% | 8 (5/5) | 0 |
| **q16** | 1 | 16 | 4 | **0.695** | **0.730** | **PASS** | 0.706 | 0/4 | 14.4 | 2.90 / 16 = 18% | 16 (4/4) | 0 |
| q32 | 1 | 32 | 6 | 1.362 | 1.405 | NOT MET | 1.383 | 0/6 | 13.6 | 8.27 / 32 = 26% | 32 (5/5) | 2 |
| l32 | 0 | 32 | 5 | 2.902 | 2.965 | NOT MET | 2.907 | 4/5 | 13.9 | n/a | 32 | 0 |
| l16 | 0 | 16 | 6 | 4.611 | 4.682 | NOT MET | 5.511 | 5/6 | 14.0 | n/a | 16 | 0 |
| q64 | 1 | 64 | 1 | **WEDGED** (live window 0 s of 60 s) | | | | | 9.8 | 45 / 64 = **70%** | aperiodic ~69 | — |

Paired by cycle against the `q32` default (unit = the run, which is what controls for
this rig's drift):

| cfg | n | median Δ | mean Δ | cycles favouring | sd |
|---|---|---|---|---|---|
| q16 | 4 | **+0.715 pp** | +0.701 | **4/4** | 0.170 |
| q8  | 5 | **+0.680 pp** | +0.687 | **5/5** | 0.183 |
| l32 | 5 | −1.667 pp | −1.518 | 0/5 | 0.798 |
| l16 | 6 | −4.062 pp | −3.220 | 0/6 | 2.128 |

### Cost: goodput and CPU

Saturating UDP, 15 Mbit offered into a link whose ceiling is ~13.9 Mbit/s, direction
**rev** (148 -> 146, so 146 is the receiver and the `-M` knob is actually exercised).
Goodput is what the RECEIVER got (`rx_bytes`/`dur`), not what the sender offered.

| cfg | M | goodput Mbit/s | delivered % | CPU % |
|---|---|---|---|---|
| q8  |  8 | **14.05** | 93.65 | 13.3 |
| q16 | 16 | **14.04** | 93.60 | 13.5 |
| q32 | 32 | 13.94 | 92.93 | 13.4 |
| l16 | 16 | 13.88 | 92.51 | 13.1 |
| l32 | 32 | 13.50 | 89.99 | 13.0 |

**`-M 16` costs nothing.** The prior expectation was that smaller batches mean more DMA
transactions per frame and therefore more CPU; that is **not** what happens — CPU is
13.3-13.5% across every queued config, and goodput is if anything marginally higher at
small M. So the ~2x FER reduction is free.

Do not over-read the 0.1 Mbit/s spread between q8/q16/q32: one run each, ~0.8%, well
inside run-to-run variation. The defensible claim is that goodput and CPU are
**indistinguishable** across the queued configs. The legacy gap (l32 at 13.50 / 90.0%) is
larger and lines up with its much higher loss.

`delivered %` here is NOT a PER figure: 15 Mbit is offered into a ~13.9 Mbit/s link, so
~7% is shed by saturation regardless of config. It is included only so a repeat of the
first attempt's failure -- `rx_pkts=0`, i.e. nothing received at all -- cannot be mistaken
for a low-but-valid measurement.

CPU is the daemon's own utime+stime over its lifetime under the **capture** traffic
pattern in the ranked table, and under the **saturating** pattern here. Different loads;
not one measurement.

---

## Method notes (what these numbers are, and are not)

- **Interleaved, not blocked.** One cycle = one pass through the rotation, so every
  config sees the same channel drift. Block-vs-block comparison has been wrong more than
  once in this campaign.
- **The paired table is the load-bearing comparison.** Its unit is the run. The pooled
  Clopper-Pearson bound treats frames as the unit; losses here are bursty and
  run-correlated, so CP95UL is a precision figure, not a between-config test.
- **Stated exclusion policy.** Four runs (`q16_c4`, `q16_c6`, `q8_c3`, `l32_c5`)
  contained bursts of >100 consecutive lost frames — ~1 s link dropouts, three per
  affected run, ~7.2% PER. **Every other run in the sweep had zero such bursts.** That is
  a different failure mode from the periodic per-batch loss being compared, so those runs
  are excluded from the ranking and listed explicitly in `REPORT.txt`. They fall across
  three different configs, which is why they are treated as link events rather than a
  configuration property.
  *This mattered:* judged on pooled PER without the exclusion, q16 ranked **below** q32.
- **Every row verified.** Each run confirms the daemon actually took the requested `-M`
  from `/proc/<pid>/cmdline`; a silent default would invalidate the comparison.
- **A one-cycle read would have been wrong.** After cycle 1, M=8 looked comparable to
  M=16 and the legacy path looked merely mediocre. Six cycles were needed to separate
  them.

---

## The mechanism (this is the more useful result)

The sweep answers "which config", but the telemetry answers "why", and it points at a
fix better than any config choice.

### Is it a race? UNRESOLVED — and one of my own instruments was invalid

Both race counters read zero across every queued config and all six cycles. Neither zero
means what it appears to mean:

- **`defers = 0`** — valid but uninformative *by construction*. It can only fire when a
  request is already pending, and in steady state the submit slot is always free. It
  tests a contention mode that cannot occur here.
- **`engine_gaps = 0`** — **INVALID. Retracted.** A positive control (forced drain delay
  of 1500 µs/slice = 48 ms of drain against a 25.7 ms transfer, so the engine *must*
  starve) still reported zero. The check lives in `rx_q_on_complete()`, but during a long
  drain that function is never reached: `rx_pump_queued` returns to the main loop after
  each delivered frame and re-enters at the drain step, so the completion step only runs
  once draining finishes. The counter is structurally blind to the exact condition it was
  written to detect.

**So the race hypothesis is OPEN, not refuted.** An earlier write-up draft claimed "the
engine never starves"; that claim is withdrawn. (A first control at 400 µs/slice also
read zero, but that was a sizing error of mine — 12.8 ms of drain against a 25.7 ms
transfer leaves the resubmit in time, so zero was correct there. Only the 1500 µs run is
a valid control, and it is the one that exposed the flaw.)

The lesson is the one the caveat anticipated: a counter that only ever reads zero proves
nothing until a control shows it can fire. Here the control did not merely fail to
validate the counter — it showed the counter could never have worked.

### Causal: drain latency drives loss

The same control is the strongest mechanistic result of the night:

| | loop stalls >2 ms | worst iteration | PER |
|---|---|---|---|
| normal | 188 | 4.1 ms | **1.324%** |
| +1500 µs/slice forced drain | 2952 | 53.2 ms | **5.945%** |

**Slowing the drain raises loss 4.5x.** With the observational result below (no good
frame follows a >4 ms gap; 80–85% of loss episodes begin immediately after one), the
stall→loss link is now *demonstrated causally*, not merely correlated. The burst profile
shifts too: 5–20 and 21–100 frame episodes jump from 6/4 to 83/60, so longer stalls
destroy proportionally longer runs.

This is the actionable core: **host-side latency at the batch boundary is on the critical
path, and reducing it reduces loss** — which is also the simplest explanation for why
`-M 16` beats `-M 32`.

### It is a multi-millisecond host stall at the batch boundary
Segmenting steady-state records by inter-record time:

| capture | M | gap before GOOD frame | loss episodes preceded by >1.6 ms gap | stall rate |
|---|---|---|---|---|
| M32 | 32 | 0.803 ms; **>4 ms in 0.00%** | **84.9%** | 18% of batches |
| M16 | 16 | 0.803 ms; **>4 ms in 0.00%** | **82.1%** | 4% of batches |
| M8  |  8 | 0.803 ms; **>4 ms in 0.00%** | **80.4%** | 2% of batches |

0.803 ms is exactly the frame period. In normal operation the host is in **perfect
lockstep** with the fabric — not behind at all, despite `backlog` showing ~26% of the
area unconsumed at completion (that counter tracks the eager scan pointer, not real lag).

**Not one good frame in any capture follows a >4 ms gap**, while 80–85% of loss episodes
begin immediately after one. Only 0.02–0.1% of good frames follow even a >1.6 ms gap.

Supporting facts:
- **Maximum episode size equals M exactly** (8 / 16 / 31≈32). Damage never crosses a
  batch boundary. Usually one slice, occasionally the whole area.
- **Failed slices are largely UNWRITTEN, not corrupted** — 12–60% of CRC-failed records
  carry `host_seq == 0`, i.e. still the `carve_zero` pattern. Zero-seq and garbage-seq
  failures share the **same period and same phase within each run**, so they are one
  event seen at two severities.
- **Host records match fabric frames 1:1** (ratio 1.000), so these are not slots the
  fabric never filled — the frame existed and the host read the slot too early.

**This explains the whole shape of the data**, including the thing that never fitted:
loss *rises* with M (0.66 → 0.70 → 1.36 → wedge) whereas a one-frame-per-boundary law
would fall as 1/M. It rises because both the stall rate and the stall duration rise with
M. The periodicity at M follows because stalls happen at batch boundaries. And it is not
one-per-batch because only 2–18% of batches stall.

It also explains why the legacy path tracks M as well: legacy does per-boundary work too,
so it also stalls — worse, in fact.

### `carve_zero` was the prime suspect. It is refuted.

`rx_q_submit` writes `M x pkt_bytes` of **uncached Device memory** before every submit
(45 KB at M=32). It fit the story on every qualitative point: uncached writes, scaling
with M, and it explains why failed slices read back as zeros — that is the pattern the
host writes. So the daemon was instrumented to time it directly rather than infer it
from a FER delta:

| | zero_us_mean | zero_us_max |
|---|---|---|
| full-area zero (today) | **70.8 / 70.5 / 70.8 us** | 182 / 135 / 158 |
| header-only (8 B/slice) | 0.8 / 0.6 / 0.8 us | 16 / 16 / 20 |

**71 microseconds, not milliseconds.** 45 KB in 70.8 us is ~635 MB/s — the uncached-write
cost was simply assumed too high. Across a 60 s run `carve_zero` totals ~324 ms, 0.5% of
wall time, against stalls of 4–10 ms. It is ~50x too small and is **eliminated**.

An effect larger than ~0.3% of the boundary period was never physically available
(71 us out of 25.7 ms), so the accompanying FER A/B could not have resolved anything —
and in the event it was underpowered anyway (1 of 3 pairs clean; base wedged in one cycle
and took a link dropout in another). **The refutation rests on the timing, not the A/B.**

Header-only zeroing is nevertheless a strictly better implementation — an 88x reduction
in uncached write traffic for an identical invariant, since `qpsk_frame_decode` rejects
on the `0x51 0x4B` magic before anything else. It is just not the fix for this bug, and
is left behind the `QPSK_RXQ_ZEROHDR` env (default off).

`framelog` is refuted by arithmetic: its 1 MB stdio buffer flushes ~3 times per run
against 321 stalls, so the measurement instrument is not causing the loss it measures.

### Where the milliseconds actually go — open
The daemon is a **single-threaded TX+RX bridge** under SCHED_FIFO 50, and `rx_want_spin`
naps `usleep(60 us)` through the bulk of each fill. A nap that occasionally returns in
4–10 ms — timer slack or descheduling — would reproduce the stall exactly, and would
scale with M because larger batches mean more nap time per batch. Instrumentation for
this (nap duration, and main-loop iteration gap, both with >2 ms counters) is in the tree
behind `QPSK_RXQ_STAT`; results in `OVERNIGHT_FINDINGS_SCRATCH.md`.

The three-way outcome matters for where any fix belongs:
nap overshoot ≈ loop gap → fix in the RX path; loop gap ≫ nap → the time is spent
elsewhere in the shared loop and the RX batch is only where the damage lands; neither →
the process is descheduled and it is not a host-code problem at all.

## What could not be done host-side

The brief asked to hold M=32 and deepen the ring. **That axis does not exist.** In queued
mode the ring is exactly two areas of M slots and the axi_dmac holds one request ahead,
so ring depth *is* `2 x M`. The genuinely deeper ring (`QPSK_RX_CYCLIC`, one arm, no
per-batch boundary) was probed on hardware and **delivers nothing at all**
(`dma_rx_ok=0`, `crc_drop=0`) — the deployed bitstream is `CONFIG.CYCLIC=0`, and the
`axi_dmac` instance is not in this repo, so enabling it is a base-platform rebuild.
Staged, not built: see `STAGED_CYCLIC_RX.md` for the register map and the trade-offs.

## Corrections to earlier records

- `ROOT_CAUSE_RX_BATCH.md` next-step 1 says to measure goodput with
  `perf_ceiling.sh fwd`. **That is the wrong direction** — `fwd` puts 148 on RX and never
  exercises the 146 batch depth under test. Use `rev`.
- `ROOT_CAUSE_RX_BATCH.md` frames the loss as "roughly one slot per queued batch". The
  fuller picture is above: only 2–18% of batches lose anything, the loss is
  stall-triggered, and episodes can span up to a whole area.
- Next-step 2 ("try M=8; if FER keeps halving the trend localises further") is **answered:
  it does not keep halving.** M=8 ≈ M=16, so the curve flattens below 16.
