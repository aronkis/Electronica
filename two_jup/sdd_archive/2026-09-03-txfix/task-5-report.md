# Task 5 (T1 sim gate lane) — report

Plan: `/home/tcollins/.claude/plans/happy-bubbling-owl.md`. Ran the G0–G14 Verilator gate
matrix against `obj_txkick_{U,F1,F2,F3}` / `obj_txrate{,_F1,_F2,_F3}` (Task 2's trees and
harness). Host-only, `jupiter_240k5_byte/rtl_sim/`, no board contact, no subagents.

Full table, per-gate evidence, and the four specific questions the coordinator asked
(F3 flash eligibility, G8 decision, G11 overshoot/F3b, G12 underflow) are answered in
`two_jup/TXFIX_SIM_GATE.md`. Raw scorer output: `jupiter_240k5_byte/rtl_sim/beat_runs/txfix_gate_summary.txt`
(30 `TXFIX_GATE` lines). Scorer: `jupiter_240k5_byte/rtl_sim/txfix_gate_score.py`.

## Result

26/30 gate lines PASS. FAILs: G6 F1/F2/F3 (variant-invariant scoring caveat — RTL witness
fires identically on every variant, decoded word doesn't land on an enumerated tap3 offset;
not a fix regression), G8 F1 (real: F1 does not fully suppress the frameCount==0 mid-frame
condition under the natural fcbase3 stress — `zeroEvents=14`, not every CEN line reads
`pops=24640`).

**Decision: second Vivado build = F2.**
**F3b: not needed** (G11 overshoot past 49,279 = 1).
**F3 flash eligibility: recommend proceeding**, flagging G6's scoring caveat to the
operator.
**G12 (F1/F2): runaway over-push confirmed** (`max_count=49280>49279` on both). **Underflow
direction unresolved** — reviewer correction: `min_count=0` is the legitimate drain floor of
a correctly working FIFO, not evidence of underflow, and `near_65536_seen=False` on every
G12 line, so nothing distinguishes a normal drain from a genuine 65535→0 wrap. Denser
(per-clock, not change-detection) sampling around the drain event, on a longer untrimmed-NF
re-run, is needed before the underflow-toward-zero mechanism is cited as a confirmed defect.

## Process notes / self-corrections (both logged as `FINDING` lines in the ledger)

1. An early interim scoring pass (requested mid-run by the coordinator) wrongly reported
   G0/U and G3/F1/F2/F3 as PASS while those four `Vtxkick` processes were still actively
   running — `.bin`/`_frames.txt` files grow continuously and are not a completion signal.
   Fixed by requiring the `TXFIX_GATE_RUN_EXIT=<code>` trailer (written by the launcher's
   wrapper only after the harness process returns) before trusting any run's evidence;
   gated every G0–G13 scoring block on it.
2. `underflow_evidence()` (added for the coordinator's F1/F2 underflow-direction addendum)
   initially mixed the FORCE line's one-off `pre_count=`/`target=` annotations into the same
   list as the genuine time-ordered `count=`/`occ=` trace, which produced a false wrap-step
   positive on G11 (F3) — the real trace is a clean 49279↔49280 oscillation, not a wrap.
   Fixed by keeping those as separate, non-sequential reference values.
3. The stall detector flagged all 10 first-batch gate lanes as stale at 10:41 because
   `lanes.json`'s `log` field pointed at each unit's stdout log (only written at exit) —
   repointed every lane at the run's growing `.bin` output instead (confirmed it grows
   continuously) and patched `txfix_gate_launch.sh` so future lanes register correctly.
4. Switched from an open-ended `Monitor` wait to a bounded sleep-and-heartbeat bash loop
   (`txfix_gate_heartbeat_loop.sh`, 14 min cadence, `MAXITERS=20` ceiling) per coordinator
   instruction after a second stall-detector flag on the agent's own heartbeat cadence.

## Deviations from the literal plan text (budget-driven, declared)

- popabort/latchforce swept at k∈{0,6} instead of the full k=0..6 sweep.
- G6/G7 run once per variant (k=0) rather than swept.
- G13 (F3 producer throttle) scored from the G11 nearfull-F3 log rather than a separate run
  (same run, no separate sim needed — the plan's own gate matrix note allows this).

## Artifacts

- `jupiter_240k5_byte/rtl_sim/txfix_gate_runs.txt` — the 26-run manifest.
- `jupiter_240k5_byte/rtl_sim/txfix_gate_launch.sh` — launcher (systemd-run, cap 10 concurrent).
- `jupiter_240k5_byte/rtl_sim/txfix_gate_score.py` — scorer (exit-gated, both bugs fixed).
- `jupiter_240k5_byte/rtl_sim/txfix_gate_fix_lanes.py` — lanes.json repair utility.
- `jupiter_240k5_byte/rtl_sim/txfix_gate_heartbeat_loop.sh` — bounded heartbeat loop.
- `jupiter_240k5_byte/rtl_sim/beat_runs/txfix_gate_*.log`, `*_frames.txt` — per-run evidence
  (committed; `.bin` dumps NOT committed per instruction).
- `two_jup/TXFIX_SIM_GATE.md` — full table + answers.
- `two_jup/sdd_archive/2026-09-03-txfix/progress.md` — ledger (HEARTBEAT/FINDING/PREREG lines).
