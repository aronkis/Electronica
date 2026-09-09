# PRE-REGISTERED hardware witness for the 120.2-s burst mechanism (written 2026-08-28 22:05, BEFORE the sim A/B lands)

## The claim being tested
The burst ("119.75-s beat", STAGE_LOCALIZED.md: a COHERENT SEQUENCE SHIFT — value-perfect coded bits at
a shifted position relative to the frame marker, confirmed on silicon 08-20) is TRIGGERED by the
Preamble_Detector one-frame delay FIFO: it runs exactly FULL in steady state (occupancy 12,333 = the
FULL constant; `Validate_Input_Push_Pop`: push & ~pop & (occ==FULL) → valid_push=0, symbol dropped).
Any +1 strobe excursion (interpolator strobe advancing one symbol against the sample clock) deletes one
symbol INSIDE the delay path, shifting the data path by one symbol relative to the marker path. The
fixed-point timing NCO's deterministic limit cycle supplies one such excursion every ~120.2 s at zero
SRO (loopback), after ~35–45 s from the arm. Each deletion costs ~3–7 s of Peak_Search/Timing_Adjust
re-alignment (framesync intact, no carrier reset), ≈50–68 bit errors per frame → species 215,285 /
293,433 BIST errors depending on the frame-relative landing position.

## Witness 1 — ZERO-BUILD: PdTelemetry over the debug IQ mux (0x10C = 4 selects `P1cDtc` = PdTelemetry)
`PdTelemetry` (in every flashed lineage) emits, per preamble event, a 7-slot record on the debug IQ
stream containing `fifoEnt` (delay-FIFO occupancy), `vPop`, `tRef`/`tOff` (Peak_Search reference and
reported timing offset), `done/newPk/succ/sync/armed` flags, `taRef`, `accOff`, `runMax`, `heldTs`,
`symCtr`. Captured with `iio_readdev axi-adrv9002-rx2-lpc` in 0.1-s snippets at scheduled offsets
around the first burst slot (baseline at T0+20 s; T0+32…37 s in 1-s steps) in ROM loopback.
**Predictions (must ALL hold):**
 P1. Baseline: `fifoEnt` reads 12,333 (FULL) on every record; `tOff` constant; flags steady.
 P2. At burst onset (the snippet whose 0x108 delta first exceeds ~20k): a push-on-full excursion is
     visible as a one-record `fifoEnt`/`vPop` anomaly (occupancy 12,334-wrap or a missed pop) AND
     `tOff` changes (by ±1 symbol or the +32 false value seen on the reverse leg) and STAYS changed for
     the burst duration; it returns to the baseline value at burst end.
 P3. No `tOff`/`fifoEnt` excursion in any non-burst snippet.
**Falsifiers:** `fifoEnt` steady value ≠ FULL (12,333) → the "runs exactly full" premise is false, the
FIFO cannot be the drop point → mechanism dead. No `fifoEnt`/`vPop` anomaly at onset while `tOff`
jumps → the shift originates elsewhere (Peak_Search/Timing_Adjust reference), FIFO drop dead.
`tOff` unchanged through a burst → not a timing-plane event at all; candidates revert to the SSI-
clock-domain family named in BEAT_BISECTION_PLAN.md.

## Witness 2 — BUILD (rides along with the fix build, NOT its own build): a fabric event counter
Snoop-only counters next to the existing checker/mux (16:1 mux has spare slots? no — add a 32:1):
 `pd_fifo_full_drop` = count of `push & ~pop & (occ==FULL)` events in the delay FIFO (the exact
 predicate of the mechanism), `pd_occ_max`/`pd_occ_min` since arm, `pd_toff_change` = count of
 `tOff` changes, `pd_strobe_excursion` = count of frames whose strobe count ≠ 12,333.
**Prediction:** `pd_fifo_full_drop` increments by EXACTLY ONE per burst (not per error): +1 at
~35–45 s after the arm, then +1 every 120.2 s; `pd_toff_change` = 2 per burst (onset + return).
The BIST error count per burst (215k/293k) is NOT proportional to the drop count — it is the
re-alignment time × per-frame errors; the relation is 1 drop ↔ one 215k-or-293k burst.
**Falsifiers:** counter stays 0 through a burst → mechanism dead. Counter fires at a cadence other
than the burst cadence (e.g., many per second, or not at burst onset) → drops happen but are not
the trigger → dead. Counter fires 1:1 with bursts but the FIX (FIFO slack) leaves bursts → the drop
is a symptom of the excursion, not its cause; the fix target moves upstream (NCO/strobe).

## Fix under test (sim first, build only after Witness 1 result is on record)
 F1. Delay-FIFO slack: FULL threshold raised (RAM is 16,384 words) with pop-before-push priority so a
     +1 excursion is buffered, not dropped. Prediction on silicon: `pd_fifo_full_drop` stays 0 AND
     bursts vanish (BIST errors flat at ~50/s through ≥ 3 slots = 400 s).
 F2. Existing BEATFIX contract (`fixctl`=3 at 0x208, verified 08-21 on the BIST comparator; 0x208
     reads 0 = LEGACY on the link today — bring-ups do not set it): masks the DAMAGE, not the drop.
     Prediction: with fixctl=3 the bursts vanish on the BIST/checker while `pd_fifo_full_drop` (or
     Witness-1 `fifoEnt`/`tOff` excursions) still fire on schedule. That pair distinguishes
     "trigger removed" (F1) from "damage masked" (F2), which is exactly the distinction requested.

## Sequencing (operator rule): sim A/B (forced slip, same harness/scoring) → Witness 1 on silicon
(zero-build, tonight) → fix build carrying Witness 2 → full-rails flash → Witness 2 + BIST + checker.
A fix that improves the number without Witness 2 firing as predicted is NOT confirmed.
