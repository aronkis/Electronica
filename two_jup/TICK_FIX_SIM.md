> **SUPERSEDED — 2026-08-15. DO NOT READ THIS AS A LIVE FIX.**
> The mechanism below (a swallowed write beat at the platform byte FIFO)
> and its skid-buffer guard are **REFUTED on silicon**. Both skid images
> failed: v1 deadlocked the byte plane (fsync 1252, wcnt=0), v2 cost
> **+5.6 pp** forward PER (13.78/13.93% vs 8.22%), and a ready-dip replay
> showed the DUT's own 64-deep ByteRxFifo absorbs short backpressure
> bit-identically — the whole backpressure/skid fix class is dead.
> This document is kept as the **dated archive** of the sim work.
> Read next: this file's own **Addendum (2026-08-14)** at the bottom, then
> `skidfix/SKID_BUILD.md` (the silicon outcome), then
> `HANDOFF_20260815.md` and `docs/current-state.rst` for where the
> forward class actually stands.

# TICK_FIX_SIM — sim-validated guard for the air-singles pair-beat generator

2026-08-13, staged task (PURE SIM — no rig, no flash). Premise (operator-directed,
from PAIR_RECURRENCE.md / TICK_CAMPAIGN.md / FWD_SINGLES_ROOT_CAUSE.md): the
air-singles generator is a periodic byte/control-plane beat in 148's byte plane
— a ~32-frame recurrence delivering PAIRS of corrupt frames 8 frames apart,
upstream of the 191-word packing/delivery, producing full-length 191-word
frames with wrong content that self-heal in ≤2 frames and replay clean from
the same IQ. Task: build the injection that reproduces that morphology in the
netlist harness (positive control), design a guard that neutralizes it, and
A/B them.

## 0. Drive contract (HARNESS_AB.md compliance)

HARNESS_AB's rule is that drive cadence is a property of the NETLIST
GENERATION. This campaign uses the **Jul-25 f1536 tap netlist**
(`obj_byte_lock_f1536_jul25` lineage, `wrap_byte_lock.v`), whose native
contract is **cadence 4** — the cadence-2 value in HARNESS_AB applies to the
post-Jul-29/fsv2 generation, and HARNESS_AB's own A/B matrix shows the Jul-25
netlist at cadence 2 delivers 0 CRC-good. Re-verified here on a short
evm_swap_A slice (400k samples ≈ 8 frames): cadence 4 → locks (cfc_est −357)
and delivers 7 frames; cadence 2 → never locks (cfc_est −32916), 1 malformed
frame. All campaign runs are cadence 4, vphase 0, rstcs_end 8400, the same
drive as the working `base_A` lock run (162/162 frames).

## 1. The injection (positive control) — a pair-beat write-port swallow at the
##    platform byte FIFO

**Where.** The prime suspect (PAIR_RECURRENCE.md §candidates #1) is the
platform-side **1536-word byte FIFO** between the netlist's ByteSerializer
output and the RX byte DMA — 1536 = 8×192, one wrap ≈ 8.04 payload frames; the
32-frame recurrence = 4 wraps. It is OUTSIDE the HDL netlist, which is what
makes the hardware class replay-clean against the netlist alone. The harness
(`jupiter_240k5_byte/rtl_sim/sim_byte_tickfix.cpp`) therefore models it
BEHAVIORALLY at the `byte_rx` interface of the Jul-25 netlist: a 1536-deep
ring whose write pointer advances on every delivered word.

**The fault primitive.** On a scheduled hit, the write strobe is suppressed
for EATW=3 consecutive word beats while the pointer still advances (a
control-plane tick stealing the write port for those cycles). The delivered
stream keeps its framing — `byte_rx_last` passes through untouched, every
frame still delivers **exactly 191 words** — but the swallowed positions carry
**stale ring content: the words from 1536 beats (8.04 frames) earlier**.
Wrong content, full length, CRC fail, and the corruption cannot cross the next
frame boundary (self-heal ≤ 1–2 frames, 2 only when a hit straddles a
boundary). This is deliberately NOT the retired `sim_byte_qtick` primitive,
which ate words at the serializer output and produced 188-word LENGTH
failures — a tautology TICK_CAMPAIGN.md documents; here corrupt frames must
come out at 191 words, and do.

**The schedule.** Deterministic two-scale structure in WRITE-BEAT (word)
units, matching the measured fingerprint natively:

- super-period **6144 words = 4 FIFO wraps ≈ 32.17 frames** (the exact
  32-fabric-frame recurrence of PAIR_RECURRENCE §b, drifting mod frame);
- pair offset **1536 words = 1 wrap ≈ 8.04 frames** (the invariant 8-frame
  inner offset);
- per-hit Bernoulli gate **p = 0.70** (the refractory/occupancy term: sets the
  ~4%/frame scale — 2·0.70/32.17 ≈ 4.4% — and a ~0.70 pair-up fraction vs the
  measured 73–86%).

Expected interval structure: 8-and-24/25 alternation with 16 structurally
absent (two consecutive 8-gaps are impossible in pair geometry), CV well below
1 — the PAIR_RECURRENCE fingerprint.

## 2. The guard — 1-deep skid buffer on the FIFO write port

**Behavioral model (mode 2).** The fault still fires on the identical
schedule (same seed), but a skid register captures the swallowed word and the
write is retried on the next clk. The retry window is enormous: measured
minimum inter-word gap at `byte_rx` is **1024 clk** (all 12 campaign runs,
158k words each), and the ring
address written is not read again for ~1536 beats (~8 frames), so the deferred
write always lands before it matters. The guard's only theoretical failure
mode — a second word arriving before the retry slot (gap < 2 clk) — is
counted (`skid_ovf`) and never fires.

**Corresponding RTL change (the real fix spec).** At the write port of the
platform byte FIFO in 148's image (the 1536-word FIFO feeding `rx_byte_dma`,
platform HDL, outside the MATLAB-generated netlist):

1. **Skid stage**: one 64-bit register + valid flag between the
   ByteSerializer AXIS master and the FIFO write enable. If `tvalid` is
   asserted on a cycle where the FIFO write cannot commit (write-enable
   suppressed / port stolen by any control-plane access: scrubber, credit,
   status DMA), capture `{tdata,tlast,tuser}` into the skid and assert the
   write on the following cycle from the skid. Byte-plane beats are ≥1000
   fabric clks apart at line rate (191 words / 197k clk frame), so a 1-cycle
   retry always completes; skid-occupied collision is impossible in-spec and
   gets an assertion/counter anyway.
2. **Beat-parity witness**: a per-frame write-beat counter (reset on `tlast`)
   compared against the expected 192 (191 payload + flag slot); mismatch sets
   a sticky alarm bit and increments a counter, exposed next to the fsv2
   0x1C4 backpressure witness. This is telemetry proving the hazard fires (or
   stops firing) on hardware, independent of host CRC.
3. **Root-cause alternative** (stronger, larger): arbitrate the control-plane
   access OFF the write port entirely — dual-port the status/scrub access or
   cycle-steal only on `~tvalid` cycles. The skid is the minimal guard that
   makes the port stall-proof regardless of which control-plane actor is the
   thief; both close the hazard, the skid is what the behavioral model
   validates.

Cost: one 67-bit register per FIFO write port, no throughput change, no added
frame latency (worst case one clk of write latency, absorbed by FIFO
occupancy), no change to the read side or the DMA contract.

## 3. Campaign

`two_jup/simgen_symsync/tickfix/run_tickfix.sh`: 4 shards × ~202 frames of the
810-frame `hunt_auto_20260731_211829` healthy capture (8-frame warmup each),
each shard run in 3 modes with the SAME seed/schedule:
m0 clean · m1 injected+unguarded · m2 injected+guarded.
Scorer `score_tickfix.py`: QK-header crc32 verdict AND length==191; warmup+edge
frames excluded; morphology, attribution (per-frame swallow tag), stale-content
fingerprint check, and bitwise m2-vs-m0 stream comparison.

### Positive control (m1, injected + unguarded) — REPRODUCED

828 delivered frames, 780 scored; 40 gated hits (of 55 scheduled, p=0.70),
120 swallowed beats. Result:

- **39 corrupt frames = 5.00%/frame** (37 tagged to a swallow, the other 2 =
  the capture's own baseline, below) — the ~4%/frame scale (target class
  4.5–5.5%).
- **Every corrupt frame delivered at exactly 191 words** — full-length,
  wrong-content, CRC-fail. The qtick length-fail tautology is gone.
- **All 39 events have run length 1** — self-heal ≤ 1 frame; no runs, no
  resync tails. (No boundary-straddling doubles occurred in this sample.)
- **Interval fingerprint: c8=11, c16=0, c24=11, c25=2** (+ 26,30,32,33,40,41
  singletons from gated-out pair members), CV = 0.47 — the measured 8/24–25
  alternation with 16 structurally absent (PAIR_RECURRENCE: c8≈c24-26,
  c16 suppressed ~100:1, CV 0.54–0.63).
- **Stale-content fingerprint: 111/120 corrupt words bit-equal the delivered
  stream exactly 1536 words (8.04 frames) earlier** (the 9 misses are
  positions whose −1536 reference was itself disturbed or first-wrap). This
  is a testable HARDWARE prediction: if the FIFO-wrap mechanism is right, the
  wrong bytes in an air-singles frame should match the delivered content ~8
  frames before it.

Baseline: the clean run has 2/780 CRC-fail frames (0.26%, shard-local frames
108/138 of the 200–401 slice — capture-intrinsic marginal frames), present
identically in all three modes and tagged to no swallow.

### A/B table (4 shards × ~200 frames, hunt_auto capture, identical seed and
### hit schedule across modes)

| metric | m0 clean | m1 inject+unguarded | m2 inject+guarded |
|---|---|---|---|
| frames delivered | 828 | 828 | 828 |
| words delivered | 158,148 | 158,148 | 158,148 |
| scored frames | 780 | 780 | 780 |
| corrupt frames (rate) | 2 (0.26%, baseline) | **39 (5.00%)** | **2 (0.26%, same baseline)** |
| injection-attributed corrupt | 0 | 37 (+3 in warmup/edge) | **0** |
| swallowed beats / repairs | 0 / 0 | 120 / 0 | 120 / **120 repaired** |
| skid overflows | — | — | **0** (min word gap 1024 clk) |
| frame-boundary clk offsets vs m0 | — | identical | **identical (all 828)** |
| delivered stream vs m0 | — | 120 words differ | **bitwise identical** |

### Verdict

- **Fingerprint to zero: YES.** Under the identical 120-beat fault schedule
  that produces the full hardware morphology unguarded (5.00%/frame,
  191-word wrong-content, 8/24 alternation, 16 absent, self-heal ≤1), the
  skid-guarded FIFO delivers **zero** injection-attributed corrupt frames;
  the only residual CRC fails are the capture's own 2 baseline frames,
  bit-identical to the clean run.
- **Datapath unchanged: YES.** Guarded delivered stream is bitwise equal to
  the clean stream (158,148/158,148 words), frame count parity 828/828,
  frame-boundary clk stamps identical — zero added delivery latency, zero
  throughput cost. The guard's cost is one 67-bit skid register and a ≤1-clk
  write-side retry, absorbed 1024× over by the measured inter-word gap; its
  only failure mode (skid overflow) never fired.
- **No new failure mode observed** across 828 frames × 3 modes: no length
  deviations, no frame merges, no extra CRC fails in m2.
- Scope caveat, named: the guard is validated against the MODELED fault
  (write-strobe swallow with pointer advance at the platform FIFO — the
  candidate that fits every banked constraint). If the real control-plane
  beat instead corrupts the read side or the pointer itself, the skid does
  not cover it — the beat-parity witness (§2.2) is what distinguishes these
  on hardware, and the stale-content prediction above is checkable against
  banked corrupt-frame bytes today.

## 4. Files

- `jupiter_240k5_byte/rtl_sim/sim_byte_tickfix.cpp` (driver: FIFO shadow
  model, pair-beat scheduler, skid guard) + `obj_byte_tickfix_f1536_jul25/`
- `two_jup/simgen_symsync/tickfix/{run_tickfix.sh, score_tickfix.py}` + shard
  outputs
- Context: PAIR_RECURRENCE.md, TICK_CAMPAIGN.md, FWD_SINGLES_ROOT_CAUSE.md,
  HARNESS_AB.md

## Addendum (2026-08-14): hardware form — boundary-level A/B supersedes the naive skid

The FIFO-shadow skid of §2 was implemented on silicon as a plain AXIS
register slice at the rx_byte_breakout→rx_byte_dma boundary (image
c9d3e1ece983) and FAILED unconfounded on 148: fsync=1252 at line rate with
wcnt=0 (see two_jup/skidfix/SKID_BUILD.md). The DUT↔axi_dmac handshake is
not plain AXIS (drop-on-stall supersede, SOF-prime guard, SYNC_TRANSFER_START
observation), so the §2 guard was re-derived at the contract level:
`two_jup/skidfix/tb/tb_dma_contract.v` + `qpsk_axis_skid_v2.v`.

Boundary-level A/B (400 frames/cell, cold start mid-frame): direct wiring +
pair-beat ready stall reproduces the class (16/403 corrupt = 3.97%/frame ≈
49/s scaled, 3 superseded words/hit, self-heal at descriptor sync); the naive
v1 skid deadlocks totally (wcnt=2≈0 — the silicon fail reproduced); the
guard-preserving v2 repairs all 64 injected swallow beats → **0/403 corrupt,
delivered stream bitwise identical to clean, witness 0x400000BF (64 captures,
0 parity mismatches, alarm clear)**. The §3 verdict stands with the fix
re-hosted: the skid must be TRANSPARENT to the ready side-channel and engage
only on mid-packet stalls; v2 is the flash-candidate RTL, pending an
operator-authorized rebuild.
