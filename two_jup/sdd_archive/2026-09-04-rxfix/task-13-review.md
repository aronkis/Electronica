# Task 13 review — W1+R4B image for 148: kit/build/bank, flash, controls, air leg

Scope: read-only review of the committed record. No board contact, no sims, no
builds. Every number below was either independently recomputed from the banked raw
artefacts using the committed tools, or checked against the git history / kit tree
already on local disk.

## Verdict: **CONDITIONAL**

The physical/silicon claims that matter for the campaign's conclusion (the fix
works, PER 8.309 %→0.224 %, register witnesses, all seven pre-registered
predictions and three falsifiers) reproduce exactly, including a byte-identical
re-run of `w1_score.py` against the banked readings. Two things keep this from a
clean PASS: (1) the report's headline "checker garbage %/crc_fail %" row for the
W1/Task 10 baseline is not Task 10's own number — it is copy-pasted from an
unrelated, earlier Task 5 leg and is wrong — and (2) the postflash_check.sh
"operator error" episode in §4.5 leaves no rig-unit journal trace at all, unlike
every other step in this task and unlike Task 10's own postflash step. Neither
defect changes the seven-predictions verdict, but both need fixing/clarifying
before this is a clean record.

**Numbers I could NOT independently reproduce:** the modem-clock intra-clock WNS
build-gate figures (+0.437 ns for this build; the 0.227/0.169 calibration values for
SEQ-BIST/W1) — the routed timing reports for `jupiter_byte_rxfixr4b_build`,
`jupiter_byte_rxfixw1_build` and `jupiter_byte_seqbist_build` are not present in the
repo or on local disk (only the final BOOT.BIN was transferred back; the kit
script's rsync excludes `vivado_prj.runs/impl_1/`), and the reports exist, if at
all, only on the remote hdl-dev-2 build host, which is out of scope for this
read-only review. Also not reproduced: the verilator-lint pass (0 errors/40
warnings) — no committed script encodes the exact invocation/file list used, and
it is not one of the six required check items, so I did not attempt to
reconstruct it.

---

## Findings

### Critical

**C1. The "checker garbage % / crc_fail %" figure attributed to the W1 image
(Task 10) is not from Task 10's leg — it is a different task's data, and it is
wrong for the leg it is compared against.**
`two_jup/sdd_archive/2026-09-04-rxfix/task-13-report.md:23` (headline table) and
`two_jup/RXFIX_STATE.md:246` both state `checker garbage % / crc_fail % | 5.896 /
2.023 | 0.028 / 0.022`, presenting 5.896/2.023 as Task 10's W1-image number on the
same forward air leg used for the PER/gap-events/lag-32 comparison in that same
row.

- Task 10's own report never states a garbage%/crc_fail% percentage at all —
  only raw counts (`task-10-report.md:207-208`: `chk_garbage +33,960`,
  `chk_crc_fail +11,887`, out of `chk_frames +584,054`).
- Recomputing directly from Task 10's own banked checker series
  (`two_jup/comb/runs/20260904_165420_w1_air/chk.jsonl`, identical to
  `t10_evidence/air_checker.jsonl`, confirmed by `diff`), summing consecutive-read
  deltas exactly as `seqbist_score.py:156-166` does: `garbage_pct =
  100*33,960/584,054 = 5.8145 %`, `crc_fail_pct = 100*11,887/584,054 = 2.0353 %`.
  Neither matches 5.896/2.023 by any denominator variant I tried (sum/sum,
  average-of-ratios, frames+lost, good+garbage+crc).
- `5.896 / 2.023` traces instead to `two_jup/RXFIX_STATE.md:99`, the **Task 5**
  `enSlack OFF (0x208=0x0)` control leg — a different task, a different leg, and
  (Task 5 predates Task 9) very plausibly a different image epoch entirely, run
  five days before Task 10's W1 leg.
- Consequence: the number is a citation/provenance error, not a measurement of the
  compared leg. It does not gate any of the seven pre-registered predictions
  (T13-P1..P7 use occupancy, `pop_on_empty`, `r4b_skips`, `push_on_full`, gap
  events, PER, lag-32/comb — none reference garbage%/crc_fail% as a criterion), so
  the PASS verdicts stand, but the table row is factually wrong and is now banked
  in a persistent project-state file (`RXFIX_STATE.md`) that future tasks may cite
  as Task 10's baseline.
- Fix: replace `5.896 / 2.023` with the correct Task-10-leg figures (`5.81 / 2.04`,
  computed the same way as the R4B side) in both `task-13-report.md` and
  `RXFIX_STATE.md`, or state plainly that the comparator is a different leg if that
  comparison was intentional.

### Important

**I1. The postflash_check.sh operator-error episode (§4.5) has no rig-unit journal
trace under any name, unlike every other step in this task.**
`task-13-report.md:353-358` describes a first `postflash_check.sh` invocation with
`SINK=tgenrx` failing `PF_FAIL_TGENMODE`, then an immediate corrected re-run giving
`POSTFLASH_OK`, between the flash (`flash148-r4b` unit, ends `20:09:36
FLASH_DDRCAP2_OK`) and the Step-2 control leg (`w1ctl-r4b` unit, starts
`20:12:03`). I checked `journalctl --user -u flash148-r4b -u pf148-r4b -u
w1ctl-r4b -u w1air-r4b -u restore-t13 -o cat` as instructed, and separately
searched the whole day's user journal for `postflash|PF_FAIL|POSTFLASH_OK|TGENMODE`
and for every `Started ...` unit line in the 19:30–20:20 window:
- No `pf148-r4b` unit was ever started (it does not appear in
  `systemctl --user list-units --all` either).
- No unit of any name started between `20:09:36` (flash148-r4b ends) and
  `20:12:03` (w1ctl-r4b starts) — the exact window the episode claims.
- `PF_FAIL_TGENMODE` does not appear anywhere in the day's journal; the only
  `PF_FAIL_*` in the whole day is an unrelated `t6-postflash` failure from
  `00:10` (Task 6, image `a1ff3c876d91`, "PF_FAIL_SEGMENTS/PF_FAIL_SLOTS", not
  `PF_FAIL_TGENMODE`).
- Task 10's equivalent step, by contrast, has a named unit and a clean log:
  `Started pf148-w1.service ... 16:47:21 [pf] POSTFLASH_OK image=2728dab3979a`.
- Every OTHER step this task claims (flash148-r4b, w1ctl-r4b, w1air-r4b,
  restore-t13, restore-t13b) does have a matching, content-consistent unit in the
  journal — including the launcher-usage-error detail in §4.10 (`restore-t13`
  really did die instantly on `usage: bringup_r2r3.sh r2|r3` before touching
  either board, exactly as claimed, immediately followed by `restore-t13b`
  passing `ARM GATE PASS (try 1)`).
- Consequence: either the postflash_check step ran as a bare command outside
  `launch_rig_unit.sh` (a rails deviation — the brief's rails require "launch_rig_unit.sh
  units + watchers" for every rig-touching step), or the specific narrative in
  §4.5 is unverifiable from the audit trail that every other step in this task
  left behind. It does not put the final image state in doubt — `postflash_check`
  passing is corroborated indirectly by the Step-2 control table and the air leg
  itself both behaving correctly on `9f13705d9fb0` — but the rails-mandated
  audit trail for this one step is missing.

### Minor

**M1. The modem-clock WNS gate figures could not be checked against a routed
report.** `boot_known_good/BOOT.BIN.148.rxfixr4b.9f13705d9fb0` is banked and its
md5 matches exactly (`9f13705d9fb0ea6ae6af3c4c1ab5e95d`, 7,203,552 B), and the
kit-tree provenance (injector commit, markers) is independently verified — but
the `system_top_timing_summary_routed.rpt` for this build, and for the two
calibration builds (SEQ-BIST `a1ff3c876d91`, W1 `2728dab3979a`), are not present
anywhere under `/mnt/onetb/scratch/qpsk-jupiter-modem` (the kit's rsync excludes
`vivado_prj.runs/impl_1/`, and only the bitstream came back from hdl-dev-2). The
`+0.437 ns` / `0.227` / `0.169` figures are therefore taken on faith from the
report text, not independently reproduced. This is out of scope to chase further
under the read-only/no-build constraint (the reports live only on the remote
build host), but it is the one first-order physical claim in the task that I
could not check against an artefact.

**M2. Verilator lint pass not reproduced.** No committed script wraps the
`verilator --lint-only --top-module TxRxCompo_ip` invocation the report/ledger
cite (0 errors, 40 pre-existing warnings, 0 on any `r4b_`/`w1_` net); reproducing
it would require reconstructing the exact file list and include paths ad hoc.
Not one of the six required check items — deprioritized, not attempted.

---

## What reproduced exactly (evidence)

**1. Kit provenance.**
- Injector commit `7eef225ab19ab4f44ec29e9ad0553ace807af7e2` exists
  (`git log -1 -- two_jup/skidfix/rxfix_inject.py` at that SHA matches); `git show
  7eef225:two_jup/skidfix/rxfix_inject.py | md5sum` = `25ea6237c1272d03f832d43971c56113`,
  matching the kit's own `RXFIX_VARIANT` file and the report exactly. (The file has
  since changed under Task 14 — HEAD md5 differs — which is expected drift, not a
  discrepancy.)
- `jupiter_byte_rxfixr4b_build/RXFIX_VARIANT` on disk: `W1 R4B`, commit and md5 as
  above, `READ_WORDS=...,0x234`, matching `two_jup/rxfix/w1leg_go.sh`/`w1_read.sh`.
- Both markers (`RXFIX_W1`, `RXFIX_R4B`) present in all 3 loose mirrors of all 12
  files (re-grepped directly) and in both `TxRxCompo_ip_v1_0.zip` members
  (re-verified with a standalone script reproducing `jupiter_byte_rxfix_kit.sh`'s
  own `verify_zip` logic) — both markers OK in both zip copies.
- `RXFIX_VARIANTS='W1 R4B' jupiter_byte_rxfix_kit.sh 146` really does exit 1 with
  `RXFIX_KIT_REFUSE_146` before touching anything (executed directly, harmless).
- `test_rxfix_inject.py` at commit `39dad6a` (Phase A kit commit): 123 `def test_`
  functions, no parametrize — matches "123/123 pass" exactly, including
  `test_119_w1_then_r4b_apply_to_a_kit_shaped_tree_with_verify_zip`
  (`two_jup/skidfix/test_rxfix_inject.py:1336`).
- `test_rxfix_rig_scripts.py`: 29 `def test_` pre-Task-13 (commit `39dad6a^`) + 2
  pre-existing `@pytest.mark.parametrize` cases (both from before Task 13) = 31
  pytest-collected pre-existing, exactly matching "31 pre-existing"; +4 new R4B
  reader tests at `e186fa7` = 35 (matches §1.2's "35/35"); +1 fail-closed-guard
  test at `1be33ee` = 36 (matches the ledger's final "36/36"). Ran
  `test_w1leg_r4b_refuses_the_default_w1_image_expectation` directly: PASSED.
  Confirmed the fail-closed logic in `w1leg_go.sh:66-78` (`EXP_SET=${EXP:+1}`
  captures caller-set vs default correctly).

**2. Rails / flash chain.** `journalctl --user -u flash148-r4b -u w1ctl-r4b -u
w1air-r4b -u restore-t13` (full text, not truncated) matches the report's
timeline and figures exactly: `148 current image: 2728dab3979a`, `FLASHED
9f13705d9fb0`, `booted image: 9f13705d9fb0`, `GATE_PASS x2` at `fps=1248
capTAP=0xBCF94856`, Tier-2 witness `524,288 records / 43 demod marks / toff mode
12314 distinct 1`; `restore-t13` really did fail instantly on `usage:
bringup_r2r3.sh r2|r3` (the reported launcher signature bug) before touching
either board, and the immediately-following `restore-t13b` unit (not in my
instructed list, found via the journal) passed `ARM GATE PASS (try 1)`. See I1
above for the one rails element I could not corroborate (postflash_check).

**3. Step-2 control table.** `two_jup/comb/runs/20260904_201203_w1_ctrl/verdict.txt`
matches the report row for row: `r4b_locked` 1 on 6/6, `r4b_skips` cumulative flat
at 8 across all 6 readings (delta 0 on every interval), occupancy [8,9],
`pop_on_empty` 44/44 across the re-arm (jump 0, hence the raw `FAIL (DEAD)` label).
Independently diffed `jupiter_byte_rxfixw1_build` vs `jupiter_byte_rxfixr4b_build`
for `TxRxCompo_ip_src_Validate_Input_Push_Pop_block.v` and
`TxRxCompo_ip_src_Frequency_and_Time_Synchronizer.v`: confirmed R4B's only change
to the first file is an added `r4bOcc` output tapping the existing `Delay_out1`,
and the second file gets only the `pcEnd` route-through plus the witness
pass-through — `pop_on_empty_FIFO` (line 145 in the R4B kit's own copy) and
`w1PopEmpty` (line 168) are byte-identical to W1, exactly the line numbers and
argument quoted in the report. The "NOT EXERCISED" relabel is netlist-justified,
not merely asserted.

**4. Air-leg numbers**, all recomputed directly from
`two_jup/comb/runs/20260904_201814_w1_air/{w1_reads.csv,chk.jsonl,cap/frames.bin}`:
- occupancy ∈ {8,9,10} on all 48 reads; `pop_on_empty` delta = 0 on all 47
  intervals; `push_on_full` delta = 0 on all 47; `r4b_skips` delta mean = 391.04
  (min 355, max 398); `r4b_locked` = 1 throughout; read spacing exactly 10.0 s on
  every interval — all match the report exactly.
- `accept_analyze.py two_jup/comb/runs/20260904_201814_w1_air/cap/frames.bin`:
  **PER = 0.224 % (1956/871805), CP95UL 0.235 %, live 715 s/721 s [WEDGE
  truncated], bins {1:18, 2:1, 3-4:33, 5-20:161, 21-100:0}** — byte-for-byte the
  report's numbers. Same tool on Task 10's `20260904_165420_w1_air/cap/frames.bin`
  gives **8.309 % (72738/875375), CP95UL 8.367 %, live 718/723 s, bins {1:37288,
  2:15731, 3-4:500, 5-20:220, 21-100:1}** — also exact, confirming the burst-bin
  comparison table (§4.8/F-C) is not cherry-picked.
- `comb_autocorr.py --live-window` on the R4B leg: lag16 +0.0208, **lag32
  +0.0182**, lag33 +0.0203, lag64 +0.0029 (all-loss); singles-only lag32 −0.0000.
  `comb_period_ms.py`: band R=0.1851 (25-27 ms) vs random-event null 0.2499 →
  **COMB_LINE=absent**. Both match exactly.
- Checker (`chk.jsonl`, deltas summed the way `seqbist_score.py` does):
  `chk_frames` 12,452/10 s, `chk_gap_events` **3.06/10 s** (gap1 0.32/gap2
  2.0/gap3plus 0.74), garbage **0.0280 %**, crc_fail **0.0220 %** — matches the
  report's "3.1 / 0.3 / 2.0 / 0.7" and "0.028 / 0.022" exactly. The equivalent
  Task-10-leg numbers (656.6/10 s using per-interval mean, 656.2/10 s using
  elapsed-time basis matching Task 10's own report method) also reproduce — only
  the garbage/crc_fail pairing is wrong, per C1.
- Re-ran `w1_score.py` fresh against a copy of the banked
  `t13_evidence/air_readings.jsonl` (not just read the banked `verdict.txt`):
  produced a `w1_reads.csv` that `diff`s byte-identical to the committed one, and
  printed T13-P1/P2/P3/P4 HOLDS and F-B does-not-fire with the same figures as
  the report.

**5. Predictions/falsifiers quoted verbatim** — diffed the brief's
`PRE-REGISTERED [silicon] ...` / `FALSIFIERS: (F-A) ... (F-B) ... (F-C) ...`
paragraph in `task-13-brief.md` against `task-13-report.md:258-270`: word-for-word
identical. **G14 acquisition-window numbers**, recomputed directly from
`frames.bin`: 0 lost slots in the first 30 and first 1,000 good-frame host_seq
intervals from the absolute start of the capture; 2 lost slots by t<5 s and still
2 by t<30 s (i.e. 0 added 5→30 s) — matches "2 lost slots in the first 5 s and
none added out to 30 s" exactly. First CSV row's cumulative-since-arm counters
(`push_on_full`=0, `pop_on_empty`=53, `r4b_skips`=1668, `r4b_locked`=1, occ=9)
match the report's register-side G14 claim exactly.

**6. Comparability (1038 vs 1900 f/s).** Confirmed `deliver_rate_pre/post` really
is 1900 in Task 10's `meta.txt` vs 1038 in Task 13's — a real difference in that
one field. But the report's own resolution checks out: `chk_frames` per 10 s is
12,419 (Task 10) vs 12,452 (this leg) — 0.3 % apart; PER-denominator ÷ live
seconds is 875,375/718 = 1,219.19 vs 871,805/715 = 1,219.31 — a 1.0001× ratio,
both independently recomputed. Both legs are wedge-truncated by exactly one wedge
(Task 10: 718/723 s; this leg: 715/721 s), and both legs' `pair.iq` taps are
independently flagged `DEGENERATE` by `capture_r3`'s own health check for the
same reason (stale-DDR-replay signature) — neither leg's PER depends on that tap,
only on `frames.bin`, so this is a pre-existing instrument limitation affecting
both legs equally, not a new asymmetry. The 8.309 %→0.224 % comparison is
like-for-like on offered load and window handling.

---

## Files referenced
- `two_jup/sdd_archive/2026-09-04-rxfix/task-13-brief.md`,
  `task-13-report.md`, `progress.md` (Task 13 lines), `RXFIX_STATE.md:99,246`
- `two_jup/comb/runs/20260904_201203_w1_ctrl/`, `20260904_201814_w1_air/`,
  `20260904_165420_w1_air/` (Task 10 comparator)
- `two_jup/rxfix/w1leg_go.sh`, `w1_score.py`, `w1_ctl.py`, `w1_read.sh`,
  `modem_wns.py`
- `two_jup/skidfix/jupiter_byte_rxfix_kit.sh`, `rxfix_inject.py`,
  `test_rxfix_inject.py`
- `two_jup/tests/test_rxfix_rig_scripts.py`, `two_jup/accept_analyze.py`,
  `two_jup/comb/comb_autocorr.py`, `two_jup/comb/comb_period_ms.py`,
  `two_jup/seqbist/seqbist_score.py`
- `jupiter_byte_rxfixr4b_build/`, `jupiter_byte_rxfixw1_build/` (local kit trees)
- `boot_known_good/BOOT.BIN.148.rxfixr4b.9f13705d9fb0` (md5 verified)
