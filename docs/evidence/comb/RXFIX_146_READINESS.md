> Evidence ledger, moved verbatim from `two_jup/comb/RXFIX_146_READINESS.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# 146 witness-first readiness (2026-09-05 10:45, read-only check for the operator)

## 1. Is the W1-only witness image built and banked?
YES — it is a real, built bitstream, not a plan. It is the 148-lineage W1 image that Task 9 built and Task 10 flashed and judged on 148 (09-04 16:40–17:30):
- `boot_known_good/BOOT.BIN.148.rxfixw1.2728dab3979a` (built 09-04 16:19), md5 `2728dab3979a54616f1ad67f1ac8e8a7`
- `boot_known_good/BOOT.BIN.146.w1x148.2728dab3979a` (byte copy made 09-05 08:17 for the 146 chain's naming rule), md5 identical `2728dab3979a54616f1ad67f1ac8e8a7`
Contents: txfixF3 + SEQ-BIST judge + W1 (eight AXI read words 0x214..0x230), NO steering. The combined fix image `BOOT.BIN.146.rxfixr4dr1.9acbe2ebe1db` (md5 `9acbe2ebe1dbf280e030952fc4fc23d8`) is a separate banked bitstream. Both are 148-lineage images; 146's own lineage (vendh) has no W1. So witness-first costs one extra flash cycle, nothing else.

## 2. Positive controls per tap (Task 10 Step 2, run 20260904_164756_w1_ctrl, all on silicon on the same image)
| tap | positive control | null | where it can be validated |
|---|---|---|---|
| freeze path (fixctl bit 4, write-only 0x208) | hold 10 s: all eight words identical across two sweeps (aux_lag 10.049 s); release: they advance | — | silicon (done) + sim |
| census cSS, cRH, cCFC, cCS, cPD | advance ~1.68e8 per 10 s in loopback = 12,333 × frames, five stages within ±1 (phase jitter) | freeze holds them at 0 | silicon (done) + sim (word = harness tap, 0 mismatches over 10.5 M beats) |
| census cPC | advances at 12,320/frame (the 13-slot guard drop by design), matched to −1/+10 | freeze | silicon (done) + sim |
| witA occupancy | nonzero, constant 1 in steady loopback (matches the 09-02 sel15 pinning) and moves across an arm | — | silicon (done) + sim |
| witA pointers | 6 distinct (push,pop) pairs advancing mod 32 | — | silicon (done) + sim |
| pop_on_empty | ARM-TRANSIENT control: cleared by the arm's soft reset, then +34 in the first frames (sim predicted 34); 10 and 44 on two arms | delta 0 in steady loopback | silicon (done) + sim |
| push_on_full | NONE ON SILICON — it has never fired on any board; its only positive control is sim (b_p10: 21 events at the FULL edge; W1 word = harness tap) | delta 0 in loopback | **sim only; on silicon it can only be exercised by the defect itself (a FULL-trending link)** |
| stuck-at sweep | every word differs between at least two reads | — | silicon (done) |
| AXI decode 0x214..0x230 | first board read returned structured, varying values (not const_0) | — | silicon (done) |
Caveat carried into the 146 witness leg: a zero push_on_full on 146 is ambiguous between "no FULL event" and "counter dead" (Task 9 concern 2); the pre-registered branch table treats it as branch (a) = not credited as a null, and the same leg's occupancy word (31/32 pinned vs 0–1) decides which edge the ring is on independently of the counter.

## 3. Did W1 clear routed timing? Any lite variant?
Final routed WNS of the W1 image (Task 9, unit txfix-build-rxfixw1_build-1788544650): **+0.071224 ns, TNS 0, 0 failing endpoints of 342,217**, "All user specified timing constraints are met". The −0.317 (global iteration 0) and −0.598 (iteration 1) were router transients before the explore-strategy post-route optimisation; the SEQ-BIST build had gone negative mid-route in the same way. Modem-clock intra-clock routed WNS 0.169 ns (SEQ-BIST 0.227, R4B 0.437, R4D+R1 0.620); the overall WNS is the vendor IDELAYCTRL recovery path, not a modem path; no W1 net appears on any reported path (RXFIX_W1_TIMING.md).
**No lite variant was built.** W1L (registered read path / reduced census) was prepared as insurance (Task 9b) and cancelled when W1 closed; no counter was dropped, so no positive control was lost. The flashed W1 image on 148 today is the full eight-word instrument.

## 4. The prediction and its arithmetic, and what it becomes on 146
Frame = 12,333 symbol slots (13 preamble + 12,320 data). Rate_Handle pops rigidly every 4th receive sample; the symbol-sync strobe (push) follows the true symbol rate. With the receiver's sample clock fast by s ppm, pushes lag pops by s ppm, so the 32-entry ring drains 12,333 × s entries per frame:
- s = 2.575 ppm (148's XO vs 146's, from the −5.15 kHz RX-LO residual at 2.0 GHz) → 0.0318 entries/frame → one edge event per 31.5 frames; at 2.5 ppm → 32.4 frames; × 802.93 µs/frame → 25.3–26.0 ms. Measured on 148 (Task 10): 394 pop_on_empty per 10 s = one per 25.38 ms, and the PER comb period 25.39 ms.
**146 (reverse leg):** the clock offset is symmetric, so the SAME magnitude applies with the opposite sign — the ring FILLS at 0.0318 entries/frame and the natural event is a push_on_full DELETION once per ~31.5 frames = 25.4 ms ≈ 394 per 10 s. But the reverse comb measured this morning is one event per **25.39 frames = 20.39 ms** (a lag-25 family, no mod-32 line). Those two numbers are different (25.4 vs 20.4 ms), so the witness leg is a discriminating test, pre-registered in RXFIX_NIGHT2_PREREG.md §5/§5.1:
- (W) occupancy pinned 30–32 and push_on_full advancing at ~394/10 s whose mean interval matches the leg's own comb period within 2 % → the ring's FULL edge IS the reverse comb (then the 20.4 vs 25.4 ms discrepancy must be explained by the leg's own rate, e.g. a different effective drift on 146);
- push_on_full at ~394/10 s (25.4 ms) while the losses run at 20.4 ms → TWO processes: the ring deletes symbols but is NOT the dominant reverse comb;
- (a) occupancy 31/32 with push_on_full 0 → counter not exercised/dead; (b) occupancy 0–1 with pop_on_empty ~394/10 s → the sign model is wrong, 146 is EMPTY-trending (fix = R4B); (c) neither edge → the reverse loss is not the ring.
The prediction is therefore NOT the same as 148's: the ring's edge rate should be ~394/10 s on both boards, and the open question is whether that equals the comb 146 actually shows.

## 5. 146's restore point and flash history
- Restore point: `boot_known_good/BOOT.BIN.146.seqbist.3378861d30bd`, md5 `3378861d30bd3d85663b31cfdd9c6296` — the image on 146 now (readback 09-05 08:30). Second-level rollback `BOOT.BIN.146.txfixF3vendh.6b4744ca73f8` (146's own lineage), on-board .bak from the 09-04 flash.
- 146 HAS been through the 146 flash chain once in this campaign family: 2026-09-04 03:28–03:35 (SEQ-BIST Task 8, unit t8-flash146, seqbist 3378861d30bd over vendh 6b4744ca73f8, DRY chain pass then real chain, both-board bring-up, credited). Since then untouched (no flash in the RXFIX campaign; uptime continuous). So the rails have been exercised on this board once, with the same chain.
- The chain (two_jup/skidfix/flash_146_txfix.sh via txfix_flash146_go.sh): A0 gate = the nemo rollback bank file must BE the rollback image (md5-checked); pre-flash liveness check of 148 (the gate instrument); the on-board `/root/BOOT.BIN.<bak>.bak` is CREATED and re-verified, not assumed; staged copy + md5 verify; reboot; readback verify; full both-board bring-up (re-arms 148 as a side effect); NAK=4 re-check; reset-aware two-pass health gate; rollback on any failure; NO retry loop. The DRY=1 run of exactly this command passed end to end this morning with the real A0 gate satisfied.

## 6. Board time (this session: 6 of 8 captures wedge-flagged, ~2 attempts per credited leg)
- Witness-first: flash + post-flash + loopback controls ≈ 20 min; reverse witness leg 10 min × ~2 attempts ≈ 25 min → **~45–50 min** to the mechanism answer. Then the fix: flash + controls ≈ 20 min; reverse after-leg ×2 ≈ 25–50 min; hand-back ≈ 10 min → **~55–80 min**. Total ≈ **1 h 40 – 2 h 10**.
- Fix-first: **~55–80 min** to a PER answer with the witnesses read on the same leg; if the extras rate lands in the pre-registered ambiguous band (368–453 per 10 s) or PER does not move, the W1-only witness leg is still needed afterwards (+45–50 min), i.e. the same total in the worst case.
- Witness-first therefore costs ~50 min more in the good case and nothing in the bad case, and it is the only ordering that yields an unsteered FULL-edge measurement (push_on_full's first-ever silicon exercise) — the mechanism proof you are asking for.
