# Task 9 report: secondary arms on the §82 P2 branch (sel13, sel14, sel15) -- COMPLETE

Status: DONE_WITH_CONCERNS.

## Sequence of events (condensed; full detail in TASK9_PREREG.md and SESSION_20260830_AUTONOMOUS.md
§83-§85)

1. Pre-registered sel13 (`TASK9_PREREG.md`, commit `b969269`) before arming.
2. Armed sel13 (`beatcap2-sel13-192051`, second attempt -- first failed 127 on a relative script
   path, no board state touched). Original per-pair detector failed its own positive control (§0
   rule); revised to a windowed-mean-shift detector on `countReg`, validated, scored: zero events
   anywhere in either 512 MB window. First write-up overstated this as "FALSIFIES" (commit `34d22e6`).
3. **Coordinator ruling:** a sel13/14/15 record carries no data word -- "zero events in a window
   that may contain no event" proves nothing without independent evidence a re-anchor event is
   inside the window. Reconstructed window timing (errps.csv + journalctl + meta.txt) and capTAP
   pre/post brackets for both sel13 windows: both show rung->gold (a return event evidenced
   inside). Corrected verdict: FALSIFIED for the return-to-quiet event specifically; UNINFORMATIVE
   for the quiet->rung onset transition (commit `7d84140`). **Superseded by step 9 below** (review
   found the capTAP bracket itself was mis-timed; the final sel13 wording is the one in the
   per-selector findings section, not this step's).
4. Armed sel14 (`beatcap2-sel14-193632`, let finish untouched per the coordinator's HOLD).
   Raw-record-index frame-correlation detector failed its own positive control (baseline
   correlation ~0 everywhere due to the ~1-in-2049 drop rate corrupting the framing). Verdict:
   UNINFORMATIVE (commit `4919290`).
5. **Coordinator ruling:** the sel14 detector violated the standing "index by tref, never record
   index" instruction -- exactly why it hit the drop confound. Directed detector revision 2 (the
   last allowed for sel14): rebuild frames by tref VALUE, excluding drop-adjacent positions
   per-frame. Re-scored the SAME captures, no new arm. Baseline correlation is now `~0.965`
   (matches the original premise); controls PASS; real data shows a localized, controlled,
   multi-boundary correlation dip in BOTH windows (`onset.bin` frames 1112-1115, `mid.bin` frame
   858) -- CONFIRMED (commit `9c2b7be`).
6. **Coordinator wording ruling:** sel14's dip shows the displacement is present at the
   interpolator's OUTPUT (data content), not that the Delay8 buffer is the mover (§72
   transparent-stage logic: any tap at/downstream of the true mover shows the same dip; frame-
   identity limit explains the transient shape). Corrected phrasing: "CONFIRMED: displacement
   present at sel14; event located in-window", locating the mover at or upstream of the
   interpolator output. sel13 strengthened: comparable-burst-phase windows (within 0.03-0.12s
   across arms) show no phase-accumulator step -- together, the mover is not the interpolator's
   phase control loop. Addendum, not a rewrite (commit `774aae9`).
7. Pre-registered sel15 (`TASK9_PREREG.md` Addendum 5, commit `4aa87f2`) as a displaced-state LEVEL
   form (occupancy comparison), since a transition's presence in a window cannot be assumed.
8. Armed sel15 (`beatcap2-sel15-195819`, last of 3 arms). Decoded, Tier-2 PASS, window timeline
   reconstructed, LEVEL form controls run (PASS), real data scored: `occupancy=(push-pop) mod 32`
   is exactly constant at `1` across all 16,744,451 clean samples in BOTH captures, zero variance
   anywhere. Secondary transition detector: degenerate null (consistent). Verdict: FALSIFIED for
   the LEVEL form; no event located (commit `5a905e2`).
9. **Reviewer round (write-up only, no arm, no board contact):** two Important framing gaps found
   and fixed. (a) Every capTAP "post" read is taken ~9-11s AFTER board-side window close (the 512 MB
   SSH copy-back), not at window close -- so every capTAP bracket's evidenced interval is ~10-12s
   (window+copy), not the ~1.1s scored window. sel13's null (`countReg` continuous through the
   scored data) stays [silicon]; placing the return event INSIDE that scored window is [inferred]
   via cross-arm transfer from sel14's directly-located events (phase-locked beat timing across
   arms). Reworded: "FALSIFIED [inferred: event placement transferred from the sel14 arm's
   in-window location under the phase-lock observation]; phase continuous through the whole window
   [silicon]." (b) sel15's occupancy is pinned at exactly `1` at every clean sample across ALL
   records (checked directly) -- an interpretive limit stated alongside the unchanged FALSIFIED
   verdict: the LEVEL form can exclude an occupancy-based mover but not one that leaves occupancy
   unchanged. `TASK9_PREREG.md` Addenda 8-9, `SESSION_20260830_AUTONOMOUS.md` §83/§85 corrections
   (addenda, not rewrites), this report updated to match (commit below).

## Commands run

Pre-registration commits: `git add TASK9_PREREG.md && git commit -s -m "..."` (x4, one per
selector plus one wording correction).

Arms (absolute script path, per the sel13 launch-path lesson after one relative-path failure):
```
cd two_jup && bash launch_rig_unit.sh beatcap2-sel13-192051 "$PWD/beat_tap_capture.sh" SEL=13 LEAD=0.5 OUT="$PWD/beatcap/20260902_192051_sel13"
cd two_jup && bash launch_rig_unit.sh beatcap2-sel14-193632 "$PWD/beat_tap_capture.sh" SEL=14 LEAD=0.5 OUT="$PWD/beatcap/20260902_193632_sel14"
cd two_jup && bash launch_rig_unit.sh beatcap2-sel15-195819 "$PWD/beat_tap_capture.sh" SEL=15 LEAD=0.5 OUT="$PWD/beatcap/20260902_195819_sel15"
```

Decode / Tier-2 (each capture): `python3 ddrcap2_decode.py --summary <file>`;
`python3 ddrcap2_pc.py <file> --sel {13,14,15}` -- all six captures PASS Tier-2.

Unit tests: `python3 -m pytest tests/test_task9_sel13_detector.py tests/test_task9_sel14_detector.py tests/test_task9_sel15_detector.py -q` -- **18 passed.**

## Unit names and rig status

- `beatcap2-sel13-192039.service` -- FAILED (exit 127, relative path under systemd-run's different
  cwd; before ARM ran; no board state touched, not a retry).
- `beatcap2-sel13-192051.service`, `beatcap2-sel14-193632.service`, `beatcap2-sel15-195819.service`
  -- all success, rc=0, `=== done`.
- Board 148 verified idle/golden (`0x20C`=`0xBCF94856`) before the first and before the sel15 arm.
  Board 146 never touched. Sentinel stayed stopped throughout
  (`~/modem-status/SENTINEL_STOP` present, verified multiple times). Exactly three arms used
  (sel13, sel14, sel15) -- the Task 9 P2-branch maximum.

## Arm results and capture credits

| capture | bytes | pre capTAP | post capTAP | credit |
|---|---|---|---|---|
| sel13 mid.bin | 536,870,912 | `0xD71F70D3` (rung) | `0xBCF94856` (gold) | yes |
| sel13 onset.bin | 536,870,912 | `0xD8A04817` (rung) | `0xBCF94856` (gold) | yes |
| sel14 mid.bin | 536,870,912 | `0xD71F70D3` (rung) | `0xBCF94856` (gold) | yes |
| sel14 onset.bin | 536,870,912 | `0xBCF94856` (gold) | `0xBCF94856` (gold) | yes |
| sel15 mid.bin | 536,870,912 | `0xD71F70D3` (rung) | `0xBCF94856` (gold) | yes |
| sel15 onset.bin | 536,870,912 | `0xD8A04817` (rung) | `0xBCF94856` (gold) | yes |

## Tier-2 results

All six captures PASS `ddrcap2_pc.py --sel {13,14,15}`. `d0` (toff mode): sel13 `12314` (both
captures), sel14 `2` (both), sel15 `12314` (both) -- cross-arm drift already established (§82) as
evidence tOff is live, not stuck.

## Window-timeline reconstruction (all three arms; method: errps.csv + `journalctl -o
short-precise` `BOARD`-line timestamps + `meta.txt`, window bounds [inferred, ±0.2-0.3s])

| arm | mid.bin window (T_trigger+) | onset.bin window (T_trigger+) | capTAP bracket (mid / onset) |
|---|---|---|---|
| sel13 | `[2.15s,3.25s]` | `[122.80s,123.90s]` | rung→gold / rung→gold |
| sel14 | `[2.18s,3.28s]` | `[122.92s,124.02s]` | rung→gold / **gold→gold** |
| sel15 | `[2.13s,3.23s]` | `[122.44s,123.54s]` | rung→gold / rung→gold |

`mid.bin` windows agree within 0.05s across all three arms; `onset.bin` windows agree within 0.36s.
This close cross-arm agreement is why sel13's and sel14's windows are treated as "comparable in
burst phase" in the corrected §84 reading, despite being different arms (different `T_trigger`).
The ~120.22s onset anchor is from the (different) sel6 arm, §82; the controller noted ≥0.5s
arm-to-arm burst-phase jitter, so it is an approximate reference only.

**Review-directed correction: capTAP bracket width.** Every capTAP "post" read above is taken at the
`mid:`/`onset:` log line, which fires only AFTER the 512 MB file is copied back host-side over SSH --
NOT at window close. Measured directly (`journalctl -o short-precise`, `BOARD` line = window close):

| arm | capture | window close (BOARD) | post-read line | gap |
|---|---|---|---|---|
| sel13 | mid | 19:23:43.251386 | 19:23:52.675573 | 9.42s |
| sel13 | onset | 19:25:43.901890 | 19:25:55.460606 | 11.56s |
| sel14 | mid | 19:39:24.263863 | 19:39:33.726432 | 9.46s |
| sel14 | onset | 19:41:25.005575 | 19:41:36.427881 | 11.42s |
| sel15 | mid | 20:01:10.863098 | 20:01:21.033103 | 10.17s |
| sel15 | onset | 20:03:11.166307 | 20:03:20.583911 | 9.42s |

Every capTAP bracket's evidenced interval is therefore **window+copy (~10-12s), not the ~1.1s
scored window** the detectors actually ran on. Pre-reads are unaffected (taken at window open,
before `iio_readdev` is issued). Consequence for sel13's verdict below; sel14's finding did not rely
on the bracket (its detector located the event directly in scored data); sel15's LEVEL-form finding
is a direct measurement of the actually-scored data, unaffected by this correction.

## Detector controls (all real-data, on the actual captures, §0 rule)

**sel13 (windowed mean-shift on `countReg`, w=1000 tref-indexed clean pairs):** original per-pair
design FAILED its positive control (6% real background jump rate swamped an injected step); revised
windowed-mean-shift design PASSED (injected step found exactly, 0 false positives on an unmodified
stretch). Real-data score: 0 events anywhere in either 512 MB window (both captures).

**sel14 revision 1 (raw-record-index frame correlation):** FAILED its positive control (baseline
correlation ~0 everywhere; an injected shift larger than any real target produced no detection) --
not used to score real data.

**sel14 revision 2 (tref-indexed, drop-aware frame correlation):** PASSED (baseline correlation
~0.965, matches the original premise; injected skew collapses correlation across 6 consecutive
boundaries exactly at the injection point; unmodified control reports nothing). Real-data score: a
localized multi-boundary dip found in BOTH windows (details below).

**sel15 (occupancy LEVEL comparison, `push-pop` mod 32):** PASSED (negative control on an unmodified
real stretch: `diff=0`; positive control, injected `+15` mod-32 step: `diff=15`, detected exactly).
Real-data score: occupancy is exactly `1` everywhere, zero variance, in both captures.

## Per-selector findings and window-qualified verdicts

**sel13 [silicon]/[inferred]:** the interpolator phase accumulator (`countReg`) shows no
discontinuity anywhere in either 512 MB window that was actually decoded and scored (full-file
windowed-mean-shift scan, 16,744,451 clean pairs each) -- **[silicon]**, a direct measurement. The
capTAP bracket (rung→gold) does NOT bracket window-open-to-window-close as originally stated: the
post-read is taken at the `mid:`/`onset:` log line, ~9-11s AFTER the board-side window actually
closes (the 512 MB copy-back over SSH), so the bracket's evidenced interval is ~10-12s (window +
copy time), not the ~1.1s of data scored. Placing the return event INSIDE the scored 1.1s window
(rather than in the trailing copy gap) is therefore **[inferred]**, via cross-arm transfer: the beat
is phase-locked to the arm script (six arms, six `+40s` triggers, `mid.bin` pre-read rung 6299 every
time), and sel14's detector -- which CAN locate an event within its own scored data -- found its
events at ~45%/~61% of comparably-timed windows using the same script and timing. Verdict:
**"FALSIFIED [inferred: event placement transferred from the sel14 arm's in-window location under
the phase-lock observation]; phase continuous through the whole window [silicon]."** Not presented
as a silicon-proven falsification. **UNINFORMATIVE for the quiet→rung onset transition
specifically** -- no comparable evidence either window contains that particular transition (the
timeline places `onset.bin` after, not straddling, the ~120.22s anchor).

**sel14 [silicon]:** the frame-to-frame self-similarity of the interpolated sample buffer
(`Symbol_Synchronizer.Delay8`) shows a real, localized, controlled discontinuity in BOTH windows:
`onset.bin` frame boundaries 1112-1115 (records 40,891,966-41,001,202, ~61% of file, correlation
`0.52/0.06/0.71/0.05` vs a `0.965`/`0.935` baseline/threshold); `mid.bin` frame boundary 858 (record
30,318,592, ~45% of file, correlation `0.55`) -- within ~20,700 records of an independently-designed
(deprecated) detector's own single flagged anomaly at the same capture, a cross-validation. Both
dips sit mid-window (~0.5-0.67s into each ~1.1s window), not at an edge artifact.

**Verdict (corrected wording, per the controller's ruling): "CONFIRMED: displacement present at
sel14; event located in-window."** This shows the displacement is present at the interpolator's
OUTPUT (data content) and LOCATES it in time within each window -- it does **not** show the Delay8
buffer is the mover: per the §72 "transparent stage" logic, any data tap at or downstream of the
true mover shows the same dip, and the frame-identity limit (bit-identical repeating ROM frames)
explains why the dip is transient (a few boundaries, then apparent recovery) rather than sustained
-- this is exactly what a genuine k-symbol shift between identical frames looks like, not
independent evidence of "recovery" to a different physical state. Locates the mover **at or
upstream of the interpolator output.**

**sel13 + sel14 together:** the sel13 and sel14 windows are different arms but comparable in burst
phase (agree within 0.03-0.12s of `T_trigger`). On that comparable window, sel13's phase
accumulator shows no step while sel14's buffer content does. **Together: the mover is not the
interpolator's phase control loop; the displacement enters at or upstream of the interpolated
sample stream** -- consistent with, not narrower than, §82's original P2 finding.

**sel15 [silicon]:** the Rate_Handle FIFO's occupancy (`push-pop` mod 32, the FIFO's actual 32-entry
depth) is exactly constant at `1` across all 16,744,451 clean samples in BOTH windows -- `push` and
`pop` each individually cycle their full range (not stuck) but stay in exact lockstep throughout.
Checked over ALL records (not just the clean subset): `occupancy` takes only `{0,1}` anywhere, and
`0` occurs EXCLUSIVELY at `tref<0` (decode-artifact) positions -- at every clean, tref-valid sample,
`occupancy` is exactly `1`; the FIFO runs effectively pass-through at this tap.

**Verdict: "FALSIFIED under the pre-registered LEVEL form [silicon]; interpretive limit: with
occupancy pinned at 1, the LEVEL form can exclude an occupancy-based mover but cannot see a
re-anchor that leaves occupancy unchanged (e.g. one in the FIFO's control/pacing path). The `+15`
positive control proves the detector, not that the field can move under a real re-anchor event."**
**Secondary transition detector: no event located** (degenerate given zero variance in the primary
signal, consistent with the LEVEL result). Read against sel14: sel15 is downstream of the
interpolator and tracks FIFO throughput bookkeeping (item counts), not sample values -- a pure
data-content shift (sel14's finding) need not perturb `occupancy` if the FIFO stays properly paced
regardless of which samples pass through it. Does not contradict sel14; says sel15's own
instrumented quantity is insensitive to that event, and that this LEVEL form cannot see an
occupancy-invariant mover even if one exists.

## By-product worth stating plainly [silicon, with controls]

The tref-indexed, drop-aware frame-correlation detector built for sel14 (revision 2) is the first
tool in this campaign that successfully LOCATES a re-anchor event inside a full-rate (high-drop-rate,
enb-domain) DDRCAP-v2 window. It resolves the general "where inside a full-rate window is the
event" problem that blocked a real verdict on the first sel14 attempt and that sel13's/sel15's own
detectors cannot address on their own (a null result from those tools cannot, by itself, distinguish
"no event" from "an event outside the detector's sensitivity" -- this tool can and did locate one).
Available for future full-rate arms; implementation in `two_jup/task9_sel14_detector.py`
(`tref_frames`/`tref_frame_corr_series`/`score_onset_tref_frames`).

## Deviations from the brief / pre-registration

1. sel13's originally pre-registered per-pair detector failed its own positive control and was
   revised before scoring real data (documented, TASK9_PREREG.md Addendum 1).
2. Per the controller's ruling, the first sel13 write-up's "zero events = falsified" framing was
   corrected to a window-qualified verdict (Addendum 2) requiring independent evidence (capTAP
   bracket) that an event is inside the scored window.
3. sel14's originally pre-registered raw-index detector failed its own positive control; the
   controller directed and I implemented the one allowed revision (tref-indexed, drop-aware,
   Addendum 4), re-scoring the EXISTING captures with no new arm.
4. The controller corrected sel14's causal wording (event located vs "the buffer is the mover",
   Addendum 6) -- applied as an addendum, not a rewrite of the original text.
5. sel15's LEVEL form used a within-window before/after split (rather than a pure cross-file
   quiet-vs-displaced comparison) once it became clear neither file was a pure single-state
   reference (both showed rung→gold capTAP brackets) -- documented in Addendum 7.
6. No sel15 arm was launched until the coordinator's explicit go-ahead after reviewing sel13's
   corrected verdict and sel14's revised result, per the HOLD instruction from mid-task.

## Facts for the record (memory-style)

- **sel15 occupancy dynamic range [silicon]:** `(push-pop) mod 32` observed range across all six
  captures = `{1}` only at every tref-valid (clean, scored) record; `{0,1}` across ALL records
  including tref-invalid ones, with `0` occurring EXCLUSIVELY at `tref<0` positions (a decode
  artifact of push/pop updating on a different sub-cycle than the tref sidecar, not a real "empty
  FIFO" reading). The FIFO runs pass-through at this tap -- one item always in flight. This bounds
  what the sel15 LEVEL form can ever detect (see interpretive-limit wording above); record this fact
  before any future sel15-based arm.
- **capTAP bracket width [silicon]:** the post-read half of every `beat_tap_capture.sh` capTAP
  bracket is taken ~9-11s after board-side window close (after the 512 MB SSH copy-back), not at
  window close itself. Any future use of a capTAP pre/post bracket to place an event "inside a
  window" needs this correction applied, or an independent in-window detector (like sel14's
  tref-indexed frame-correlation tool) to locate the event directly.

## Concerns for the operator

- The physical identity/location of the sel14-located re-anchor event remains unresolved (sel14
  carries no data word) -- only that a displacement is present in the interpolator's output stream,
  and that it is not the interpolator's own phase-tracking loop nor the Rate_Handle FIFO's occupancy
  bookkeeping.
- No `.bin` files were committed (hard rail honored); all six 512 MB `mid.bin`/`onset.bin` pairs
  remain locally in `two_jup/beatcap/<ts>_sel{13,14,15}/`, untracked.
- All three arms of the Task 9 P2-branch budget are now used; any further silicon work on this
  question needs a new task/ruling.
