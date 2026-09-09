# Task 1 (T0a) review — harness truth taps + re-score

**Verdict: PASS.** The taps are the true guarded-ring signals, the arithmetic is
reproducible byte-for-byte from the committed CSVs, and no report number is overstated
relative to what was measured. Two Important documentation-precision findings below; no
Critical findings.

## What was checked

1. **Tap paths vs netlist** (`jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/`).
   Traced `Rate_Handle.v:99 FIFO_block u_FIFO` → `FIFO_block.v:100
   Validate_Input_Push_Pop_block u_Validate_Input_Push_Pop` →
   `Validate_Input_Push_Pop_block.v:49,57,61,106-129` (`Delay_out1`, `pop_on_empty_FIFO`,
   `push_on_full_FIFO`) — matches `wrap_byte_sro.v`'s
   `u_Rate_Handle.u_FIFO.u_Validate_Input_Push_Pop.{Delay_out1,pop_on_empty_FIFO,push_on_full_FIFO}`
   exactly. Same for the PD FIFO: `Preamble_Detector.v:320 FIFO u_FIFO` →
   `FIFO.v:102 Validate_Input_Push_Pop u_Validate_Input_Push_Pop` →
   `Validate_Input_Push_Pop.v:51,59,63,108-131`. Thresholds confirmed from source:
   `Compare_To_Constant1_block.v:36` = `6'b100000` = 32 (ring FULL);
   `Compare_To_Constant1.v:36` = `14'b11000000101101` = 12333 (PD FIFO FULL); both EMPTY
   constants are 0. `grep -rn 'pushOnFullRaw|push_on_full_raw|enSlack'` over
   `s1_rtl/hdlsrc/` returns nothing, confirming the report's claim that this tree has no
   `enSlack` and `push_on_full_FIFO` **is** the raw event — verified independently, not
   just asserted.
2. **Wrapper lint.** `bash build_sro.sh` (the actual build path) succeeds cleanly, exit 0.
   However `verilator --lint-only -Wall wrap_byte_sro.v -y <VD>` is **not** clean: 272
   warnings (all `UNUSEDSIGNAL`/`LATCH` inside vendor files — `subFilter.v`,
   `FrameStatChecksum.v`, `FrameStatProbe.v`, etc., unrelated to the new taps). Plain
   `verilator --lint-only` (no `-Wall`) also exits nonzero with 52 warnings. I re-ran the
   same lint against the pre-T0a `wrap_byte_sro.v` (commit `95475f3^`) and got **identical
   counts, 52 and 272**, so the new taps add zero incremental lint findings — the
   substantive claim ("the taps don't introduce new problems") holds — but see Important
   finding 1.
3. **Tap self-check and reproduction.** Ran `score_sro2.py r_p000 r_p000 q_m2p5 q_m10
   q_p2p5` against the committed `_frames.txt`/`_marks.txt`/`_deliv.txt`. All four legs:
   `TAP SELF-CHECK ... PASS`. Numbers reproduced **exactly** as in the report/doc:
   q_m2p5 loss 4.11%, gate 47.1% (8/17), reciprocal 87.5% (7/8); q_m10 loss 23.04%, gate
   55.3% (26/47), reciprocal 95.2% (20/21); q_p2p5 ring FULL first touch f=843,
   `push_on_full` at f=875/907, single loss at f=875, gate 100% n=1, reciprocal 50%;
   `pdPof`/`pd_pop_on_empty` = 0 on every leg both signs. Local-time census deficits (8,
   21) match `pop_on_empty` event counts one-for-one as claimed. The self-check
   (`occTE-occTS == pushes-pops`, PASS on hundreds of frames per leg) is real evidence the
   taps read the intended nets — an unrelated net would not satisfy the ring's own
   push/pop arithmetic identity by coincidence across that many frames — combined with the
   independent hierarchical-path verification in (1), this is solid.
4. **Verdict table vs pre-registered rules.** The plan (`happy-bubbling-owl.md` §T0a/
   Verification) only pre-registers a *qualitative* requirement ("a verdict without
   phase-locked tap events is INCONCLUSIVE") and the numeric `f≈876` prediction (from
   `RATE_HANDLE_FIX_SURVEY.md` §6), which the report correctly cites as pre-registered and
   which lands within 33 frames (f=843/875 vs 876). The specific **"≥80%"** phase-lock
   gate number does not appear anywhere before this task's own commit — see Important
   finding 2. Applied consistently and, if anything, conservatively (it downgrades
   `q_p2p5`'s single-loss coincidence to INCONCLUSIVE rather than crediting the
   report's own preferred `RATE_HANDLE_FULL_DELETES` reading).
5. **Paths / no forbidden artifacts.** `git show --stat` on all four commits: only
   `jupiter_240k5_byte/rtl_sim/{sim_sro.cpp,wrap_byte_sro.v}`,
   `two_jup/comb/{COMB32_SRO_SIM_TAPS.md,sro_sim/{runall3.sh,runall4.sh,score_sro2.py}}`,
   `two_jup/sdd_archive/2026-09-04-rxfix/{progress.md,task-1-report.md}` — all in-scope.
   No `.iq`/`.bin` in any of the four commits.

## Findings

**Critical:** none.

**Important:**
1. "Lint-clean" (stated in the commit message and `COMB32_SRO_SIM_TAPS.md` §1: "lint-clean,
   `verilator --lint-only`, no `%Error`") is not literally true — plain `--lint-only`
   exits nonzero with 52 pre-existing vendor-netlist warnings, `-Wall` with 272 — both
   identical before and after this diff. The correct claim is "adds zero new lint
   findings," which is true and is the substantively important fact; the doc's wording
   overstates it in a way that could mislead someone re-running the exact quoted command
   expecting a clean exit.
2. The "GATE, ≥80%" phase-lock threshold in `COMB32_SRO_SIM_TAPS.md` §2.3 is presented
   adjacent to language elsewhere in the same doc calling other numbers "pre-registered."
   The 80% figure itself was authored in the same commit that produced the scored results
   (`git log -p` on `score_sro2.py` shows it introduced in `95475f3`, with no earlier
   appearance in the plan or survey docs). It should be described as this task's own
   scoring convention, not implied to be pre-registered by the controller. This does not
   look like post-hoc cherry-picking — it is applied uniformly and works against the
   report's own preferred mechanism claim on `q_p2p5` — but the provenance should be
   stated accurately.

**Minor:**
- `two_jup/sdd_archive/2026-09-04-rxfix/progress.md` has uncommitted Task 6 heartbeat
  lines mixed into the working tree at review time; unrelated to Task 1's deliverable,
  just noting it's not yet committed.

## Bottom line
The taps are correct and independently verifiable against the netlist; the self-check and
full numeric reproduction both check out exactly; nothing was written outside the allowed
paths and no `.iq`/`.bin` was committed. The two Important findings are about precise
wording of already-true underlying claims ("no new lint issues" vs "lint-clean"; "this
task's own gate" vs "pre-registered"), not about the correctness of the taps or the scored
results.
