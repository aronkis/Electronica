### Task 9: Secondary arms in operator priority order (sel 12, then 13/14, then 15) — each pre-registered on the §82 outcome

**Files:**
- Output: `two_jup/beatcap/<ts>_sel{12,13,14,15}/`, §83+

- [ ] **Step 1: Pre-register per §82 outcome (write before arming)**

- If **P1**: sel 12 burst capture. Prediction: in the 12,333 beats before `onset_beat_toff`, the correlator magnitude shows a SECOND peak at ≈ d0 ± rung whose slot-2 `runMax`/slot-3 `threshold` readings show it crossing threshold (correlator-sidelobe origin); falsifier: no second above-threshold peak (latch origin). Then sel 13/14 to confirm the interpolator did NOT change phase at that beat.
- If **P2**: sel 13 burst capture. Prediction: `countReg`/`mu` (or the underflow cadence) show a discontinuity at `onset_beat_data` ± 2 beats; falsifier: interpolator phase continuous → sel 14 (buffer) then sel 15 (Rate_Handle occupancy step at onset).
- If **NEITHER/UNINFORMATIVE**: no secondary arm; report and return to the operator.

- [ ] **Step 2: Run the chosen arm(s) with `beat_tap_capture.sh SEL=<n>` under `launch_rig_unit.sh`, decode with `ddrcap2_decode.py`, score liveness with `ddrcap2_pc.py --sel <n>`, and extract the ±16-beat window around `onset_beat_toff`/`onset_beat_data` (from §82) with a 12-line numpy snippet in the report, comparing against the pre-registered prediction.**

- [ ] **Step 3: §83+ and commit, one section per arm, each labelled [silicon].**

---

## Ordering

1 → 2 → 3 (decoder can parallel 2) → 4 (gate, blocks the build) → 5 (build) → 6 (chain; flash needs operator go) → 7 → 8 → 9. Tasks 7's scripts and 8's analysis can be written and unit-tested while the build runs (Task 5 Step 2), but no capture runs before the flash.
