# Task 12 — R4: pre-filled ring + lock-armed skip-only steering (sim cut + gate), the shippable form of R3S

## Why (read task-11-report.md first, then task-7-report.md)
R3S proved the mechanism on non-repeating content [sim]: with one skipped pop per inter-frame guard band whenever occupancy ≤ 1, the ring is lifted off the EMPTY edge (occupancy 1/2, pop_on_empty = 0 on every frame after arming) and the loss falls from 10.93 % → 0.95 % at −10 ppm, 78.1 % → 4.5 % at −40 ppm, 22.0 % → 1.9 % on the tiled control. EVERY residual loss is either the unexplained seq 133/134 pair (present in baseline too) or the frames straddling the ONE hole that R3S needs in order to arm (its arming = the first post-lock pop_on_empty). R3S cannot arm on lock alone because at 0 ppm the ring settles at occupancy 1 on the TGEN stream (and at 31 on the −2.5 ppm stream): a bare occ ≤ 1 predicate would skip every frame at 0 ppm and fill the ring.

## R4 = define the operating point, then steer from lock
1. **Pre-fill to mid-ring**: after reset, suppress pops until occupancy has reached 16 once (sticky `prefilled` flag); thereafter pops are the baseline expression. Effect: +16 symbols of latency (constant), and the steady-state occupancy is ~16 regardless of the acquisition transient. This replaces "arm on the first hole".
2. **Steering armed by `prefilled` (i.e. from lock)**, skip-only as in R3S: in each guard band (same window definition as R3S), if occupancy ≤ 8, skip exactly one nominal pop (r4_skips witness); at most one per frame. At 0 ppm occupancy stays ~16 → never fires. At −10 ppm the ring drains 16 → 8 over ~65 frames, then one skip per 8.1 frames holds it at 8/9; the EMPTY edge is never reached, so there is no arming hole and no straddling-frame loss.
3. Nothing on the FULL side (reverse-leg problem, separate task); no extra pops anywhere.
4. Witnesses: r4_prefilled, r4_skips, plus the existing rh_pop_on_empty / push_on_full and occupancy taps. No new IP port (structural insertion as R3/R3S). Marker RXFIX_R4; R3S untouched; mutual exclusion with R3/R3S/W1 handled in the injector (W1 must remain COMBINABLE with R4 — check that the W1 and R4 anchors do not collide; if they do, make R4 anchor on the W1-injected text as well and add a test for the combined application, because Task 13 builds W1+R4).
5. Tests: TestR4 class (exactly-once anchors both lineages, idempotency, --sim-tree/zip shapes, mutual exclusion, W1+R4 combined application); verilator --lint-only both lineages, logs banked as two_jup/comb/sro_sim/r4_lint_<tree>.log.

## Gate (pre-register in two_jup/comb/RXFIX_R4_SIM_GATE.md before running; same harness/stimuli/scorers as Task 11; object dir obj_byte_sro_rxfix4; wrapper file wrap_byte_sro4.v with the WRAP4_FILE/DEFINE provenance print)
- n_p000: CONTENT-identical delivered stream to b_p000 (every frame's nwords/FNV/user flag equal; sidx may differ by the constant pre-fill latency — state the measured constant), r4_skips = 0, occupancy after acquisition in [14, 18].
- n_m10: LOSS ≤ 0.5 % and the only losses allowed are seq 133/134; r4_skips ≈ 21 (band 15–35) all within ≤ 60 slots of the epoch boundary; pop_on_empty in the scored window = 0.
- n_m40: LOSS ≤ 1 %; r4_skips ≈ 211 (band 150–260); pop_on_empty in the scored window = 0.
- s_m10 (tiled): LOSS = 0.00 %.
- n_p10 (NEW: generate n_p10.iq at +10 ppm from tx432.iq with gen_sro_stim.py --no-tile; ~130 frames to the FULL edge): report only — expected push_on_full deletions after the edge with ~2 frames lost per event; this documents the reverse-leg problem R4 does not address. Not a pass/fail condition.
- Falsifier: n_m10 loses frames at the skips (losses aligned to r4_skips) → position of the skip matters after all → per-stage stagewin dump around one skip, as Task 11 did.

## Rails
Sim only; no board contact; do not modify Task 10/11/9b files or live units; add new files; commit early and often (rxfix_inject.py is shared — rebase on conflicts, never force). Heartbeat unit t12hb (`HEARTBEAT task12 <ISO> <state>`, ≤ 5 min); ledger `Task 12:`; commit -s + trailer `Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq`; commit implies push; labels; no background sleep polls or Monitor loops — end your turn while legs run; report two_jup/sdd_archive/2026-09-04-rxfix/task-12-report.md; return status/commits/one-line summary/concerns. No subagents.
