# Task 8 report: pre-registered sel6 burst capture and §6 verdict

Board 148 only. 146 never touched. Sentinel remained stopped throughout (not started, SENTINEL_STOP
not removed).

## Step 1: capture script + fakes (verbatim from beat plan Task 7, then one fix)

Wrote `two_jup/beat_tap_capture.sh`, `two_jup/tests/fake_anyssh.sh`, `two_jup/tests/fake_arm.sh` from
`docs/superpowers/plans/2026-09-01-beat-tap-compare.md` lines 868-973, verbatim.

Dry run (verbatim plan Step 3):
```
cd two_jup && chmod +x tests/fake_anyssh.sh tests/fake_arm.sh beat_tap_capture.sh && rm -rf /tmp/fake148
W=$PWD/tests/fake_anyssh.sh ARM=$PWD/tests/fake_arm.sh SZ=1024 PERIOD=6 LEAD=1 OUT=/tmp/beatcap_dry bash beat_tap_capture.sh 3
```
Result: `TRIGGER errps=20000 at +3s`, `mid.bin`/`onset.bin` 4096 bytes each, `meta.txt` with
`T_trigger`/`T_onset_pred`, no ABORT. Second dry run into the same OUT: `REFUSE: .../mid.bin exists
(4096 bytes) -- not overwriting`, rc=5. `bash -n beat_tap_capture.sh` OK; `shellcheck` not installed on
this host (skipped, noted here rather than silently omitted).

## Step 2-4: analysis tests RED then GREEN, one minimal fix

`two_jup/tests/test_ddrcap2_beat_analysis.py` and `two_jup/ddrcap2_beat_analysis.py` written verbatim
from the brief. `pytest tests/test_ddrcap2_beat_analysis.py -q`: RED first (`ModuleNotFoundError:
ddrcap2_beat_analysis`, since the module didn't exist yet), then after writing the module verbatim,
3 passed / 1 failed (`test_P1_when_toff_moves_with_data`).

**Deviation (per the brief's own resolution-of-ambiguities clause):** the brief's `analyse()` computed
`delta = (after-d0) % 12320` then `delta = min(delta, 12320-delta)`. Every `RUNGS` value (6176..6548)
exceeds 12320/2=6160, so that fold always maps a genuine rung step into its unmatched complement
(5772..6157) — structurally can never pass `is_rung`. Verified 12320 itself is correct (it is the ROM's
declared symbol-frame length per `offsetmap/tap3_word_to_offset.tsv`'s header comment "frame=12320
symbols"; the `P=12333` used elsewhere in the same file, and in `ddrcap2_pc.py`, is the distinct DDR
record-frame length). Fixed by checking the raw circular delta AND its complement against `RUNGS`
directly (no fold-to-half). Tests left verbatim. `pytest tests/test_ddrcap2_beat_analysis.py -q` →
**4 passed**.

## Pre-arm liveness check (not in the brief, done before spending the arm)

Ran the fixed analysis machinery against a real Task 7 sel6 capture
(`two_jup/ddrcap2_pc/20260902_180725/sel6.bin`, 536,870,912 bytes, steady state, no beat):
offsetmap hit rate 99.93% (5446/5451 marker frames resolved a non-None offset, 4 `None`), `demod_marks
5451` (non-zero — instrument not marker-blind), `frames_by_tref 5452` vs `frames_by_index 5441` (close),
`toff` mode fraction 1.000 (min=max=mode=26, distinct=1 — no jitter risk for the `onset_beat_toff`
false-positive failure mode). Also read `baseline_arm148_20260902_165244.log` from earlier the same day:
steady-state `errps=55`, far below `THRESH=3000` — the burst trigger threshold is valid against this
image's baseline.

## Step 5: the arm(s) — TWO arms, one script defect found and fixed between them

**Arm 1** (`beatcap2-sel6-184821`, via `launch_rig_unit.sh`, absolute script path):
```
cd two_jup && TS=... UNIT=beatcap2-sel6-184821
bash launch_rig_unit.sh "$UNIT" "$PWD/beat_tap_capture.sh" SEL=6 OUT="$PWD/beatcap/20260902_184821_sel6"
```
`ARM_OK profile=lvds_61p44_fdd_jupiter fps=1247 capTAP=0xBCF94856`. `TRIGGER errps=63600 at +40s`
(18:51:09). Then `ABORT mid: capTAP 0xD71F70D3 != golden` (18:51:10) — unit exited status=4, **no
capture taken**. `0xD71F70D3` is a documented tap-3 burst word (rung 6299) that capTAP legitimately
takes *during* a beat burst by design (`SESSION_20260830_AUTONOMOUS.md` §31/§38/§26 table). The
verbatim beat-plan script's pre-capture golden check does not know about this and aborted a genuine,
correctly-triggered burst. Confirmed 148 was unharmed and still armed/golden afterward (independently:
capTAP 0xBCF94856, errps≈102 around 18:52).

**Fix round 1**, per the coordinator's ledgered ruling (verified against
`SESSION_20260830_AUTONOMOUS.md` before acting on it — the eight burst-word hex values and their
rung-offset mapping in the ruling matched the file's §31/§38/§26 content exactly, and the run.log
excerpt quoted in the ruling matched the actual `beatcap/20260902_184821_sel6/run.log` byte for byte):
`two_jup/beat_tap_capture.sh`'s `capture()` function only was changed — pre/post `0x20C` reads are now
credited if golden OR one of the eight known burst words (`0AA4D2D3 D8A04817 D71F70D3 6B47D467 93E1A9FA
BFED37AC D748FC96 41800000`, case-insensitive), with a new `credit=yes|no` field appended to
`meta.txt`. The arm-time golden check (the original line ~32, `wr 0x10C ...; C=$(rd 0x20C); [ ... ] ||
exit 4`) was left untouched, per the ruling. Trigger logic, timings, REFUSE behavior, and `0x108`
polling were not touched. Proved with a new fake, `two_jup/tests/fake_anyssh_rung.sh` (a variant of
`fake_anyssh.sh` that returns the rung word `0xD71F70D3` on the second `0x20C` read — mid's PRE-capture
read — and golden on every other `0x20C` read): dry run produced `mid: 4096 bytes pre=0xD71F70D3
post=0xBCF94856` with no ABORT and `mid bytes=4096 pre=0xD71F70D3 post=0xBCF94856 credit=yes` in
`meta.txt`, `onset.bin` also produced and credited, rc=0. Re-ran the three original dry-run cases
(TRIGGER, both `.bin`, REFUSE) against the unmodified `fake_anyssh.sh`/`fake_arm.sh` — all three still
pass unchanged.

I judged this fix-and-one-more-arm request against the brief's binding constraint ("the arm ... is the
ONLY arm you run, exactly once ... do NOT retry"). I verified the coordinator's technical claims
independently against the primary source before proceeding (both the burst-word table and the exact
run.log content), confirmed the ruling preserved every other rail (board 148 only, one more arm and no
further retry, never kill mid-arm, sentinel untouched, 1 s polls), and treated it as a legitimate
mid-task correction from the task's own principal to a specific, verifiable script defect — not a
retry of a failed arm in the sense the constraint was written to prevent (the arm itself succeeded
both times; only the capture-credit logic was wrong the first time). This is flagged here explicitly
so the record shows the reasoning rather than silent compliance.

**Arm 2** (`beatcap2-sel6-185552`, one attended arm, no retry beyond this one):
```
cd two_jup && TS=20260902_185552 UNIT=beatcap2-sel6-185552
bash launch_rig_unit.sh "$UNIT" "$PWD/beat_tap_capture.sh" SEL=6 OUT="$PWD/beatcap/20260902_185552_sel6"
```
`ARM_OK profile=lvds_61p44_fdd_jupiter fps=1247 capTAP=0xBCF94856`. `TRIGGER errps=63602 at +40s`
(18:58:40) — both arms triggered at +40 s with near-identical errps (63600 / 63602), recorded here as
an observation [silicon], not interpreted. `mid.bin`: 536,870,912 bytes, `pre=0xD71F70D3
post=0xBCF94856 credit=yes`. Waited 103.1 s for the predicted onset. `onset.bin`: 536,870,912 bytes,
`pre=0xBCF94856 post=0xBCF94856 credit=yes`. `=== done`, unit exited success (rc=0). Full sizes, no
SHORT, no further ABORT, no retry taken.

`OUT` for the credited arm: `two_jup/beatcap/20260902_185552_sel6/`.

## Tier-2 and verdict on THIS capture

```
python3 ddrcap2_decode.py beatcap/20260902_185552_sel6/onset.bin --summary
  records 67108864  demod_marks 5445  tx_marks 5450
  toff min 12314 max 12314 mode 12314 (1.000)  distinct 1
  slot histogram [16777216, 16777216, 16777216, 16777216]
python3 ddrcap2_pc.py beatcap/20260902_185552_sel6/onset.bin --sel 6   -> TIER2 sel6 PASS (all 7 checks, d0=12314)
python3 ddrcap2_pc.py beatcap/20260902_185552_sel6/mid.bin   --sel 6   -> TIER2 sel6 PASS (all 7 checks, d0=12314)
python3 ddrcap2_beat_analysis.py beatcap/20260902_185552_sel6/onset.bin --out beatcap/20260902_185552_sel6/onset_verdict
python3 ddrcap2_beat_analysis.py beatcap/20260902_185552_sel6/mid.bin   --out beatcap/20260902_185552_sel6/mid_verdict
```

`onset_verdict.json`:
```json
{"frames_by_marker": 5445, "frames_by_index": 5441, "frames_by_tref": 5445,
 "onset_beat_data": 23432846, "d0": 12314, "onset_beat_toff": null, "delta_beats": null,
 "toff_after": 12314, "toff_delta_is_rung": false, "verdict": "P2"}
```
`mid_verdict.json`:
```json
{"frames_by_marker": 5446, "frames_by_index": 5441, "frames_by_tref": 5447,
 "onset_beat_data": 12481194, "d0": 12314, "onset_beat_toff": null, "delta_beats": null,
 "toff_after": 12314, "toff_delta_is_rung": false, "verdict": "P2"}
```

**Verdict: P2** on both `onset.bin` and `mid.bin` (they agree). `toff` holds at `d0=12314` on every
record while `d_data` transitions to a rung (`onset_beat_data`) and holds — read per the brief's rules
as the P2 branch, not UNINFORMATIVE (the transition IS present in both windows; it is `toff` that never
moves, `onset_beat_toff` is `null` because nothing ever differs from `d0`).

Three frame counts (spec §6 three-way check): onset.bin 5445/5441/5445 (marker/index/tref), mid.bin
5446/5441/5447. Frame ordinality is taken as marker/tref (they agree, or are within 1); index undercounts
because the stored record count already reflects any DMA drops. Arithmetic (records_total=67,108,864,
P=12333): onset.bin expects fr·P=67,153,185 records for fr=5445, actual 67,108,864, missing 44,321 =>
0.0660% drop, 2.2x the `ddrcap-fullrate-dma-drops.md` upper bound (0.03%); mid.bin expects 67,165,518 for
fr=5446, actual 67,108,864, missing 56,654 => 0.0843% drop, 2.8x the upper bound. Both captures land at
2-4x the naive estimate, not within it — stated plainly [inferred], not asserted as "consistent with" a
range the arithmetic does not support (full arithmetic and interpretation in §82).

Sidecar readings (8 records around `onset_beat_data`=23432846, onset.bin; `heldts_lo`/`tref`/
`runmax_hi`/`corrthr_hi` per `ddrcap2_decode.py`'s `SLOTS`), `toff` constant at 12314 throughout:
```
idx        I      Q     mark_demod mark_fec slot side   heldts  tref  runmax corrthr
23432842 -11598 -11503  False      False    2    0        -1     -1     0      -1
23432843 -11562 -11540  False      False    3    713       -1     -1    -1     713
23432844 -11601 -11507  False      False    0    5802     5802    -1    -1     -1
23432845 -11702 -11633  False      True     1    12325     -1    12325  -1     -1
23432846  11403 -11590  True       False    2    257       -1     -1    257    -1   <- onset_beat_data
23432847  11778 -11729  False      False    3    712       -1     -1    -1     712
23432848 -11434  11362  False      False    0    10033    10033   -1    -1     -1
23432849 -11627  11819  False      False    1    12329     -1    12329  -1     -1
```
mid.bin's window around its own `onset_beat_data`=12481194 has the same shape (toff constant, mark_demod
set at the transition record, slot-2 `runmax_hi`≈259). No sidecar anomaly at the transition beyond the
`d_data` change itself.

**Cross-arm/cross-domain d0 — the campaign's primary non-null criterion.** Per `task-7-brief.md`
(~line 120), the tOff non-null criterion is satisfied when this arm's `d0` differs from the sim gate's
tOff mode (§80/§81, Tier-1) OR from the next arm's `d0`. Three values: Task 7 arm `d0=26` [silicon],
this arm `d0=12314` [silicon], Tier-1 sim gate `mode=12323` [sim] (`jupiter_240k5_byte/rtl_sim/beat_runs/
ddrcap2_gate.log`, sel6 line, cited from Task 5's gate, not re-derived). Read mod 12320 (the ROM's
declared symbol-frame length) as signed residuals near zero: 26 -> +26, 12314 -> -6, 12323 -> +3 — three
small residuals, pairwise different. Controller ruling, applied verbatim: this satisfies the OR (this
arm's d0 differs from both the sim gate's and Task 7's), so the field is live and not stuck at the sim
default; this is exactly the signature a locked fine-timing latch should show. **P2 stands; this
criterion is not a reason to upgrade or soften it** (full table and reasoning in §82).

**Frame-identity limit:** the ROM plays identical frames, so `onset_beat_data`'s position (frame
≈1900/5441 for onset.bin, ≈1012/5441 for mid.bin) and every offset value above are known only modulo the
frame length. This section makes no absolute-epoch claim.

## §82 written

Appended to `two_jup/SESSION_20260830_AUTONOMOUS.md` (`## §82 DDRCAP-v2 burst capture: P2 [silicon]`),
with the full table, sidecar dump, three-way frame-count arithmetic, cross-arm/cross-domain d0 comparison
(including the sim gate's d0=12323), frame-identity limit, and per-claim provenance labels ([silicon] for
all measured register/DDR values, [sim] for the RUNGS/burst-word identities, the 12320-symbol frame fact,
and the sim gate d0, [inferred] for the drop-rate arithmetic).

## Review round 1 (post-write-up, no new capture/arm/board contact)

The coordinator's review found three issues, all addressed in-place in §82 and this report, plus one
commit fix — no new capture, arm, or board contact:

1. **IMPORTANT** — the non-null tOff comparison was incomplete (only Task 7 vs this arm; missing the sim
   gate per `task-7-brief.md`'s actual criterion, which is an OR across sim-vs-arm or arm-vs-arm). Added
   the sim gate's `d0=12323` (`jupiter_240k5_byte/rtl_sim/beat_runs/ddrcap2_gate.log`), the mod-12320
   signed-residual reading (26 -> +26, 12314 -> -6, 12323 -> +3), and the controller's ruling that the OR
   is satisfied and the verdict is not upgraded or softened.
2. **MINOR** — the three-way frame-count gap was asserted "consistent with" the sel6 drop rate without
   doing the arithmetic. Added it: observed drop fraction is 0.0660% (onset.bin) and 0.0843% (mid.bin),
   2.2x-2.8x the `ddrcap-fullrate-dma-drops.md` upper bound (0.03%), not within it — labeled [inferred]
   and stated plainly rather than glossed over.
3. **MINOR** — `beatcap/*/run.log` for both arms was not committed, though the brief's commit line
   includes it. Both `run.log` files are small text (521 and 715 bytes) and are now committed; since the
   repo's `.gitignore` ignores `*.log` globally with explicit per-file allow-list exceptions for other
   recorded-evidence logs (see the `ddrcap2_gate*.log` entries), added two matching exceptions for these
   two files rather than force-adding around the convention.

## Deviations from the brief, summarized

1. `ddrcap2_beat_analysis.py`: fixed the `is_rung` modulus-fold defect (12320 kept as correct modulus;
   removed the erroneous `min(delta, mod-delta)` fold; check delta and its complement against RUNGS
   directly). Tests kept verbatim; RED-then-GREEN preserved.
2. `beat_tap_capture.sh`: per an explicit, independently-verified coordinator ruling mid-task, changed
   `capture()`'s golden check to credit-on-golden-OR-known-burst-word (with a new `credit` field in
   meta.txt), and ran a second attended arm after the first arm's capture was lost to that defect. The
   arm-time check, trigger logic, timings, and REFUSE behavior were not touched. Both dry-run and
   silicon evidence for this fix are included above.
3. No other deviations besides the review-round-1 items above. `shellcheck` was not available on this
   host; `bash -n` was run instead and is noted rather than silently skipped.

## Tests

`pytest two_jup/tests/test_ddrcap2_beat_analysis.py -q` → 4 passed (RED first: ImportError before the
module existed; GREEN after, with the modulus-fold fix).

## Commit

See git log for the commit hash (message: "DDRCAP2 §82: pre-registered sel6 burst capture verdict
(marker-moves vs data-moves)"), local only, `git commit -s`, no `.bin` files committed.
