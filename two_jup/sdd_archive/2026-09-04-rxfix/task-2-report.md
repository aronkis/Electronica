# Task 2 (T0b) report — docs correction + SRO sign cross-check

Commit: 4f1144b (per-under-1pct-2026-07), signed off, trailer included.

Applied "[correction 2026-09-04, RATE_HANDLE_FIX_SURVEY.md]"-labelled corrections
(guarded ring: empty edge skips a slot, only full edge deletes) to:
- two_jup/comb/COMB32_RTL_HUNT.md (bottom-line-up-front, §1a row A1/A2, §2 #1)
- two_jup/comb/COMB32_SRO_SIM_2p5.md (VERDICT mechanism paragraph; period/loss
  numbers kept, sim's occupancy-metric blindness to 0-vs-32 noted, deleting stage
  handed to Task 1)
- two_jup/OVERNIGHT_20260904_SEQBIST.md (item 5, 06:3x line — added CORRECTION
  blockquotes, did not rewrite history)
- two_jup/COMB_STATE.md (05:2x entry — added CORRECTION blockquote)

two_jup/NEXT_STEPS.md top block: replaced "ROOT CAUSE CONFIRMED IN SIM 06:3x ...
unguarded ... deletes a symbol at its edge" with the corrected mechanism wording
and a pointer to two_jup/RXFIX_STATE.md + the RXFIX ledger.

New two_jup/RXFIX_STATE.md, "Sign cross-check [inferred]" section (full page,
every step labelled [silicon]/[inferred]):
- [silicon] bringup_r2r3.sh:15 — 148 RX LO plain at 2.0 GHz, residual -5.15 kHz.
- [inferred] -> 148's XO runs ~2.575 ppm FAST relative to 146's.
- [inferred] Forward leg (148 RX): SRO ~ -2.575 ppm, ring trends EMPTY (benign
  edge). Reverse leg (146 RX): SRO ~ +2.575 ppm, ring trends FULL (lossy edge),
  per gen_sro_stim.py:72-73's sign convention.
- Sim: -2.5 ppm lost 4.1%, +2.5 ppm lost 0% (one-sided).
- Silicon: BOTH legs lose (fwd 8.1-8.4%, rev 3.7%) — does NOT match a one-sided
  Rate_Handle-only mechanism, and the emphasis is backwards (the nominally
  benign-edge forward leg loses more).
- Verdict: a one-sided mechanism is incomplete; points at the Preamble_Detector
  realignment FIFO (chronically pinned at its own full mark, sign-agnostic) as
  the stronger candidate for explaining loss on both legs, pending Task 1.

Memory updated: residual-loss-localised-fabric-rf.md's "ROOT CAUSE CONFIRMED ...
unguarded ring ... deletes a symbol at its edge" replaced with the guarded-ring
correction + re-localisation pointer (fixctl bit 3 / 0x208 noted); MEMORY.md
index line for that file updated to match. Both outside the repo, not committed.

No board contact, no subagents used, no push.
