# Task 2 (T0b) — analysis tooling — report

Plan: `/home/tcollins/.claude/plans/happy-bubbling-owl.md` §T0b.
Status: **complete, desk-only, zero board contact.**

## Commits

* `b66f068` — COMB Task 2 (T0b): FFT autocorrelation, comb-phase, and
  fail-class census tooling (`two_jup/comb/{__init__.py,common.py,
  comb_autocorr.py,comb_phase.py,comb_census.py,joinlog.py,comb_lagcheck.md,
  baseline_20260903/*.json}`, `two_jup/tests/test_comb_tools.py`).
* `dc6d7e8` — Task 2 report (original).
* (this fix-round-1 commit) — addresses `task-2-review.md`'s two Important
  findings (failhdr time-windowing, `decoded_not_delivered`) plus the report
  table gap and axis-docstring mislabelling, and the listed Minor items; see
  "Fix round 1" below.

## Tests

19 tests in `two_jup/tests/test_comb_tools.py`, all pass
(`python3 -m pytest two_jup/tests/test_comb_tools.py -q` → `19 passed`):
FFT-vs-direct autocorrelation equivalence; synthetic period-32 loss train
recovered as the top lag with the permutation null respected; an iid noise
train not flagged; comb-phase histogram uniformity (fixed-phase
non-uniform, random uniform); fail-class census on synthetic `frames.bin`
(including the degenerate-pre-instrumentation-capture flag); TX↔RX join
(never-sent / sent-not-decoded / delivered-excluded, ARQ-resend "any record
= sent", t_submit_ns span clipping to UNJOINABLE); the class-4
delivery-hole-vs-alignloss split; dump-completeness rejection of a truncated
QFAILH01 file; QFAILH01/QTXLOG02 round-trips; **new in fix round 1:**
failhdr time-window exclusion (`test_failhdr_window_excludes_out_of_window_records`),
`decoded_not_delivered` with and without `--delivered`
(`test_join_classifies_decoded_not_delivered_with_delivered_set`,
`test_join_decoded_not_delivered_stays_unclassified_without_delivered_arg`),
`read_delivered_seqs` round-trip, and an end-to-end join test that feeds a
REAL `loss_slot_trains()` output into `tx_rx_join()` rather than a hand-built
fixture dict (`test_join_end_to_end_real_loss_slot_trains_pipeline`).

## Top-lag table (three usable `two_jup/r3cap/ballpark_*` captures)

`rev` (`ballpark_rev_20260903_141328`) is UNUSABLE/WEDGED under both
`accept_analyze.py` and `comb_autocorr.py` (0 s live window) — excluded, as
it is from `accept_analyze.py`'s own output.

| capture | accept_analyze lag33 (singles) | comb_autocorr SINGLES-ONLY lag33 | comb_autocorr ALL-LOSS lag33 | top-5 lags (ALL-LOSS) |
|---|---|---|---|---|
| `ballpark_fwd_20260903_141328` | -0.035 | **-0.0350** | +0.2817 | 32 (+0.698), 64 (+0.595), 127 (+0.534), 95 (+0.508), 96 (+0.502) |
| `ballpark_fwd_after_20260903_151147` | 0.204 | **+0.2040** | +0.4162 | 97 (+0.712), **65 (+0.670)**, 32 (+0.576), 33 (+0.416), 8 (+0.336) |
| `ballpark_rev2_20260903_143523` | 0.018 | **+0.0180** | +0.1633 | 32 (+0.699), 64 (+0.653), 96 (+0.606), 128 (+0.553), 97 (+0.235) |

The SINGLES-ONLY variant reproduces `accept_analyze.py`'s printed `lag33=`
values exactly (to the printed 3 decimals) on all three — this is the
variant that matches, because it is the identical construction
(host_seq-indexed, isolated-run-length-1 losses only; see
`two_jup/comb/common.py:loss_slot_trains`). The ALL-LOSS variant (every lost
slot, any run length) is a different, generally noisier signal and does NOT
match `accept_analyze.py` (it isn't supposed to — `accept_analyze.py` never
computes it). Full top-8/null tables (and the harmonic-family annotation
added below) are in `two_jup/comb/baseline_20260903/autocorr_*.json`.

**Harmonic structure, stated plainly (review finding 4) — a ±1 slip, not a
different period.** `fwd` and `rev2` peak exactly on multiples of 32
(32/64/96/127-128, slip 0 against `k×32`). `fwd_after` peaks one slot off
that grid, at 33/65/97 — i.e. `k×32 + 1` for k=1,2,3 (slip 0 against
`k×32+1`, NOT against `k×33`: `2×33=66≠65`, `3×33=99≠97`). This is an
observation, not a theory: it means `fwd_after`'s comb is phase-slipping by
exactly one slot relative to `fwd`/`rev2`'s, not running at a different
period. `comb_autocorr.py` now prints this harmonic-family annotation
(nearest `k×32` and `k×33`, signed slip) for its top-5 lags on every run, so
this is not a one-off manual observation. Bearing on T2's PREREG ("comb lag
follows 148's own -M"): a period that stays 32 but slips phase by ±1 between
runs is also consistent with an off-by-one in which -M boundary carries the
back-pressure event, not necessarily a different mechanism — worth checking
against `-M 8` vs `-M 16` explicitly in T2 rather than assuming period
alone settles it.

Permutation null (200 shuffles, 95th percentile of max over lags 1–128) was
≈0.0037–0.0039 on all three captures/variants, and every reported top-5 lag
clears it by roughly an order of magnitude — but this null is a **sampling
floor, not a burst-structure null** (review finding 6): shuffling destroys
run structure, so with thousands of doubles/triples in these captures, any
burstiness alone would already clear ≈0.004 regardless of periodicity. The
weaker, supportable claim is: the ALL-LOSS lag-32(+1) peaks are not sampling
noise, but part of their height reflects burst/run contamination rather
than periodicity alone — the SINGLES-ONLY values (isolated losses only, no
run contamination) are the more trustworthy periodicity signal, and they
are smaller (0.40–0.63) but still clear the null by an order of magnitude
on the same lags. A block-permutation null (preserving run structure) would
tighten this further and is a natural T1/T2 follow-up, not done here.

## Lag-units verdict (`comb_lagcheck.md`)

* `accept_analyze.py` (accept_analyze.py:81,86,96-97,108-109): lag is in
  **transmitted-frame slots** — the array index is `host_seq - host_seq[0]`
  over CLEAN frames only, so "lag 33" = 33 TX-frame sequence numbers.
* `frame_taxonomy.py` (:118-132): lag is in **logged-record position** — the
  array index is the physical position of a record (good or bad) in
  `frames.bin`. Close to the TX-slot axis when reception is near 100 % but
  not identical (it has no entry at all for frames never logged).
* `analyze_comb_census.py`: **no lag concept exists in this file** —
  `grep -n lag two_jup/analyze_comb_census.py` returns nothing; it computes a
  register-delta bit-error census, not an autocorrelation. Any historical
  "lag-N per `analyze_comb_census.py`" claim does not trace to code in this
  file.
* So "lag 32" in the E3 facts = **32 transmitted-frame slots**, not 32
  records and not 32 loss-events (no tool implements a loss-event-indexed
  lag).
* RXQ=1 two-request-slot "heavy boundary" question: **[inferred, grep-level
  only]** — current code (post-Task-1-edit line numbers cited in
  `comb_lagcheck.md`) shows both RX areas run the identical
  carve_zero/submit sequence on every completion; nothing in the state
  machine alone shows an every-other-boundary asymmetry. Not confirmed or
  ruled out — no witness/measurement taken.

## Task-1-review corrections addressed

1. **Class-4 split**: `comb_census.py:class4_split()` splits `fail_class==4`
   records (from `--failhdr`) on `first_zero_off==0` (all-zero carve slice =
   delivery-plane hole; lands in class 1 instead under `rxq_zerohdr`) vs `>0`
   (real TX ALIGNLOSS). Reported alongside the plain census, never collapsed.
   Test: `test_class4_split_delivery_hole_vs_alignloss`.
2. **`magic_off` not used as a shift discriminator** — `comb_census.py`
   never reads `magic_off` for classification; it is carried informationally
   in `FAILHDR_DTYPE` only.
3. **ARQ resends**: `tx_rx_join()` treats "sent" as membership in
   `set(tx_arr['seq'])`, so any number of resend records for one seq collapse
   correctly to "sent". Test: `test_join_treats_arq_resend_as_sent_any_record`.
4. **Join clipped to the TX log's `t_submit_ns` span**: a lost RX frame
   outside `[tx_arr.t_submit_ns.min(), .max()]` is reported UNJOINABLE, not
   NEVER_SENT; its time is estimated by `common.py:interp_t_mono_ns()`
   (linear interpolation against the surrounding clean frames' host_seq/
   t_mono_ns). Test: `test_join_clips_to_txlog_t_submit_span_as_unjoinable`.
   Dump completeness: `joinlog.py:_read_hdr_records()` now checks file size
   against `header.n_records * rec_bytes + 32` and raises on mismatch before
   any census/join can silently run on a truncated file. Test:
   `test_read_failhdr_rejects_truncated_dump`.
5. **±10 % `first_zero_off` tolerance**: documented in `class4_split()`'s
   docstring — irrelevant to the exact `==0`/`>0` split used there, material
   for any future cross-tap onset matching (T3/T4), which this tool does not
   attempt.

## Fix round 1 (`task-2-review.md`)

Verdict was **Needs fixes** (two Important findings, no Critical defects).
All addressed:

* **Important 1 — failhdr never time-windowed**: `comb_census.py` now has
  `failhdr_window_mask()`, applying the identical `[SETTLE_S, live_end)`
  window (via `failhdr_rec.t_mono_ns`, same clock as `frame_rec.t_mono_ns`,
  `qpsk_join.h:176`) to `fh_arr` before `onset_histogram()`/`class4_split()`
  run. Both raw (`n_raw`) and windowed (`n_windowed`) record counts are kept
  in the JSON output so a reader can see how much was clipped. Test:
  `test_failhdr_window_excludes_out_of_window_records` (asserts an
  out-of-window fzo==0 record is excluded from the delivery-hole count).
* **Important 2 — `decoded_not_delivered` was a placeholder**: added
  `--delivered` (raw `<u4` seq array; `joinlog.read_delivered_seqs`, format
  documented there since no on-disk ABI exists for it yet — see Concerns).
  `tx_rx_join()` now classifies a decoded seq (`lt['cw']`) absent from the
  delivered set as `DECODED_NOT_DELIVERED`; absent `--delivered`, the class
  stays the UNCLASSIFIED string exactly as `qpsk_join.h:239-241` specifies
  ("state that... rather than silently calling the class absent"). Tests:
  `test_join_classifies_decoded_not_delivered_with_delivered_set`,
  `test_join_decoded_not_delivered_stays_unclassified_without_delivered_arg`.
* **Finding 3 — axis mislabelling**: `comb_autocorr.py`'s module docstring
  and `common.py:loss_slot_trains()`'s docstring now say "reconstructed
  TX-slot (host_seq) axis" explicitly and state it is NOT
  `frame_taxonomy.py`'s record-position axis, matching `comb_lagcheck.md`.
* **Finding 4 — report table dropped a larger peak**: fixed above (lag 65
  added to the `fwd_after` row; the ±1-slip harmonic-family observation
  stated plainly). `comb_autocorr.py` now prints a top-5-with-harmonic-family
  block (nearest `k×32` and `k×33`, signed slip) for every run/variant
  rather than a bare top-8 list, so this is reproducible per-run, not a
  one-off report edit.
* **Minors** (5–10, all addressed): common.py's stale sanity-cap comment
  fixed (finding 5) to state the anomalous-delta case IS folded into
  `all_loss` today (diagnostic only, not enforced) rather than claiming it
  is excluded; report language on the permutation null softened to the
  sampling-floor claim (finding 6, see Top-lag table section and Concerns);
  `comb_phase.py` prints an anti-conservative-p-value caveat at runtime
  (finding 7); `fail_class_crc_ok_crosstab()` added and printed when
  non-zero (finding 8); the end-to-end join test (finding 9); and
  `comb_census.py --txlog` prints the cross-board-clock `[CAVEAT]` banner at
  runtime (finding 10).

## Concerns

* **Cross-board clock caveat on the t_submit_ns join clip**: `t_mono_ns` /
  `t_submit_ns` are `CLOCK_MONOTONIC`, per-machine. The clip is exactly
  correct for a same-host capture (e.g. T1's loopback floor); on a real
  forward/reverse leg (TX board ≠ RX board) the two are different clocks and
  the UNJOINABLE count from this clip should be read as a coverage sanity
  check, not a hard cross-board time comparison. `tx_rx_join()`'s docstring
  states this, and as of fix round 1 `comb_census.py --txlog` now also
  prints a runtime `[CAVEAT]` banner every time (minor 10 — "cannot miss
  it" even from a bare stdout log, not just the docstring/report); no
  cross-board captures with both a txlog and frames.bin exist yet to test it
  against real data (T3 will produce the first one). Task 1's README states
  the same t_submit_ns-based rule without flagging this caveat — worth
  confirming with Task 1/T3 before trusting UNJOINABLE counts on a T3
  forward-leg join.
* **No real failhdr.bin/txlog.bin fixtures yet**: the three baseline
  captures in `two_jup/comb/baseline_20260903/` predate the Task-1
  instrumentation (fail_class reads 0 throughout, correctly flagged
  DEGENERATE by `comb_census.py`). `comb_census.py --failhdr/--txlog`,
  `class4_split()`, and `tx_rx_join()` are exercised only by synthetic
  fixtures in the test suite, not yet against a real instrumented capture —
  first real exercise will be T1/T3.
* `comb_autocorr.py` is O(n log n) per run but the 200-shuffle permutation
  null still costs ~90 s/variant on an ~880k-record capture (~9 min for all
  three captures × 2 variants); fine for T0b's one-off baseline, worth
  knowing if it's invoked per-window in a later task.
* **`--delivered` file format is Task 2's own invention** (documented in
  `joinlog.read_delivered_seqs`: a headerless raw little-endian `uint32`
  array), because `qpsk_join.h:239-241` declares the in-memory
  `delivered`/`n_delivered` C signature but no on-disk producer or ABI
  exists yet (no tun/qpsk_perf delivery log). If Task 1/a later task defines
  an actual on-disk delivery log, this reader (and its one-line format
  choice) needs reconciling against it, not assumed compatible.
* **Permutation null is a sampling floor, not a burst-structure null**
  (review finding 6, addressed in the report text above, not in code — the
  brief specified a permutation null and the tool matches that spec). A
  block-permutation null (shuffling whole runs, not individual slots) would
  give a tighter, burst-aware significance bound and is a reasonable
  follow-up if T1/T2 need to distinguish "periodic" from "just bursty."
* **Chi-square p-values in `comb_phase.py` are anti-conservative** for the
  same non-independence reason (review finding 7); `comb_phase.py` now
  prints a `[CAVEAT]` line saying so at runtime, but the underlying
  statistic is unchanged — treat its p-values as a screening signal.
