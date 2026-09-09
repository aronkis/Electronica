# TICK_CAMPAIGN — byte/control-plane tick family vs the air-singles fingerprint

2026-08-13, operator-approved full campaign (fleet-parallel). **Outcome: the
campaign was STOPPED on evidence before spending fleet time**, because a
consistent re-derivation of the *measured* target fingerprint showed the
campaign's premise — fit gate MEMORY (memoryless / refractory / Markov) on an
~8-frame free-running tick to reproduce a "CV~1.5, 16-suppressed 8-lattice" —
is built on a target spec that fuses two different measurements, and the
surviving real structure is **deterministic, not a stochastic gate**. This
document is the reconciliation and the reformulated question.

## What was actually built and run (pure analysis + one Phase-A sweep)

- Fleet confirmed up and reachable (nemo local 12c; mini2.local 6c;
  hdl-dev-2.local -> 10.0.0.11, 8c, key auth). **No fleet jobs were spent** —
  see verdict.
- `two_jup/simgen_symsync/tick_process.py` — Phase-A synthetic gated-tick
  renewal sweep (gate × cadence-jitter × MEMORY), 10k-frame scale, pure
  Python (interval statistics are set by the tick process, not the DSP).
- `two_jup/simgen_symsync/target_fingerprint.py` — ONE consistent
  collapse/interval/binning scorer (`frame_taxonomy.read_frames`,
  reg_packets frame identity, reset-segmented, adjacent-merge events,
  start-to-start intervals) applied to both banked framelogs and sim output.
- `jupiter_240k5_byte/rtl_sim/sim_byte_qtick.cpp` (+ `run_qtick.sh`,
  `score_qtick.py`) — the byte-plane tick netlist driver from the quick-look;
  carries a KNOWN DEFECT (below).

## Finding 1 — the stated target signature fuses two different measurements

Re-deriving with a single scorer over **all** CRC-fail frames of the banked
forward air captures (settle 15 s, reg_packets identity):

| capture (all CRC fails) | rate | S:D:L | double frac | CV | dominant interval | 16 band |
|---|---|---|---|---|---|---|
| singles_reread (-M16) | 5.38% | 2644:436:0 | 0.14 | 0.36 | **16** (2035), 32 (948) | dominant, not suppressed |
| singles_disc (-M16)   | 5.20% | 2552:422:0 | 0.14 | 0.37 | **16** (1853), 32 (1070) | dominant |
| evm_swap_A (-M16)     | 5.54% | 2538:545:0 | 0.18 | 0.52 | **16** (2070), 32 (945) | dominant |
| hunt_auto_211829      | 1.21% | 343:134:42 | 0.26 | **1.57** | **32** (316), 64,96,128… | absent |
| accept_rxq_201153     | 4.52% | 1075:633:48 | 0.36 | 0.22 | **32** (1265) | absent |

Two facts fall out, and they are the whole story:

1. The **CV~1.5** in the stated target matches only `hunt_auto` (1.57) — a
   run whose intervals lie on a **32-frame** lattice (32, 64, 96, 128 …), the
   DMA-batch class, with a heavy multiples-of-32 tail. It is NOT an 8-lattice
   and it does NOT suppress 16 (16 simply doesn't occur; the grid is 32).
2. The **"modes at 8 & 24/25, 16 suppressed"** comes from a *different*
   subset — the curated replay-clean singles (Finding 2) — which has
   **CV ≈ 0.53**, not 1.5.

So "rate ~4% + CV~1.5 + 8/24-modes + 16-suppressed" is not a single measured
distribution; it is a splice of `hunt_auto`'s pooled all-fails (for rate/CV)
and the curated replay-clean singles (for the lattice). No single mechanism
needs to — or can — reproduce all four numbers at once, because they were
never one distribution.

## Finding 2 — the real curated air-singles structure is a doublet-on-a-super-period, not a gate

The curated air-singles events (the delivered-but-corrupt-yet-replay-clean
class, `compare_singles.py` `hw_single`/`hw_pair`, in **host_seq / payload
frame** units), scored with the same binning:

- 16 events (12 singles + 4 adjacent-seq doublets), n = **16** intervals.
- start-to-start intervals: **8, 25, 8, 25, 8, 25, 8, 25, 8, 24, 8, 25, 8, 25, 8**
  → hist {8:8, 24:1, 25:6}. **c8 = 8, c16 = 0 (suppressed), c24 = 7.**
- CV = **0.53**. k mod 8 of starts = [2,2,2,4,2,2,0,2] (roughly flat, drifting).

The "8 and 24/25, 16-suppressed" IS real on this subset — but its mechanism
is transparent from the numbers: the singles recur with **alternating gaps 8
and 25**, i.e. a **~33-frame super-period carrying a substructure at spacing
8** (8 + 25 = 33). 16 = 2×8 is structurally absent because you never get two
consecutive 8-steps; you get one 8-step then the 25-step remainder of the
super-period. This is not memoryless-vs-Markov gating — it is TWO coupled
processes (a ~33-frame recurrence and a fixed 8-frame internal offset).

**Units caveat (checked):** the super-period is **33 in host_seq (payload
frame) units, not 32.** host_seq is NOT 1:1 with reg_packets in these logs
(no fixed offset holds for >1.2% of good frames; reg_packets steps 0/1 per
host record). So the ~33-frame recurrence CANNOT be cleanly asserted to equal
the 32-frame DMA batch — it is close (33 vs 32) but off by one in the units
that matter, and naming it "the DMA batch" would be unproven. Name it: a
**~33 payload-frame super-period with an 8-frame internal doublet offset.**

**Sample-size caveat:** the entire curated fingerprint rests on **16 events
in a ~250-frame window of ONE capture** (singles_reread). c16 = 0 on 15
intervals is consistent with genuine structural suppression, but is also
reachable by chance from a small sample of a mostly-alternating process.
Broader replication needs the per-capture replay-clean subset (the
SINGLES_REPLAY IQ-replay machinery) on singles_disc / evm captures — a
separate effort, not run here. Treat Finding 2 as one-capture-strong,
class-unconfirmed.

## Finding 3 — Phase-A negative result (now explained, not just observed)

Full gate × cadence-jitter × memory sweep at 10k-frame scale
(`tick_phaseA.csv`): **no** memoryless / refractory{1,2} / 2-state-Markov
gate on an 8.04-frame tick produces **c24 > c16** (the target's defining
non-monotone shape). Every simple gate gives either monotone decay
(c8 > c16 > c24, memoryless & mild Markov), or a refractory that annihilates
the 8 mode entirely (refractory D≥1 → minimum interval 16, c8 = 0). Best
memoryless CV = 0.83 = √(1−p) as the quick-look predicted; bursty Markov
reached CV ≈ 1.45 but with 16 present (c16 > c24), never suppressed.

This negative is now **explained** by Finding 2: the real structure isn't a
gate at all. A single-tick renewal process cannot manufacture a peak at 3×
the quantum with 2× suppressed; that requires the doublet-on-super-period
geometry (two periods), which is outside the entire specified grid.

## Known defect in the netlist morphology primitive (do not reuse as-is)

`sim_byte_qtick.cpp` eats words **at the ByteSerializer OUTPUT**: an eaten
word is dropped from the delivered stream, so the frame is emitted at **188
words** and fails CRC on LENGTH, not content. Verified: all 32 eaten frames
= 188 words. The quick-look's "31/31 gated ticks each corrupt one frame" was
therefore a **tautology of the primitive** (every eat shortens exactly its
own frame), not a mechanism result — the tick-*timing* interval/CV analysis
in SIMGEN_SYMSYNC.md stands (it comes from the tick generator), but the
morphology attribution does not.

The target morphology is **delivered 191-word frames with wrong content**
(CP1 measured fabric ByteSerializer checksum == host checksum, 107/117). The
correct injection point is **upstream of the ByteSerializer's 191-word
packing**: words lost there make the serializer pull following words forward
and still emit 191 — full length, shifted content, CRC-fail — and, crucially,
such a shift does NOT self-heal, so it corrupts a RUN until re-sync. The
measured class is singles + ~25% doubles, so **the self-heal-within-1–2-frames
property is itself a hard discriminator** any fabric candidate must satisfy —
the output-eat primitive faked it for free by honoring frame boundaries, and
that freebie must not re-enter any future morphology test.

## VERDICT

**The specified tick-memory campaign cannot be the generator, and fleet time
was not spent on it.** The gate-memory dimension (the coordinator's stated
crux) is answered in the negative and, more importantly, is the wrong axis:
the measured air-singles are not a gated single-tick renewal process. The
"CV~1.5 / 16-suppressed 8-lattice" target is a splice of two subsets with
different statistics (hunt_auto pooled all-fails CV 1.57 on a 32-lattice; the
curated replay-clean singles CV 0.53 on an 8/25 alternation).

### Reformulated question for the operator (what to match against fabric candidates)

The generator signature to hunt in the fabric is **NOT** a probabilistic tick
gate. It is a **deterministic two-scale structure**: a **~33 payload-frame
super-period** whose events are **two-frame doublets at a fixed 8-frame
internal offset** (yielding the 8-and-25 interval alternation, 16 structurally
absent, on the curated replay-clean singles). The two candidate fabric
mechanisms consistent with that geometry:

1. a ~33-frame recurrence (a counter/credit/cal cadence near — but per the
   units check NOT provably equal to — the 32-frame DMA batch) that
2. disturbs a *pair* of frames 8 apart per recurrence, at the byte plane,
   producing 191-word-wrong-content frames that replay clean (so the
   disturbance is in delivery/packing, not in the samples).

The productive next step is analysis, not simulation: (a) replicate the 8/25
curated-singles fingerprint on singles_disc + one evm capture via the
SINGLES_REPLAY replay-clean subsetting to lift n above 16 and confirm the
class; (b) pin the ~33 super-period's units against a fabric counter
(reg_packets vs host_seq bridge) to name the recurrence; (c) THEN, if a
netlist repro is still wanted, inject a paired byte-plane disturbance
UPSTREAM of the 191-word packing at that recurrence — not a memoryless tick
gate at the output.

## Files

- `two_jup/simgen_symsync/{target_fingerprint.py, tick_process.py,
  tick_phaseA.csv}`
- `jupiter_240k5_byte/rtl_sim/sim_byte_qtick.cpp` (defective primitive, kept
  for the record)
- Measured inputs: `two_jup/r3cap/*/frames.bin` (via `frame_taxonomy.py`),
  curated list in `jupiter_240k5_byte/rtl_sim/tap_replay_study/singles_replay/compare_singles.py`
