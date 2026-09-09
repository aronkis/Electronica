# Task 9 pre-registration -- secondary arms on the §82 P2 branch

Task 8 (§82) delivered verdict **P2** on board 148, image 638b36de3493: the Peak_Search `timingOffset`
latch (`tOff`, ch2[13:0]) holds at `d0` on every beat while the demod-anchored data offset (`d_data`,
computed only for sel6 via the tap3 offset-map) steps to a rung and holds >=3 frames, in both onset.bin
(rung 6363) and mid.bin (rung 6432). Per the brief (`task-9-brief.md`), P2 takes the **sel 13 first**
branch: interpolator phase accumulator (`Interpolation_Control.countReg`/`mu`), one attended arm, scored
before any sel14/sel15 arm is considered. This file is written and committed **before** any arm is
launched, per the controller ruling.

## Selector encoding (design doc §3, lines 40-65)

sel13, `enb_1_2_0_gated`-valid (captures at **4 records/symbol**, not 2 -- 2026-09-02 correction):
- `I[15]` = `underflow_sticky`, `I[10:0]` = `Interpolation_Control.countReg[10:0]` (11-bit phase accumulator)
- `Q[10:0]` = `mu[10:0]` (the `mu` output port, the fractional interpolation phase)
- ch2/ch3 (the universal anchor, present on every selector): `mark_demod`, `mark_fec`, `toff` (ch2), and
  `slot`/`side`/`tref` (ch3, slot 1 = `tref` mod-12333 symbol counter) -- unaffected by which tap sel13
  multiplexes into I/Q.

sel13 does **not** carry `d_data` (the tap3 hard-decision offset-map lookup is sel6-specific, decoded from
I/Q sign bits of the RRC-domain tap). There is therefore no `onset_beat_data` analog on sel13 -- the only
onset anchor available is the burst-timing prediction (`T_trigger + PERIOD - LEAD`) plus the interpolator-
phase discontinuity itself. The `onset_beat_toff`/`onset_beat_data` naming from §82 is reused here only as
terminology for "the beat at which the interpolator phase record shows a step"; it is **not** the same
record index as §82's sel6 capture (different arm, different absolute trigger time, unrelated record
stream) and no attempt is made to align record indices across the two captures.

## Prediction (brief, P2 branch, sel13)

**Prediction:** `countReg`/`mu` (or the underflow cadence) show a discontinuity at the predicted onset
beat, +/-2 beats (records, tref-indexed -- see detector below).

**Falsifier:** interpolator phase is continuous through the predicted onset window -> UNINFORMATIVE for
sel13 alone if the predicted-onset window itself is not reached in onset.bin (see below), or FALSIFIED if
the window is reached and no discontinuity is found -> proceed to sel14 (buffer) per the stop rule.

## Locating the predicted onset record (time -> record index)

`beat_tap_capture.sh` with `LEAD=0.5` starts the `onset.bin` capture at `T_trigger + PERIOD - LEAD`; the
controller ruling states the burst is expected to land ~0.5 s into onset.bin's capture window, and that a
512 MB full-rate window spans ~1.1 s wall-clock (both rulings already in the ledger, cited not re-derived).

`expected_onset_record ~= (LEAD / window_seconds) * total_records_in_file`, with `window_seconds ~= 1.1`
(the ruling's approximate figure -- there is no exact register-derived record rate for sel13, so this is
explicitly an **approximate locus**, not an exact record number). With `LEAD=0.5`: `expected_onset_record
~= 0.4545 * total_records`.

The detector (below) searches a generous window around this locus -- +/-10% of `total_records` (~half the
120.2 s beat period's worth of slack in either direction is not needed; 10% of a 512 MB/4-byte-record file
at 4 records/symbol is far more than the +/-2-beat tolerance the prediction requires, and cheap to scan) --
rather than trusting the locus to +/-2 records. The reported `onset_beat` is the record index of the actual
detected discontinuity (or, if none found, the search proceeds to report FALSIFIED/UNINFORMATIVE as below);
the "+/-2 beats" tolerance in the prediction is then evaluated against the SEARCH being anchored on the
predicted locus (i.e. a discontinuity anywhere far from the locus, e.g. near a different beat entirely,
would not confirm this prediction even if the interpolator does glitch there for an unrelated reason) --
concretely: a candidate discontinuity CONFIRMS the prediction only if it falls within the +/-10% search
window AND its own local record offset from `expected_onset_record`, converted to a beat/record count, is
consistent with "at the onset" (i.e. it is not simply the interpolator's normal per-symbol wrap, and it is
the *first* such anomalous jump found in the search window, not a steady-state artifact recurring throughout
the whole capture -- see "not-a-gate" cadence census in the detector below, which distinguishes a single
onset-coincident event from a periodic artifact that would fire everywhere).

## Detector definition

Operate only on **clean** consecutive record pairs: `(i-1, i)` such that `tref[i-1]>=0`, `tref[i]>=0`, and
`(tref[i]-tref[i-1]) mod 12333 == modal_delta` (the modal tref cadence, from `ddrcap2_pc.py`'s
`_tref_cadence`; at 4 records/symbol the modal delta is 1 tref-unit/symbol per §3's 2026-09-02 correction).
Pairs straddling a DMA drop (delta far from modal) are excluded by construction -- this satisfies the
ledger's "index by tref, exclude drop-coincident events" rule structurally, not by a post-hoc filter.

For each clean pair, compute the raw circular step of the phase accumulator:
`raw_delta[i] = ((countReg[i] - countReg[i-1] + 1024) mod 2048) - 1024` (signed fold of the 11-bit field,
range [-1024, 1024)).

**Baseline:** from a quiet stretch far from the predicted onset locus (the first 20% of clean pairs, i.e.
away from `expected_onset_record`), compute `median_delta` and `MAD` (median absolute deviation) of
`raw_delta`. Define `threshold = max(64, 8 * MAD)` (a floor of 64 counts guards against a baseline that is
already near-zero-spread; 8*MAD is a standard robust outlier bound).

**Event:** a clean pair is a "phase event" if `abs(raw_delta[i] - median_delta) > threshold`.

**Discontinuity at onset:** CONFIRMED iff there is >=1 phase event whose record index falls within
`expected_onset_record +/- 0.02*total_records` (an operational "+/-2 beats" proxy -- see note above; exact
per-symbol beat count is not independently known for this capture, so the window is expressed as a fraction
of the file consistent with the 4 records/symbol capture domain and the phase accumulator's own use of
records, not beats, as its natural unit) AND that event is not part of a periodic pattern recurring at
every beat of the whole capture (i.e. it is not simply steady-state wrap noise -- checked by comparing the
onset-window event rate against the whole-capture event rate away from the locus; a real one-off transition
should be a local spike, not a uniform background rate).

## Positive / negative controls (§0 rule)

Both run on the SAME onset.bin capture, on quiet stretches away from `expected_onset_record` (so neither
control can accidentally land on the real transition):

- **Positive control:** take a quiet stretch of >=2000 clean pairs, at a record offset far (>15% of the
  file) from `expected_onset_record`. Synthetically inject a phase-accumulator discontinuity by adding a
  fixed offset (e.g. +512, half the 11-bit range) to `countReg` for all records after the stretch's
  midpoint, re-run the same detector on this synthetic stretch alone (own baseline/threshold recomputed on
  the pre-injection half), and require it reports exactly the injected event (or a small cluster tightly
  bracketing it, given the modulo-2048 fold can split one true event into 1-2 adjacent flagged pairs).
- **Negative control:** take a second, disjoint quiet stretch (>=2000 clean pairs, also far from
  `expected_onset_record` and from the positive-control stretch), run the same detector unmodified, and
  require zero flagged events (drop-coincident pairs are already excluded by the "clean pair" construction,
  so this is a true negative, not a drop artifact suppressed after the fact).

No onset-window result is reported until both controls pass on this same capture.

## UNINFORMATIVE definition

The sel13 arm is UNINFORMATIVE if any of:
- `ddrcap2_pc.py --sel 13` does not PASS on `onset.bin` (Tier-2 liveness gate), OR
- fewer than 100 clean pairs exist within the `expected_onset_record +/- 0.02*total_records` search window
  (insufficient data to evaluate the prediction there -- e.g. a DMA-drop-heavy region swallowed the locus),
  OR
- the predicted onset window is entirely outside the captured file (onset.bin's window ended before
  `expected_onset_record`, or LEAD's 0.5 s assumption was wrong for this arm) -- in which case `mid.bin`
  (in-burst, displaced-state) is scored for the presence/absence of an in-burst discontinuity pattern
  instead, and onset.bin's miss is stated explicitly, per the controller ruling.

If UNINFORMATIVE, no verdict of CONFIRMED/FALSIFIED is claimed for sel13 and the stop rule's next branch
(sel14) still applies only if the falsifier condition (continuous phase, evaluated where data exists) is
met, not merely because data is thin -- an UNINFORMATIVE sel13 does not by itself trigger sel14; it is
reported to the operator per the brief's "NEITHER/UNINFORMATIVE: no secondary arm; report and return to
the operator" instruction, adapted here to the P2/sel13 sub-branch.

## Command

```
cd two_jup && bash launch_rig_unit.sh beatcap2-sel13-$(date +%H%M%S) beat_tap_capture.sh SEL=13 LEAD=0.5 OUT=$PWD/beatcap/$(date +%Y%m%d_%H%M%S)_sel13
```

Board 148 only. Sentinel stays stopped (`~/modem-status/SENTINEL_STOP` present, verified before this file
was written). Poll `systemctl --user is-active <unit>` at most once per 60 s; never kill the unit. Maximum
one arm at sel13 under this pre-registration; sel14/sel15 each get their own arm and (if reached) their own
addendum to this file before arming, per the stop rule.

---

## Addendum 1 (post-sel13-arm): detector revision and sel13 verdict

**Arm:** `beatcap2-sel13-192051` (see task-9-report.md for the full run log). Both `onset.bin` and
`mid.bin` credited (`credit=yes`), Tier-2 `ddrcap2_pc.py --sel 13` PASS on both.

**Detector revision (documented before the verdict is drawn, same discipline as §82's delta-fold
fix).** The originally pre-registered detector (per-pair magnitude threshold on the raw circular
`countReg` step, `max(64, 8*MAD)`) was run first. Its own positive control -- inject a sustained
+512 step into a quiet real-data stretch -- FAILED per the §0 rule: real silicon `countReg` has a
heavy-tailed per-symbol background (~6% of clean pairs show a step >64 counts, std~253, present
uniformly across the whole file including far from the predicted locus -- ordinary timing-loop
tracking jitter, not a drop artifact, not anomalous). The injected step could not be distinguished
from this background (event count rose from 50,923 to 52,532 out of 837,223 pairs -- not "the
injected event or a small cluster", the pre-registered pass criterion). Per the §0 rule ("no witness
may report a null until it has shown a non-null"), this result was **not used** to score real data.

Fix: the same background, examined via a WINDOWED MEAN (window w=1000 clean pairs = symbols) rather
than per-pair magnitude, has std~1.15 and range +/-3 over a 200k-pair quiet sample -- i.e. the raw
per-symbol jitter is tightly mean-reverting locally (consistent with a locked loop whose tracking
noise self-cancels), while a genuine timing-offset step should shift the LOCAL MEAN persistently, not
just one pair's value. Detector revised to a windowed-mean-shift statistic:
`rolling_mean(raw_delta, w=1000)`, baseline (median, MAD) from a quiet stretch, threshold
`max(10, 8*MAD)`, flag a window start as an event if `|rolling_mean - median| > threshold`. Same
tref-indexed clean-pair construction (drop-coincident pairs excluded structurally, unchanged).

**Controls (real data, this capture, §0 rule), re-run against the revised detector:**
- Negative control (real `onset.bin`, pair-index range [1.34M, 4.70M), unmodified): **0 events**
  (`n_pairs=837222`).
- Positive control (same capture, disjoint pair-index range [0.33M, 1.75M), synthetic sustained
  +40-count step injected at the stretch midpoint): fires immediately at the injection point
  (`closest event to injection point: 0` clean-pair steps) and stays flagged for the remainder of the
  stretch (expected: the injected step is sustained, so every window containing it stays flagged
  until the stretch ends). **PASS** -- the revised detector is validated against this capture's real
  noise floor before being used to score the real locus.
- Unit tests (`tests/test_task9_sel13_detector.py`, synthetic streams): 7/7 pass, including a
  drop-coincident-step exclusion test and an injected-mean-shift confirmation test.

**Real-data scoring:**
- `onset.bin`: search window (record `[29,161,852, 31,846,206)`, i.e.
  `expected_onset_record +/- 0.02*total_records` with `expected_onset_record` at 0.5s/1.1s = 45.5% of
  the file per the LEAD=0.5 ruling): **0 window-mean-shift events.** Full-file scan (all 16,744,451
  clean pairs, not just the search window): **0 events anywhere in the capture.**
- `mid.bin`: same search window and full-file scan: **0 events anywhere.**
- Tier-2 `toff` is constant at `d0=12314` on 100% of records in both captures (matches §82's `d0`).

**Onset-window caveat (operator flag, addressed):** `onset.bin`'s pre-capture capTAP read was
`0xD8A04817` (a known burst/rung word, not golden), meaning the coarse tap-3 state was already
mid-burst when the capture command was issued -- raising the concern that the quiet->displaced
transition itself may have already happened before the window opened. This capture's own toff
(constant, no transition visible) cannot resolve that on its own. However, because the sel13
full-file scan found **zero** mean-shift events anywhere across the entire 512 MB window (not just at
the predicted locus), the "did onset.bin capture the transition instant" question does not change the
verdict: if the transition instant is inside this window, no discontinuity fires; if it is not, there
is still no evidence of one anywhere else in the window either. Both readings are consistent with
"interpolator phase never steps in this capture", which is what FALSIFIED requires.

**Verdict: FALSIFIED for sel13.** The prediction ("countReg/mu show a discontinuity at the predicted
onset beat, +/-2 beats") did not hold, on a detector shown (via positive/negative control on this same
capture's real noise) to be capable of finding a discontinuity of comparable magnitude and character
had one been present. Per the stop rule, proceed to **one arm at sel14** (Delay8 interpolator buffer).

## sel14 pre-registration (P2 branch, falsifier reached)

**Selector:** sel14, `enb_1_2_0_gated`-valid, I = `Symbol_Synchronizer.Delay8_out1_re[18:3]`,
Q = `Delay8_out1_im[18:3]` (design doc §3) -- the raw (RRC-filtered) sample buffer the timing-error
detector reads, not an accumulator/register. There is no phase-accumulator concept here; the ROM
plays an identical repeating sequence, so under steady lock the buffered I/Q content should repeat
with a stable frame-to-frame relationship. A coarse timing/skew step (the kind of event that would
explain §82's `d_data` rung transition) should show up here as a transient LOSS of frame-to-frame
self-similarity at the moment of the step (misaligned samples right at the shift), not as a sustained
level shift the way sel13's accumulator would show one.

**Detector:** using the DDR record-domain frame length for these enb-domain taps
(`FRAME_RECORDS = 4 * 12333 = 49332`, per the design doc's 2026-09-02 correction, "matching the
sample-domain golden streams at 49,332 = 4x12,333 records/frame"): for each non-overlapping
frame-length window `k` of the I channel, compute the Pearson correlation coefficient between window
`k` and window `k+1` (both real, `float64`, over the full `FRAME_RECORDS` samples). Under steady lock
this should be high and stable (near-repeating ROM content); flag frame boundary `k` as an event if
its correlation drops more than a robust threshold (`median - 8*MAD` of the correlation series, from
a quiet reference stretch) below the quiet baseline.

**Prediction:** a correlation dip (frame-to-frame self-similarity loss) localized at the predicted
onset locus, +/-2 frame boundaries, on a detector shown by its own positive/negative control (inject
a sample-index roll/shift at a frame boundary in a quiet stretch; require the dip is reported there
and nowhere in an unmodified control stretch) to be able to detect a comparable shift.

**Falsifier:** no localized dip at/near the predicted locus (correlation stays within the quiet band
throughout) -> proceed to sel15 (Rate_Handle FIFO occupancy step), per the stop rule.

**UNINFORMATIVE:** Tier-2 `ddrcap2_pc.py --sel 14` does not PASS on `onset.bin`, OR fewer than 10
frame-to-frame boundaries fall within the search window, OR the predicted onset window is entirely
outside the captured file (in which case `mid.bin` is scored instead and the miss is stated).

**Command:**
```
cd two_jup && bash launch_rig_unit.sh beatcap2-sel14-$(date +%H%M%S) $PWD/beat_tap_capture.sh SEL=14 LEAD=0.5 OUT=$PWD/beatcap/$(date +%Y%m%d_%H%M%S)_sel14
```
(absolute path to `beat_tap_capture.sh`, per the sel13 arm's launch-path lesson -- a relative path
under `systemd-run` fails with `127` before ARM ever runs, since the unit's cwd is not `two_jup`; that
failure carried no board state change and is not a "retry" under the stop rule.)

---

## Addendum 2 (controller correction): window-timeline reconstruction, sel13 verdict corrected

**The problem, as the controller stated it:** a sel13/14/15 record carries no data word, so a
data re-anchor event (0->rung, rung->rung, rung->0) cannot be located INSIDE a capture from the
capture's own contents -- only from timing evidence external to the record stream. Addendum 1's
"zero events anywhere in the file" result does not by itself falsify anything unless there is
independent evidence that a re-anchor event actually falls inside the scored window. This addendum
reconstructs each sel13 window's timing from `errps.csv`, `journalctl --user -u <unit> -o
short-precise`, and the arm's own capTAP pre/post reads, and re-words the verdict accordingly.

**Timeline reconstruction (records `-o short-precise` timestamps and `meta.txt`/`errps.csv`,
labelled [inferred] where noted):**

`T_trigger = 1788391420.003257 (epoch) = 19:23:40.003 local`, from `meta.txt` (matches
`errps.csv`'s `40,63602` row -- the errps threshold crossing during the 300 s poll).

Journal (`journalctl --user -u beatcap2-sel13-192051.service -o short-precise`) shows two
untagged `BOARD <bytes>` lines (the board-side `iio_readdev` + `stat` completing, piped through
`tee`, no HH:MM:SS prefix from `log()`):
- `mid`: `BOARD 536870912` at `19:23:43.251386` = `T_trigger+3.25s`
- `onset`: `BOARD 536870912` at `19:25:43.901890` = `T_trigger+123.90s`

Taking each `BOARD` line as the (approximate) END of the board-side acquisition window, and the
established ~1.1 s full-rate acquisition duration (controller ruling, already in the ledger) as the
window length, gives **[inferred, +/-0.2-0.3s uncertainty from the 1.1s duration estimate and SSH/stat round-trip]**:
- `mid.bin` window: `T_trigger+[2.15s .. 3.25s]`
- `onset.bin` window: `T_trigger+[122.80s .. 123.90s]`

(Note: `T_onset_pred` in `meta.txt`, `T_trigger+119.70s`, is when the script's wait-loop released
and issued the SSH capture command -- NOT when board-side acquisition began; there is a ~3.1 s gap
between loop-release and the acquisition end inferred above, consumed by SSH dispatch/connection
overhead, not part of the acquisition window itself.)

**Where the burst actually is, and where these windows sit relative to it:** the controller's cited
sel6 arm (§82, a *different* arm, different `T_trigger`) placed `onset_beat_data` at
`T_trigger+120.22s` of ITS OWN arm. Burst phase is not exactly reproducible arm-to-arm (controller:
"jittered >= 0.5 s between arms"), so `120.22s` is a rough anchor, not an exact prediction for this
arm. Against that anchor:
- `mid.bin`'s window (`T_trigger+[2.15,3.25]s`) sits ~2-3 s AFTER `T_trigger` itself, well before the
  next period's ~120.2 s mark -- it is inside the SAME burst episode that crossed the errps
  threshold (the threshold-crossing second's errps value, 63602, reflects elevated activity already
  accumulated over the preceding ~1 s poll, so the burst was almost certainly already underway
  before `T_trigger`). `mid.bin` is confidently INSIDE the burst.
- `onset.bin`'s window (`T_trigger+[122.80,123.90]s`) sits ~2.6-3.7 s AFTER the ~120.2 s periodic
  anchor -- i.e. AFTER, not straddling, the nominal onset instant. This is the same conclusion the
  operator flagged from the pre-read alone (see below): the window most likely opened once the
  transition (if it follows the ~120.2 s anchor) had already happened.

**capTAP pre/post reads bracketing each window (direct [silicon] evidence, from `meta.txt`,
independent of the timeline estimate above):**

| capture | pre (window start) | post (window end) | reading |
|---|---|---|---|
| mid.bin | `0xD71F70D3` (known rung/burst word) | `0xBCF94856` (GOLD) | rung -> golden: a RETURN-TO-QUIET re-anchor event occurred somewhere inside this window |
| onset.bin | `0xD8A04817` (known rung/burst word) | `0xBCF94856` (GOLD) | rung -> golden: same -- a return-to-quiet event occurred somewhere inside this window |

This is exactly the check the controller asked for: "the post-read of your sel13 onset.bin was
golden, so the burst->quiet return may lie inside that window." Both captures' pre/post capTAP
pair shows a genuine rung->golden transition. **Unlike the quiet->rung onset (for which we have no
positive evidence of capture in either window -- the timeline puts both windows after, not
straddling, the ~120.2s anchor), the rung->golden RETURN event is directly evidenced as present
somewhere inside BOTH windows, by the arm's own credit-check reads.** We cannot say which record it
falls at (sel13 carries no data word), but its presence inside the window is not in question the way
the onset's is.

**Re-scored: does the interpolator phase step across the (evidenced) return event?** Addendum 1's
full-file scan (not just the +/-2% locus window -- appropriate here since the return event's exact
record position is unknown) already covers this: **zero windowed-mean-shift events across the
entire 512 MB window, in both `mid.bin` and `onset.bin`** (16,744,451 clean tref-indexed symbol
pairs each), on a detector whose positive/negative control (Addendum 1) demonstrated it can isolate
an injected sustained step of comparable magnitude against this same capture's real noise floor.

**Corrected verdict:**
- **FALSIFIED, window-qualified, for the return-to-quiet re-anchor event**: a real re-anchor
  transition (rung->golden capTAP) is evidenced inside both `mid.bin` and `onset.bin`'s windows, and
  the interpolator phase accumulator shows no discontinuity anywhere in either window while that
  event occurred. This is the falsifier condition earned honestly (a window in which a re-anchor
  event can be placed with stated evidence -- the capTAP bracket -- not a window that may contain no
  event at all).
- **UNINFORMATIVE for the quiet->rung onset transition specifically**: neither window's timeline
  reconstruction places it convincingly at/before the ~120.2 s onset anchor (`onset.bin` in
  particular opens ~2.6-3.7 s after that anchor, consistent with the operator's flag from the raw
  pre-read alone); we have no capTAP-bracket evidence (unlike the return event) that the 0->rung
  transition specifically is inside either window, only that BOTH windows are already in a displaced
  state at window-open (`mid.bin` pre=rung, `onset.bin` pre=rung). The original Addendum 1 wording
  ("FALSIFIES the sel13 prediction... interpolator phase accumulator does not step at the observed
  data-offset rung transition") overstated this: it is corrected to the two-part reading above.
- The `two_jup` commit `34d22e6` ("Task 9: sel13 arm result -- detector revision, controls, verdict
  FALSIFIED") is corrected by this addendum, not amended (a new commit, per repo convention); its
  claim "FALSIFIES the sel13 prediction (interpolator phase accumulator does not step at the
  observed data-offset rung transition)" should be read as superseded by the window-qualified
  statement above.

**Per the stop rule, applied to the corrected reading:** the return-to-quiet falsifier is earned, so
sel14 proceeds as pre-registered (Addendum 1's sel14 section) -- but the SAME window-timeline
reconstruction and capTAP-bracket check must be applied to the sel14 windows before any verdict is
drawn from them, per the controller's ruling. sel15 does not arm until the controller has reviewed
this addendum's sel13 correction and the sel14 result together.

---

## Addendum 3: sel14 arm result -- window timeline, detector failure, verdict UNINFORMATIVE

**Arm:** `beatcap2-sel14-193632` (absolute-path launch, per the sel13 launch-path lesson). Both
`onset.bin` and `mid.bin` credited (`credit=yes`); Tier-2 `ddrcap2_pc.py --sel 14` PASS on both
(`d0=2`, `toff` constant 100% of records on each -- a different `d0` than the sel13 arm's `12314`,
consistent with the established cross-arm `d0` drift pattern, §82).

**Window-timeline reconstruction (same method as Addendum 2), from `meta.txt` and
`journalctl --user -u beatcap2-sel14-193632.service -o short-precise`:**

`T_trigger = 1788392360.983072 = 19:39:20.983 local` (matches `errps.csv`'s `40,63600` row -- the
fourth `+40s` trigger in a row across these arms).

Journal `BOARD` lines: `mid` at `19:39:24.263863` = `T_trigger+3.28s`; `onset` at
`19:41:25.005575` = `T_trigger+124.02s`. With the ~1.1 s acquisition-duration estimate
**[inferred, +/-0.2-0.3s]**:
- `mid.bin` window: `T_trigger+[2.18s .. 3.28s]` -- inside the same burst that crossed the errps
  threshold (same reasoning as the sel13 arm's `mid.bin`).
- `onset.bin` window: `T_trigger+[122.92s .. 124.02s]` -- ~2.7-3.8 s AFTER the ~120.22 s periodic
  onset anchor (per the sel6 arm, itself only a rough cross-arm reference given the controller's
  noted >=0.5 s arm-to-arm jitter). Essentially the same offset from the anchor as the sel13 arm's
  `onset.bin` window (`+122.80..123.90` there vs `+122.92..124.02` here), consistent with a
  repeatable ~3.1 s SSH-dispatch overhead between `T_onset_pred` (loop release) and acquisition
  start, not itself evidence about burst phase.

**capTAP pre/post reads (direct [silicon] evidence):**

| capture | pre | post | reading |
|---|---|---|---|
| mid.bin | `0xD71F70D3` (rung 6299) | `0xBCF94856` (GOLD) | rung->golden: a return-to-quiet event is evidenced inside this window (same pattern as the sel13 arm) |
| onset.bin | `0xBCF94856` (GOLD) | `0xBCF94856` (GOLD) | golden->golden: **no re-anchor event is evidenced inside this window** |

**On the onset.bin golden/golden bracket, per the controller's specific question ("say whether the
onset can be inside the 1.1 s window or whether it is undetermined"):** a single instantaneous
register read at window-open and another at window-close, both golden, are consistent with (a) the
window sitting entirely in the already-quiet, post-return state (no event inside), or (b) a
transient rung episode fully contained within the ~1.1 s window with both endpoints landing outside
it. (b) requires the ENTIRE quiet->rung->quiet cycle to complete inside ~1.1 s; the two arms' own
`mid.bin` windows (each ~1.1 s, opened only ~2-3 s after `T_trigger`) still show the RUNG state at
their pre-read, i.e. the displaced state persists at least that long past `T_trigger` -- so a full
cycle collapsing into ~1.1 s within the SAME burst episode, ~123 s later, is not ruled out but is not
the parsimonious reading either. Given this arm's `onset.bin` window sits at essentially the same
offset-from-anchor as the sel13 arm's `onset.bin` window (which opened rung and closed golden --
i.e. caught the tail of the return), the more likely explanation is that THIS burst's return
completed slightly earlier (burst-to-burst jitter, as the controller noted), so this window opened
already past it. **Verdict on locating the onset: UNDETERMINED, not ruled out but not evidenced --
stated as such, not scored either way.**

**Detector: full-file frame-to-frame correlation scan (`task9_sel14_detector.py`,
`FRAME_RECORDS=49332`).**

`onset.bin`: 1359 frame boundaries scored, baseline median correlation `-0.0002` (MAD `0.0065`,
threshold `-0.0526`), **0 dip events**, corr range `[-0.032, +0.041]`.

`mid.bin`: 1359 boundaries, baseline median `0.0006` (MAD `0.0062`, threshold `-0.0493`), **1 dip
event** at frame boundary 615 (corr `-0.242`, ~40x the baseline MAD from the median).

**This dip is NOT reported as a finding -- the detector fails its own positive control (§0 rule),
below.** Two things undermine trusting it even before running the control:
1. The predicted premise ("under steady lock the buffered I content should repeat with a stable
   [high] frame-to-frame relationship") does not hold on real data: the baseline median correlation
   is ~0 (statistically indistinguishable from uncorrelated), not high and stable. Root cause: these
   enb-domain taps drop records at a very high rate for this purpose -- `drops_per_1e6_records=488`
   (Tier-2 output, both files) means roughly 1 drop per ~2049 records; a `FRAME_RECORDS=49332`-record
   window contains ~24 drops on average, so naive fixed-raw-record-index frame slicing is not
   phase-aligned to the ROM's actual repeat cycle almost anywhere in the file (confirmed directly:
   49.7% of ALL 1359 frame boundaries, in both captures, have a tref gap/drop within +/-500 records
   -- this is the base rate everywhere, not something distinguishing about boundary 615).
2. **Positive control (real data, `onset.bin`, quiet stretch frames 50-150, far from any locus
   assumption): FAILED.** Negative control (unmodified) reported 0 events, as expected. But
   injecting a synthetic sample roll of `FRAME_RECORDS//5` (~9866 records, a shift far larger than
   any plausible sub-symbol timing artifact) at the stretch's midpoint frame boundary produced **NO
   detected dip** (`events=[]`, corr at the injection boundary `-0.0128`, well inside the quiet
   band). The detector cannot find an injected discontinuity substantially larger than what it
   would need to find at a real onset. Per the §0 rule ("no witness may report a null until it has
   shown a non-null"), and here the detector cannot even show a controlled non-null: **the detector
   is not fit for purpose as designed** and no confirm/deny reading may be drawn from it. The single
   raw dip at boundary 615 is therefore reported as an unexplained data point, not evidence of
   anything -- most plausibly ordinary noise in an already near-zero, high-variance baseline (the
   ~50% drop-adjacency base rate means "near a drop" describes half the file, so it does not
   distinguish this boundary either), but the detector's own demonstrated insensitivity to a much
   larger injected shift means a genuine event of the predicted kind could just as easily have
   produced nothing.

**Verdict: UNINFORMATIVE for sel14 -- not because data was scarce, but because the detector, as
designed, is invalidated by the enb-domain tap's drop rate (raw-index frame slicing is not
phase-aligned to the ROM cycle) and demonstrably cannot detect an injected discontinuity of
comparable-or-larger size. A drop-aware (tref-corrected, short-local-window) redesign would be
needed before sel14 can produce a real CONFIRMED/FALSIFIED reading. This is not attempted here --
reported to the operator per instruction, holding before any sel15 arm.**

**Corrected §83/§84 note:** the SESSION_20260830_AUTONOMOUS.md sections for this task use the
window-qualified language from this addendum and Addendum 2, not commit `34d22e6`'s original
overstated framing.

---

## Addendum 4 (controller-directed): sel14 detector revision 2 (tref-indexed, drop-aware), CONFIRMED

**Revision, per the controller's ruling** ("index every analysis by tref and mark_demod, never by
record index" -- the standing dispatch instruction the original sel14 design violated): rebuilt the
frame-to-frame comparison keyed by tref VALUE (0..12332), not raw record count. Each "frame" is now
a `[12333]`-length array built only from tref-valid (slot==1) record positions, with any position
adjacent to a DMA drop on either side (its incoming or outgoing tref step not the modal cadence)
EXCLUDED from that frame's data rather than left in to corrupt alignment. Frame-to-frame Pearson
correlation is computed only over tref values present (non-excluded) in BOTH compared frames, so an
isolated drop removes a handful of tref positions from one comparison, not the phase alignment of
every later frame (the raw-index design's failure mode). Implementation: `task9_sel14_detector.py`
`tref_frames`/`tref_frame_corr_series`/`score_onset_tref_frames`; unit tests in
`tests/test_task9_sel14_detector.py` (6/6 pass, including a scattered-drop robustness test and an
injected-skew confirmation test). **This is the second and last detector revision the controller
allowed for sel14 -- no further sel14 detector changes without a new ruling.**

**No new arm -- re-scored the existing `beatcap2-sel14-193632` captures.**

**Result: the premise holds on real data once correctly aligned.** Baseline frame-to-frame
correlation (quiet 20% of file, both captures): median `~0.965`, MAD `~0.004-0.006` -- high and
tight, unlike the deprecated raw-index design's `~0` baseline. Median tref-position overlap per
compared frame pair: `6610-7192` of `12333` (healthy, not driven down by drops).

**Positive/negative control (real `onset.bin`, quiet stretch, §0 rule), against the revised
detector:**
- Negative control (frames 195-205, unmodified): correlation stays in `[0.954, 0.971]`, 0 dip
  events, well inside the baseline band.
- Positive control (frames 395-405, synthetic sample roll of `(TREF_MOD//3)*4` records injected at
  the frame-400 boundary -- a real skew, not a mean shift, since Pearson correlation is invariant to
  additive constants): correlation collapses from `~0.96` to `[0.02, -0.003, -0.02, 0.01, 0.03,
  0.01]` across 6 consecutive boundaries starting exactly at the injection point, then would recover
  (steady periodic content resumes, just shifted). **PASS** -- the revised detector reliably finds
  an injected discontinuity and reports nothing on an unmodified quiet stretch.

**Real-data scoring (full-file, both captures):**
- `onset.bin`: 1825 boundaries scored. **4 consecutive dip events at frame boundaries 1112-1115**
  (correlation `0.521, 0.065, 0.707, 0.055` against a `0.965` baseline / `0.935` threshold) --
  the SAME multi-boundary collapse-then-partial-recovery shape as the positive control. Records
  `40,891,966`-`41,001,202` (`60.93%-61.10%` of the file). Nowhere else in the file dips.
- `mid.bin`: 1878 boundaries scored. **1 dip event at frame boundary 858** (correlation `0.554`
  against `0.966`/`0.920`). Record `30,318,592` (`45.18%` of the file). Nowhere else dips. (This is
  within ~20,700 records of the DEPRECATED raw-index detector's single flagged anomaly at raw frame
  boundary 615, `~record 30,339,180` -- two independently-designed detectors landing on
  essentially the same location is a cross-validation the deprecated design's single hit was not
  purely a coincidence, even though that design could not be trusted in general.)

**Window-timeline placement of the dips (method as Addendum 2/3):** `mid.bin`'s dip falls at
`T_trigger+2.68s` [inferred], inside its `[2.18s,3.28s]` window (~0.5s in, mid-window).
`onset.bin`'s dip span falls at `T_trigger+[123.59s,123.59s]` [inferred], inside its
`[122.92s,124.02s]` window (~0.67s in, also mid-window, not an edge artifact of the framing).

**Reconciling with the capTAP-bracket evidence (Addendum 3):** both windows' capTAP brackets
already showed a return-to-quiet event evidenced inside `mid.bin` (rung->gold) and, unusually,
NOT inside `onset.bin` (gold->gold, "UNDETERMINED" in Addendum 3). The detector's positive finding
in `onset.bin` now revises that UNDETERMINED reading: **a real content discontinuity is directly
found inside `onset.bin`'s window, independent of the capTAP register** (which only reflects the
coarse tap-3 state, not this buffer) -- so the earlier "gold/gold, no event evidenced" reading is
superseded by this more specific, validated positive detection. (This does not contradict the
capTAP brackets: capTAP's own quiet/rung register is a DIFFERENT signal than the buffer content
sampled here, and the two need not always agree on whether "an event" occurred by their own
separate definitions.)

**Verdict: CONFIRMED for sel14** -- a localized, controlled, twice-independently-observed (in
`mid.bin`) frame-to-frame self-similarity loss is found inside BOTH windows, at the predicted
character (a transient dip, not a sustained level shift), validated against a detector shown (via
real-data positive/negative control) to reliably distinguish an injected discontinuity from quiet
baseline and from drop noise. This supersedes the prior (revision-1, raw-index) UNINFORMATIVE
verdict for sel14 in `SESSION_20260830_AUTONOMOUS.md` §84 and in the task-9 report.

**What this does NOT establish:** the exact physical identity of the event (sel14 carries no data
word, so this cannot be tied to a specific `d_data` rung value the way §82's sel6 arm could); only
that the buffered sample content the timing-error detector reads shows a real, localized
discontinuity inside each window, at a point consistent with (though not independently dated
against) the burst-timing evidence already gathered. Contrast with sel13 (§83): the SAME kind of
window (capTAP rung->gold, return event evidenced) showed ZERO discontinuity in the interpolator
PHASE ACCUMULATOR on a different arm; sel14's BUFFER shows one. Read together (different arms,
same conceptual protocol, not the same physical burst instance), this is suggestive that the
re-anchor mechanism perturbs the buffered sample stream (a skip/skew in what is read) without a
correlated step in the loop's own phase-tracking register -- stated as a hypothesis for the
operator, not re-litigated further here.

---

## Addendum 5: sel15 pre-registration (last of the three arms) -- displaced-state LEVEL form

**Selector:** sel15, `enb_1_2_0`-valid (not gated -- a different valid strobe than sel13/14's
`enb_1_2_0_gated`), Rate_Handle FIFO. Bit packing (design doc §3, with the 2026-09-02 correction):
`I[15:8] = beatobsRhCtr` (BfGridPace's own mod-4 pacer counter at `fixctl=0`, NOT FIFO occupancy --
ignored here), `I[7:3] = beatobsPush[4:0]` (`u_FIFO.Push_Counter_out1`), `Q[15:11] =
beatobsPop[4:0]` (`Pop_Counter_out1`). Both `push` and `pop` are 5-bit (0-31) counters -- the FIFO's
own physical depth, per the design doc's "(buffer, §66's 32-deep FIFO)" note. Matches
`ddrcap2_pc.py`'s existing `check_sel(sel=15)` unpacking exactly (`push_pop_advance` check).

**Why a level form, not a transition-in-window form:** per the controller's ruling (§83/§84), a
sel13/14/15 record carries no data word, so a transition event's presence inside a specific window
cannot be assumed -- it must be evidenced (capTAP bracket, or a controlled detector finding, as in
sel14 Addendum 4) or the window scored some other way. The LEVEL form sidesteps needing the
transition to fall inside the window at all: it compares a STEADY-STATE statistic (the FIFO's
resting occupancy) between a known-quiet reference and a known-displaced reference, which works even
if neither capture straddles the exact transition instant.

**Expected units (read from the bit packing above):** `occupancy = (push - pop) mod 32` is bounded
to `[0, 31]` -- the FIFO's actual depth. A rung-scale event (thousands of symbols, per the §82
`RUNGS` table `6176..6548`) cannot appear as a mod-32 occupancy difference directly; the achievable
observable range for a LEVEL shift is therefore "tens of symbols" (up to 31), not "hundreds" as a
naive rung-scale expectation would suggest. This is stated as a correction to the "tens to hundreds"
framing: the counter width caps the observable level shift at 31 counts.

**Prediction (LEVEL form):** the median `occupancy` (tref-indexed, DMA-drop-adjacent records
excluded, same construction as `task9_sel13_detector.clean_pairs`) in `mid.bin` (in-burst,
pre-read a known rung/burst word -- confidently displaced, per the arm's own capTAP credit check)
differs from the median `occupancy` in `onset.bin`'s quiet reference (the whole window if its
capTAP pre AND post are both golden; otherwise the sub-range of the window before/after any detected
capTAP-implied event) by an amount that is a substantial fraction of the FIFO's 32-entry range (order
tens of counts, not a small few-count fluctuation) and that is OUTSIDE the quiet-state spread
(median +/- a few MAD).

**Falsifier:** `mid.bin`'s median occupancy falls within the quiet-state spread of the `onset.bin`
reference (no level difference beyond ordinary jitter).

**UNINFORMATIVE:** `ddrcap2_pc.py --sel 15` does not PASS on either capture, OR `push`/`pop` do not
behave as decodable level counters (e.g. `push_pop_advance` fails, or only isolated pulses are seen
rather than a steady, computable occupancy), OR `onset.bin`'s capTAP is not both-golden and no other
reliable quiet sub-range can be identified.

**Controls (§0 rule), BEFORE scoring the real level comparison:** on a quiet stretch of one real
capture, (a) negative control: unmodified, occupancy should show no significant level break within
the stretch; (b) positive control: inject a synthetic sustained occupancy step (add a fixed offset,
mod 32, to `push` for all records after a chosen point in the stretch) and confirm the same
level-comparison statistic detects it.

**Secondary (kept per the controller's instruction, "if a window turns out to contain an event"):**
the same tref-indexed windowed-mean-shift TRANSITION detector as sel13 (`task9_sel13_detector`'s
`score_onset_window`, generalized to the 5-bit `push`/`pop` fields' circular fold instead of
`countReg`'s 11-bit one) is also run on both captures as a secondary check, in case either window
does happen to straddle a genuine step (as sel14's `onset.bin` turned out to).

**Command:**
```
cd two_jup && bash launch_rig_unit.sh beatcap2-sel15-$(date +%H%M%S) "$PWD/beat_tap_capture.sh" SEL=15 LEAD=0.5 OUT="$PWD/beatcap/$(date +%Y%m%d_%H%M%S)_sel15"
```
(absolute script path, per the sel13/sel14 launch-path lesson.) This is the LAST of the three
allowed arms (sel13, sel14, sel15) under the Task 9 P2-branch stop rule.

---

## Addendum 6 (controller-directed wording correction): sel14 interpretation, not a re-measurement

**The controller's correction to Addendum 4's interpretation (data/verdict unchanged):** sel14 =
`Symbol_Synchronizer.Delay8` = the interpolated SAMPLE stream (the sample the timing-error detector
itself sees) -- i.e. DATA content, not a control register. A frame-to-frame correlation dip at this
tap shows that a re-anchor event occurred inside the window and that the displacement IS PRESENT in
the interpolator's OUTPUT stream. It does **not** show that the Delay8 buffer is the mover: per the
§72 "transparent stage" logic, any data tap AT OR DOWNSTREAM of the true mover shows the same dip,
because a shift that has already happened upstream simply propagates through every later stage
unchanged. Read together with the frame-identity limit already stated for the ROM (§82 and
elsewhere): since the ROM plays identical repeating frames, a k-symbol shift between two identical
frames is invisible everywhere except at the shift BOUNDARY itself -- which is exactly why the sel14
dip is transient (4 frame boundaries, then apparent recovery to a high correlation baseline) rather
than a sustained drop. This is fully consistent with Addendum 4's data; only the causal-language
overreach is corrected.

**Corrected wording (supersedes Addendum 4's "What this does NOT establish" paragraph and any
"CONFIRMED for sel14" phrasing read as identifying the mover):**

- **sel14 [silicon]:** re-anchor events LOCATED inside both windows by the buffer content itself
  (`onset.bin` frame boundaries 1112-1115, `mid.bin` frame boundary 858); the displacement is
  present at the interpolator's output. This locates the mover AT OR UPSTREAM of the interpolator
  output -- not specifically at the Delay8 buffer itself. Verdict phrasing: **"CONFIRMED:
  displacement present at sel14; event located in-window"** -- never "CONFIRMED that the buffer is
  the mover."
- **sel13 [silicon], strengthened by sel14's event location:** the sel13 and sel14 arms are
  DIFFERENT arms (different `T_trigger`), but their windows are comparable in burst phase --
  `mid.bin`: sel13 `T_trigger+[2.15s,3.25s]` vs sel14 `T_trigger+[2.18s,3.28s]` (within 0.03s);
  `onset.bin`: sel13 `T_trigger+[122.80s,123.90s]` vs sel14 `T_trigger+[122.92s,124.02s]` (within
  0.12s). Given this close phase agreement across independently-triggered arms, the sel13 windows
  are treated as capturing a comparable point in the beat cycle to the sel14 windows in which the
  event was located. On that comparable window, the interpolator PHASE ACCUMULATOR (`countReg`)
  showed no step (§83, full-file windowed-mean-shift scan, zero events). Together: **the mover is
  not the interpolator's phase control loop, and the displacement enters at or upstream of the
  interpolated sample stream** -- consistent with, but not narrowing beyond, the original §82 P2
  finding (mover upstream of the demod marker anchor, in the data path).

**Frame-identity limit, stated explicitly for this paragraph:** because the ROM's frames are
bit-identical repeats, sel14's dip locates WHEN (which frame boundary, in each window) a
displacement is visible, not WHERE in the RTL pipeline it originates, nor whether the shift is a
one-time event or a repeating one at every ROM frame boundary that happens to be masked everywhere
except where two adjacent frames' content actually differs post-shift-vs-pre-shift alignment; the
transient (not sustained) character of the dip is exactly what the frame-identity limit predicts for
a genuine shift between identical frames, not independent evidence of "recovery" to a quiet state.

**A by-product worth stating plainly:** the tref-indexed, drop-aware frame-correlation detector
(`task9_sel14_detector.tref_frames`/`tref_frame_corr_series`) is the first tool in this campaign that
successfully LOCATES a re-anchor event inside a full-rate (enb-domain, high-drop-rate) DDRCAP-v2
window, validated by real-data positive/negative control (Addendum 4). This resolves the general
"where inside a full-rate window is the event" problem that blocked a real verdict on the first
sel14 attempt (Addendum 3) and that sel13's own detector cannot address (it found nothing, which
without an independent event-location tool cannot distinguish "no event" from "an event outside the
detector's sensitivity"). **[silicon], with its controls, as documented in Addendum 4.** Available
for future full-rate arms.

---

## Addendum 7: sel15 arm result (LAST of the three arms) -- LEVEL FALSIFIED, event-location none found

**Arm:** `beatcap2-sel15-195819` (20:01:07 TRIGGER `errps=63602 at +40s`; `mid.bin` credited
`pre=0xD71F70D3 post=0xBCF94856`; `onset.bin` credited `pre=0xD8A04817 post=0xBCF94856`; both
536,870,912 B; rc=0, `=== done`). Tier-2 `ddrcap2_pc.py --sel 15` PASS on both (`d0=12314`, matching
the sel13 arm's; `rhctr_bounded_nonzero` and `push_pop_advance` both PASS).

**Window timeline (same method as §83/§84):** `mid.bin` window `~= T_trigger+[2.13s,3.23s]`
[inferred] -- inside the burst. `onset.bin` window `~= T_trigger+[122.44s,123.54s]` [inferred] --
~2.2-3.3s after the ~120.22s cross-arm anchor, the same pattern as the sel13/sel14 arms'
`onset.bin` windows. capTAP brackets: `mid.bin` `0xD71F70D3`(rung)->`0xBCF94856`(gold); `onset.bin`
`0xD8A04817`(rung)->`0xBCF94856`(gold) -- BOTH windows show the return-to-quiet pattern (unlike
sel14's `onset.bin`, which was gold/gold), so **both sel15 windows have a return event evidenced
inside them**, per the same capTAP-bracket logic as §83.

**LEVEL form (primary, pre-registered), scored as specified, controls first (§0 rule):**
- Negative control (real `onset.bin`, quiet stretch split in half, unmodified):
  `diff=0.0, confirmed=False` -- no spurious level difference.
- Positive control (same file, disjoint stretch, synthetic `+15` (mod 32) step injected at the
  midpoint): `diff=15.0, confirmed=True` -- detector cleanly finds an injected level step of the
  predicted-scale magnitude. **Both PASS.**
- **Real data: `occupancy = (push - pop) mod 32` is EXACTLY constant at `1` across every single
  tref-indexed clean sample in BOTH captures** -- 16,744,451 samples each, `min=max=median=1`,
  zero distinct values other than `1`. `push` and `pop` each individually cycle through their full
  `[0,31]` range (Tier-2's `push_pop_advance` PASS confirms they are not stuck), but always in exact
  lockstep (`push` always exactly 1 ahead of `pop`, mod 32) -- the FIFO's occupancy itself never
  moves, in either window, anywhere.
- The pre-registered `first-20%` vs `last-20%` within-window comparison (using each window's own
  pre/post capTAP bracket as the before/after reference, since neither `onset.bin` nor `mid.bin`
  turned out to be a pure "whole-window-quiet" reference) gives the same result: `diff=0.0` in both
  captures -- no detectable level difference between the near-pre-read and near-post-read portions
  of either window, despite the capTAP register itself changing state within that same window.

**Verdict: FALSIFIED for the LEVEL form.** The FIFO occupancy shows no level difference of any kind
-- not "tens of counts", not any counts -- between the in-burst-adjacent (`mid.bin`) and
onset-adjacent (`onset.bin`) samples, nor within either window's own before/after capTAP-bracketed
halves, on a detector shown (by real-data positive/negative control) to reliably detect an injected
level step of the same or smaller order of magnitude.

**Secondary: event-location (transition) detector, windowed mean-shift on occupancy, per
`task9_sel15_detector.transition_score`.** Degenerate given the LEVEL result: since `occupancy` is
literally constant everywhere (zero variance), every possible delta is exactly `0` and no baseline,
threshold, or event can be anything but null. Ran formally per the pre-registration: `baseline_mad
=0.0`, `threshold=10.0` (the floor), `confirmed=False`, 0 events, on both captures. This is
consistent with, not independent of, the LEVEL result above -- both readings say the same thing
(occupancy never changes), kept separate here only because the pre-registration asked for both forms
to be scored and reported distinctly.

**Verdict: sel15 -- FALSIFIED (LEVEL); no event located (secondary).** The Rate_Handle FIFO's
occupancy is not the mover and shows no trace of the re-anchor event visible at sel14 (§84):
occupancy is downstream of the interpolator (design doc §3, "buffer, §66's 32-deep FIFO"), and per
the §72 transparent-stage logic that correctly predicted sel14's dip, a downstream tap that shows NO
effect from an upstream displacement is informative only if the tap is actually reading a quantity
sensitive to timing/data content -- here `push`/`pop` track FIFO throughput bookkeeping, not sample
VALUES, so a pure data-content shift (of the kind sel14 located) need not perturb `occupancy` at all
if push/pop simply track item counts moving through a FIFO that stays properly paced regardless of
which samples are inside it. This result does not contradict sel14's CONFIRMED-event-located
finding; it says the FIFO's own occupancy bookkeeping is insensitive to (or unaffected by) that
event, which is a different question than whether the FIFO is the mover.

**No further arms -- this was the third and last arm under the Task 9 P2-branch stop rule.**

---

## Addendum 8 (review-directed): capTAP bracket width -- the post-read is ~9-11s after window close

**Reviewer finding, no arm/board contact needed to fix -- a write-up-only correction.** Every capTAP
"post" read quoted in §83/§84/§85 as bracketing "window close" is actually taken at the `mid:`/
`onset:` log line, which fires only AFTER the 512 MB file has been copied back host-side over SSH
(`beat_tap_capture.sh`'s `capture()`: `cat /tmp/g.bin` over `anyssh.sh`, then the `rd 0x20C` post-read,
then the `log()` line). That copy takes ~9-11 s. The capTAP bracket's evidenced interval is therefore
**window + copy-time (~10-12 s total), not the ~1.1 s scored/decoded window** the detectors actually
run on. Measured directly from `journalctl -o short-precise` (`BOARD` line = board-side acquisition
done = window close; `mid:`/`onset:` line = post-read, after copy):

| arm | capture | BOARD (window close) | post-read line | gap |
|---|---|---|---|---|
| sel13 | mid | 19:23:43.251386 | 19:23:52.675573 | 9.42s |
| sel13 | onset | 19:25:43.901890 | 19:25:55.460606 | 11.56s |
| sel14 | mid | 19:39:24.263863 | 19:39:33.726432 | 9.46s |
| sel14 | onset | 19:41:25.005575 | 19:41:36.427881 | 11.42s |
| sel15 | mid | 20:01:10.863098 | 20:01:21.033103 | 10.17s |
| sel15 | onset | 20:03:11.166307 | 20:03:20.583911 | 9.42s |

(Pre-reads are taken right at window open, before `iio_readdev` is issued, so the PRE side of every
bracket is accurate to window-open; only the POST side is displaced by the copy-time gap.)

**Consequence for sel13 (controller ruling):** the §83 null result -- the interpolator phase
accumulator (`countReg`) shows no discontinuity anywhere in the ~1.1 s of data actually decoded and
scored -- stays **[silicon]**: that is a direct measurement of the real, scored records, unaffected
by where exactly the capTAP transition happened. What is **not** established by the capTAP bracket
alone is that the rung->gold transition itself occurred INSIDE that scored 1.1 s window, as opposed
to during the ~9-11 s trailing copy period after the window closed. Placement of the event inside the
sel13 scored window is instead **[inferred]**, via cross-arm transfer: the beat is phase-locked to
the arm script's own timing (all six arms across sel13/sel14/sel15 triggered at `+40s` of the 300s
poll; `mid.bin`'s pre-read was rung `6299` (`0xD71F70D3`) on every one of the six captures where a
`mid.bin` was taken), and sel14's tref-indexed detector -- which CAN precisely locate an event within
its own scored data, unlike sel13's null result -- found its events at closely matching relative
positions across its two windows (~45% of `mid.bin`, ~61% of `onset.bin`) using the SAME script,
SAME `LEAD=0.5`, SAME timing structure as the sel13 arm. Transferring that in-window location onto
sel13's comparably-timed windows (§84's cross-arm phase-agreement finding: sel13/sel14 `mid.bin`
windows agree within 0.03s of `T_trigger`, `onset.bin` within 0.12s) is the basis for placing the
event inside sel13's scored window too -- but it is a transfer from a different arm's finding, not a
direct measurement on the sel13 captures themselves.

**Corrected sel13 verdict wording (replaces the "FALSIFIED for the return-to-quiet re-anchor event"
phrasing in §83 and Addendum 2 -- addendum, not a rewrite):**

> **FALSIFIED [inferred: event placement transferred from the sel14 arm's in-window location under
> the phase-lock observation]; phase continuous through the whole window [silicon].**

Do not present this as a silicon-proven falsification of an event known (from sel13's own data
alone) to be inside the window -- the [silicon] fact is "phase is continuous through all 1.1 s of
data we scored"; the [inferred] fact is "a re-anchor event was inside that 1.1 s, not in the
trailing copy gap."

**Same bracket-width caveat applies to the sel14 and sel15 capTAP brackets quoted in §84/§85** --
stated there for completeness, though it does not change either of those verdicts: sel14's finding
did not rely on the capTAP bracket at all (its own tref-indexed detector located the event directly,
inside the scored data, independent of any register read); sel15's LEVEL-form finding is a direct
measurement of the actually-scored ~1.1 s of data (occupancy pinned at 1 throughout) and does not
depend on knowing exactly when within the wider bracket a transition occurred.

## Addendum 9 (review-directed): sel15 dynamic range -- occupancy is pinned at 1, an interpretive limit

**Reviewer finding.** Computed over ALL records (not just the tref-indexed clean subset scored in
Addendum 7), `occupancy = (push-pop) mod 32` takes exactly two values across both captures: `{0, 1}`.
Checked directly: `occupancy==0` occurs ONLY where `tref<0` (the 3-of-4 records per symbol that do
not carry a valid tref sidecar reading -- i.e. `0` is a record-decode artifact of push/pop updating
on a different sub-cycle than the tref sidecar write, not a real "empty FIFO" observation) --
`10,768,405` (onset) / `10,733,703` (mid) records, 100% at `tref<0` positions, 0% at `tref>=0`
positions. At every tref-valid (anchored, clean) sample -- the only samples the pre-registered LEVEL
form scores -- `occupancy` is **always exactly `1`**. The FIFO runs effectively pass-through at this
tap: one item is always in flight, never more, never fewer, at the granularity this record format can
observe.

**Consequence, stated as an interpretive limit (verdict word unchanged):**

> **FALSIFIED under the pre-registered LEVEL form [silicon]; interpretive limit: with occupancy
> pinned at 1, the LEVEL form can exclude an occupancy-based mover but cannot see a re-anchor that
> leaves occupancy unchanged (e.g. one that alters the FIFO's control/pacing path -- which record
> gets pushed/popped WHEN -- without changing how many records are in flight at any instant). The
> `+15` positive control (Addendum 7) proves the DETECTOR works (it can find an injected level step),
> not that the FIELD can move under a real re-anchor event -- push/pop themselves were never observed
> to produce anything but a 0/1 occupancy pattern in this data, so the control's `+15` injection
> demonstrates sensitivity to a hypothetical excursion the silicon has not been shown to produce.**

This does not soften "FALSIFIED" -- the pre-registered LEVEL prediction (an occupancy difference of
order tens of counts between displaced and quiet references) is cleanly falsified by data that never
leaves `{0,1}`. It states plainly what that falsification does and does not rule out: an
occupancy-invariant re-anchor mechanism at or through this FIFO remains possible and untested by this
form.

---

## Addendum 10 (final-fix round, 2026-09-02): overreach in Addendum 6's "mover is not the interpolator's phase control loop" sentence, corrected

Addendum, not a rewrite of Addendum 6. Filed against the final whole-branch review's fix brief
(`.superpowers/sdd/2026-09-02-ddrcap2-joint-timing-capture/final-fix-brief.md`), item C. No arm, no
board contact.

**The sentence under correction (Addendum 6):** "Together: the mover is not the interpolator's phase
control loop, and the displacement enters at or upstream of the interpolated sample stream."

**Why it overreaches.** The sel13 windowed-mean-shift detector's own positive control (Addendum 1)
injects a **sustained +40-count-PER-SYMBOL offset** into `countReg` -- a rate change held over many
symbols, not a one-shot value step. That is the only kind of discontinuity the detector has been
shown, on this capture's own real noise floor, to be able to find. A one-shot phase step -- the size
and shape a single symbol re-anchor event would actually produce in the NCO accumulator -- was never
injected as a positive control. Per this file's own module-docstring characterization of the real
background (`task9_sel13_detector.py`: ~6% of clean pairs show a single-pair step >64 counts
uniformly across the whole file, ordinary timing-loop jitter), a one-shot step of comparable
magnitude sits inside that jitter and would not, by itself, move a `w=1000`-pair windowed mean past
threshold. §83's zero-events full-file result is therefore a valid null for "no sustained rate
change," not for "no one-shot phase step."

**Corrected claim, earned:** *"No sustained change in the interpolator's phase-accumulation rate
(the mean `raw_delta` per clean pair) anywhere across the scored window [silicon]."*

**Not earned, struck/qualified:** *"the mover is not the interpolator's phase control loop"* -- this
requires ruling out a one-shot phase step, which the detector's own controls do not cover. The
sentence is corrected to the earned form above wherever it appears (this file's Addendum 6; the
mirrored text in `SESSION_20260830_AUTONOMOUS.md`'s "§84 wording correction" section -- see that
file's own §83/§84 addendum for the parallel correction).

**The underflow-cadence alternative, named but not scored.** This file's original pre-registration
(before Addendum 1's detector revision) named an underflow-cadence statistic as an alternative to the
countReg magnitude/windowed-mean-shift approaches. Only the windowed-mean-shift statistic was carried
forward and scored against real data (Addendum 1). **The underflow-cadence alternative was never run
on either sel13 capture** and remains an open check, not a ruled-out one.

**What is unaffected:** §82's P2 finding and sel14's own located-event result (Addendum 4: `onset.bin`
frame boundaries 1112-1115, `mid.bin` frame boundary 858, both real, positively-controlled
measurements) are unaffected -- sel14 still locates the mover AT OR UPSTREAM of the interpolator
output. Only the further negative claim, built by combining sel14's finding with sel13's
under-controlled null, is withdrawn.
