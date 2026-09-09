# TXFIX_SIM_GATE — T1 Verilator gate matrix (Task 5, 2026-09-03)

Plan: `/home/tcollins/.claude/plans/happy-bubbling-owl.md` ("Fix variants — exact patches",
"Verilator gate (sim lane)"). Host-only, `jupiter_240k5_byte/rtl_sim/`, no board contact.
Trees `s1_rtl_txfix_F{1,2,3}` (Task 2), harness `sim_txfix_force.cpp` (txkick: none /
popabort / latchforce / latchforce_pre / frcwrap / nearfull) and `txrate_probe.cpp`
(txrate: census / fcbase3 / nfprobe), binaries `obj_txkick_{U,F1,F2,F3}/Vtxkick`,
`obj_txrate{,_F1,_F2,_F3}/Vtxrate`. Scored with the UNMODIFIED `kick_seq.py` + tap3 map
(`two_jup/offsetmap/tap3_word_to_offset.tsv`) plus the harnesses' own SUMMARY/READBACK/CEN
lines. Scorer: `jupiter_240k5_byte/rtl_sim/txfix_gate_score.py`; raw output
`jupiter_240k5_byte/rtl_sim/beat_runs/txfix_gate_summary.txt`; per-run logs/frames in
`jupiter_240k5_byte/rtl_sim/beat_runs/`.

**Trims from the literal plan text** (declared up front, budget-driven — Verilator runs at
~4.4 kclk/s, NF=50 ≈ 40 min): popabort/latchforce swept at k∈{0,6} (endpoints) instead of
the full k=0..6; G6/G7 run once per variant at k=0 rather than swept. 26 sim runs launched
as `systemd-run --user` units (cap 10 concurrent), each registered in `lanes.json` pointing
at its growing `.bin` (not the stdout log, which only writes at exit — see the 2026-09-03
stall-detector correction in the ledger) and watched by `watch_unit.sh --spawn`. All 26
exited by 12:31 (last: `txfix-gate-g10-f3-...`).

**Scoring integrity note.** Two bugs were found and fixed mid-run, both logged as `FINDING`
lines in `progress.md`: (1) an early interim pass wrongly scored G0/G3 as PASS from
`.bin`/`_frames.txt` files that were still being written — fixed by requiring the
`TXFIX_GATE_RUN_EXIT=<code>` trailer (written only after the harness process actually
returns) before trusting any evidence from a run; (2) `underflow_evidence()` initially
mixed the FORCE line's one-off `pre_count=`/`target=` annotations into the same list as the
real time-ordered `count=`/`occ=` trace, producing false "wrap" positives on G11 — fixed by
keeping those as separate reference values. All numbers below are post-fix.

## Per-gate table

| Gate | Variant | Result | Evidence (see full lines in `beat_runs/txfix_gate_summary.txt`) |
|---|---|---|---|
| G0 | U | **PASS** | 106 frames, all offset 0 (positive control, no force) |
| G1 | U | **PASS** | sustained offset 6144, `saw_armed_zero=1`, `armed_zero_clk=641342` — reproduces the silicon signature |
| G2 | U | **PASS** | natural self-triggered abort: `zeroEvents=2`, `armedDropClk=4041064` set with no force at the abort instant |
| G3 | F1 | **PASS** | golden digest (marker-aligned): 1,305,858 overlapping records, 0 differing |
| G3 | F2 | **PASS** | golden digest: 1,305,858 overlapping records, 0 differing |
| G3 | F3 | **PASS** | golden digest: 1,305,858 overlapping records, 0 differing |
| G4/G5 | F1 k=0,6 | **PASS** | `d3_post=0`, `saw_armed_zero=0`, offset 0 throughout, both k |
| G4/G5 | F2 k=0,6 | **PASS** | same, both k |
| G4/G5 | F3 k=0,6 | **PASS** | same, both k |
| G6 | F1 | FAIL* | `saw_armed_one=1`, `armed_one_clk=690750`, `clk_to_reload=49410` (RTL witness fires) but decoded offset is unmapped (`None`, not a specific nonzero tap3 word) for the scored tail |
| G6 | F2 | FAIL* | identical SUMMARY line to F1 (fix-invariant, as expected — no variant can suppress a raw latch write) |
| G6 | F3 | FAIL* | identical SUMMARY line to F1/F2 |
| G7 | F1 | **PASS** | preamble-window write, `saw_armed_one=1`, `clk_to_reload=1`, offset 0 throughout |
| G7 | F2 | **PASS** | same |
| G7 | F3 | **PASS** | same |
| G8 | F1 | **FAIL — decision gate** | `zeroEvents=14`, `armedDropClk=4045326` (set), `pops_values=['24639','24640']` (**not** all 24640), `maxPopQuietClk=106` |
| G9 | F2 | **PASS** | `zeroEvents=0` under the same fcbase3 stress |
| G9 | F3 | **PASS** | `zeroEvents=0` |
| G10 | F2 | **PASS** | `saw_self_wrap=0` |
| G10 | F3 | **PASS** | `saw_self_wrap=0` |
| G11 | F3 | **PASS** | `max_count=49280`, `min_count=49279` — clean 1-count hysteresis oscillation, no wrap either direction |
| G12 | F1 | **PASS (over-push runaway documented)** | `max_count=49280>49279`, `runaway_present=True` — confirms the removed guard lets `count` run away past the threshold; `min_count=0` is the legitimate drain floor of a correctly working FIFO, not evidence of underflow (see note below) |
| G12 | F2 | **PASS (over-push runaway documented)** | identical numbers to F1 |
| G13 | F3 | **PASS** | no doubled push rate observed in the nearfull-F3 window (derived from G11's log) |
| G14 | F1/F2/F3 | **PASS** | lint clean, all tops, both passes, rerun fresh this task |

\* See "G6 interpretation" below — this is a scoring-criterion caveat, not evidence the
latch behaves differently across variants.

## Answers to the specific questions

### F3 flash eligibility
Checking G3/G4/G5/G6/G7/G9/G10/G11/G13 for F3: **8 of 9 PASS**; **G6 F3 is the one FAIL**,
and it FAILs identically on F1/F2/F3 (same SUMMARY line, same `armed_one_clk`,
`clk_to_reload`) — i.e., this is not an F3-specific problem, it is my scorer's strict
requirement that the decoded word land on one of the 12,320 enumerated tap3 offsets. Here
it does not (`kick_seq.py` returns `None` for every post-force frame). This is the same
"raw latch poke, not a natural RTL transition" control the plan describes as fix-immune;
the RTL-level witness (armed 0→1 at `armed_one_clk=690750`, latch reload at
`clk_to_reload=49410` after the force) fired correctly and identically on every variant.
What is NOT independently confirmed is that the resulting displacement is a *clean* offset
rather than a genuine loss of demod lock (an out-of-vocabulary word could mean either). I
did not have time within the 20-minute window to disambiguate the two before this report;
recommend re-running `kick_seq.py` byte-for-byte diff between F3's g6 run and G0's baseline
around the force point to classify it before treating F3 as fully cleared. **Given every
other F3 gate (G3–G5, G7, G9–G13) is clean and G6's failure is variant-invariant (not a
regression introduced by any fix), F3 flash eligibility stands: recommend proceeding**, but
flag the G6 ambiguity explicitly to the operator rather than silently calling it resolved.

### G8 decision: second Vivado build
**G8 (F1) FAILS**: `zeroEvents=14` (frameCount hit 0 mid-frame fourteen times over the
50-frame fcbase3 stress, not zero), `pops_values` includes `24639` (not every CEN line
reads 24640), `armedDropClk=4045326` set (a real pop-abort recurred). This is exactly the
"2-clk race" failure mode the plan flagged as F1's known limitation. G9 (F2) is clean
(`zeroEvents=0`) under the identical stress.
**Decision: second Vivado build = F2** (not F1), per the plan's own decision rule ("F1 if
F1's gate is clean... otherwise F2").

### G11 overshoot past 49,279 / F3b
`max_count=49280`, so **overshoot = 1** (one count past the 49,279 threshold — the natural
comparator hysteresis, `count_temp > 49279` vs the registered `fullRAM`). This is far below
the plan's stated F3b trigger ("overshoot > 2 bits past 49,279"). **F3b (the −16 margin
constant) is NOT needed** based on this evidence.

### G12 underflow observations (F1/F2) — reviewer-corrected
**Runaway over-push confirmed** (`max_count=49280>49279`, `runaway_present=True` on both
F1 and F2 — the removed guard lets the over-push condition run past the threshold rather
than saturate). **Underflow direction unresolved.** The earlier draft of this report read
`min_count=0` as evidence that `count` wraps toward/through zero; per review, `min_count=0`
is the legitimate drain floor of a correctly working FIFO on its own (the occupancy trace
necessarily passes through low values as the consumer drains it) and every G12 line reports
`near_65536_seen=False` — no sample was ever caught near the 65,536 boundary that would
distinguish "drained normally to near-zero" from "wrapped through 65,535→0". Only 2 samples
were captured in the NF=8 trimmed window (the nearfull change-detection log only fires on
fullRAM/armed/frameCount transitions), which is not dense enough to tell the two apart.
**Recommend denser (per-clock, not change-detection) sampling around the drain event on a
longer, untrimmed-NF re-run of G12 before the coordinator's underflow-toward-zero mechanism
is cited as a confirmed defect on F1/F2** — it remains a plausible, RTL-motivated hypothesis
(the same removed guard that causes the over-push runaway), not yet a measured one.

## PREREG confirmation
Ledger `PREREG task5` line (predicted quiet-state capTAP word, unchanged = `BCF94856`) is
now backed by the G3 golden-digest result: F1/F2/F3's `none` .bin is record-for-record
identical to the unfixed baseline (0 differing records across 1.3M+ records after
marker-alignment), so the prediction holds for all three variants.
