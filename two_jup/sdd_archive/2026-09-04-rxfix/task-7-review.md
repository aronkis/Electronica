# Task 7 (T2b) review [desk, read-only]

Reviewer commit under review: HEAD (`f1ddfb6`, branch `per-under-1pct-2026-07`); Task 7 spans
`da45c13..a368264` (code) plus ledger/state commits `6f824ad`/`f1ddfb6`. No board contact, no
Vivado, no sims run by this review; verification below is static reads plus reproduction from
committed scripts against the working-tree result files the task itself produced.

## Verdict: PASS

Every headline number in `task-7-report.md` reproduces exactly from the named tools and the
working-tree result files: the 432-frame stimulus certification, all four decisive legs'
expect/OK/CORRUPT/MISSING/LOSS and `rh_pop_on_empty`/`rh_push_on_full` frame placements, the
21 scored `b_m10` hole frames (byte-for-byte identical list), the `b_m40` 272 = 61 acq + 211
scored split, the tiled controls (0.00 / 0.63 / 22.01 %), the ring-lap refutation's identical
occupancy/pointer histograms and 14-of-30 mismatch counts in both `pop_on_empty` windows, the
`h_m10_ring.txt` row at `sidx=1997338` field-for-field, and the smoke-leg R3 gate numbers
(`r3_skips=4`, `r3_extras=4`/`r3_skips=1`, `capout` transitions). Retractions are recorded and
nothing in the report relies on them. R3 outputs on the decisive capture are genuinely absent.
Two Important-adjacent gaps below don't touch the H-B verdict itself (R3 was rejected before
any of them could matter) but are worth fixing before the injector's "reusable rails" are reused
by Task 11 (R3S).

## Reproduced, with method

1. **Stimulus certification** — `tx432.iq.frames.txt`: 432 data rows, `repeat_of_prev` sums to
   0, `allzero` sums to 0, `seq_at_end` strictly 1..432 (checked by direct `awk`). The
   `repeat_of_prev`/`allzero` computation itself is a `memcmp` against the previous 49,332-sample
   frame plus a nonzero-word count, in `jupiter_240k5_byte/rtl_sim/sim_sro.cpp:107-115` — not an
   assumption, an actual per-frame comparison.
2. **Four legs** — `score_t7.py b_p000 b_m2p5 b_m10 b_m40` (with `T7_NAIR=428` for `b_m40`,
   see caveat below) reproduces `b_p000` 420/420/0/0/0.00 %, `b_m2p5` 420/420/0/0/0.00 %,
   `b_m10` 421/375/8/38/10.93 %, `b_m40` 424 delivered/93 OK/78.1 % exactly. `rh_pop_on_empty`
   and `rh_push_on_full` per-frame placement verified directly against `*_frames.txt` columns
   21-30 (`sim_sro.cpp:16-19`'s documented layout): `b_p000` 34 all frame 0; `b_m2p5` 34 all
   frame 0, push_full 17@frame2+1@frame3; `b_m10` 34@frame0 + the 21 scored events at exactly
   frames 259,267,...,421 (identical to the report's list), push_full 17 all at frame 2 only;
   `b_m40` 61@frames{0,1} + 211 at frames 3..427. Tiled controls `tb_p000`/`tb_m2p5`/`tb_m10`
   reproduce 0.00 / 0.63 / 22.01 % exactly via `score_sro2.py`.
3. **H-B argument** — offset scan of the 46 lost `b_m10` seqs against the 21 hole frames: −3 is
   the *unique* argmax at 42/46 within ±1 (next-best offset is +5 at 38/46) — a stronger check
   than the report itself ran, and it confirms −3 is not a fitted number. 44/169 = 26.04 % ≈
   "26.0 %" reproduces using the pre-registered edge frame (252) as the post-edge window start
   (421−252=169). Seq 133/134: nearest hole frame 259, distance 126 — matches "126 frames later"
   exactly. `b_m40` 272 pop_on_empty = 61 (frames 0-1, acquisition) + 211 (frames 3-427,
   scored) reproduces exactly from `b_m40_frames.txt` col 25. `b_m40`'s per-frame correlator
   census (col 14) is 12,332/12,333 on all 428 real frames (indices 0-427) except the two
   boundary rows: frame 0 = 12,259 (acquisition transient) and an extra trailing row indexed
   "428" = 25,001 (a post-loop flush bucket — its `con`/`dem` columns, 12,592/25,186, are not
   near any real frame's 12,320/24,640, confirming it's harness bookkeeping past the 428-frame
   capture, not a mid-run missed boundary). "Lock held throughout" is supported as stated.
4. **Retractions** — `4a` explicitly supersedes `4`'s `[inferred]` ring-lap mechanism and is
   itself reproduced: `t7_ramreplay.py t7_ram_m10.txt` gives occupancy histograms
   `{0:49,1:72,2:8}`/`{0:49,1:64,2:16}` identical to the `(wr-rd) mod 32` histograms, lap
   distance only 0 or 1 (never 32), and mismatch=14/30 in both windows — exact match to the
   report's numbers. `task-7-report.md:330` lists the ring lap among mechanisms the silicon
   instrument section does *not* rely on. The 32-symbol-ambiguity-at-all-times claim is
   retracted in `4(b)` and does not reappear. The 60-frame smoke-leg 0.00 % result (retracted
   in the ledger as an H-A signal, `progress.md:315`) does not appear anywhere in
   `task-7-report.md`; the report's own §7 verdict rests only on the 428-frame legs.
5. **Cadence-fidelity quote** — see Minor-1 below: verified true in substance in both trees,
   the line numbers as given are correct only for one of them.
6. **Labels/binaries/R3-absence** — `[sim]`/`[netlist]`/`[inferred]` labels are present and
   used correctly (blanket `[sim]` at line 5, `[netlist]` at 177/263/391, `[inferred]`
   introduced and then explicitly withdrawn at 194/205/215). Task 7's five code/doc commits
   (`da45c13`,`b5c39a1`,`82a5a54`,`83a808d`,`d4f1a82`) carry only scripts, `.sh`, and `.md` —
   no binaries, no large data dumps. R3 on the decisive capture is genuinely absent:
   `r3_{p000,m2p5,m10,m40}_*.txt` are all 0 bytes (timestamped 14:02, the moment the ruling
   stopped them). `r_p000_res.txt` (`packets=164 biterr=51 capout=04922282 ... rh_pop_on_empty=16`)
   matches the ledger's quoted watcher misread line exactly — confirms the "watcher confusion"
   story rather than a hidden R3 result.

## Important

1. **`task-7-report.md:129-133`** — the R3 `**Verified:**` sentence bundles three claims of
   materially different strength under one word:
   - *sim-lineage build*: actually **over**-verified relative to "lint-only" — `build_sro_rxfix3.sh`
     does a full Verilator `--cc` build + `make` against `jupiter_240k5_byte/rtl_sim/s1_rtl_rxfix_R3`
     (confirmed on disk, `RXFIX_R3` markers present in all 7 files), and the smoke-leg R3 results
     (`sm_r_p000`, `sm_r_m10`) prove it actually compiled and ran, not just linted.
   - *flashed `s1_rtl_txfix_F3` lineage lint-only*: **no artifact exists to check.** There is no
     R3-patched F3-lineage tree anywhere in the working tree (only `s1_rtl_rxfix_R3`, the sim
     lineage), no lint log, and neither `rxfix_inject.py` nor `test_rxfix_inject.py` contains any
     `verilator`/`lint` reference. This half of the claim is unfalsifiable from what's on disk.
   - *"`test_rxfix_inject.py` 39 tests green"*: literally true as a count (confirmed 39 test
     methods at `b5c39a1`, matching Task 6's already-reviewed number), but **zero of the 39 test
     R3 specifically**. `TestPatcher` (`test_rxfix_inject.py:58`), `TestMain` (`:133`) and
     `TestRealNetlists` (`:211`) all hardcode `'R1'` / `R.patch_preamble_detector` (R1's own
     function); `TestR2` (`:236`) is R2-specific. The only R3-touching test is
     `test_15_tables_cover_every_variant` (`:126`), which checks that `R.VARIANT_FILES['R3']`
     entries have corresponding `FILE_MARKER`/`PATCHERS` dict entries — a registration check,
     not a patch-correctness check. Unlike R1 and R2, R3 has no dedicated test class exercising
     its 7 patcher functions against synthetic or real netlist content.

   Net effect: the sentence reads as "R3 is verified the same way R1/R2 were" when the middle
   claim is unevidenced and the third is registration-only. This doesn't touch the H-B verdict
   (R3 is rejected, §5), but the report itself keeps "the seven-file injector, its structural
   anchors and the both-lineage lint result... as reusable rails" (`task-7-report.md:240-241`),
   and Task 11 (R3S) is dispatched against exactly those rails — so a future reader relying on
   "Verified" for reuse would be trusting an unevidenced half-claim and a mis-scoped test count.

## Minor

1. **`task-7-report.md:397-399`** (`### Cadence fidelity`) — `TxRxComposite.v:476-481` and
   `:721` are correct line numbers **only** for
   `jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/TxRxComposite.v` (the T7 harness's
   own DUT tree, confirmed: `assign IntValidConst_out1 = 1'b1;` etc. at exactly those lines).
   The equivalent statements in the flashed `s1_rtl_txfix_F3`-lineage mirror
   (`jupiter_240k5_byte/rtl_sim/s1_rtl_txfix_F3/hdlsrc/commhdlQPSKTxRxLoopback/TxRxComposite.v`)
   are at **`:536-541` and `:787`** — the F3 tree's earlier `beatobs*`/`bfGridEn` insertions
   shift every downstream line number, exactly as §3 itself notes for the R3 injector's other
   five files. The underlying claim ("hard-tied `1'b1` in both modes") verified true, word for
   word, in both trees — this is a citation-precision issue, not a substantive error. Since this
   section directly answers the controller's pre-verdict 15:10 cadence question
   (`progress.md:407`), the citation is worth being tree-qualified for the record: either name
   the `s1_rtl` (sim) tree explicitly, or give both line pairs.
2. **`task-7-report.md:239`** — `sm_b_m10`'s table cell reads "`pf` 17 (all in frames 0–2)".
   Measured directly from `sm_b_m10_frames.txt` col 26: all 17 `rh_push_on_full` events are at
   frame index **2 only** (0 at frames 0 and 1). "0–2" is not false (2 is in that range) but is
   looser than the report's own language for the decisive `b_m10` leg two sections later
   ("**17, ALL in frame 2**, 0 in the scored window", `task-7-report.md`'s H-B table), which is
   exactly precise. Cosmetic; the smoke leg is superseded and this table isn't load-bearing for
   the verdict.

## Reproduction caveats (not defects)

- **Working-tree vs. git state.** None of the result `.txt` files in `two_jup/comb/sro_sim/`
  (the `b_*`/`tb_*`/`sm_*` legs, `tx432.iq.frames.txt`, `h_m10_ring.txt`, `t7_ram_m10.txt`) are
  git-tracked, and `*.iq` is gitignored (`.gitignore:34`). This matches the project's existing
  convention — `task-6-review.md` used "committed data" the same way for its own untracked
  `e_m10_ring.txt` — and no large binaries are in git history (Task 7's 5 code commits carry
  only scripts/`.sh`/`.md`). But it means the reproduction above is against ephemeral
  working-tree state, not against anything git preserves; if this directory is ever cleaned,
  the numbers stop being independently reproducible from the repo alone.
- **`score_t7.py`'s `T7_NAIR` gate is environment-only.** `score_t7.py b_m40` with no
  `T7_NAIR` set silently computes `expect=15,729,143`, `LOSS=100.00%` — it does *not* print the
  "SEQ RANGE IMPLAUSIBLE... refusing to score" message the report and ledger both quote. That
  message only fires with `T7_NAIR=428 python3 score_t7.py b_m40` set (`score_t7.py:34-37`,
  `nair = int(os.environ.get('T7_NAIR','0')) or None`). Anyone re-running the bare command will
  see an alarming, wrong-looking number that appears to contradict "93/424, 78.1 %" until they
  notice the env var. Recording the exact invocation here for future reproduction:
  `T7_NAIR=428 python3 score_t7.py b_m40`.

## Not checked

- Vivado build/place-route: task states none was run; no build evidence found, consistent.
- Silicon/board legs: task states none; no board-contact evidence in the commits reviewed.
- The `verilator --lint-only` runs themselves (both lineages) were not re-executed by this
  review (task instructions bar running sims); see Important-1 for why the flashed-lineage half
  in particular has no artifact to check even if re-run were permitted.
- `test_rxfix_inject.py`'s 39 tests were not re-run (task instructions bar running sims); the
  R3 coverage gap in Important-1 was established by reading the file at `b5c39a1`, which is
  sufficient to show no R3-specific test exists regardless of pass/fail status.
