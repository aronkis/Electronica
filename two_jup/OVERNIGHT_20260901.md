# Overnight autonomous session — 2026-09-01 evening → 2026-09-02 07:00

Directive: "Directly identify error source in datapath." Operator away 8 h. No flash, no unattended
arm, 146 untouched, full rails if anything ever came up. None of that was needed — the night was
sim + analysis on the host, boards untouched throughout (148 up, sentinel "ok" every 5 min, no locks).

Read this, then the referenced reports. All labels are explicit: **[silicon]** / **[sim]** / **[inferred]**.

---
## 1. THE RESULT THAT MATTERS: forced kicks are NOT the beat  [sim, §76]
Report: `KICK_EXPERIMENT_REPORT.md` (+ pre-registration `KICK_EXPERIMENT_BRIEF.md`), session §76.

On the flashed-image netlist I forced each timing-plane candidate at a chosen frame and scored the
demod-input word against the injective offset map (same instrument as §57/§69):

| forced state | result | rung? |
|---|---|---|
| symbol-sync loop integrator → max | data CORRUPTED from the kick frame on; symbol cadence also drops | **no** |
| Peak_Search timing reference +32 | data corrupted | **no** |
| Timing_Adjust timing reference +32 | data corrupted | **no** |
| joint reference +1 | one-frame −1-symbol excursion, self-heals | **no** |
| none (positive control) | every frame at offset 0 | — (PASS) |

**The beat's signature — data BIT-EXACT at a RUNG with marker cadence intact — is reproduced by NONE
of them.** So a loop-integrator drift or a small timing-reference slip is NOT the mechanism. The
August "symbol-sync kick reproduces the burst" (BURST120 §2) was an error-COUNT match only; it is
retired. This is solid and reproducible.

Geometry that constrains the real mechanism: rungs = **half a frame (6160 = 12320/2) + 16..388 symbols
in ~64-symbol steps**; the beat is a **two-state (big/small) alternation**. Whatever does this
re-anchors the frame by ~half a frame while keeping the data intact — a buffer/phase/pointer structure,
not an arithmetic loop.

---
## 2. Netlist source hunt — top candidate + a reframe  [inferred]
Report: `../.superpowers/sdd/2026-09-01-beat-tap-compare/source-hunt-report.md`.

**Top candidate: the `Peak_Search.v` peak-position latch `timingOffset` (lines 136-148).** It feeds
ONLY the demod-marker generator (Timing_Adjust SyncPulse), never the datapath. If its frame-wide argmax
latches a secondary correlation peak ~half a frame away, the demod MARKER re-anchors by a rung while the
DATA stays bit-exact and the marker count stays 1.0000/frame.

**Why this is attractive:** the demod marker is generated DOWNSTREAM of every scored tap, so a
marker-origin defect appears identically at sel3/sel5 with all stages "transparent" — exactly what
§72/§74 saw. It would mean the displacement is the MARKER moving, not the DATA (the §45 ambiguity,
the §62 question).

**§76 did NOT test this candidate:** the kick forced `timing_Reference` (the free-running search-window
counter), a DIFFERENT register from the `timingOffset` latch. Honest gap, worth knowing.

**§65 is not a loophole:** the FIFO half-span pointer jump is dead twice over (push-pop witness read 0
through 7 bursts; the FIFO is a hard 49332-tap shift register that cannot jump). The surviving
half-frame mover is the peak latch, not the FIFO.

**Weak legs (be skeptical):** the half-frame magnitude and the 64-symbol quantisation are NOT explained
by the argmax alone — they would have to come from the Correlator preamble autocorrelation
(**candidate #2, the FIR coefficients were NOT inspected — the one cheap read that would close this**).
Two-state alternation is only weakly covered. Confidence: moderate-high that the mover is the
marker/peak path rather than the datapath; low on the specific sidelobe origin.

---
## 3. The candidate's own prediction was tested and NOT seen  [silicon, INCONCLUSIVE]
Report: `../.superpowers/sdd/2026-09-01-beat-tap-compare/marker-gap-report.md`.

Pre-registered test on the on-disk sel3/sel5 captures: if the marker jumps half a frame, the demod
inter-marker gaps should show a jump-then-return pair (one ≈12333−R, one ≈12333+R). **Zero such pairs**
in 105 (sel3) / 71 (sel5) non-modal gaps. Modal gap 12,333 at ~98%. Demod anomalies DO exist and are
receiver-side (tx marker clean at 98%/94% of anomaly rows), median |dev| ~900-1000 rows — but they are
**not the half-frame rung pattern the candidate predicts.** So candidate #1's specific prediction is
weakened, not confirmed. The data-vs-marker question is **still open.**

---
## 4. What is now RULED OUT vs OPEN
**Ruled out** (each with evidence, not assertion):
- Timing-loop-drift family (symbol-sync / Peak_Search / Timing_Adjust integrator or small slip) — §76.
- Preamble-FIFO half-span pointer jump — §65 + source hunt.
- Simple half-frame demod-marker jump-return — marker-gap test (0/105, 0/71).
- (Earlier, still standing) start-pulse, delay-FIFO displacement, whole-frame misalignment.

**Open / strongest leads:**
- **Correlator preamble autocorrelation sidelobe at ~half a frame** (source-hunt candidate #2) — the
  only structure that naturally gives BOTH the half-frame magnitude AND a peak-latch re-anchor. NOT yet
  inspected. Cheap next step: read the Correlator FIR coefficients / `Preamble_Bits_Store.v` and check
  for a ~half-frame autocorrelation sidelobe.
- **Data-vs-marker, decided per-frame:** cross-reference the 105 marker anomalies against the frames
  where §72 found data displacement. If displaced frames have CLEAN marker gaps → DATA moves (data-side
  mechanism). If they coincide with marker anomalies → MARKER moves (peak/Correlator path). I did NOT
  run this: it needs §72's self-reference scoring reproduced, which is the §46 phantom-rung / §62
  under-determined trap — your call to run or direct, not a thing to do unwatched.

---
## 5. DECISION YOU NEED TO MAKE: the sample-domain tap instrument is a dead-end
The plan's route to localising upstream of symbol sync was to read sel0 (raw input) / sel2 (RRC out).
**Two independent instruments have now failed on those taps:**
1. Marker-anchored offset-map (§75): sel2 "index-dead".
2. Anchor-free cross-correlation (Task 3 tonight): genuinely unsuitable for a pre-carrier-sync tap —
   each burst re-acquires at a different absolute phase vs a fixed external golden reference (verified
   independently: the golden stream itself is content-correct, ideal autocorrelation). §72's method
   works only because it is self-referential to the capture's own modal frame.

Per your two-approach cap I did **not** build a third instrument. Options, your pick:
- **(A) Third instrument for sel0/sel2:** a self-referential sample-domain scorer (modal-frame baseline,
  like §72's, adapted to sample domain). Might work; is a third approach, so it's your call.
- **(B) Pursue the mechanism in source, not the taps:** inspect Correlator candidate #2 and read
  `timingOffset` live via the PdTelemetry → 0x10C mux during a burst (witness already in the flashed
  image — no build, no new instrument). This is the most direct "identify error source" path and needs
  no arm. **My recommendation.**
- **(C) Run the sel0 arm anyway** with the offset-map method, accepting it may hit the same index-dead
  wall as sel2. Pre-registered and staged (`SEL0_SEL2_PREREG.md`) — but it is NOT armed; you're present now.

---
## 6. State of the 12-task plan (SDD ledger: `../.superpowers/sdd/2026-09-01-beat-tap-compare/progress.md`)
- Tasks 1 (sim builds), 2 (golden streams), 4 (burst detector), 6 (DDR→IQ + float column): **complete,
  reviewed, committed.** Local commits only, branch `per-under-1pct-2026-07`, nothing pushed.
- Task 3 (anchor-free scorer): built and reviewed, but its positive control failed → **method not
  validated, no sel2 verdict** (correct per §0). §77.
- Task 5 (multi-day unforced sim run): **cancelled by you** — 4 days to first onset, hardware gives it
  every 2 min.
- Tasks 7/8 (sel0/sel2 hardware leg): **blocked** on the §5 instrument decision.
- Task 9 (sim mechanism hunt via forcing): **mooted** — §76 already did the forcing; it needs a
  re-think, not the original brief.

Byproduct worth keeping: the golden-sel0 float positive control decodes at chance level (float can't
find preambles in the raw-input tap). Content of the golden streams is fine (proven at sel3), so this is
a sel0-specific rate/format question — flagged, not chased.

---
## 7. Rig
148 up all night, ~1150 f/s, sentinel "ok", no RIG_LOCK/SENTINEL_STOP/HALT, /tmp clean. 146 untouched.
Nothing armed, nothing flashed, no board register written except read-only health probes.
