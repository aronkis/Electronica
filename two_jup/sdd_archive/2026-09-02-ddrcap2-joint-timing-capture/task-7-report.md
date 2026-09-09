# Task 7 report: DDRCAP-v2 Tier-2 silicon positive controls

## TDD
- Wrote `two_jup/tests/test_ddrcap2_pc.py` verbatim from the brief first.
- RED: `python3 -m pytest tests/test_ddrcap2_pc.py -q` → collection error, `ModuleNotFoundError: No module named 'ddrcap2_pc'` (ddrcap2_pc.py did not exist yet).
- Wrote `two_jup/ddrcap2_pc.py` verbatim from the brief, then found the two `is True`/`is False` identity
  assertions in the test failed under numpy 1.26 (`np.bool_(...)` is truthy-equal but not identity-equal to
  Python `True`/`False`). Fixed by wrapping every boolean field the scorer emits in `bool(...)` — an
  implementation-only change; the test file was not touched.
- GREEN: `python3 -m pytest tests/test_ddrcap2_pc.py -q` → `3 passed in 2.50s`.
- Wrote `two_jup/ddrcap2_capture.sh` verbatim from the brief, `chmod +x`.

## Precondition checks
- Before touching anything: read `0x20C` on 148 directly — `0xBCF94856` (golden), confirming the board was
  still armed from §81 gate pass 2 as stated. Did not re-arm.
- `launch_rig_unit.sh`'s actual CLI (`<unit-name> <script-file> [env=val ...]`) does not accept an inline
  `/bin/bash -c "..."` command the way the brief's Step-4 one-liner shows (`Cannot assign environment variable
  -c` on the first attempt) — wrote the loop to a small script file (`/tmp/ddrcap2_pc_run.sh`) and passed that
  as `<script>` instead. No change to `ddrcap2_capture.sh` or `ddrcap2_pc.py` was needed for this.

## The five captures (run.log / meta.txt in `two_jup/ddrcap2_pc/20260902_180725/`)
One `systemd-run --user` unit (`ddrcap2-pc-180725.service`), ran sel6, sel12, sel13, sel14, sel15 sequentially,
2 s apart. All five: 536,870,912 bytes, capTAP `0xBCF94856` golden immediately before AND immediately after
every capture (`ddrcap2_capture.sh`'s built-in check never tripped the ABORT/WARN branches). `meta.txt`:

```
sel6 sel=6 bytes=536870912 pre=0xBCF94856 post=0xBCF94856
sel12 sel=12 bytes=536870912 pre=0xBCF94856 post=0xBCF94856
sel13 sel=13 bytes=536870912 pre=0xBCF94856 post=0xBCF94856
sel14 sel=14 bytes=536870912 pre=0xBCF94856 post=0xBCF94856
sel15 sel=15 bytes=536870912 pre=0xBCF94856 post=0xBCF94856
sel13b sel=13 bytes=536870912 pre=0xBCF94856 post=0xBCF94856
```
(`sel13b` is the one permitted re-capture, discussed below.)

## Scorer output (verbatim `ddrcap2_pc.py FILE --sel N`)

```
=== sel6 ===
  not_constant_IQ              PASS
  not_ramp_IQ                  PASS
  demod_marks_periodic         PASS
  slots_cycle                  PASS
  d0 (toff mode) = 26
  toff_range_steady            PASS
  tref_monotone                PASS
TIER2 sel6 PASS
=== sel12 ===
  not_constant_IQ              PASS
  not_ramp_IQ                  PASS
  demod_marks_periodic         PASS
  slots_cycle                  PASS
  d0 (toff mode) = 26
  toff_range_steady            PASS
  tref_monotone                PASS
  peaks_per_frame_ok           FAIL
TIER2 sel12 FAIL
=== sel13 ===
  not_constant_IQ              PASS
  not_ramp_IQ                  PASS
  demod_marks_periodic         FAIL
  slots_cycle                  PASS
  d0 (toff mode) = 26
  toff_range_steady            PASS
  tref_monotone                PASS
  countreg_not_constant        PASS
  underflow_per_symbol         PASS
TIER2 sel13 FAIL
=== sel14 ===
  not_constant_IQ              PASS
  not_ramp_IQ                  PASS
  demod_marks_periodic         FAIL
  slots_cycle                  PASS
  d0 (toff mode) = 26
  toff_range_steady            PASS
  tref_monotone                PASS
  not_constant                 PASS
  not_ramp                     PASS
TIER2 sel14 FAIL
=== sel15 ===
  not_constant_IQ              PASS
  not_ramp_IQ                  PASS
  demod_marks_periodic         FAIL
  slots_cycle                  PASS
  d0 (toff mode) = 26
  toff_range_steady            PASS
  tref_monotone                PASS
  rhctr_bounded_nonzero        PASS
  push_pop_advance             PASS
TIER2 sel15 FAIL
=== sel13 RE-CAPTURE (sel13b) ===
  not_constant_IQ              PASS
  not_ramp_IQ                  PASS
  demod_marks_periodic         FAIL
  slots_cycle                  PASS
  d0 (toff mode) = 26
  toff_range_steady            PASS
  tref_monotone                PASS
  countreg_not_constant        PASS
  underflow_per_symbol         PASS
TIER2 sel13 FAIL
```

(`pc.log` under the timestamped output dir has the raw tee'd output, same content, minus the `=== ===` headers
for the original five — those only went to my terminal stdout, not the file, since the loop only piped the
python output through `tee`. The re-capture's header was tee'd. All six `TIER2` lines are in `pc.log`.)

## Investigation before writing verdicts (not a rubber-stamp of the raw scorer output)
Four of five selectors FAILed on the first pass. Before writing "4 dead" into §81 I checked with the advisor
and it flagged, correctly, that `d0=26` and `toff_range_steady`/`slots_cycle` PASS identically on all five
captures — ch2/ch3 (marker + toff, slot + side) are supposed to be independent of the `SEL` field that only
picks the I/Q debug tap, so a marker-plane failure correlated with `SEL` alone would be suspicious.

- **sel12** (`peaks_per_frame_ok` FAIL, 8.49 above-half-max samples/frame): checked whether this was a
  scorer artifact (one wide correlator peak counted as several isolated samples). A contiguous-run count over
  the same threshold gave the identical count (46,171 runs == 46,171 samples — no clustering at all), so the
  data is genuinely noisy near the half-max threshold at this tap, not a scoring bug. Also note: the brief's
  prose rule (line 9) states only a lower bound ("≥ 0.5 peaks/frame"); the verbatim code adds an upper bound
  of 3. Reported as coded (FAIL) — this discrepancy is a plan-owner call, not mine to silently resolve, and is
  written into the §81 addendum.
- **sel13/14/15** (`demod_marks_periodic` FAIL, ~1,340 marks vs 5,439–5,451 on sel6/sel12 over the same
  67,108,864-record file): checked per-decile mark density — uniformly sparse across all ten deciles on all
  three files (no mid-file transition, ruling out "degraded partway through this specific capture"). Checked
  whether the sparse marks still sit on the true 12,333-record frame grid — they do (residual spread matches
  sel6/sel12), with a dominant gap of 3×P and a secondary lobe at 6×P, i.e. real intermittent
  mark-detection dropout, not a wrong-grid decode bug and not a clean fixed decimation.
  This pattern — same signature, present the instant sel13's capture started and persisting through sel14 and
  sel15 (18:08:30–18:09:23) — could have been a transient link condition rather than three independent dead
  channels. I spent the one re-capture the brief permits on **sel13 alone**: a fresh capture (`sel13b`) at
  18:16, seven minutes after the original five, same arm, capTAP golden pre/post. It reproduced the identical
  sparse signature (1,364 marks, same decile profile). That rules out a transient blip at the sel12→sel13
  capture boundary and confirms this is a reproducible property, so sel13/14/15 are written up as genuinely
  DEAD, not "no verdict — link condition."

## Files changed
- `two_jup/ddrcap2_capture.sh` (new, executable)
- `two_jup/ddrcap2_pc.py` (new)
- `two_jup/tests/test_ddrcap2_pc.py` (new)
- `two_jup/ddrcap2_pc/20260902_180725/pc.log`, `meta.txt` (committed; the six `.bin` captures — sel6, sel12,
  sel13, sel14, sel15, sel13b, ~512 MB each — are NOT committed)
- `two_jup/SESSION_20260830_AUTONOMOUS.md` — §81 addendum with the full per-selector rule table and the
  investigation above

## Concerns / open items for the plan owner
1. sel12, sel13, sel14, sel15 are all DEAD for this campaign per the Tier-2 gate. Only sel6 passes in full.
2. sel12's FAIL depends on the code's upper bound (≤3 peaks/frame) that is not stated in the brief's prose
   rule; under prose-only sel12 would PASS. Flagged, not resolved unilaterally.
3. sel13/14/15's shared `demod_marks_periodic` failure, reproducible on independent re-capture, suggests a
   condition shared by these three tap positions upstream of the `SEL` mux rather than three unrelated
   per-channel silicon defects — worth a follow-up investigation, but out of scope for this task (no fixing
   on the rig, no further re-capture beyond the one already spent).
4. `launch_rig_unit.sh`'s CLI contract differs from the brief's Step-4 example (it takes a script file, not
   `bash -c` inline); worked around locally, no change to the sanctioned launcher script.

---

## Fix round 1 (coordinator-directed, same session, no board contact)

The coordinator read the .bin files independently and diagnosed two scorer defects behind the four FAILs:
(a) sel12's `peaks_per_frame_ok` was a pre-§80-census leftover rule; the real per-frame shape is one dominant
record >0.8x frame-max plus ~16 secondaries in (0.45,0.8]x. (b) sel13/14/15's `demod_marks_periodic` indexes by
raw record position, which is not a valid time base on these full-rate (enb_1_2_0, ~61 Mrec/s) taps because the
rx2 DMA drops records in bursts; the sidecar `tref` (slot-1) symbol counter is a valid time base since every
surviving record still carries its own frame position in-band.

### What I did
1. Reproduced the diagnosis independently on the actual `.bin` files (not just accepted the coordinator's
   numbers) before writing any code — confirmed sel13/14/15's tref-delta cadence: modal=1, 99.805% at modal,
   drop median 156-163 symbols, essentially identical across all three selectors.
2. Rewrote `ddrcap2_pc.py`:
   - `check_sel(a, 12)`: replaced `peaks_per_frame_ok` with `peak_one_per_frame` (PASS iff every scored frame
     has exactly one record > 0.8x that frame's own max), plus an informational `sel12_census` line (mean
     secondaries/frame in (0.45,0.8]x, largest secondary ratio) explicitly labelled "data, not a gate".
   - `check_common(a, sel=None)`: added `_tref_cadence()` (unwrap tref deltas mod 12,333; PASS iff >=95% equal
     the modal delta) plus an informational `tref_drop_stats` line. When `sel` is 13, 14, or 15, `check_common`
     now deletes `demod_marks_periodic` from its result and substitutes `tref_cadence`; sel 6 and 12 are
     unaffected (they keep `demod_marks_periodic`, unchanged).
   - `main()`'s print loop now handles any non-bool value generically (prints `key = value`, not gated into the
     PASS/FAIL aggregate) rather than special-casing only `d0`.
3. Added 6 new tests to `tests/test_ddrcap2_pc.py` (synthetic, real math, no mocking): two for
   `peak_one_per_frame` (clean-pass and two-primaries-fail), one confirming `check_common(a, sel=13)` swaps the
   rule, and two exercising the `_tref_cadence` helper directly at a sparse (0.2%) vs heavy (10%) burst rate.
   All 3 original tests are untouched and still pass unmodified. `pytest tests/test_ddrcap2_pc.py -q` →
   **8 passed**.
4. Re-scored all five existing captures with the fixed scorer — **no re-capture, no board contact**:

```
sel6  TIER2 PASS   (unchanged)
sel12 TIER2 FAIL   (peak_one_per_frame: 5,428/5,438 frames = 99.82% clean, not literally "every")
sel13 TIER2 PASS   (tref_cadence: 99.80% at modal delta)
sel14 TIER2 PASS   (tref_cadence: 99.80% at modal delta)
sel15 TIER2 PASS   (tref_cadence: 99.80% at modal delta)
```

5. **Did not stop at the numbers matching expectation.** sel12 came back FAIL under the rule exactly as the
   coordinator specified it ("every scored frame"), not the LIVE verdict the coordinator's message anticipated.
   Traced the 10 failing frames (of 5,438): all 5 are matched pairs — a short (12,333-record) frame with an
   anomalously suppressed local max and primary_count 12-13, immediately followed by a double-length
   (24,666-record) frame with primary_count 2 — i.e. a missed demod-mark merging two real frames into one
   measured segment, the same mechanism as the enb-domain marker/record drops, just ~50x rarer here (0.18% of
   frames vs the enb-taps' burst losses). Reported this as FAIL, narrow and diagnosed, rather than loosening the
   rule myself to force a PASS matching the coordinator's stated expectation — flagged in §81 for the plan owner
   to decide whether a tolerance band (matching every other Tier-2 rule's design) belongs in this rule.
6. **Caught and fixed my own arithmetic error before writing it into §81.** My first pass at "fraction of
   records lost in bursts" used an inconsistent records-per-tref-unit conversion factor across selectors (1x
   for sel6/12, but also 1x — should have been 4x — for sel13/14/15 the first time, then wrongly 4x for all
   five the second time). Derived the correct conversion from the structural invariant that exactly 4 records
   separate consecutive slot-1 samples when nothing drops (records-per-tref-unit = 4/modal_delta: 1 for
   sel6/sel12 since modal=4, 4 for sel13/14/15 since modal=1), recomputed, and corrected the §81 table from an
   initially-written ~9.6-9.9% to the correct ~38.3-39.5% before committing. Labelled that column `[inferred]`
   (estimate, assumes uniform drop distribution across slot phases) as distinct from the `[silicon]` cadence
   measurements it's derived from.
7. Appended the fix-round-1 re-score output and the sel12 outlier-frame diagnostic to the existing
   `two_jup/ddrcap2_pc/20260902_180725/pc.log` (kept the original first-pass output in place above it for the
   audit trail — nothing overwritten).
8. Appended a "§81 addendum, fix round 1" section to `two_jup/SESSION_20260830_AUTONOMOUS.md` with the full
   per-selector table, the corrected records-lost table, and the revised five-selector verdict.

### Revised bottom line
sel6, sel13, sel14, sel15 PASS Tier-2. sel12 FAILs narrowly (99.82% clean) on a rule now diagnosed rather than
stale — same missed-marker mechanism as the enb-domain taps, ~50x rarer. Four of five selectors are usable for
the campaign; sel12 is flagged FAIL-but-explained for the plan owner's tolerance-band decision, not silently
promoted to PASS.

---

## Fix round 2 (coordinator ruling on sel12's tolerance, same session, no board contact)

Ruling: give `peak_one_per_frame` the same tolerance-band design as every other Tier-2 rule (>=99.5% of frames
clean, not literal "every"), and require the report to list every exception frame with its anomaly so a genuine
multi-peak frame could never hide behind the band.

### What I did
1. One-line rule change in `check_sel(a, 12)`: `all(ones)` -> `np.mean(ones) >= 0.995`.
2. Made the scorer itself enumerate every exception frame (index, segment length, primary count) as a new
   `sel12_exceptions` info field, rather than relying on the separate diagnostic script from fix round 1 — so
   the exception list is part of the tool's own output, reproducible by anyone running `ddrcap2_pc.py`, not
   just something I ran once by hand.
3. Added 2 new tests exercising the band boundary directly (2/499 bad frames = 99.60% clean -> PASS; 5/499 bad
   = 98.99% clean -> FAIL), on top of the existing 8. `pytest tests/test_ddrcap2_pc.py -q` -> **10 passed**.
4. Re-scored the same existing sel12 capture (no re-capture): `peak_one_per_frame PASS` (99.82% clean, >= 99.5%
   band), `sel12_exceptions` lists all 10 exception frames — the same 5 short/merged-frame pairs traced in fix
   round 1, every one a missed-demod-mark event, none an independent multi-peak frame.
5. Appended the fix-round-2 output to `pc.log`.
6. Appended a "§81 addendum, fix round 2" section: revised Tier-2 table (sel12 -> PASS), and the loss-fraction
   range as directed: "~20% (sum of burst sizes) to ~38-40% (structural estimate), both [inferred]; the direct
   measurement is the tref-delta burst statistics."
7. **Could not independently reproduce the ~20% bound.** I tried several plausible readings of "sum of burst
   sizes" against the actual tref-delta data (raw excess-units/n with no unit conversion: ~9.6%; burst-time
   share of total elapsed symbol-time: ~28%; full burst size with the same 4x conversion as the structural
   estimate: ~38-39%, i.e. converges on the structural bound rather than a distinct lower one) and none landed
   near 20% by a method I can fully justify. Included the ~20% figure verbatim as directed — it is the plan
   owner's own earlier estimate — but flagged in §81 that this report did not independently re-derive it,
   rather than presenting it as equally verified alongside the ~38-40% structural bound (which is directly
   reproducible from the [silicon] burst-statistics table).

### Final bottom line
**All five selectors (sel6, sel12, sel13, sel14, sel15) now PASS Tier-2.** sel12's PASS rests on a tolerance
band identical in kind to every other rule in the scorer, with every exception frame enumerated and traced to
the same missed-demod-mark mechanism documented for sel13-15 — not a loosened or hand-waved gate.
