> Evidence ledger, moved verbatim from `two_jup/PAIR_RECURRENCE.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# PAIR_RECURRENCE — the air-singles generator: full-log replication + unit bridge

2026-08-13, operator-approved analysis (a)+(b) from TICK_CAMPAIGN.md's
reformulation. Pure banked-data analysis; no rig, no sims. Tool:
`two_jup/simgen_symsync/pair_recurrence.py` (hole-census event positioning —
a corrupt frame's own host_seq is garbage, so an event = a maximal crc=0
record run sandwiched in an exactly-matching seq hole between good records;
events of size 1–2 = the singles class, mutes/bursts excluded).

## (a) Replication: the 8/25 alternation is the class structure at full scale

Full 60-s logs (settle 15 s), n = 2,500–3,900 events per capture — not 16:

| capture | small events | S:D (double frac) | top intervals | c8 : c16 : c24-26 | 8→24-26 alternation | CV |
|---|---|---|---|---|---|---|
| singles_reread | 3412 | 2513:899 (0.26) | 8×1331, 25×1033, 33×286, 24×262 | 1447 : **12** : 1319 | 1200/1447 (83%) | 0.63 |
| singles_disc   | 3700 | 2712:988 (0.27) | 8×1589, 25×1223, 24×393 | 1702 : **7** : 1634 | 1525/1701 (90%) | 0.58 |
| cp1_verdict2   | 3644 | 2651:993 (0.27) | 8×1567, 24×786, 25×718 | 1626 : **14** : 1541 | 1392/1625 (86%) | 0.59 |
| evm_swap_A     | 3868 | 2896:972 (0.25) | 8×1265, 24×905, 23×781, 7×503 | 1772 : **5** : 1720 | 1586/1771 (90%) | 0.54 |
| accept_rxq_201153_r1 | 2520 | 1808:712 (0.28) | 8×1062, 25×525, 24×511 | 1099 : **5** : 1061 | 951/1098 (87%) | 0.58 |

**VERDICT (a): REPLICATED, five for five.** Modes at 8 and 24/25 with 16
suppressed ~100–300:1 (c16 = 5–14 vs c8 ≈ 1100–1800); the 8-interval is
followed by a 24–26 interval 83–90% of the time (strict alternation);
doubles fraction 25–28%; CV 0.54–0.63 (the curated-subset 0.53 was
representative; CV~1.5 in the old target spec was definitively from the
other, 32-lattice population); event-start phase mod 33 is flat (drifting).
Replay-clean discipline: the class definition here (delivered-but-corrupt
via exact hole census) is the same population whose IQ-window sample was
12/12 replay-clean in SINGLES_REPLAY; no new replay was needed for the
interval structure, and the class-purity caveat is that only the
singles_reread window has direct replay confirmation.

Per-run wobble worth naming: the pair's inner offset is 8 everywhere, but
the long leg varies by run — 25-dominant (singles_reread/disc, accept),
24/25 split (cp1), 23/24 (evm_swap_A, with 7 alongside 8). So the
super-period in host_seq units is run-dependent: ~31 (evm_swap_A), ~32.4
(cp1), ~33 (the others).

## (b) Unit bridge: host_seq ↔ reg_packets

- On CRC-good records, d(reg_packets)/d(host_seq) = **0.9925–0.9964**
  (median over 5000-record windows, per capture) — the units are ~1:1 with a
  small per-run deficit; reg_packets steps 0/1 per host record (several
  records per frame; reset-segmented).
- Collapsing 8-apart event pairs into super-events (73–86% of events pair
  up), the recurrence in **reg_packets units is exactly 32, dominant in
  every capture** (1446/1631/1602/1720/1081 at 32; nothing else close):

| capture | pair offset (host_seq) | pair offset (reg_packets) | super-period (host_seq) | super-period (reg_packets) |
|---|---|---|---|---|
| singles_reread | 8×1323 | 16×678, ~1×264 | 33×1235, 32×199 | **32×1446** |
| singles_disc   | 8×1584 | 16×847, ~1×356 | 33×1332, 32×281 | **32×1631** |
| cp1_verdict2   | 8×1557 | 16×828, ~1×187 | 32×834, 33×649 | **32×1602** |
| evm_swap_A     | 8×1264, 7×499 | 16×843, ~1×444 | 31×1341, 32×334 | **32×1720** |
| accept_rxq_201153_r1 | 8×1060 | **~1×237 only** | 33×544, 32×517 | **32×1081** |

Reading the reg_packets columns correctly: reg_packets is latched when the
host writes the record, and records arrive in DMA batch reads — so pk
differences are quantized to batch arrivals. The pair-offset bimodality
{~1, 16} on the -M16-era captures = the two pair members landing in the
same batch read vs straddling one 16-frame batch boundary; in the
accept run the pair offset is **~1 only** (237/237 pairs in the same read
batch — zero straddles).

**VERDICT (b):** In fabric/batch units the recurrence is **32 frames,
exactly and universally** — which is 2× the 16-frame DMA batch on the M16
captures and matches 1× a 32-frame batch on the accept run. The pair's
internal offset is **8 payload frames, constant across every capture** (the
one invariant that never moves), and the pair freely straddles 16-frame
batch boundaries at M16 — so the 8-offset is generated in the fabric, not
by host reads. The accept run's zero straddles say the pair sits inside one
32-frame window there, i.e. the recurrence is aligned to a 32-frame
structure.

What does NOT close cleanly (named, not smoothed over): the host_seq-unit
super-period varies per run (~31 evm, ~32.4 cp1, ~33 others) by more than
the good-record slope deficit predicts (32/0.995 ≈ 32.16). Either the
hole-census position inference carries run-dependent bias (±1 by which side
of the hole the good anchors sit), or the recurrence has a genuine
run-dependent beat term of ±1 frame per period. The banked logs cannot
separate these; the fabric witness counter can (below).

## Fabric-candidate shortlist

Constraints every candidate must satisfy simultaneously:
{recurrence = 32 fabric frames; pair offset = 8 payload frames invariant;
corruption upstream of/at the ByteSerializer 191-word packing with full
191-word delivery (CP1: fabric checksum == corrupt host bytes 107/117);
replays clean from the same IQ (netlist alone never reproduces);
self-healing within 1–2 frames (singles + 25% doubles, no runs)}.

1. **The platform-side 1536-word byte FIFO (prime suspect).** 1536 = 8 × 192
   exactly — an 8-frame wrap quantum if the byte plane moves 192 words per
   frame (191 payload + 1 idle/flag slot), 8.042 frames at a strict 191.
   The recurrence 32 = 4 wraps; the PAIR = two corruptions one wrap apart
   with the next two wraps clean — a refill/occupancy oscillation with
   period 4 wraps fits the 8/25 alternation natively. This FIFO is OUTSIDE
   the HDL netlist (the netlist's own ByteRxFifo is 64 deep), which
   structurally explains replay-clean; a word lost/duplicated at the FIFO
   under a specific occupancy self-heals at the next frame boundary
   (serializer re-anchors at 191-word packing), matching the 1–2-frame
   morphology. The earlier "FIFO-wrap KILLED" verdict does not cover this:
   that test excluded a FIXED-ADDRESS (phase-locked) hazard; a drifting
   wrap-beat with uniform residues is exactly what it could not exclude.
2. **The 32-frame RX DMA area structure (ping-pong of 2×M16 batches / one
   M32 batch).** Favored by the accept run's zero straddles (pair inside
   one 32-frame window); weakened by (i) N1's cyclic A/B falsifying
   transfer boundaries for the loopback class (the air class was not
   tested under cyclic — a real gap, not an exclusion), (ii) no natural
   meaning for the 8-frame inner offset (it is half/quarter of a batch, and
   pairs straddle 16-frame boundaries freely at M16), and (iii) the
   rate-vs-M invariance from the discriminator chain.
3. **A 32-frame-period control-plane cadence in 148's byte plane** (credit,
   scrubber, or status DMA touching the FIFO/serializer clock domain every
   32 frames, disturbing two words 8 frames apart). Generic fallback if 1
   and 2 fail their discriminators; nothing in the banked data
   distinguishes it from 1 today.

**The deciding instrument already exists:** the fsv2 witness image (0x1C4
backpressure counter + stall bit, banked, gated-red pending the dirty-slx
reconcile) reads the byte-plane FIFO state at line rate. One loopback run
with it answers: does the 0x1C4 counter advance on a 32-frame cadence
phase-locked to the corrupt pairs, and is the 8-frame inner offset visible
as two stall/backpressure excursions per period? That is a hardware step —
operator's call, not taken here.

## Files

- `two_jup/simgen_symsync/pair_recurrence.py` (analysis, rerunnable on any
  frames.bin)
- Inputs: `two_jup/r3cap/{singles_reread,singles_disc,cp1_verdict2,
  evm_swap_A,accept_rxq_20260812_201153_r1}/frames.bin`
- Context: TICK_CAMPAIGN.md (the reformulation this executes),
  FWD_SINGLES_ROOT_CAUSE.md (CP1/discriminator chain), HANDOFF_20260813.md
