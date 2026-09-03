# Overnight scratch — findings as they land (2026-08-09/10)

Working notes. The durable write-up is `RX_CONFIG_SWEEP_RESULTS.md`.

## 1. The ring-depth axis does not exist host-side (settled)
Queued mode: ring = **2 areas x M slots**, axi_dmac holds ONE request ahead. Ring depth
IS `2*M`. Cyclic (the real deep ring) probed: **CONFIG.CYCLIC=0 on the deployed
bitstream** — arms, then `dma_rx_ok=0 crc_drop=0`, nothing lands. Staged in
`STAGED_CYCLIC_RX.md`. Axes actually available: M, and RXQ=0/1.

## 2. Neither race counter fires (M=32)
`defers=0` **and** `engine_gaps=0` at M=32, over 3869 completions.
- `defers` was the wrong instrument by construction: it fires only when SUBMIT is
  pending, and in steady state the slot is always free.
- `engine_gaps` is the right one (transfer ended with the next area not queued) and it
  is also 0 — so **the engine never starves**. Needs a positive control before this
  negative is trusted (task #24).
- Known false-negative, bounded: `rx_arm_queued` leaves area 0's flag set from the arm
  submit, so at most ONE gap per arm can be missed. A gap-driven mechanism would need
  ~850 events at M=32, so the negative stands.

Occupancy at M=32: `full_eager` 741/3869 (19%), `backlog_sum` 30819 → **7.96 of 32
slices undrained at completion (25%)**, `backlog_max=32` (sometimes nothing drained).
Headroom is tight-ish but the engine still never starved.

## 3. Loss RISES with M — it is not one-slot-per-batch
Measured 0.34 / 0.68 / 2.55% at M = 16/32/64. A one-frame-per-boundary law would go as
**1/M** (6.25 / 3.13 / 1.56%) — i.e. fall as M grows. It does the opposite. So only a
FRACTION of batches lose a slot, and that fraction grows steeply with M:
0.05 → 0.22 → 1.63 of the 1/M ceiling.

## 4. *** The failed slices are largely UNWRITTEN, not corrupted ***
For steady-state CRC-failed records, the logged raw header seq:

| capture | bad | `host_seq==0` |
|---|---|---|
| q32_c1 | 2297 | 288 (12.5%) |
| mab_M32_r1 | 616 | 367 (**59.6%**) |
| mab_M16_r1 | 261 | 121 (**46.4%**) |

`host_seq==0` means the slice still held the `carve_zero` pattern — the DMA never wrote
it, or the write was not visible when the drain read it.

**And both classes carry the SAME periodicity and the SAME phase, per run:**

| capture | zero-seq | other |
|---|---|---|
| M32_r1 | n=360, period 32 phase 31, 90% | n=105, period 32 phase **31**, 84% |
| M32_r3 | n=296, period 32 phase 22, 83% | n= 99, period 32 phase **22**, 79% |
| M16_r1 | n=118, period 16 phase 0, 90% | n= 85, period 16 phase **0**, 94% |

(Phase is relative to the first steady-state frame, so it is not comparable ACROSS runs
— the point is that within each run the two classes agree exactly.)

**Reading:** one fixed slot per batch, sometimes entirely unwritten (zeros), sometimes
partially written (garbage seq). That is a write-visibility / partial-write signature,
not a channel or decode signature — and it sits downstream of the demod, which is
exactly why the ADC, float and netlist legs all disagreed about which frames were bad.

### The discriminating experiment (task #25)
Two hypotheses both predict zeros:
- **(a) visibility race** — `TRANSFER_DONE` is set at EOT but the last-written slice is
  not yet visible to the CPU when the drain reads it.
- **(b) fabric gap** — the frame never entered the batch (tuser gating), so the slot
  legitimately stays zeroed.

**Re-read on CRC failure in the drain path discriminates them.** If a re-read decodes,
it is (a) — and that is a genuine FIX, not a mitigation like `-M 16`. If it does not,
it is (b) and the loss is upstream of the DMA.

Corollary worth checking: `reg_packets` (fabric counter 0x104) is logged per record, so
whether the fabric counted a frame the host never delivered is answerable from existing
captures.

## 5. Housekeeping
- 148 verified untouched mid-night: md5 **01499916** (identical to the pre-session
  baseline), 4 nakstat strings, 0 rxqstat. Byte-identity confirmed on hardware, not just
  in the local matched-basename test.
- `perf_ceiling.sh fwd` in ROOT_CAUSE_RX_BATCH.md next-steps is the **wrong direction**
  (fwd puts 148 on RX). Goodput must use `rev`.
- **Push is blocked: `GH_TOKEN` invalid.** Commits are local-only.

## 6. The host scores every fabric frame — and the bad ones sit after a stall

Largest monotonic segment per capture, steady state:

| capture | fabric frames | host records | ratio | Δreg_packets at BAD | at GOOD |
|---|---|---|---|---|---|
| M32_r1 | 55919 | 55911 | **1.000** | **9.87** | 0.90 |
| M32_r3 | 55853 | 55847 | **1.000** | **9.11** | 0.93 |
| M16_r1 | 55897 | 55893 | **1.000** | **5.90** | 0.98 |

Two things fall out:

**(i) ratio = 1.000.** The host writes one record per fabric frame — no phantom records
from empty slots and no records missing. So the zeroed slices are *not* slots the fabric
never filled; they line up 1:1 with frames the fabric counted. That argues against
hypothesis (b) (fabric gating) and for (a) (the host read a slot whose data was not
there yet).

**(ii) A bad record sits where the fabric counter jumped ~10 frames (M=32) / ~6 (M=16)**,
against ~0.9 for good records — and the jump **scales with M**. Bad slices are read at
the moment the host resumes after waiting out the fill, i.e. at the completion boundary,
not scattered through the batch.

Combined with `backlog_max = M` (completions where the host had drained *nothing*), the
suspicion is that **completion is sometimes detected early**, and the drain then reads a
region the DMA has not finished writing. `rx_done_q()` tests the per-ID `TRANSFER_DONE`
bit, IDs are `rx_q_nsub++ & 3` and each area reuses its ID every other cycle; the bit is
cleared at SOT and set at EOT, so there is a window between one transfer's EOT and the
next transfer's SOT where the incoming area's DONE bit is still set from *its previous*
transfer. Reading it there would report a completion that has not happened.

NOT yet established — the arithmetic does not fully line up (a premature completion
should spoil far more than one slot per batch, and measured loss is 0.68% at M=32, not
~20%). Recorded as the leading structural suspect, to be settled by the re-read
experiment and, if needed, by logging the raw `TRANSFER_DONE` word at completion.

## 7. *** The periodicity is NOT specific to the queued path *** (cycle 1, n=1)

| cfg | RXQ | M | PER% | gate | CPU% | backlog/cmp | period |
|---|---|---|---|---|---|---|---|
| q16 | 1 | 16 | 0.705 | PASS | 14.4 | 2.97 / 16 = 19% | 16 |
| q8  | 1 |  8 | 0.748 | PASS | 14.5 | 1.78 / 8 = 22% | 8 |
| q32 | 1 | 32 | 1.202 | NOT MET | 13.5 | 7.97 / 32 = 25% | 32 |
| l16 | 0 | 16 | 1.731 | NOT MET | 14.2 | n/a | **16** |
| l32 | 0 | 32 | 1.838 | NOT MET | 14.0 | n/a | **32** |
| q64 | 1 | 64 | WEDGED (live window 0s of 60s) | — | 9.8 | 45 / 64 = **70%** | aperiodic ~69 |

Three things:

**(a) Legacy tracks M too.** `RXQ=0` is a different architecture — reset and reprogram
per transfer, no one-ahead queue — and its loss is *still* periodic at exactly M. So the
batch periodicity is **inherent to batching**, not an artefact of the queued path. Any
explanation resting purely on queued-path bookkeeping (ID reuse, submit timing) is
therefore incomplete at best.

**(b) Legacy is WORSE, so do not "fix" this by reverting.** 1.73/1.84% vs 0.71/1.20%.
Consistent with the documented ~2% per-boundary reset-window loss the queued path was
built to remove. Queued + small M is the right direction.

**(c) M=8 does NOT continue the halving — it plateaus.** 0.748% at M=8 vs 0.705% at
M=16 (M=8 marginally worse). This answers next-step #2 from ROOT_CAUSE_RX_BATCH.md: the
trend turns over between 16 and 8, which bounds the mechanism — the loss is not simply
proportional to batch size all the way down.

**(d) M=64 is unstable, not merely lossy.** Last session it measured 2.55%; this time it
wedged the link outright. Its backlog is 70% of the area with `full_eager` 20/1142
(1.8%) — the host is hopelessly behind. Both observations say the same thing: do not run
M=64.

Cycle 1 is n=1 and NOT a result yet; the load-bearing numbers are the paired-by-cycle
table over all cycles.

## 8. *** THE MECHANISM: a multi-ms host stall at the batch boundary ***

Segmenting steady-state records by inter-record time:

| capture | M | gap before GOOD | gap before BAD | stalls >4ms | % of batches |
|---|---|---|---|---|---|
| M32_r1 | 32 | **0.803 ms, >4ms in 0.00%** | median 4.80 ms, >4ms in 52% | 321 | **18%** |
| M16_r1 | 16 | **0.803 ms, >4ms in 0.00%** | median 4.00 ms, >4ms in 50% | 130 | **4%** |
| q8_c1  |  8 | **0.803 ms, >4ms in 0.00%** | median 2.39 ms, >4ms in 37% | 107 | **2%** |

0.803 ms is exactly the frame period (1/1245 f/s). So in normal operation the host is in
perfect lockstep with the fabric — it is not "behind" at all, despite `backlog` showing
25% of the area unconsumed at completion (that counter tracks the eager scan pointer,
not real lag).

**Not one good frame in any capture follows a >4 ms gap.** And essentially every stall is
followed by exactly one bad frame (M=32: 313 bad at burst position 0 across 314 bursts;
M=16: 125/126; M=8: 90/91).

**This explains the whole shape of the data:**
- *Why loss rises with M* — the stall RATE rises with M (2% → 4% → 18% of batches).
- *Why it looks periodic at M* — stalls happen at batch boundaries, so losses are
  separated by multiples of M.
- *Why it is not one-per-batch* — only 2–18% of batches stall.
- *Why M=8 plateaus* — the stall rate is already down at ~2%; a floor dominates.
- *Why legacy tracks M too* — legacy also does per-boundary work, so it also stalls.
- *Why the slices read as zeros* — see below.

### Prime suspect: `carve_zero` before every submit
`rx_q_submit` does `carve_zero(area, M * pkt_bytes)` before submitting — **M x 1400 bytes
of UNCACHED Device-memory writes** on every batch boundary. At M=32 that is 45 KB of
uncached stores; at Device-memory write rates that is plausibly milliseconds, and it
scales with M exactly as the stalls do. It also explains the zeros: the failing slice
holds the `carve_zero` pattern because zeroing is precisely what the host was doing.

The stall medians (4.80 / 4.00 / 2.39 ms for M = 32/16/8) scale with M but not linearly,
so `carve_zero` is likely the dominant term rather than the only one. NOT yet proven.

### The fix this suggests is much better than `-M 16`
`carve_zero` exists only to keep the "valid CRC = fresh slice" eager invariant — a stale
slice must fail to decode. That does not require zeroing 1400 bytes: **zeroing the first
few bytes destroys the frame magic and the CRC just as effectively**, a ~175x reduction
in uncached writes per slice.

If the stall is `carve_zero`, header-only zeroing should remove most of it, and with it
the loss — at ANY M. That is a real fix, not a mitigation, and it is host-side only.

**This supersedes the drain-delay probe as the top experiment.** (Drain delay is still
worth running as the positive control for `engine_gaps`, which reads 0 everywhere.)

### 8b. Refinement: the unit is the loss EPISODE, and episodes are bounded by M

Frame-level framing overstated it — ~40% of bad frames arrive 0.03 ms apart, i.e. they
are continuations, not separate events. Grouping consecutive bad records into episodes:

| capture | M | bad | episodes | mean size | **max size** | preceded by >1.6ms gap | median start gap |
|---|---|---|---|---|---|---|---|
| M32_r1 | 32 | 616 | 417 | 1.5 | **31** | **84.9%** | 10.43 ms |
| M16_r1 | 16 | 261 | 184 | 1.4 | **16** | **82.1%** | 7.21 ms |
| q8_c1  |  8 | 290 | 184 | 1.6 | **8**  | **80.4%** | 4.00 ms |

Baseline for comparison: only **0.02–0.1%** of GOOD frames follow a >1.6 ms gap.

Two sharp facts:

**Maximum episode size equals M exactly** (31≈32 / 16 / 8). Loss never crosses a batch
boundary — the unit of damage is bounded by one area. Mostly singles, occasionally the
whole batch.

**~80–85% of episodes begin right after a multi-ms host stall**, and the median stall
scales with M (10.4 / 7.2 / 4.0 ms). Good frames essentially never follow one.

So the corrected mechanism statement is: *the host stalls for milliseconds at batch
boundaries; on resumption it reads slices that are still holding the carve_zero pattern;
the damage is confined to the current area and is usually one slice but can be the whole
batch.* Loss rises with M because both the stall rate and the stall duration rise with M.

## 10. zerohdr A/B: manipulation worked, comparison underpowered

The manipulation did exactly what it was designed to do:

| arm | zero_us_mean | zero_us_max |
|---|---|---|
| base (full-area zero) | 70.8 / 70.5 / 70.8 us | 182 / 135 / 158 |
| hdr  (8 B per slice)  | **0.8 / 0.6 / 0.8 us** | 16 / 16 / 20 |

An **88x reduction** in pre-submit zeroing cost, reproducible across all three pairs.

The FER comparison, however, is **underpowered and proves nothing**: only 1 of 3 pairs is
clean. Base wedged in cycle 2 and took a 3-burst link dropout in cycle 1 (8.046%); the
surviving pair is c3, 1.518% -> 1.344%, delta +0.174 pp at n=1. The link was materially
less stable in this window (~00:00-00:40) than during the sweep.

**This does not weaken the carve_zero refutation**, because that refutation rests on the
direct timing (71 us against 4-10 ms stalls, ~50x short), not on the FER delta. Indeed
an effect larger than ~0.3% of the boundary time was never physically available: 71 us
out of a 25.7 ms batch period. Re-running the A/B for more pairs would buy precision on
a quantity already known to be negligible, so the remaining time goes to attribution
instead.

Worth keeping anyway: **header-only zeroing is a free, strictly-better implementation**
(88x less uncached write traffic for an identical invariant, since qpsk_frame_decode
rejects on the magic first). It is just not the fix for this bug.

## 12. *** POSITIVE CONTROL FAILED -- engine_gaps is an INVALID instrument ***

Forced drain delay 1500 us/slice at M=32 = 48 ms of drain against a 25.7 ms transfer, so
the resubmit MUST be late and the engine MUST starve. The delay unambiguously landed:

    normal      : loop_over2ms=188   loop_us_max=4105 us    PER=1.324%
    delay 1500us: loop_over2ms=2952  loop_us_max=53243 us   PER=5.945%

and yet **`engine_gaps=0` again**.

**Why it cannot fire:** the check lives in `rx_q_on_complete()`, but during a long drain
that function is never reached. `rx_pump_queued` returns to the main loop after each
delivered frame and re-enters at step 1 (drain); step 3 (completion detect) only runs
once the drain is finished. So the counter is structurally blind to precisely the
condition it was written to detect.

**Consequences, stated plainly:**
- **RETRACTED: "the engine never starves".** `engine_gaps=0` carries no information. The
  earlier write-up claim that this is "not a race" is NOT established.
- `defers=0` remains valid but uninformative by construction (it can only fire on submit
  contention, which cannot occur in steady state).
- **So the race hypothesis is once again OPEN**, not refuted. Nothing measured tonight
  rules it out.

An earlier 400 us/slice control also read zero, but that one was *my sizing error*, not
the counter's fault: 32 x 400 us = 12.8 ms of drain against a 25.7 ms transfer still
leaves the resubmit in time, so zero was the arithmetically correct answer. Only the
1500 us run is a valid control -- and it is the one that exposes the flaw.

## 13. *** CAUSAL: drain latency drives loss ***

The same control is a causal experiment, and it is the strongest mechanistic result of
the night:

| | loop_over2ms | loop_us_max | PER |
|---|---|---|---|
| normal | 188 | 4.1 ms | **1.324%** |
| +1500 us/slice drain delay | 2952 | 53.2 ms | **5.945%** |

**Slowing the drain raises loss 4.5x.** Combined with the observational finding (no good
frame follows a >4 ms gap; 80-85% of loss episodes begin right after one), the
stall -> loss relationship is now demonstrated causally, not merely correlated.

Note the burst profile also shifts: 5-20 and 21-100 frame episodes jump from 6/4 to
83/60, i.e. longer stalls destroy proportionally larger runs -- consistent with episode
size being bounded by how long the host is away, and with max episode size = M.

**This is the actionable core:** whatever the stall turns out to be, host-side latency at
the batch boundary is on the critical path, and reducing it reduces loss. That is also
the simplest explanation for why -M 16 beats -M 32 -- less time per boundary window.

## 14. *** LAYER A/B BISECT: the fabric is NOT clean -- prior framing was wrong ***

### Layer A (in-fabric ROM/BIST, DMA + byte plane + host CRC all bypassed) -- DONE
`reverse_rom_soak.sh 120`, 148 TX ROM -> 146 RX:

    locked golden on try 1: cap=0x4922282  dpkts/3s=3734 (= 1245 f/s, nominal)
    then over 152 s:
      packets advanced 75559 (630/s -- HALF nominal)
      rstcs 14
      BIST bit_errors grew 4,424,468 across 1199 growth events
      cap_out golden in only 0.4% of samples
    adc_forensic: maxGap median 1, max 1 -> ADC/SSI delivery CLEAN
    cfc(0x154): median 4548, std 3925, range [-6395, 18380]
    VERDICT: reverse ROM/BIST WEDGES -> PHY/modem/interface
             adc clean but cfc dither -> MODEM CARRIER LOOP

**This contradicts the framing built up over this session.** With the DMA and host
entirely out of the path, the fabric still loses badly. "Fabric clean, host lossy" is
FALSE as a general statement.

### Layer B (PN through the batched DMA, host-scored) -- INVALID, not clean
    SEQRX frames_scored=31456 ok=0 biterr=0 lost=0 dup=0 junk=31456  seq_span=0
    SEQDMA torn_zero=0 torn_stale=0 scattered=0 batch_drop=0 batch_m=0

Every frame junk, nothing anchored, so every zero means "never measured", NOT "no fault".
Raw dump shows pure noise with no frame structure, and TX ran at 467 f/s against the
1245 f/s air rate. Two defects, both mine:
  * `batch_m` is never set from rx_multi in seq_run, so BATCH_DROP was inert. The
    classifier self-test passed only because the test sets batch_m by hand.
  * `-S` does not sustain the f1536 air cadence. Making the mode combination legal
    (and verifying the banner + cmdline) is not the same as making it work at that
    geometry -- I checked the former and inferred the latter.

### What survives, and what does not
NOT supported any more: "the loss is host-side" as a blanket claim.
STILL supported, and still needing an explanation the carrier loop cannot give:
  * the steady-state loss period tracked -M across FOUR values (8->8, 16->16, 32->32,
    64->aperiodic). The fabric has no knowledge of the host's DMA batch depth.
  * failed slices read back as the carve_zero pattern (never-written memory).
So the working model is TWO faults: an episodic modem-carrier-loop fault (Layer A, large,
dominates when it fires, and is very likely the all-day wedge source) plus a steady-state
M-periodic host-DMA fault (small, ~0.7%). The float oracle's 0.0000% ceiling stands but
is CONDITIONAL -- those bigiq captures were health-gated, i.e. drawn from stable-carrier
windows.

### Next
1. Fix Layer B: set batch_m = rx_multi; make -S sustain the f1536 air rate; re-run.
2. Treat the carrier loop as a first-class target -- LOOP_POKE on 0x170-0x184 is the
   existing runtime lever, and this campaign has prior history there (the loop-filter
   gain that ran 3.14x hot).
