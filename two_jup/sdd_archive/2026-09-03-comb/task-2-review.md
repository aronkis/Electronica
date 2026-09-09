# Task 2 (T0b) analysis tooling — review

**Verdict: Needs fixes** (two Important spec gaps; no Critical defects; the
delivered numbers that exist are reproducible and correct).

Scope: `git diff d69d3e9..dc6d7e8 -- two_jup/comb two_jup/tests` (b66f068 code,
dc6d7e8 report), against the T0b bullet and the P1/P2 corrections of
`/home/tcollins/.claude/plans/happy-bubbling-owl.md`. Read-only, CPU only, no
board contact.

## Independent verification performed

* `python3 -m pytest two_jup/tests/test_comb_tools.py -q` → **14 passed**
  (2.3 s). Period-32 recovery, iid-noise null, and the never-sent join case are
  all really asserted (`test_comb_tools.py:90,106,201`).
* Re-ran `comb_autocorr.py` on `two_jup/r3cap/ballpark_fwd_after_20260903_151147/frames.bin`
  and `accept_analyze.py` on the same file. SINGLES-ONLY `lag33=+0.2040` vs
  accept_analyze `lag33=0.204`; `run_bins` identical
  (`1:36811, 2:15392, 3-4:453, 5-20:173, 21-100:3, >100:0`); live window
  722 s/723 s in both. **The report's exact-reproduction claim holds.**
* Layouts cross-checked byte-for-byte against the C, not just the README:
  `frame_rec` 48 B / `fail_class` at offset 44 (`host_app_k5/qpsk_join.h:155-167`,
  `_Static_assert` at :167) vs `frame_taxonomy.DTYPE`; `failhdr_rec`
  `<QIIBBH12s` = 32 B (:175-184) vs `joinlog.py:22-27`; `txlog_rec` `<QQIIIHH`
  = 32 B (:195-204) vs `joinlog.py:29-33`; `qpsk_log_hdr` `<8sIIQII` = 32 B and
  the `QFAILH01`/`QTXLOG02` magics (:211-222) vs `joinlog.py:15-20`. **All
  match.**
* Lag-units verdict re-derived independently: `accept_analyze.py:81-97,108-109`
  builds `pres` indexed by `host_seq - cw[0]` over crc_ok frames ⇒ lag is in
  **transmitted-frame slots**; `frame_taxonomy.py:118-131` autocorrelates over
  record index ⇒ a different axis; `grep -n lag two_jup/analyze_comb_census.py`
  → no lag concept (only a comment hit at :10). **`comb_lagcheck.md`'s verdict
  is correct as written.**

## Findings

### Important

1. **`two_jup/comb/comb_census.py:190-202` — failhdr records are never
   time-windowed.** `fail_class_census()` is clipped to `[SETTLE_S, live_end)`
   (`:175`), but `fh_arr` goes straight into `onset_histogram()` and
   `class4_split()` un-windowed; `grep t_mono_ns comb_census.py` shows
   `fh_arr["t_mono_ns"]` is never read, even though `failhdr_rec.t_mono_ns` is
   documented as the same clock as `frame_rec` (`qpsk_join.h:176`). The settle
   ramp and any post-`live_end` wedge tail are exactly where unfilled carve
   slots occur, and those land in class 4 with `first_zero_off == 0` — i.e. the
   contamination lands directly on the delivery-hole-vs-ALIGNLOSS split the
   Task-1 review demanded. Latent today (no real `failhdr.bin` exists), live at
   T1/T3. Fix: apply the same `[SETTLE_S, live_end)` mask to `fh_arr` and report
   both the windowed and raw counts.

2. **`two_jup/comb/comb_census.py:142` — `decoded_not_delivered` is a
   placeholder string, not a computed class.** The T0b brief requires the
   three-way join. The counterpart exists on the C side:
   `qpsk_join.h:249-252` declares
   `qpsk_join_classify(..., const uint32_t *delivered, size_t n_delivered)`, so
   Task 1 designed a delivered set into the ABI; `comb_census.py` simply never
   plumbs a `--delivered` argument (`grep -n delivered two_jup/comb/*.py` hits
   only the placeholder and its print at `:214`). Fix: add `--delivered` and
   classify `seq ∈ txlog ∧ seq ∈ frames.bin(crc_ok) ∧ seq ∉ delivered` as
   DECODED_NOT_DELIVERED; keep the current string only when the option is
   absent.

3. **Axis mislabelling (doc defect over a correct implementation):**
   `comb_autocorr.py:4-7` and `common.py:93-94` describe the analysis axis as
   "record position (reconstructed slot)", while `comb_lagcheck.md` (same
   commit) correctly defines *record position* as `frame_taxonomy.py`'s
   file-order axis and the accept_analyze axis as host_seq slots. The
   implementation is right — the axis is built from crc_ok frames' host_seq
   only (`common.py:112-132`), so garbage seqs from magic-bad frames never
   enter, which is what the P1 correction actually wanted, and it is the axis
   required to reproduce accept_analyze. But a T3 consumer reading the docstring
   will believe it is the record axis. Fix: rename to "reconstructed TX-slot
   (host_seq) axis" in both docstrings and state explicitly that it is *not*
   `frame_taxonomy`'s record axis.

4. **`task-2-report.md` top-lag table drops a peak larger than the one it
   quotes.** For `ballpark_fwd_after` the table lists "97 (+0.712), 32 (+0.576)"
   but the actual ALL-LOSS top-8 (reproduced by me and present in
   `baseline_20260903/autocorr_fwd_after.json`) is
   `97:+0.7118, 65:+0.6696, 32:+0.5755, 33:+0.4162`. Omitting 65 understates a
   real structural observation: `fwd` and `rev2` show clean harmonics
   (32/64/96/127-128) while `fwd_after` shows 32k+1 (33/65/97). That ±1 slip
   bears directly on T2's PREREG "comb lag follows 148's own -M" and should be
   in the report as an observation (not a theory). Fix: quote the full top-8 in
   the table or add the harmonic-structure row.

### Minor

5. **`two_jup/comb/common.py:134-139` — stale comment.** It states an
   out-of-sanity-cap good-good delta is "*not* folded into the loss trains as
   ordinary loss"; the code does fold it in, since `all_loss = 1 - pres`
   (`:143`) and `lo_`/`hi_` are unclamped first/last seqs. Empirically harmless
   on this data: on `ballpark_fwd` all 26 anomalous deltas are `d <= 0`
   (duplicate/out-of-order) and `max(delta) = 1278 << SANITY_CAP`, so `all_loss`
   is unaffected and `validity_frac = 0.99997`. Fix the comment (or enforce the
   cap), not the numbers.

6. **Permutation null is a sampling floor, not a burst-structure null**
   (`common.py:204-218`). Shuffling destroys run structure, so with 15,392
   doubles any burstiness clears ≈0.0038. The tool is spec-compliant (the brief
   said "permutation null"), but the report's "clears it by more than an order
   of magnitude, so lag-32 dominant is not a null-threshold artefact" leans
   harder than the test supports; the ALL-LOSS vs SINGLES gap (0.70 vs
   0.53–0.63) is what run contamination predicts. Soften the claim or add a
   block-permutation null.

7. **`comb_phase.py:98-104` chi-square p-values are anti-conservative** for the
   same reason (lost slots inside a run are not independent draws). Exposure
   weighting (`:96-97`) is correct; the independence assumption is not. Worth a
   caveat line in the printed output.

8. **`comb_census.py:45-54` never cross-tabs `fail_class` against `crc_ok`**, so
   it cannot surface the `crc_ok==0 ∧ fail_class==0` inconsistency
   `README_hostlog.md` §2 warns about in `-B` mode. One extra row would make the
   census self-checking.

9. **Join integration untested end-to-end.** `test_comb_tools.py:194-198` builds
   `_lt_fixture()` dicts by hand rather than feeding a real
   `loss_slot_trains()` output into `tx_rx_join()`, so a key/dtype drift between
   the two would pass CI. Add one test that runs the real pipeline on a
   synthetic `frames.bin` + `txlog.bin` pair.

10. **Cross-board clock caveat is documented but not enforced at runtime**
    (`comb_census.py:110-117`). The report's Concerns section discloses it
    honestly; the tool should also print a "UNJOINABLE count is a coverage
    sanity check only (cross-board CLOCK_MONOTONIC)" banner whenever `--txlog`
    is used, so a T3 reader of the JSON cannot miss it.

## What is solid

Dump-completeness check (`joinlog.py:41-71`, size == 32 + 32×n, magic and
`rec_bytes` both validated, `wrapped` kept separate and non-fatal) is exactly as
specified and tested (`test_read_failhdr_rejects_truncated_dump`). ARQ "any
record = sent" (`comb_census.py:123`) and the `t_submit_ns` span clip
(`:132-133`) implement the Task-1-review rules correctly and are tested.
`fft_autocorr` (`common.py:184-201`) zero-pads to a power of two ≥ 4n, so no
circular wrap for lags < n, and matches `np.correlate` — verified both by the
unit test and by the exact lag33 match on real data. `class4_split`
(`:57-78`) splits on `first_zero_off == 0` vs `> 0` and never uses `magic_off`
as a discriminator, as required. The degenerate-capture flag
(`:53`) correctly refuses to report a pre-instrumentation capture as "all OK".

## Recommended gate

Fixes 1 and 2 before T1/T3 consume the tools (both are on paths no existing
capture exercises, so they will silently produce wrong or absent answers on
first real use). Fixes 3 and 4 are documentation/report edits and can land in
the same commit. 5–10 are follow-ups.
