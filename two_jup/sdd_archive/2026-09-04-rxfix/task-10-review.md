# Task 10 review — W1 on silicon: flash 148, control legs, one witnessed air leg

Reviewer: read-only, no board contact (no ssh to 10.0.0.148/146, no sims, no
edits except this file). Verified from committed data: task-10-brief.md,
task-10-report.md, the `Task 10:` ledger lines in progress.md, the two run
directories, w1leg_go.sh / w1_score.py / w1_ctl.py / w1_read.sh at the commits
Task 10 actually used (cc344e6, 695cf42), the `t10_evidence/` archive, the six
named unit journals, and (independently, from the raw captured `frames.bin`
and `chk.jsonl`) re-runs of `comb_period_ms.py` and `comb_autocorr.py`.

## VERDICT: PASS

No Critical findings. The core scientific claim — P1/P2 hold, P2‑alt is
refuted at 0/188 stage‑readings, F2 fires — reproduces **exactly**, digit for
digit, from the raw `readings.jsonl`/`w1_reads.csv`/`chk.jsonl`/`frames.bin`
using the committed scoring scripts and two independently‑written analysis
tools. The findings below are all Important/Minor: one place where the
report's rhetorical framing outruns its own instrument's stated confidence,
one undisclosed post‑hoc edit to a (non‑decisive) evidence file, one
replicated small numeric transcription error in the hand‑back fps, and two
places where a review‑charge item ("every tap", "every conjunct") is true
only with a caveat the report itself already discloses elsewhere.

**Not independently reproduced, stated up front:** the exact accept_analyze.py
run — its own printed `72,738 / 875,375` and `CP95UL 8.367 %` line — was not
obtained by executing that script: `analyze()` calls `np.correlate(spc, spc,
'full')` on an ~875k-element array, which is O(n²) and did not finish in a
reasonable time (>20 min, ~680% CPU) on this shared rig host (`nemo`, which is
concurrently running live Task 12b/13 work per the heartbeat log), so I killed
it rather than let it keep consuming that host's CPU. In its place I
corroborated PER independently via `comb_period_ms.py` (72,738/875,376 →
8.309 %) and `comb_autocorr.py` (identical `run_bins`, identical `live
718s/723s`, identical `events=72738`), and computed CP95UL directly via
`scipy.stats.beta.ppf(0.975, k+1, n-k)`, which gives 8.367 % at **both**
plausible denominators (875,375 and 875,376) — so the reported PER and CP95UL
are corroborated, just not from the named script's own output. Also not
covered by the six journal units specified for this review: sentinel
stop/restart (`sentinel-100708`→`sentinel-172940`), keeper-hold release, and
the final 148/146 image readback — these are consistent with everything else
in evidence but are not independently verifiable from the given unit list.

---

## What reproduced exactly (the bulk of the review)

- **Rails.** `flash148-w1`'s journal opens with `SENTINEL_STOP already present
  (external hold) -- will NOT remove it`, confirming the keeper hold was taken
  before rig work started. Readback + two-pass gate: `booted image:
  2728dab3979a (expect 2728dab3979a)`, `gate 1... gate 2...`, `GATE_PASS x2`,
  all in the journal. Rollback caveat: the report's own §1 claim that
  `/root/BOOT.BIN.a1ff3c876d91.bak` did not pre-exist and was created at flash
  time is exactly the chain's documented behaviour (`[ -f ... ] || cp -f
  /boot/BOOT.BIN ...`) — honestly disclosed, not a defect. Retry discipline:
  the ctrl unit's log shows exactly one `arm #1` / one `arm #2` (no loop); the
  hand-back shows exactly `restore-t10` (failed) then `restore-t10b`
  (passed) — one re-run, per the rails. Polls: `w1_read.sh` floors `PERIOD`
  at 10 s, well above the ≥1 s rail. `FIXCTL_BASE=0x0`: confirmed on
  **every** reading in **all five** evidence sets (ctrl reads_pre/freeze/post,
  the 48-reading air set, and the at-rest set) — `"fixctl_base":"0x0"` on
  every line, not just in the meta.txt summaries.
- **No script edited while a unit ran** — checked by file mtime, not just by
  reading the report's claim. `w1leg_go.sh`, `w1_score.py`, `w1_ctl.py`,
  `w1_read.sh` were all stable (unchanged mtime) throughout each of
  `w1ctl-a`'s (16:47:56–16:51:55) and `w1air-a`'s (16:54:20–17:08:48) run
  windows. This is worth stating explicitly because commit `695cf42`'s
  timestamp (16:55:11) falls *inside* the `w1air-a` run window and, at first
  glance, looks like a live-run edit; the working-tree mtimes (`w1_score.py`/
  `w1_ctl.py` last touched 16:53:09, `w1_read.sh` 16:46:23 — both before
  `w1air-a` started at 16:54:20) show the commit only recorded already-stable
  content. `git commit` does not rewrite the working tree, so no live-edit
  rail violation occurred.
- **Step‑2 control table.** Re-running `w1_ctl.py` against the archived
  `reads_pre/freeze/post` directories reproduces `verdict.txt` byte-for-byte
  (only the absolute path differs). Arm-transient positive control confirmed
  directly from raw JSON: `witB` = `0xA` (10) at the end of `reads_pre`, `0x2C`
  (44) at the start of `reads_post` → +34, matching sim's 34. Freeze-hold
  confirmed (`freeze_effective:true`, `aux_lag_s:10.049`). Stuck-at, edge
  NULL, cPC guard-drop match all reproduce.
- **Air-leg numbers.** Re-running `w1_score.py` on `reads/` reproduces
  `verdict.txt` byte-for-byte. Independently, from `w1_reads.csv`: occ ∈
  {0,1} on all 47 intervals; `pop_on_empty` Δ sum = 18,519 over 47 intervals,
  mean 394.02/10 s (min 361, max 403) — matches "394.0, min 361, max 403"
  exactly; `push_on_full` Δ = 0 on all 47; census equality 0/188
  stage-readings short (47×4), max deviation 2; `cPC` shortfall −33.15
  frames/interval ≈ "−33.2" and 0.266 % of guard-drop total, ratio 0.084 to
  `pop_on_empty` — both exact. Wrap accounting: `cSS` total 7,223,411,856 =
  1.6818×2³², `cPC` total 7,196,602,064, `pop_on_empty` total 18,519 =
  0.2826×2¹⁶ — matches "1.68×2³²" / "0.28×2¹⁶" exactly. `dt_s` is 10.0 on
  every one of the 47 intervals (well under the 279 s / 1,659 s wrap
  horizons), and `readings usable: 48/48` with zero `freeze_effective:false`
  discards — confirms "no interval crosses a wrap horizon" and "deltas from
  consecutive reads only" over the *whole* window, not a sample of it. I also
  spot-checked all ten rows of the report's §4.1 extract table (#1–6, 24,
  45–47, including the post-wrap `cSS` cumulative at #24 = 72,448,785) against
  `w1_reads.csv`: all ten match character for character.
- **The decisive claim.** `pop_on_empty` mean inter-event interval:
  18,519 events over exactly 470.0 s (t0→t_last from the CSV) = 25.3793 ms,
  exact. PER comb period: re-ran `comb_period_ms.py` on the actual
  `cap/frames.bin` from this run and got `P = 31.61819 frames = 25.3872 ms, R
  = 0.1310`, `R at exactly P=32.000 = 0.0017` — both numbers match the report
  exactly (see Important finding #1 below on what this number does and does
  not establish).
- **PER / checker / lag-32.** Re-ran `comb_autocorr.py --live-window` on
  `frames.bin`: `live 718s/723s`, `events=72738`,
  `run_bins={1:37288, 2:15731, 3-4:500, 5-20:220, 21-100:1, >100:0}`,
  `null(p95)=0.0039`, `lag32=+0.6130`, `lag33=+0.0557`, `lag64=+0.4014` — every
  one of these matches the report exactly. Checker gap-event rate: raw
  `chk.jsonl` gives `chk_gap_events` +30,861 over 47 intervals of varying real
  duration (9.15–10.22 s, from `ts_mono`); the correctly dt‑weighted mean
  (Σdelta/Σdt×10) is 656.17–656.23/10 s depending on weighting, matching the
  report's 656.2 — a naive `/47` division gives 656.6, which is *not* what the
  report used, so I confirmed the report is using the more careful
  per-interval-normalized average, not a shortcut.
- **P/F verdicts quoted verbatim.** Programmatically diffed all seven quoted
  blocks (P1, P2, P2-alt, P3, F1, F2, F3) in task-10-report.md §5 against
  task-10-brief.md (post-14:44 correction): all seven match character for
  character (after stripping blockquote `>` markers and whitespace).
- **Provenance correction.** `task-9-report.md:211` does print
  `injector_commit=b5c39a10367a1bbe3a84d955eefee75765e000c5`; `git log` shows
  the actual last commit before Task 10 started is `2c661e6` ("RXFIX Task 9:
  RXFIX_W1 silicon ring-witness..."). The report's correction is accurate.
- **P2's sim basis.** `task-9-report.md:177-181` shows the −10 ppm tiled sim
  gate ending with `cSS`/`cRH` both 2,614,900 and `witB` poe=21 — exactly what
  the brief's 14:44 correction cites. Not fabricated.
- **HEARTBEAT cadence.** All `HEARTBEAT task10` lines in progress.md are
  spaced ≤4 min apart from 16:28:46 through 17:32:46 (CLOSED), satisfying the
  ≤5 min rail with margin, including through the unscored gap between the air
  leg finishing (17:08:48) and the restore units starting (17:24:01).

---

## Findings

### Important

1. **The headline "decisive number" is framed with more precision than the
   instrument backing it states.** `task-10-report.md:18-31` presents the
   0.031 % agreement between `pop_on_empty`'s mean inter-event interval
   (25.3793 ms) and the independently-measured comb period (25.3872 ms) as
   "the single most decisive number," quoted to four significant figures, and
   later ("§8") as the two being "the same event." But `comb_period_ms.py`'s
   own output for `P` — the number the 25.3872 ms figure is derived from —
   reports a Rayleigh concentration `R = 0.1310` (well above the 0.0160
   permutation null, so `COMB_LINE=present` is fair) and a
   `band R / a1r2 baseline (0.1737) = 0.754`, i.e. a *reduced-but-present*
   comb relative to the campaign's earlier baseline reference, with **no
   confidence interval printed on `P` itself**. R=0.13 is a real but modest
   concentration for a phase estimate quoted to five decimal digits of
   frames. This does not touch F2's actual load-bearing evidence (census
   equality to ±2 in 156 million, which needs no period estimate at all and
   is exact), so the localisation conclusion stands — but the report should
   not present the *coincidence-in-period* number as more precise than its
   own tool states it is, and a reader skimming §0 could come away thinking
   the 0.031 % figure carries tighter uncertainty than `R=0.1310` supports.

### Minor

2. **F2's "occupancy pinned at 0" conjunct is implemented (and evaluated) as
   occ ∈ {0,1}, not occ == 0, without saying so at the point of verdict.**
   `w1_score.py:341` (at commit 695cf42, the version Task 10 used):
   `pinned_empty = all(r["occ"] <= 1 for r in dl)`, reused verbatim for F2 at
   line 376 (`f2 = pinned_empty and ...`). This silently substitutes P1's
   "EMPTY edge (0–1)" gloss for F2's literal brief wording "occupancy pinned
   at 0." `task-10-report.md:285` ("All three conjuncts are met") does not
   flag the substitution. It is almost certainly the correct reading (occ=1
   with pushPtr−popPtr=1 *is* the ring's empty edge, per W1_REGMAP §1 — 32 and
   0 are the only two states the true-occupancy encoding calls "full"/"empty"
   distinctly, and 0/1 is what the instrument actually reports at that edge),
   and P1's own text says as much, but a falsifier's literal wording being
   quietly reinterpreted is exactly what item 6 of this review asks to be
   checked for.
3. **The at-rest evidence file was patched after collection, not disclosed.**
   `two_jup/rxfix/runs/atrest_164541/readings.jsonl` — the file backing
   report §2 ("the first board read") and §3.1 ("at rest it read 44") — has
   mtime `16:46:23.012`, 21–42 s after its own recorded `ts` values
   (16:45:41/52, 16:46:02). The `w1_read.sh` version active at collection
   time (commit `cc344e6`, committed 16:40:07) still emits **unquoted**
   `"fixctl_base":%s`, which for a hex value like `0x0` produces invalid JSON
   — yet the file's actual content has `"fixctl_base":"0x0"` (quoted), and
   `two_jup/rxfix/w1_read.sh`'s own mtime (`16:46:23.002`, essentially the
   same instant) shows the quoting fix (only committed later, in `695cf42` at
   16:55:11) was already made **on disk** at that moment. The two mtimes
   matching to the millisecond, combined with the 21–42 s gap between the
   file's last write and its newest recorded reading, indicates the file's
   text was hand-patched in place (not regenerated by a fresh board read) at
   the same moment the script was locally fixed. The register **values**
   (witA=0x6D5/0x5CD/0x4A4, witB=0x2C=44, etc.) are not implicated — this is a
   JSON-formatting-only fix — but this evidence file is not pristine
   unedited instrument output, and neither the report nor the ledger says so.
   Everything else is unaffected: Step‑2's `reads_pre/freeze/post` (collected
   from 16:49:27) and the entire air leg (from 16:56:39) were all collected
   *after* this fix and show no such gap.
4. **Hand-back fps figures are transcribed incorrectly, in two places.**
   `task-10-report.md:331-332` and `progress.md:557` both state
   `restore-t10b` passed with "148 1245 f/s, 146 1247 f/s." The only fps
   readout in the `restore-t10b` unit journal is `gate try 1: 148 rx=1243
   f/s  146 rx=1246 f/s`. Off by 2 f/s on each board; does not change the
   PASS verdict (both figures clear the ≥1120 gate by a wide margin), but
   it's a repeated, not one-off, small numeric error against the primary
   source named for this review. (Also trivially: `progress.md:557`'s "146
   steady 1247" for the *failed* `restore-t10` run undercounts one dip to
   1246 f/s on try 2 — not worth a separate line, folded in here.)
5. **"Every tap has a positive control and a null" (review item 2) is true
   for 9 of 10 rows, by design.** `push_on_full` has a null (steady-loopback
   delta 0, confirmed PASS) but no positive/liveness control — it stayed 0
   through the one re-arm, unlike `pop_on_empty`'s 10→44 transient — because
   a forward leg cannot reach the ring's FULL edge. This is pre-authorized
   by the brief ("push_on_full = 0 after the arm is NOT a failure") and is
   the report's own Concern 1, so it is not a report defect; it just means
   the literal "every tap" in the review charge should be read with that one
   named, disclosed exception.

## Numbers I could not independently reproduce from the exact named tool

- `accept_analyze.py`'s own printed `72,738 / 875,375` and `CP95UL 8.367 %`
  line — script killed before completion (O(n²) `np.correlate`, would not
  finish in reasonable time on the shared rig host). Corroborated instead via
  `comb_period_ms.py` (72,738/875,376) and `comb_autocorr.py` (identical
  `events=72738`, `run_bins`, `live 718s/723s`), plus a direct
  Clopper–Pearson computation matching 8.367 % at either denominator.
- Sentinel stop/restart unit names, keeper-hold release, and the final
  148/146 image readback — not covered by the six journal units specified
  for this review (`flash148-w1`, `pf148-w1`, `w1ctl-a`, `w1air-a`,
  `restore-t10`, `restore-t10b`); consistent with everything else in
  evidence but not independently verified from the given inputs.
