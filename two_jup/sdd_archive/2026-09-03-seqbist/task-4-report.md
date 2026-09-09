# Task 4 (T0d) report -- SEQ-BIST host tools

Deliverables, all under `two_jup/seqbist/`:
- `seqbist_read.py` -- one ssh round-trip per sample: freeze (tgen_rx ctrl bit3),
  read modem 0x104/0x124, read all 32 cnt_mux32 slots via 0x9D410008 select
  (bits[31:27], preserving [26:0]) + 0x9D450008 readout, unfreeze/restore. Prints
  one JSON line with named fields + ts_wall/ts_mono. `--watch S` (S>=5) repeats;
  `--dry` fabricates with zero ssh contact.
- `seqbist_run.sh` -- K=V env (BOARD, MODE=loopback|rf, FILL>=100 refused
  otherwise, GAP, SKIP_EVERY/CORRUPT_EVERY mutually exclusive, DUR, DRY=1
  default). Sequence: snapshot -> checker clear -> TGEN on -> seqbist_read
  --watch 10 for DUR -> TGEN off -> final read -> post snapshot -> meta.txt +
  readings.jsonl + run.log under `two_jup/comb/runs/<ts>_seqbist[_<tag>]/`.
  Exits non-zero on window < WINDOW_MIN (default 150s per spec) or an
  in-window re-arm; prints `SEQBIST_DONE <dir>` last.
- `seqbist_score.py <run dir>` -- loss/garbage/crc_fail %, per-10s time series,
  interval histogram -> period estimate (int_32/int_33 only, contamination_pct
  from int_other/int_hist_lt30 reported separately), positive-control verdict
  (frames/N +/- 2), 0x104/0x124/chk_frames agreement, UNINFORMATIVE checklist,
  and a CLEAN/LOSSY verdict for control-free runs against the T2 PREREG
  (lost_slots=garbage=crc_fail=0).
- `two_jup/tests/test_seqbist_tools.py` -- 13 tests, DRY only, PATH-shim proves
  zero ssh/scp contact throughout. Covers: JSON schema, --watch >=5s guard,
  FILL<100 refusal, SKIP_EVERY+CORRUPT_EVERY-both-set refusal, TGEN register
  bitfield encoding for both modes, short-window UNINFORMATIVE exit, and
  seqbist_score.py against synthetic readings (skip_every=50 -> PASS,
  int_32:int_33=57:43 -> period_est ~=32.43).

## Bug caught by advisor review (fixed before commit)
First draft of `tgen_on()` put SKIP_EVERY/CORRUPT_EVERY into the *gap* register
and left ctrl's [31:16] empty -- inverted vs. the interface contract (`ctrl
[31:16]=N`, `gap bit27`=mode select). On silicon this would have meant N=0 (no
injection) and a ~3.3M-clock gap (~0.04 f/s, reading as a dead link) instead of
line rate with periodic loss. Fixed to `ctrl=(N<<16)|(FILL<<4)|1`,
`gap=(GAP&0x7FFFFFF)|(mode<<27)`; added a `TGEN_WORDS` log line and bitfield
tests so this class of bug is caught by DRY tests going forward.

Also tightened per advisor: positive-control tolerance to frames/N +/- 2 (was
a loose 5%), excluded int_other/int_hist_lt30 from the period estimate
(reported as contamination_pct instead of blended in), added a CLEAN/LOSSY
verdict for control-free runs, flagged negative cumulative-counter deltas
(mid-window clear/re-arm) as an UNINFORMATIVE reason instead of masking them,
and added `rate_fps=`/`image_md5=` to meta.txt for the dashboard legs table.

## Verification
`python3 -m pytest two_jup/tests/test_seqbist_tools.py -q` -> 13 passed.
No board contact anywhere in this task (DRY only, per instructions).

## Fix round 2 (Task 1/2 follow-ups + coordinator addenda)
1. ORDER: TGEN restarts its own seq at 1 on enable rise; `checker_clear()` now
   runs AFTER `tgen_on` + a 50ms settle (was: clear before TGEN on), which was
   producing a spurious dup_or_reorder=1 on the first reading. DRY log and
   tests updated to assert the new order.
2. LINEAGE: `check_tgen_rx_disabled()` preflight added to `seqbist_run.sh` --
   refuses (exit 5) if tgen_rx enable (0x9D410000 bit0) is set, since its
   ctrl[5:4] then aliases qpsk_traffic_gen_rx2's fill_len[1:0] and corrupts the
   freeze/checker-enable bits this tool relies on. `seqbist_score.py` never
   used legacy slots 0-15 for pass/fail; documented explicitly and reported as
   `legacy_slots_0_15_all_zero` (informational).
3. INTERVAL UNITS: docstring/output states int_* counters are emitted-frame
   (seq-delta) units; no received->emitted correction exists or is applied.
   Documented `frames != good+garbage+crc_fail`. CORRUPT_EVERY positive
   control now requires BOTH `garbage = floor(frames/M) +/- 2` AND
   `gap_events = garbage +/- 2` (one gap1 per corrupted frame).
4. Interval-peak expectation (Task 1 fix 53f5eff): SKIP_EVERY=N -> expected
   peak N+1 (skipped slot adds one to the seq-delta); CORRUPT_EVERY=M ->
   expected peak M. Checked against the int_32/int_33 bins when the peak lands
   on 32 or 33; folded into `positive_control.pass`.
5. RMW CONTRACT: verified/documented that every write to tgen_rx ctrl
   (0x9D410000) -- freeze in `seqbist_read.py`, checker-clear pulse and
   freeze-clear in `seqbist_run.sh` -- is read-modify-write, preserving bit0
   (tgen_rx enable, must stay 0) and bit5 (tgen_mode); a plain constant write
   would silently zero every counter mid-run. DRY log for `checker_clear`
   walks a concrete RMW example so the preserved bits are visible/testable.
6. int_other is bimodal under seq-delta units (30/31 tail AND >=34 tail), so
   it is no longer used as a flatness/noise signal. Added
   `interval_last_series` (raw `chk_int_last`, one point sample per 10s
   freeze) as the primary interval/flatness signal; the int_32/33/other/lt30
   histogram is now documented as a coarse cross-check only.
7. BOARD=146 UNINFORMATIVE-checklist note: slots 0-15 have no
   short_frm/truncation witness on that image; reported as an informational
   `notes` entry (does not flip the verdict).
8. TX-side witness guard: if a future `seqbist_read.py` adds
   `tx_frames_checked` (tx_seam_checker, txchk_gpio @0x9D420000 -- not read
   today), `seqbist_score.py` will NOT compare it to RX `chk_frames` under
   CORRUPT_EVERY (tx_seam_checker arms only on a good magic and undercounts by
   floor(frames/M) by construction); compared only for clean/SKIP_EVERY runs,
   +/- 2.

Tests: two_jup/tests/test_seqbist_tools.py grew from 13 to 31, all DRY-only,
zero ssh/scp contact (PATH shim + a register-model fake `$W` for the
tgen_rx-enabled-refusal test). `python3 -m pytest
two_jup/tests/test_seqbist_tools.py -q` -> 31 passed.
