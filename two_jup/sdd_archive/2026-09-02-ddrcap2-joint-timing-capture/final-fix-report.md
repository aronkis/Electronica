# Final-fix round report

**Status:** all brief items (A-D) done; item E done except one deferred sub-item. No board contact, no arm.

**Commit hashes** (branch `per-under-1pct-2026-07`):
- `e82e6d4` -- ddrcap2_beat_analysis: measure sel6 demod-marker period instead of hardcoding P=12333 (item A; also drops unused `offs`, item E)
- `d9a4a01` -- task9_sel15_detector: drop unused `pair_baseline` import and redundant local re-import (item E)
- `0c4054a` -- task9_run.py: committed driver reproducing every committed sel13/14/15 analysis JSON (item D)
- `2419734` -- ddrcap2_txmark_scan.py: independent re-derivation of the TX-marker coincidence finding (item B4)
- `64d24e9` -- addenda: §82 frame-period/None-episode/tOff-modulus/TX-marker writeup, §83/§84 mover-language correction (items B1-B3, C)

**Test summary:** `two_jup/tests/` -- 58 passed (up from the pre-existing suite; `test_ddrcap2_beat_analysis.py` now 9 tests, parametrised over period `{12320, 12333}`, up from 4). `task9_run.py all beatcap --check` confirms all 8 committed sel13/14/15 `*_analysis.json` files are byte-identical to a fresh reproduction from the `.bin` captures.

**TX-marker scan headline numbers:**
- sel6: 7/12 total d_data transitions immediately preceded (record distance exactly 1) by an anomalous extra TX-frame-start pulse -- specifically **7/7** for transitions that move `d_data` AWAY from the `0` baseline (departures: `0->rung`, `rung->None`, `0->None`), and **0/5** for transitions back to `0` (returns). This corrects the reviewer's "9/9": their own quoted onset pair (`extra=66820094`, `transition=66832415`) is actually 12,321 records apart, not 1 -- that transition is a return, not a departure.
- Full-rate (sel13/14/15, period 49332): **0 extra pulses found in any of the 6 captures scanned**, including around sel14's own located re-anchor events (record ~40.89M onset, ~30.32M mid). Positive control (regular cadence recovered at the expected period) passes on all 8 real captures scanned; negative control (`--negctl`, synthetic period-only stream) reports zero extras.

**P2 still holds: YES**, on both `onset.bin` and `mid.bin` (regenerated verdict JSONs, `measured_period=12320`).

**Deferred:** `task9_sel15_detector.py`'s `transition_score` duplicating `task9_sel13_detector.score_onset_window` (item E, "parametrise if a 10-line change") -- not done. The two functions differ in field width (11-bit `countReg` vs 5-bit `push`/`pop` circular fold) and a shared parametrisation touches both files' public call signatures; judged not a clean 10-line change within this fix round's scope, and left as-is rather than risking a behavior change to either detector this late in the review cycle.
