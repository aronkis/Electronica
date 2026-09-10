> Evidence ledger, moved verbatim from `two_jup/KNOWN_HOLES.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# Known Holes — QPSK f1536 campaign

Status snapshot 2026-08-26 ~16:4x EDT. Companion to `SINGLES_CAMPAIGN.md` (the
dated evidence ledger); this file is the open-questions inventory, grouped by
how much each threatens the campaign. Update in place; move items to a
"Closed" section at the bottom with a pointer to the closing ledger entry.

Campaign goal: delivered PER < 1% BOTH directions, ARQ OFF.
Standing: NOT MET — forward ~6% steady (new +20k off-null default,
idle-validated only), reverse ~2.6–2.9%.

## 2026-08-27 status update (sim-repro campaign + E9 fix) — read before the H-list below

- **H-1**: mechanism RE-CHARACTERISED — mu-clamp suspect REFUTED; the defect is
  symbol-DELETION handling under negative SRO (episodes ~0.7 slip-period after
  each deletion, first two harmless), reproduced synthetic AND on captured IQ
  at N=2 (`ERROR_SOURCES_SIM_REPRO.md` E5). Fix target = deleted-strobe
  handling downstream of Interpolation_Control. Still open (no fix yet).
- **H-2/H-10**: CLOSED as posed — fixed chain is within ~1 dB of float at the
  slicer (28–29 dB); the 6 % and the BER residual are episodic (E1/E5/E4), not
  margin (E6).
- **H-4 (bursts)**: startup-burst subclass REPRODUCED-IN-IQ as a TX content
  fault (E4); steady-state burst still a data gap.
- **H-5a (reverse)**: CLOSED 2026-08-28 — reverse LO operating-point sweep: +40 kHz
  off-null 1.391 % (CP95UL 1.469) vs the old +2.5k default 1.994 % (2.088); every
  off-null point beat the default. Reverse default SHIPPED +40k (`bringup_r2r3.sh`,
  reversible). Reverse standing PER now ~1.4 % (queued mode + LO point). Residual =
  the E5 deletion defect (fix target: Peak_Search early-peak handling).
- **H-5b (146 bidirectional collapse)**: RE-CHARACTERISED 2026-08-28 — under the
  guarded single-actor protocol the bidirectional soak ran the full 236-s window in
  both directions (fwd 10.37 %, rev 8.05 %); the 4 earlier ≤15-s collapses coincided
  with concurrent register readers/bring-ups (same interaction as H-7). N=2 (repeat 01:06: no collapse, rev 1.79 % with the +40k default; no further repeats
  queued). Under simultaneous load reverse degrades to ~8 % with burst holes — the
  new open item is load-dependent reverse loss, not a collapse.
- **H-6**: sentinel evidence pipeline was broken (empty snapshots) — fixed;
  still no captured wedge since.
- **H-8**: CLOSED — saturated forward at the +20k default measured 13.93/13.98 %
  (CP95UL 14.2 %), two legs 2026-08-27 (the baseline for the FIFO A/B).
- **H-7 (148 "no-ping" hang)**: NAMED 2026-08-27 (high confidence, 4 occurrences,
  forensics in RIG_NOPING_FAULT.md): a nemo-side `direct_reg_access` read on the
  AXI ADC core while `arm_rom` reloads the ADRV9002 profile → an AXI read that
  never completes → instant PS hang, nothing logged, power-cycle only. It is the
  same hazard bringup_r2r3.sh:61 guards ON-BOARD (kills lock_watchdog before the
  reload) — the nemo-side readers (health probes, sentinel/chain polls) were never
  guarded. Countermeasure: `sim_repro/no_arm_inflight.sh` arm_guard on every
  reader + the single-actor RIG_LOCK. Image-independent; the FIFO image is not a
  suspect. Confirmation = clean bring-ups with the guard in place (in progress).

- **NEW (E9, the forward comb)**: 84 % of forward loss = axi_dmac S2MM
  per-transfer tready gap overflowing the 64-word ByteRxFifo (sized for K5,
  ~70× too small at f1536). Host half fixed (queued mode, −5.2 pp, shipped).
  Fabric fix = 4096-word BRAM FIFO: sim-gated byte-exact, builds clean
  (v4 `e45df7741369`, WNS +0.23, BRAM 66.5) — **but on silicon the read side
  is dead**: diagnostic flash showed words enqueued (overflow +879k/10 s) and
  none accepted (0x1C0 frozen); handshake side (`valid` withheld / tready).
  v5 DEBUG image (handshake state on 0x1B0) built overnight; one approved
  diagnostic flash with it pins the cause. FIFO A/B NOT MEASURED. Suspect:
  the 2-cycle-later `valid` at the empty edge vs the DMAC's tready window.
- **NEW (TX side)**: ByteWordBuffer 16 words = same K5 assumption (~33 µs cover);
  follow-up, not bundled.

## 1. Root cause (the big ones)

- **H-1 [LARGELY CLOSED 2026-08-26 — repro achieved, conviction pending]**
  RTL sim REPRODUCED the sign asymmetry (Jul-25 tap netlist, commit 349c5c9):
  −15k coupled CFO+SRO → 13.0% corrupt frames vs +15k → 0%; −25k → 23.9% vs 0%;
  CFO-only clean BOTH signs → the defect REQUIRES the sample-rate-offset
  component, matching the hardware cross-board-clock finding. First divergent
  signal: Symbol_Synchronizer output (coherence collapse at corrupt frames);
  consequence chain: Peak_Search latches a false peak +32 symbols late →
  Phase_Ambiguity mis-resolves ~3 frames/event. NAMED SUSPECT (inspected, not
  yet instrument-proven): one-sided mu clamp in Interpolation_Control.v:163-172
  (mu saturates to +1023 instead of wrapping — only the negative-SRO slip
  direction exercises it). REMAINING: (a) mu/underflow tap run to convict;
  (b) fix + sim A/B; (c) the flashed v3 generation takes no IQ — new harness
  needed to repro on that exact netlist; (d) noiseless stimulus caveat: the
  mechanism, not the +32 offset, is the transferable claim.
- **H-2 The 6% floor at the best LO point is unexplained.** Self-RX at the
  same +20k dialed offset runs 0.3% steady. Remaining deltas between self and
  cross-board: SRO (~2.6 ppm sample-clock offset) and/or distance/multipath.
  The repro agent's CFO-only vs CFO+SRO legs address SRO; distance has never
  been tested (boards never co-located for a link-config leg).
- **H-3 The placement-sensitivity story (A4 / v_endh MOVED verdicts) is now
  partly suspect.** Those idle legs were single 60-s windows; 2026-08-26
  proved one burst window inflates a single-window read by up to ~+7 pp. The
  saturated legs differ beyond burst noise, but nothing placement-related has
  been re-measured under the multi-window discipline. If the comb is
  receiver-side, the seed campaign may have been chasing variance.

## 2. Measured but unexplained

- **H-4 The universal burst class.** ~5k-frame bursts every ~2–3 min, present
  in fabric loopback, both boards' self-RX, and the link. Distinct from the
  comb. Never root-caused; characterized only by cadence.
- **H-5 The reverse leg.** (a) 2.6–2.9% steady residual, mechanism unknown —
  plausibly the same tracking defect (reverse runs the +2.4k off-null policy;
  its LO operating point has never been swept). (b) Total 146 delivery
  collapse under simultaneous bidirectional load (3/3 soak attempts, ≤15 s to
  dead): mechanism evidence was lost to the 00:55 reboot; no repro has been
  run that pulls 146's logs BEFORE recovery.
- **H-6 The wedge class.** ~1–2/hour, watchdog-invisible, sentinel-recovered
  (7 on the night of 08-25/26). The sentinel's evidence-destruction bug
  (watchdog logs truncated at recovery) is FIXED — snapshots now land in
  ~/modem-status/wdlog_<ip>_<ts>.txt — but no wedge has been captured since
  the patch, so the watchdog-escape mechanism is still unnamed.
- **H-7 148's hard crash** (~09:00 on 08-26, off-network until physical power
  cycle). Cause unrecoverable — dmesg wiped by the cycle. One-off until it
  is not.

## 3. Verification debt

- **H-8 The +20k forward default is idle-validated only.** No saturated
  ≥75k-frame CP95 leg has run at the new operating point; the standing "~6%"
  is an idle-leg number. (Cheapest hole to close: one capture_r3 A leg.)
- **H-9 Float-zero rests on ONE capture** (romair_20260824_221024,
  reproduced bit-exactly). Leg 2 is blocked: the BEATFIX image on 148
  structurally lacks the IQ tap (rx-lpc ramp), so a fresh ROM-air capture
  needs a 148 image decision (rollback to e49c011b trades away BEATFIX).
- **H-10 The 8.2e-5 air BER residual is bounded, not named.** Post-
  constellation implementation, enters in the analog/CFO regime (fabric
  loopback floor 1.7e-6, self-RX ROM ~3.6k err/s). Likely the same tracking
  defect at bit scale — unproven.
- **H-11 fixctl=3 verified by effect only.** Violation counter fires
  (~130/s) and health is unaffected, but the marker-shift-class absence was
  never scored the exact way the 08-22 validation run scored it.

## 4. Standing decisions parked with the operator

- 146 image: currently candidate 4be9286ca111; v_endh ec414d2df8bc banked
  (best saturated draw, worst idle draw) — likely moot if H-1 resolves
  receiver-side.
- 148 image: BEATFIX fe5bd8a4fe19 (fixctl=3) vs e49c011b (working IQ tap,
  needed for H-9).
- SSI near-end loopback cable (Tx1→Rx1 through 30–40 dB attenuation) —
  superseded for the comb by the self-RX result (egress measured clean), but
  still the clean instrument for any future egress question.

## Suggested next closures (cheapest first)

1. H-8: saturated CP95 leg on the new default (~10 min rig).
2. H-5a: reverse-direction LO sweep (same harness as the 08-26 forward sweep).
3. H-5b: bidirectional-collapse repro that snapshots 146's qpsk_tun/perf logs
   before any recovery.
4. H-1: await the RTL agent; if HARNESS-LIMITED, decide on building a v3 IQ
   wrapper.

## Closed

(move items here with date + ledger pointer)


### 2026-08-28 07:01 E9 silicon status
FIFO-depth fix REFUTED by A/B (no gain in either RX mode). Mechanism corrected to the DMAC sync-start discard at the transfer handoff; fix path = gated tuser (Option E), operator decision. 148 currently on v5 debug image `602b26c25c35` (gate-passed, PER-equivalent).
