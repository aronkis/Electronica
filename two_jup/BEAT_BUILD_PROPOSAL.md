# Build proposal — beat witness + runtime-switchable candidate fix (2026-08-29, HOLDING FOR OPERATOR GO)

## What is established (model) vs inferred
**Established in the netlist, deterministic and repeatable:** a one-symbol displacement between the
Preamble_Detector delay FIFO's write and read addresses produces persistent ~42–56 bit errors per frame
with framesync intact and no carrier reset (hardware: ~50/frame, framesync intact, rstcs=0), and the
opposite displacement ends it within two frames. Occupancy +1 (slack) is harmless. Commands in
`SINGLES_CAMPAIGN.md` 18:45; raw per-frame data in `jupiter_240k5_byte/rtl_sim/e5fix_ab/rec_*`.
**Inferred, NOT established:** what displaces the addresses every 120.2 s on silicon. A push-on-full drop
(push suppressed while pop continues, the FIFO runs exactly full: `occ=12333` = FULL every frame in sim)
is a sufficient cause; so is anything else that moves one address. The witness below discriminates.
**Excluded by measurement:** host, DMA, TX byte plane, RF, ADRV9002 tracking cals, image lineage, board,
loop gains, RX mode, and `fixctl` (inert on hardware AND in the model on this lineage).

## The build (one image, both purposes — as agreed: the witness rides with the fix)
1. **Witness (snoop-only, no datapath change).** `pd_addr_witness.v` next to the existing counters:
   - `pd_addr_delta` — the live (push−pop) address difference, and `pd_delta_changes` — how many times it
     changed since reset (the quantity that shifts is the quantity we count);
   - `pd_push_on_full` — count of `push & ~pop & (occ==FULL)` events (the specific trigger hypothesis);
   - `pd_occ_min` / `pd_occ_max`; `pd_toff_changes` (Peak_Search reported offset changes).
   Read through the existing 16:1 mux on the working GPIO (0x9D450008, select `gap[31:28]`) — extended to
   32:1; no new smartconnect master ports (that failure is on record from probe-2).
2. **Candidate fix, runtime-switchable, default OFF** (`fixctl` bit 3 at 0x208, so one image gives both
   arms without a reflash): delay-FIFO slack — FULL raised to 12,333+N with pop-before-push priority, so a
   +1 excursion is absorbed instead of suppressing a push. Sim basis: `rec_D` (occupancy 12,334 is harmless).

## Pre-registered predictions and falsifiers (written BEFORE the build)
- **P1** `pd_delta_changes` increments by exactly **2 per burst** (onset + recovery), not per error, and the
  increments land at the burst edges seen by the BIST counter (0x108). Falsifier: no change through a
  burst → the displacement model is wrong and the whole delay-FIFO line dies.
- **P2** `pd_addr_delta` sits at one constant value between bursts, steps by ±1 at onset, and returns at
  the end. Falsifier: it moves continuously, or steps by other than ±1.
- **P3** If `pd_push_on_full` increments at burst onsets 1:1 with P1, the drop is the trigger and the slack
  fix is justified. **If P1/P2 hold but `pd_push_on_full` stays 0, the trigger is something else that
  displaces the addresses and the slack fix is NOT justified** — that is the discriminator, and I expect it
  to be the decisive number.
- **P4** With `fixctl` bit 3 on: `pd_push_on_full` → 0 and bursts vanish (BIST flat through ≥ 3 slots,
  ≥ 400 s). If bursts persist while `pd_push_on_full` is 0 in both arms, the fix targets the wrong cause —
  and per the standing rule that is a coincidence-free way to tell, before we credit any PER change.
- **P5 (negative control, no build needed):** the burst must remain at 120.2 s in every arm; a change in
  period means the experiment perturbed the trigger and the arms are not comparable.

## Cost and rails
~3–4 h Vivado on the probe-4 lineage (all instruments retained), then one full-rails flash of 148
(restore point, readback, two-pass gate, auto-rollback, no retry). 146 untouched. Measurement plan:
ROM-loopback BIST series (bursts are deterministic at ~34 s / +120.2 s) with the witness sampled each
second, both `fixctl` arms, then an air A/B only if the loopback arms separate.

## What I am NOT proposing
- The E5 `Peak_Search` window patch: it fixes the `edge` case (framesync loss) but that is not the hardware
  signature, and under a disturbed timing loop it misses every other frame (100 frames vs 177). Not in this build.
- Any change justified by the `ss` injection: that selector saturates the loop filter and is not evidence.
