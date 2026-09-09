# Task 2 (T0b) review — docs correction + SRO sign cross-check

**Verdict: PASS.** No Critical or Important findings. Commit 4f1144b's corrections and
sign cross-check are accurate, dated, non-destructive, and appropriately hedged.

## Checked

1. **Guarded-ring corrections in the four documents** — all present, dated
   `[correction 2026-09-04, RATE_HANDLE_FIX_SURVEY.md]`, state the facts correctly
   (empty edge suppresses a pop only — no loss; full edge suppresses a push — deletes),
   and are additive blockquotes, not rewrites of the original text:
   - `two_jup/comb/COMB32_RTL_HUNT.md:15,98,99,152-153` — bottom-line-up-front + §1a
     rows A1/A2 + §2 #1.
   - `two_jup/comb/COMB32_SRO_SIM_2p5.md` VERDICT — also correctly flags the harness
     ambiguity (`sim_sro.cpp:115`'s `(pushPtr−popPtr)&31` cannot distinguish occupancy
     0 from 32), matching the task brief.
   - `two_jup/OVERNIGHT_20260904_SEQBIST.md:19-27,196-207` — item 5, blockquote added,
     original 06:3x text retained below it.
   - `two_jup/COMB_STATE.md` (05:2x entry) — blockquote added, same pattern.
   - `two_jup/NEXT_STEPS.md` top block — "ROOT CAUSE CONFIRMED ... unguarded" replaced
     with the corrected wording and a pointer to `RXFIX_STATE.md`/the RXFIX ledger.
   None of the five overstates a new "root cause" — all defer deleting-stage
   localisation to Task 1, consistent with `RATE_HANDLE_FIX_SURVEY.md` §0.

2. **Sign cross-check arithmetic** (`two_jup/RXFIX_STATE.md`) — verified against primary
   sources, no sign error:
   - `bringup_r2r3.sh:15` (comment) states 148 RX LO plain at 2.0 GHz, residual −5.15 kHz;
     confirmed the forward-leg direction (146 TX → 148 RX) from `:122` ("B = ... reverse
     dir, 148→146" ⇒ forward is 146→148) and from `:55/:58` (`LO_B_TX=2000000000` on 146,
     `LO_A_RX` nominal 2.0 GHz on 148).
   - `residual = 2.0e9×(ppm_146−ppm_148) = −5150 Hz ⇒ ppm_146−ppm_148 = −2.575 ppm ⇒
     148 fast by 2.575 ppm` — arithmetic checks (−5150/2e9 = −2.575e-6). The
     receiver-frame convention (residual = actual-carrier minus local-LO) is not
     independently documented elsewhere in the repo, but the doc labels this step
     `[inferred]` and shows its work, so this is a transparent assumption, not a hidden
     one.
   - Sign-to-edge mapping checked against `gen_sro_stim.py:72-73`
     (`t = n*(1+s)`, `i=floor(t)`): negative `s` ⇒ source position advances slower than
     the local index ⇒ pop (fast local clock) outruns push (slow source) ⇒ ring drains
     toward EMPTY. Forward leg (148 RX, local clock fast by +2.575 ppm relative to the
     146-referenced incoming stream) ⇒ `s≈−2.575 ppm` ⇒ EMPTY-trending — matches the
     doc's claim and matches `COMB32_SRO_SIM_2p5.md`'s own `q_m2p5` leg (occupancy 5→0,
     i.e. toward empty, at `s=−2.5 ppm`). Reverse leg (146 RX, local clock slow) ⇒
     `s≈+2.575 ppm` ⇒ FULL-trending, matching `q_p2p5` (occupancy 5→18, away from the
     edge it must cross to reach FULL). Internally consistent across
     `RXFIX_STATE.md`, `COMB32_SRO_SIM_2p5.md`, and `gen_sro_stim.py`.
   - Silicon-vs-sim mismatch (both legs lose on air; sim predicts loss at one sign only)
     is stated plainly and used only to motivate re-localisation toward the
     Preamble_Detector FIFO as a candidate — not asserted as confirmed.

3. **Memory notes** — `residual-loss-localised-fabric-rf.md` and the `MEMORY.md` index
   line both carry the same guarded-ring correction, both explicitly retract the
   "SRO ≤ 0.06 ppm" bound (calling it "wrong"/counted post-deletion symbols) rather
   than leaving it standing beside "2.5 ppm" — no contradiction found.

## Minor (non-blocking)
- `CLOCK_OFFSET_OPTIONS.md`'s independent `exp_forward.sh:25` figure (~3.15 ppm) differs
  from the 2.575 ppm used in the sign cross-check; the document itself labels it
  "older" and lists it alongside the 2.51-2.57 ppm cluster it does not match as closely
  — already flagged as a table entry, not a claim needing correction here.
