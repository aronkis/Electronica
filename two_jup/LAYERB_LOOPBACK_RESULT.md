# Layer B — FIRST TRUSTWORTHY DMA-BOUNDARY NUMBER (loopback), 2026-08-11

`DUR=90 ./loopback_s_test.sh` → `r3cap/loopback_20260811_173945/`

After six air-link runs produced nothing, the loopback bisect produced a number on the
first valid attempt — **and the wedge reproduced with no air, no peer and no RF.**

## The number

```
SEQDMA torn_zero=0  torn_stale=0  scattered=1  batch_drop=0  batch_m=32  tear_off=0..0
SEQRX  frames_scored=27260  ok=2766  biterr=1  lost=22389 (2766 gaps)  dup=0  junk=24493
SEQRX  seq_span=25156  accounted=25156  (ok+biterr+lost)
SEQRX  total_bits=33823808  bit_errors=1717  BER=5.076e-05
```

**It passes its own integrity check: `seq_span == accounted == 25156`.** Every seq in the
observed span lands in exactly one bucket. That is the check that was missing when the
earlier all-zero buckets were nearly reported as "the DMA is clean" — there, span was 0.

### What it says

| bucket | count | meaning |
|---|---|---|
| `torn_zero` | **0** | no slice was left half-written / never completed |
| `torn_stale` | **0** | no half-old/half-new slice |
| `batch_drop` | **0** | no whole batch of M dropped |
| `scattered` | **1** | one decode-side (non-DMA) corruption in 25156 |

**The batched DMA is not tearing writes and not dropping batches.** With `batch_m=32`
genuinely live (verified in the banner), `BATCH_DROP` was armed and did not fire. The
loss that IS present — `lost=22389`, ~89% of the span — is *whole frames never arriving*,
not corrupted or partially-written ones. That points upstream of the DMA boundary.

## The wedge reproduces in loopback

```
t=40s  ok=2766  ...
t=45s  ok=2766  <- frozen
t=106s ok=2766  while tx climbed to 80950
```

Wedged at **t≈45 s** (first run of the same test wedged at ≈36–40 s). No air, no peer, no
RF, no LO, no channel. **The wedge is not an RF/propagation effect**, which retires a
large part of the search space the campaign has been working through, and makes the wedge
reproducible on a single board with no bring-up lottery.

## Caveats — read these before using the number

1. **This is LOOPBACK, not the air link.** It bounds what the DMA does under a perfect
   channel; it is not the delivered-PER figure.
2. **The ~50% TX under-feed persists** (`TXRATE` ~600 f/s against 1245 f/s air). Half the
   air slots carry frames the feeder never wrote, which is where `junk=24493` comes from.
   So the instrument still samples only about half the DMA's behaviour, and the 89% `lost`
   figure is inflated by it. The DMA *bucket* result (0/0/0/1) is not affected — those
   classify frames that DID arrive.
3. `biterr=1` frame carried 1717 bit errors — a burst in a single frame, not a spread.

## The positive control, and the defect it caught in my own harness

Arm A runs `-G` in the identical loopback config. First version scored it on `dma_rx_ok`
and reported **VOID — control failed**. That was wrong: `-G` with no tun traffic and no
peer transmits *only idle* frames (`tunB_tx=0`, `idle_tx=161929`), so `dma_rx_ok` — which
counts DATA frames — is structurally zero and cannot indicate framing. The correct metric
is `idle_rx`, which advanced to **154028**.

The control was sound; my counter choice was blind. Same failure mode as `crc_health`
being a ratio and `engine_gaps` being unable to fire: a metric that cannot express the
condition it is asked about. Fixed in the script, with the reasoning recorded inline.

A second harness defect: the first run `pkill`ed the daemon at `DUR` while it had been
launched with `-d DUR+20`, so it never reached its end-of-run summary and the
`SEQRX`/`SEQDMA` classification — the actual number — was destroyed. The daemon is now
allowed to exit on its own.

## What this changes

- **`-S` works.** Six air-link runs assumed it and never checked; it frames, scores, and
  produces bit-exact PN in loopback. The Layer B instrument is sound.
- **The DMA boundary is not the ~0.7–1.4% fault**, at least under a perfect channel: no
  torn writes, no dropped batches, in 25156 classified frames.
- **The wedge is reproducible off-air**, on one board, in ~45 s.

## Next

1. Characterise the loopback wedge: repeat runs for a time-to-wedge distribution. It is
   now cheap (one board, no bring-up gate), where on-air TTW measurement was expensive
   and fluctuated 0.3–20 s on a ten-minute scale.
2. Fix the residual ~50% TX under-feed so the instrument sees the whole DMA, then re-run
   for a tighter bucket bound.
3. Only then return to the air link, where the remaining question is why `-S` frames in
   loopback but not on air.

---

# Session close — 2026-08-11 evening (autonomous)

## The clean dichotomy

**`-S` frames in loopback. `-S` never frames on air — including from a genuinely fresh
boot of BOTH boards.** `-G` frames on air fine (1023 f/s, 98% CRC) in the same session.

That is now a reproducible, cheap-to-test split, and it is the sharpest statement the
campaign has about this fault.

| config | `-G` | `-S` |
|---|---|---|
| internal loopback (`0x114=0`) | frames (`idle_rx` 154028) | **frames** (`ok=2766`, BER 5.1e-05) |
| air (`0x114=1`) | frames (1023 f/s, 98% CRC) | **never frames** (`ok=0`, 9 attempts) |

Ruled out cheaply along the way: **whitening is not the difference** — `bringup_r2r3.sh:43`
sets `WHITEN=${WHITEN:-0}`, so `-G` runs unwhitened exactly as `-S` does.

## A persistent non-framing state, cleared only by reboot

An 18-run anchor batch came back `ok=0` on **every** run, after the same board had been
framing in loopback 40 minutes earlier. The state survived daemon restarts and `0x000`
soft resets. A full reboot cleared it immediately: 4/4 reps framed again
(`ok=691/2979/202/2288`).

This matters operationally: `layerb_run.sh`'s retries do a bring-up but never a reboot,
so once a board enters that state, every attempt in the session is doomed regardless of
which hypothesis is under test. **It does not, however, explain the air-link failure** —
the fresh-boot run above still failed 3/3.

Also noted: 146's load average was **3.36** before that reboot.

## Time-to-wedge, off air

12 loopback reps across two batches, every one wedged:

```
batch 1 (8 reps):  20, 30, 10, 30, 45, 45, 45, 40   median 35s  stdev 13.1s  drift +4.0s/rep
batch 2 (4 reps):  10, 45, 15, 45                    median 30s  stdev 18.9s  drift +7.5s/rep
```

Broad, with a warm-into-stable-state trend. No fixed frame count at the wedge (`ok` at
wedge ranges 88..2979). A spread this wide argues **rate/occupancy or race**, not a
scheduled periodic event.

## The anchor control: NO VERDICT, and why

The first pass printed **"ARM-ANCHORED, TTW rises ~1:1"** off group means 25.0 / 38.3 /
50.0. That is not a result — it is n=3,3,2 with a within-group spread of ~25 s against a
20 s delay range, i.e. noise that happened to slope the right way. One run did not wedge
at all.

Rejected it and rebuilt the verdict with a **permutation test on the delay/TTW
correlation plus a power floor (n≥12)**, so the rule now knows how much evidence it needs.
Same defect as the on-air anchor verdict that could not distinguish "constant" from
"floored" — a decision rule with no notion of sufficiency will always eventually fire.

**No anchor claim is made.** The follow-up batch that would have supplied the power hit
the non-framing state instead.

## Harness defects found this session (all caught by controls, none by reading output)

| defect | consequence | caught by |
|---|---|---|
| `-G` control scored on `dma_rx_ok` | declared a WORKING loopback config VOID | `-G` with no traffic sends only idle frames — `dma_rx_ok` is structurally 0 |
| daemon `pkill`ed at `DUR` with `-d DUR+20` | destroyed the `SEQRX`/`SEQDMA` summary — the actual number | summary line simply absent |
| `ok_final==0` scored as "wedged at t=0" | 18 fake zeros would have poured into the TTW distribution | an all-zero batch that was obviously a different state |
| anchor verdict with no significance test | claimed ARM-ANCHORED off noise | inspecting the per-group values behind the means |
| `mux_test` read write-only registers | confident "SAME" verdict that discriminated nothing | write-then-readback positive control |

## Where the fault now sits

Not in the DMA boundary — under a perfect channel: `torn_zero=0, torn_stale=0,
batch_drop=0, scattered=1` over 25156 classified frames, with `seq_span == accounted`.

Not in RF/propagation for the wedge — it reproduces in loopback with no radio at all.

The open question is narrow and well-posed for the first time: **what does `-S` do
differently from `-G` that survives internal loopback but not the air path?** Both use the
same fabric, same geometry, same whitening setting, same `-M 32` queued RX. The remaining
structural difference is `tx_send_batch` (used only by `-S`) versus `tx_send` (used by
`-G`) — testable in loopback, off the air link, with the instrument that now works.

---

# tx_send_batch A/B (off-air, loopback) — 2026-08-11

`./batch_ab.sh 3` → `r3cap/batchab_20260811_192052/`. Interleaved, 3 cycles, NOBATCH
banner verified present on every NOBATCH run.

## On the question it was asked: CLEAN

**`tx_send_batch` is NOT the `-S`/`-G` framing difference.** Both arms framed 3/3 and
both wedged 3/3 in loopback. The last named candidate for "why `-S` frames in loopback
but never on air" is closed.

## But it surfaced something else, and it is not subtle

| arm | ok | lost | **delivered = ok/(ok+lost)** | txrate |
|---|---|---|---|---|
| BATCH | 1974 | 15871 | **11.1%** | 488 f/s |
| NOBATCH | 849 | 431 | **66.3%** | 346 f/s |
| BATCH | 957 | 7699 | **11.1%** | 765 f/s |
| NOBATCH | 237 | 115 | **67.3%** | 480 f/s |
| BATCH | 2412 | 19409 | **11.1%** | 728 f/s |
| NOBATCH | 262 | 132 | **66.5%** | 461 f/s |

**Per-frame submission delivers 6.0× more of what it sends than batched submission**
(66.5% vs 11.1% median), 3/3 in each arm with no overlap between the groups.

The ratios are suspiciously exact: BATCH is **11.1% (=1/9) three times running**, across
runs whose absolute `ok` differs by 2.5×; NOBATCH sits at ~66.5% (≈2/3). Deterministic
structural fractions, not stochastic loss — which points at the submit granularity
itself rather than at contention or timing.

**The confound, handled:** the raw `ok` comparison is NOT usable — NOBATCH feeds slower
(461 vs 728 f/s median) because one frame per transfer costs more, so it necessarily
scores fewer `ok`. My verdict function flagged that confounded metric ("MATERIAL
DIFFERENCE in ok >3x"). The delivery *ratio* is independent of feed rate and is the metric
that matters; the verdict rule needs fixing to use it.

## Status: STOPPED for a decision

Per the owner's instruction, the `tx_send_batch` test came first and no new hypothesis or
on-air run follows it without a decision. Two things are now true at once:

1. The named candidate for the air-link framing failure is **closed** — batching is not it.
2. A separate, strong, reproducible defect in the batched TX submit path is **open**:
   it loses ~89% of submitted frames where the per-frame path loses ~34%.

(2) is a real lead on delivered PER and is testable entirely off-air. It does not explain
(1). The open question — whether Layer B on air is the right instrument at all — is
unchanged and is the owner's call.

---

# CORRECTION — the loopback "lost" figure was the instrument, not the DMA

`grep` for callers settles it: **`tx_send_batch()` has exactly ONE caller** — inside
`seq_tx_fill()`, the `-S` PN feeder. Every production path uses `tx_send()`:

```
-G data      qpsk_tun.c:2223      retx_pump   :1288
-G idle      qpsk_tun.c:2235      axr_pump    :1496
-B reference qpsk_tun.c:1709      k5 path     :1642
```

Two consequences, and the second retracts a reading above.

**1. The 6x batching defect is an INSTRUMENT defect, not a product defect.** It cannot
affect delivered PER, because nothing in the production data path submits batched. It is
still worth fixing — but as a fix to Layer B's trustworthiness, not as a PER lead. It
should not be prioritised as though it were a product bug.

**2. The `lost=22389` (~89%) in the loopback Layer B run is contaminated.** That section
reads it as "whole frames never arriving → upstream of the DMA boundary". The batch A/B
now shows the batched submit path itself delivers only **11.1%** of what it sends, while
per-frame delivers 66.5%. So most of that 89% loss was **the instrument's own TX losing
frames before they ever reached the air**, not a delivery fault being measured.

The DMA *bucket* result is unaffected and still stands — `torn_zero=0, torn_stale=0,
batch_drop=0, scattered=1` with `seq_span == accounted`, plus a second run at
`BER 0.000e+00` over 35.5M bits. Those classify frames that DID arrive, and they are
clean. What is retracted is the loss *magnitude* as evidence about the DMA.

**Owed before Layer B is quoted again:** switch `-S` to the per-frame path (make
`QPSK_SEQ_NOBATCH` the default, or simply call `tx_send`), so the instrument stops
manufacturing the loss it is meant to measure.
