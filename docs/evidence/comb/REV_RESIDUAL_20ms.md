> Evidence ledger, moved verbatim from `two_jup/comb/REV_RESIDUAL_20ms.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# The reverse residual: the 20.38 ms comb — class, arithmetic, Task 30's result, and the one rig test left

**RXFIX Task 34 (fix round 2). Desk task — NO BOARD CONTACT by this desk.** Every number is
from files already banked under `two_jup/comb/runs/`, from the ledger
(`two_jup/sdd_archive/2026-09-04-rxfix/progress.md`) or from source in this tree; the
commands are in §12. Labels: **[silicon]** = measured on a capture from the rig or read from a
board by the controller; **[inferred]** = arithmetic or a source-code fact not measured on a
board; **[not in repo]** = a fact this desk could not establish.

Fix round 1 folds in: the reviewer's eight findings (ledger `Ruling (controller, 16:37)`),
Task 30's result (ledger `Task 30: SCORED`, §8), the DisplayPort finding (ledger `Task 36:
PREREG`, §10) and the witness the first pass omitted — 146's own TX log (§2b). Where the
first pass was wrong the correction is stated in place, not silently overwritten.

Fix round 3 (2026-09-06, desk only) closes the completeness critic's findings on this file: §0's
withdrawal of the "4 of 39,039–116,482" figure is **re-scoped** (the number is real; air2 is the
forward control), leg 3b's slot denominator gets the same tool off-by-one note the P-C leg has,
summary line 6's [silicon] label is split so "boot-seeded" reads [inferred], §8's deliver-rate
figures are marked as gate readings rather than frame rates, and §8 records what the P-C poke did to
the *far* receiver (`ATARM_CLASS.md` §5.1). No conclusion in this document moves.

Fix round 2 closes the second review's findings (ledger `Ruling (controller, 20:18)`): the §2b
"slip / delay" sentences now carry the numbers the data give (a late submit is one frame ≈ 0.8 ms
late, never > 1.7 ms; the 5.5 ms is a lag from the loss's *processing* stamp), the P-C leg quotes
the `accept_analyze.py` scoring the controller re-ran from its real path (§8) and states why every
tool labels that leg `[WEDGE truncated]` while it is credited as clean, the 148 piggy witness is
quoted as +5 (9 → 14), and four labels/citations are corrected in place (AGC field scope, `CONFIG_HZ`
provenance, "146 owns it" as [inferred], the forward-control sensitivity floor). The fix-2 numbers
come from `two_jup/comb/rev20ms_fix2_checks.py` (banked as `t34_evidence/t34_fix2_checks.json`).

## Summary (6 lines)

1. **Class: 146 receive chain, at or upstream of 146's RX byte pins — a 146-local scheduled process; not the ring, not 146's host/DMA, not 148's TX host, not RF level, not 146's host timing.** [silicon] 100 % of lost frames were submitted by 148 (NEVER_SENT = 0 / 8,481, 0 / 11,541 and 0 / 15,644 on the P-C leg); 146's fabric seam checker sees 0.88–0.97 of the host's lost slots already bad at the pins on all four fix-image legs (r = 0.99 / 0.90 / 0.86 / 0.91 per 10 s); 148's TX log has no 20 ms cadence (R = 0.04, null 0.09). 146's own TX log *does* carry the cadence (R 0.38–0.47) but as a **reaction**: 98–99.5 % of its late submits follow an individual lost frame within 3–10 ms (§2b) — it is the daemon echoing the loss, not a witness of the actor.
2. **The event is a demod-level destroyed frame, 1–2 frames long, not a byte displacement.** [silicon] 91 % of comb frames reach the host as full-length garbage with no frame magic anywhere (class 1, `magic_off = none`); singles and doubles are both phase-locked (R 0.73 / 0.77); the k×192-byte displacement cascades (runs ≥ 3, CRC-seeded, ≈ 0.4 /s) are present on 146 too but are **not** on the comb (R 0.04) — the forward residual's class, as a separate 0.1 pp.
3. **One phase, a 6.5 ms window every 20.382 ms.** [silicon] Loss-onset phase histogram FWHM = 16/50 bins = **6.52 ms on both judge legs** (≈ 5.7 ms after removing one frame of quantisation), peak/floor contrast 24× / 33×; the comb carries 88 % / 91 % of the residual; the off-comb floor is 1.0 onsets/s ≈ 0.11 % PER.
4. **The period is a clock [silicon]; that 146 owns it is an inference [inferred].** [silicon] 20.38226 ms = 25.38486 frames; identical to 2.4 ppm on four legs of one boot spanning 2 h 10 min (judge1, judge2, judge3b, Task 30: 25.38486 / 25.38483 / 25.38483 / 25.38480), sub-cycle phase drift < 0.03 cycle over 719 s, identical on 148's own CLOCK_MONOTONIC to < 1 ppm; it **moved by 204 ppm** at the 146 fix flash + reboot and by 8 ppm at the earlier W1 flash + reboot, and did not move across two full ADRV9002 re-initialisations (judge3b) or across the P-C knob set (Task 30). [inferred, from coincidence] The ownership reading — the period is set at 146's boot, not by the RTL lineage and not by the radio's tracking loops — rests on the pairing of the two 146 flash + reboots with the 204 and 8 ppm steps, of the radio re-inits and the P-C knob set with no step, and on 148 not having been rebooted with its PS-clock / frame-clock ratio constant to < 1 ppm across the legs; no banked number measures which board's clock moved.
5. **Excluded by direct test [silicon, Task 30]: 146's ADRV9002 RX tracking calibrations and its AGC slow loop** (gain control → `spi` at the frozen 34.0 dB, `agc` / `bbdc_rejection` / `rfdc` / `rssi` / `quadrature_fic` tracking → 0, every write read back) — the line is unchanged: P = 25.38480 fr = 20.3822 ms, **R = 0.7004** (P1 needed < 0.05), PER 2.667 % (15,644 / 586,602 by `comb_period_ms.py` / `comb_census.py`; `accept_analyze.py`: 15,644 / 586,601, **CP95UL 2.708 %**, lost frames in the denominator; the leg carries the tools' `[WEDGE truncated]` label for an end-of-file artefact, §8). The first pass's AGC-beat identification (§5.1) is **retired**; it was already in tension with the 204 ppm step. Nothing in the fabric / host / DMA / clock-ratio inventory produces 20.382 ms directly, and whether the line is a **beat** (a 146 cadence at 835.857 µs against 148's 802.930 µs frames) or a **direct** 20.382 ms process with a ~5.7 ms active window is **not decided** by any banked number (§5.1).
6. **What remains: a 146-local scheduled process, owner unnamed.** The one host activity found with every required property — periodic, boot-seeded, 146-only, lineage-independent — is 146's **DisplayPort pipeline** (DPDMA at 120.011 IRQ/s on 146 and 0 ever on 148; 1920×1080 fbcon on a connected monitor; VPLL 890,999,848 Hz) [silicon, read-only probes 19:36–19:41 — those probes measured the IRQ rate, the connector state, the CRTC mode and the VPLL frequency and nothing else]. Its arithmetic does **not** produce 20.382 ms or a 1,196.377 Hz partner on any low harmonic (§10) and the mechanism is **not claimed**; **Task 36** (display unplugged or blanked, DPDMA IRQ rate verified ≈ 0, one reverse leg; P5: R < 0.05 and PER ≤ 0.30 %; P6: R ≥ 0.5) is the test — pre-registered in the ledger at 19:42, not yet run. **"Boot-seeded" is [inferred], not [silicon]:** §10 derives it from the VPLL and the pixel clock being programmed at boot and never by the radio or the daemon, and concedes that the pre-fix boot's VPLL and mode were never read ([not in repo]) — and boot-seeding is the property that pairs with the 204 ppm reboot step, i.e. the reason DP is the candidate at all, so it is labelled where it is load-bearing.

---

## 0. Data and windows

| run | leg | 146 image | 148 image | PER (live) | live window | used for |
|---|---|---|---|---|---|---|
| `20260905_142322_w1_t22_judge1` | B rev (148→146) | W1+R4D+R1 `9acbe2ebe1db` | `9f13705d9fb0` | 0.967 % (8,481 / 876,789) | 15–719 s of 740, wedge-truncated | Q1–Q6, §2b |
| `20260905_143845_w1_t22_judge2` | B rev | same | same | 1.316 % (11,541 / 876,788) | 15–719 s of 740, wedge-truncated | Q1–Q6, §2b |
| `20260905_153825_w1_t29_judge3b` | B rev (Task 29 leg 3b) | same boot | same | 2.825 % (20,514 / 726,090) | 15–598 s | Q2, Q5, §2b |
| `20260905_163044_w1_t30_pc` | B rev, **P-C on 146** (Task 30) | same boot | same | 2.667 % (15,644 / 586,602; `accept_analyze`: / 586,601, CP95UL 2.708 %) | 15–486 s of 493, tool label `[WEDGE truncated]` (end-of-file artefact, no mid-capture wedge; §8) | §8, Q2, Q5, §2b |
| `20260905_105153_w1_t19_witness` | B rev | W1 `2728dab3979a` | same | 4.845 % (42,421 / 875,536) | 15–718 s | Q5, §2b control |
| `20260905_064400_legB_rev_before2` | B rev | vendh `3378861d30bd` | same | 9.644 % (84,437 / 875,535) | 15–718 s | Q1, Q5, §2b control |
| `20260905_075030_w1_air2` | A fwd (146→148) | vendh | same | 0.183 % (1,611 / 879,050) | 15–721 s | negative control |

Axis for every period/phase number: the reconstructed TX-slot axis (`two_jup/comb/common.py:loss_slot_trains`, one slot per 148 `host_seq`, settle 15 s + live-window rule), events = loss-run **onsets**, score = Rayleigh R(P) = |mean exp(2πi·n/P)|, ms conversion by the fabric frame period 12,333 / 15.36 MHz = 802.9297 µs — exactly `comb_period_ms.py`'s contract. The judge legs are wedge-truncated and **credited** under the operative rule (ledger 15:08, line 1108). Two origins are in use for that truncation and they differ: "544 s" is counted from the **traffic start** (`capture_r3.log:36`, `MID_CAPTURE_WEDGE after 544s`, judge1; the wrapper's own clock), while the table's "15–719 s of 740" is counted from the **first `frames.bin` record** (the capture start, `t_mono_ns[0]`), which precedes the traffic start by the bring-up and settle — the two numbers describe the same wedge. Task 30's leg has **no mid-capture wedge** (stall watchdog done, wall 468 / 464 s, `poll_read_failures` 0, no `MID_CAPTURE_WEDGE` line, watchdog relaunches 0 / 0) and is credited (ledger 19:40); every scorer nevertheless prints `[WEDGE truncated]` for it (live 486 / 493 s) — the reason, an end-of-file artefact, is given in §8. The reader windows (`chk.jsonl`, `rssi.jsonl`) lie inside the live windows. **Leg 3b's slot denominator differs by one between the two tools, exactly as on the P-C leg (§8):** `comb_period_ms.py` / `comb_census.py` count **726,090** slots (`slots=726090 lost=20514`, 2.825 %) while the run dir's `accept.txt` reads `PER=2.825% (20514/726089)`, CP95UL 2.864 % — the same off-by-one between the two tools' slot reconstructions, with 20,514 lost in both. The table quotes the comb tools' denominator; `RXFIX_STATE.md` quotes `accept_analyze`'s. Neither number moves the PER.

**`cap/frames_peer.bin` is not usable as a peer-direction control, on every reverse leg** [silicon]. It holds 148's RX of 146's idle frames; the record and `crc_ok` counts per leg (`read_frames`, 48 B records, `t34_txlog_self.json`): judge1 **31,802 / 4**, judge2 **301,305 / 0**, judge3b **34,706 / 4**, Task 30 **207,305 / 0**, T19 **39,039 / 4**, before2 **55,855 / 4**. The 146→148 direction carried no decodable frames during these legs (the idle frames carry a constant sequence word, §2b, so 148's host could not have framed them even if the air were clean). The first pass wrote this as "**4** `crc_ok` records out of 39,039–116,482" for "all reverse legs". Re-measured, the figure is real and the citation is now given: `crc_ok` = 4 on T19 (**39,039** records) and on `20260905_075030_w1_air2` (**116,482** records), the two endpoints of that range. What was wrong is the **scope**, not the number, and the earlier correction ("the upper figure matches none of these files") was itself wrong: **air2 is the LEG=A forward negative control** of the table above, not a reverse leg — on it `frames_peer.bin` is 146's RX of 148's idle frames, the opposite direction — and judge1's 31,802 sits *below* the quoted lower endpoint, so neither endpoint bounds the reverse-leg set. Across the six reverse legs the counts are **31,802–301,305** with `crc_ok` **4 / 0 / 4 / 0 / 4 / 4**, so "4" is not universal either. The sentence is therefore re-scoped, not retracted: the six per-leg pairs above are the reverse-leg statement, and the 39,039–116,482 range belonged to a set that mixed the forward control in. `pair.iq` is 65 ms = 3.2 cycles and was not demodulated.

## 1. Pre-registered expectations, then the measurements

**Provenance, stated honestly.** The expectations in this table were written by this desk into the draft of this file *before* the numbers were computed, but they were **not ledgered first**: no timestamped `progress.md` entry precedes the computations, so the pre-registration rests on the desk's word and the draft's edit order, not on the record (reviewer finding 3). The Task 30 predictions (§8) and the Task 36 predictions (§11) were, by contrast, ledgered by the controller before their legs (`Task 30: PREREG` 16:30:44, before the 16:30:44 launch; `Task 36: PREREG` 19:42, leg not yet run).

| Q | expected (this desk; the brief's hints in brackets) | measured | label |
|---|---|---|---|
| Q1 TX or RX | ≥ 99 % SENT_NOT_DECODED (the 06:44 leg already gave NEVER_SENT = 0 with the peer log); no 20 ms cadence in the TX log | **100 % SENT_NOT_DECODED on both judges and on the P-C leg; 148's TX log flat at P (R = 0.04 / 0.04, null 0.09 / 0.11)** | [silicon] |
| Q2 fabric or host | [brief: "far less" → host/DMA, as the forward 4.3× gap] — this desk expected the checker to see **most** of it, because singles/doubles at 1 % are too dense for a transfer-boundary cascade | **checker sees 0.88 / 0.94 of the host's lost slots, r = 0.99 / 0.90** (and 0.96 / 0.97 on 3b / P-C) → at or upstream of the pins | [silicon] |
| Q3 phase | one phase; displacements k×192 like the forward residual | **one phase, 6.5 ms FWHM; NOT displacements — full-length garbage frames; k×192 cascades exist but are off-comb** | [silicon] |
| Q4 arithmetic | none of the listed quantities equals 20.382 ms | **none; table in §5** | [inferred] |
| Q5 stability | fixed to 4 digits across images (a clock) | **fixed to 6 digits within a boot (2.4 ppm over four legs / 2 h 10 min), moved 204 ppm at the 146 flash/reboot** | [silicon] |
| Q6 RSSI | no correlation | **none (r = −0.32 / +0.06, n = 46 each; gain 34.000 dB on 96/96 reads)** | [silicon] |

## 2. Q1 — TX or RX? [silicon]

`comb_census.py cap/frames.bin --failhdr cap/failhdr.bin --txlog cap/txlog_peer.bin` (the **peer** log = 148's TX log on a reverse leg; the 06:44 leg's `comb_census.txt` vs `comb_census_peertx.txt` pair shows what the wrong log does: 84,437 NEVER_SENT with `txlog.bin`, 0 with `txlog_peer.bin`).

| | judge1 | judge2 | Task 30 (P-C) | before2 (06:44, vendh) |
|---|---|---|---|---|
| lost RX slots (live window) | 8,481 | 11,541 | 15,644 | 84,437 |
| NEVER_SENT | **0** | **0** | **0** | 0 |
| SENT_NOT_DECODED | **8,481 (100 %)** | **11,541 (100 %)** | **15,644 (100 %)** | 84,437 (100 %) |
| txlog_peer records / wrapped | 939,290 / no | 940,853 / no | 623,987 / no | 979,844 / no |
| in-window records, seq step census | 876,790, all +1, 0 dups | 876,789, all +1, 0 dups | 586,602 slots (peer-log step census not run on this leg) | 875,536, all +1 |
| fail class (frames.bin) | MAGIC 6,514 · LEN 242 · CRC 1,278 · ZEROTAIL 0 | MAGIC 9,178 · LEN 332 · CRC 1,581 · ZEROTAIL 0 | MAGIC 12,874 · LEN 380 · CRC 2,055 · ZEROTAIL 4 | MAGIC 68,509 · LEN 1,825 · CRC 13,572 |
| run-length bins 1 / 2 / 3–4 / 5–20 | (see §4) | (see §4) | 8,367 / 3,096 / 321 / 7 | — |
| failhdr records in window (none wrapped) | 8,034 | 11,091 | 15,313 | 62,300 (wrapped) |

`unjoinable_time` = all lost seqs on every leg, as the tool's caveat predicts for a cross-board join (annotation only; two CLOCK_MONOTONICs).

**Does 148's TX host carry the cadence?** `rev20ms_txlog_peer.py` on the same records:

| 148 TX host, in window | judge1 | judge2 | before2 |
|---|---|---|---|
| inter-submit median / p99 / max (µs) | 802.93 / 855 / 1,351 | 802.93 / 890 / 1,351 | 802.93 / 890 / 1,219 |
| submits later than 1.5 frames | 5 | 20 | 1 |
| queue-empty gap events (`gap_ns ≠ NONE`) | 339 (0.039 %) | 242 (0.028 %) | 401 (0.046 %) |
| of which > 20 µs / max | 22 / 146 µs | 4 / — | 27 / 101 µs |
| inflight before submit (polled TX) | 1–2 | 1–2 | 1–2 |
| spins > 0 | 0 | 0 | 0 |
| lost frames whose own txlog record has a gap | 0.094 % (8 / 8,481) | 0.16 % | 0.056 % |
| lost frames with a gap > 20 µs | **0** | **0** | 3 |
| R(P) of the gap-event train (null95) | 0.039 (0.085) | 0.040 (0.111) | 0.042 (0.097) |
| R(P) of `inflight ≤ 1` (n ≈ 352 k) | 0.0004 (0.0029) | 0.0008 (0.0027) | 0.0006 (0.0025) |
| R(P) of submits > 1.2 frames late | **0.273 (0.071), n = 546, phase 0.40** | 0.010 (0.015), n = 16,153 | 0.046 (0.137), n = 156 |
| comb period on 148's CLOCK_MONOTONIC | **20.382254 ms** | **20.382230 ms** | 20.386411 ms |
| same, from the slot count × 802.9297 µs | 20.382258 ms | 20.382234 ms | 20.386409 ms |

Verdict: the transmitter's host was never silent at a lost frame (0 lost frames sit on a > 20 µs gap on either judge; the ByteWordBuffer covers 33 µs), the queue never ran dry in any pattern related to the period, and the frame pacing on 148's own clock reproduces the period to < 1 ppm — the TX host is exonerated. The one non-null line — judge1's 546 late submits at R 0.27 — sits at a different phase (0.40 vs the loss phase 0.12), occurs at 0.76 /s against 8.5 loss onsets/s, and is absent on judge2 (n = 16,153, R = 0.010 = null); it cannot make the comb and is recorded, not explained. **148's TX fabric plane** was unwitnessed on a reverse leg until Task 30's piggy read: `tx_starve_witness` `ep_gt1k` on 148 advanced **+5 (9 → 14) across the 36 piggy reads** (`chk148.jsonl`, 16:32:59 → 16:38:49; +4 over either 35-read sub-window — the ledger's "+4 over 36 reads" is that sub-window count; prediction < 10 per 10 s holds either way) while transmitting the data frames [silicon] — 148's transmit plane is clean.

## 2b. The witness the first pass omitted: 146's own TX log — it carries the comb, as an echo of the loss [silicon]

Reviewer finding 7: `cap/txlog.bin` on a reverse leg is **146's** daemon's TX log (146 transmits idle frames toward 148 while receiving), stamped on the same CLOCK_MONOTONIC as `frames.bin` — a 146 host-side clock the first pass never scored. `rev20ms_txlog_self.py` (committed with this round; time-windowed on that shared clock, because 146's idle frames carry a **constant** sequence word — step census `{0: all}` on every leg — so the seq axis is empty of information):

| 146 TX log, in window | judge1 | judge2 | judge3b | Task 30 (P-C) |
|---|---|---|---|---|
| records in window / wrapped | 876,789 / no | 876,789 / no | 726,091 / no | 586,601 / no |
| inflight census 0 / 1 / 2 / 3 | 2,305 / 383,076 / 490,679 / 729 | 3,017 / 381,714 / 491,091 / 967 | 5,198 / 341,304 / 378,330 / 1,259 | 4,109 / 265,395 / 316,053 / 1,044 |
| inter-submit median / p99 / max (µs) | 802.9 / 952 / 2,513 | 802.8 / 980 / 2,502 | 802.8 / 1,477 / 2,445 | 802.8 / 1,445 / 2,488 |
| queue-empty gap events (n, /s) | 2,305 (3.27) | 3,017 (4.29) | 5,198 (8.92) | 4,109 (8.72) |
| gap median / p99 / max (µs) | 885 / 1,475 / 1,711 | 916 / 1,491 / 1,695 | 900 / 1,454 / 1,642 | 887 / 1,401 / 1,684 |
| late submits > 1.5 fr (n, /s) | 4,590 (6.52) | 6,526 (9.27) | 11,615 (19.92) | 8,860 (18.81) |
| **R(P), gap events** (null95) | **0.384** (0.035) | **0.427** (0.029) | **0.469** (0.026) | **0.428** (0.025) |
| R(P), gaps > 20 µs | 0.475 | 0.496 | 0.526 | 0.503 |
| **R(P), late > 1.5 fr** (null95) | **0.433** (0.025) | **0.441** (0.021) | **0.440** (0.015) | **0.429** (0.018) |
| R(P), late > 1.2 fr | 0.247 | 0.270 | 0.293 | 0.286 |
| R(P), inflight ≤ 1 (n ≈ 270–385 k) | 0.002 | 0.004 | 0.006 | 0.006 |
| band-best P of the gap train (20.07–20.72 ms scan) | 20.38226 ms (−0.1 ppm vs the RX line) | 20.38223 (−0.2) | 20.38221 (−1.1) | 20.38221 (+0.2) |
| gap events: mean phase lag after the RX-onset mean phase | 8.48 ms | 8.34 ms | 8.35 ms | 8.35 ms |
| late > 1.5 fr: same lag | 6.33 ms | 6.19 ms | 6.22 ms | 6.22 ms |
| RX onsets on the same time axis (interpolated on clean anchors), R | 0.597 | 0.627 | 0.605 | 0.592 |

The reviewer's numbers reproduce (0.38 / 0.43 gaps, 0.43 / 0.44 late submits), the band-best period is the RX line to ≤ 1.1 ppm, and **the host-side comb persisted under P-C** at the same R (0.428 / 0.429) and the same lag (8.35 / 6.22 ms). So far this is what "a 146 host-side signature of the same cadence" means. The question is whether it is a signature of the **actor** or of the **loss**. The event-level test — lag from each TX event to the most recent RX loss onset on the same clock, against a control that keeps the cycle phase but breaks the pairing (TX times shifted by k whole periods, k = 5…60):

| | judge1 | judge2 | judge3b | Task 30 (P-C) | T19 (ring comb, W1) | before2 (vendh) |
|---|---|---|---|---|---|---|
| late > 1.5 fr within 12 ms after an individual RX onset | **98.1 %** | **98.7 %** | **99.5 %** | **99.4 %** | 99.6 % | 99.9 % |
| same, cycle-shift control | 20.3 % | 19.1 % | 40.3 % | 38.1 % | 66.1 % | 82.4 % |
| same, Poisson at the onset rate | 9.9 % | 13.6 % | 27.3 % | 25.9 % | 43.1 % | 62.2 % |
| lag median (p10–p90), ms | 5.58 (3.2–9.6) | 5.57 (3.0–9.5) | 5.50 (2.9–8.4) | 5.49 (2.9–8.5) | 5.06 (0.7–7.8) | 4.12 (0.3–7.4) |
| RX onsets followed by a late submit within 12 ms | 74.8 % | 75.9 % | 75.7 % | 75.8 % | 78.4 % | 82.6 % |
| gap events within 12 ms after an onset (control) | 77.7 % (16.9 %) | 86.3 % (17.9 %) | 90.7 % (38.5 %) | 88.1 % (35.7 %) | 94.2 % (52.5 %) | 98.1 % (79.9 %) |
| gap events: lag median (p10–p90), ms | 7.53 (4.7–79.6) | 7.36 (4.7–17.3) | 6.95 (4.3–10.9) | 6.96 (4.2–15.6) | 6.47 (0.6–9.9) | 4.11 (0.2–8.9) |

**Reading [inferred from the numbers above and from `qpsk_tun.c`]:** the TX events are locked to **individual lost frames**, not to the cycle: 98–99.9 % of late submits follow a loss onset within 12 ms (median 5.5 ms) against 19–40 % if they were only phase-locked, on every leg — including T19 and before2, where the losses are dominated by the *ring* comb and the 20.38 ms line is weak (R 0.14 / 0.23). Three quarters of all losses are followed by a late submit and 30 % by a queue-empty gap. `qpsk_tun` is a **single event loop** (one `ppoll` over tun / tx_uio / rx_uio, `qpsk_tun.c:2904-3006`), and its own txgap design note predicts exactly this (`qpsk_tun.c:575-590`: "silence appears whenever an event-loop iteration … takes longer than the remaining slack … gt20us per window ≈ garbage-header (magic_bad) frames per window"): a destroyed frame costs the loop a re-anchor scan and a failhdr write, one TX submit goes out about a frame late, and the 1–2-deep TX queue runs dry. The size of that stall, with the numbers [silicon, `rev20ms_fix2_checks.py`, P-C leg / judge1 / judge2 / judge3b]: the late submit's **own interval is 1.57 / 1.58 / 1.59 / 1.57 ms median and 2.49 / 2.51 / 2.50 / 2.45 ms max** (the `dt max` row above), i.e. a **slip of 0.76–0.78 ms median past the 802.9 µs frame, never more than 1.7 ms**; the queue-empty gap is 0.89 / 0.89 / 0.92 / 0.90 ms median (max 1.7 ms). The 5.5 ms in the table is a **lag, not a delay**: `frames.bin`'s `t_mono_ns` is stamped in `framelog_emit` (`qpsk_tun.c:328-334`) when the daemon *processed* the slice, not when the frame was on air, and measured from that stamp the daemon's preceding, **on-time** submit already sits 3.96 / 3.97 / 3.97 / 3.96 ms after the onset (p10 1.6 / 2.0 / 1.8 / 1.6 ms) with the late one 5.49 / 5.58 / 5.57 / 5.50 ms after it; the onset falls inside the stalled interval in only 1.6 / 1.3 / 1.0 / 1.7 % of cases. Direction check: the lag from a late submit to the *next* onset is 18.9 / 32.8 / 31.2 / 18.7 ms median with 36 / 28 / 29 / 36 % within 12 ms — the cycle-shift / Poisson baseline — so late submits precede an onset only at chance; the direction is loss → late submit. **146's TX comb is the daemon's reaction to each destroyed frame — a host-side echo of the loss, not an independent witness of what causes it.** It persisted under P-C because the losses did. Consequently the "shows up on the host" property that the DisplayPort finding was credited with (§10) is **withdrawn**: 146's host TX timing carries no information about the actor beyond what `frames.bin` already says. What this witness does add: on 146 each processed loss is followed, roughly 5 ms later, by **one frame of TX silence — a submit ≈ 0.8 ms late, at most 1.7 ms** — a per-loss cost that the forward direction pays too, and which is not itself the reverse residual.

## 3. Q2 — fabric or host on 146? [silicon]

`chk.jsonl` deltas over the consecutive 10 s reads that fall inside the host live window, against the host loss on the same wall-time cut (`t_real_ns` ↔ `ts_wall`; the reader's `ts_mono` is nemo's clock, not 146's). Slots 0–7 are the `rx_seam_checker` at 146's RX byte pins (frame = user-marked word + 190; header parse + CRC32), `chk_*` is the `rx_seq_checker`; `chk_lost_slots` is the known-defective counter on this image (it reads ±10⁹) and is not used.

| per window | judge1 (460 s) | judge2 (460 s) | judge3b (339 s) | Task 30 P-C (330 s) |
|---|---|---|---|---|
| fabric frames `0x104` / `0x124` | 573,318 / 573,319 (1,243.6 /s) | 572,643 / 572,644 (1,244.9 /s) | 422,774 / 422,774 (1,247.1 /s) | 411,414 / 411,414 (1,246.7 /s) |
| seam checker frames | 573,132 | 572,409 | 422,575 | 411,226 |
| seam `crc_fail` | 574 (1.25 /s) | 1,119 (2.43 /s) | 1,549 (4.57 /s) | 1,531 (4.64 /s) |
| seam `magic_bad` | 2,338 (5.07 /s) | 6,043 (13.1 /s) | 9,740 (28.7 /s) | 9,147 (27.7 /s) |
| seam `short` / `orphan` words | 173 / 16,775 | 227 / 27,810 | 208 / 24,876 | 179 / 17,351 |
| seq checker `gap_events` (gap1 / gap2 / gap3+) | 1,896 (1,152 / 612 / 132) | 4,961 (3,334 / 1,420 / 207) | 7,903 (5,466 / 2,186 / 251) | 7,388 (5,038 / 2,047 / 303) |
| seq checker `garbage` / `crc_fail` | 2,353 / 574 | 6,056 / 1,119 | 9,756 / 1,549 | 9,166 / 1,531 |
| **host** lost slots / onsets | **3,300 / 2,272** (7.16 / 4.93 /s) | **7,660 / 5,757** (16.7 / 12.5 /s) | **11,723 / 8,879** (34.6 / 26.2 /s) | **11,047 / 8,331** (33.5 / 25.2 /s) |
| host slots (clean + lost) − fabric `0x104` | 833 (0.145 %) never counted by the fabric | 272 (0.047 %) | — | — |
| **(seam crc_fail + magic_bad) / host lost** | **0.88** | **0.94** | **0.96** | **0.97** |
| host onsets / checker gap events | 1.20 | 1.16 | 1.12 | 1.13 |
| Pearson r per 10 s, onsets ~ `chk_gap_events` | **+0.987** | **+0.898** | **+0.856** | **+0.915** |
| r, onsets ~ seam `magic_bad` / `crc_fail` | +0.985 / +0.900 | +0.863 / +0.601 | +0.784 / +0.250 | +0.901 / +0.645 |

The fabric checker at the pins loses at the host's rate, event for event and interval for interval, on every fix-image leg including the P-C leg. The forward residual was the opposite (host 3.97× the checker, Task 23 §Q3). Nothing between the pins and the host buffer adds loss here; the 146 host/DMA byte plane is exonerated as the origin. The loss is born at or upstream of the RX byte pins: modem fabric or radio.

## 4. Q3 — phase, singles vs doubles, and what a comb frame looks like [silicon]

`rev20ms_period_phase.py` (onsets on the slot axis; P refined per leg):

| | judge1 | judge2 |
|---|---|---|
| onsets / lost slots / cycles in window | 6,094 / 8,481 / 34,540 | 8,568 / 11,541 / 34,540 |
| onsets per cycle | 0.176 | 0.248 |
| R(P), onsets (null95, 100 random sets over the band) | **0.700** (0.036) | **0.732** (0.031) |
| circular sd of the onset phase | 3.4 frames = 2.7 ms | 3.2 frames = 2.6 ms |
| phase-window FWHM (50-bin histogram) | **16 bins = 6.52 ms** | **16 bins = 6.52 ms** |
| peak / floor per bin | 343 / 14.2 = **24×** | 504 / 15.1 = **33×** |
| share of onsets in the comb (1 − floor × 50 / n) | **88 %** | **91 %** |
| off-comb floor | 1.00 onsets/s | 1.07 onsets/s |
| R(P) singles / doubles / runs ≥ 3 | 0.726 / 0.772 / **0.040** | 0.755 / 0.757 / **0.044** |
| mean phase singles / doubles | 0.121 / 0.117 | 0.916 / 0.911 |
| R(P/2) / R(2P) | 0.325 / 0.016 | 0.350 / 0.010 |
| sub-window phase (7 equal windows) | 0.131 0.120 0.101 0.114 0.122 0.120 0.123 | 0.910 0.915 0.916 0.921 0.912 0.918 0.911 |

50-bin onset-phase histogram, judge1 (P = 25.38486 fr; each `#` ≈ 12 onsets):

```
bin  0-9 : 319 364 362 364 359 354 363 327 325 287   ########################### (plateau)
bin 10-19: 287 281 208 198 148 116  78  65  33  22   ####### (falling edge, ~3 ms)
bin 20-39:  16  21  13  15  19  13  21  16  16  14   # (floor, ~8 ms)
            15  11  17   8  10  14  27  12   9  17   #
bin 40-49:  19  12  23  17  42  55  95 163 212 292   ####### (rising edge, ~2.5 ms)
```

Judge2 has the same shape rotated by 0.80 cycle (a different boot-time phase, §6): plateau 519–558, floor 8–22, FWHM 16 bins. The window is a **single, broad, one-sided-rising** state ≈ 6.5 ms long out of 20.38 ms (32 % duty at half maximum), during which frames die at 24–33× the off-comb rate; runs ≥ 3 do not participate at all. R(2P) ≈ 0.01 rules out an alternating (period-doubled) pattern. Reviewer finding 8, accepted: a *direct* 146-local process with a ~5.7 ms active window (6.52 ms less one frame of onset quantisation) fits this histogram exactly as well as a beat sweeping a 32 % region of the frame does — the histogram does not distinguish them (§5.1).

**Anatomy of a comb frame** (`failhdr.bin`, exact `t_mono_ns` join to every failed `frames.bin` record: 8,034 / 8,034 and 11,091 / 11,091):

| run shape | n (judge2) | position 0 | position 1 | position 2 |
|---|---|---|---|---|
| single (gap 1, 1 record) | 5,594 | class 1: 4,412 (79 %) — **4,152 with no magic anywhere**; class 3 (CRC): 968; class 2 (LEN): 214 | | |
| double (gap 2, 2 records) | 2,305 | class 1: 1,871 (1,686 no magic); CRC 319; LEN 115 | class 1: 2,305 (2,188 no magic; 952 ×87, 1144 ×8, 568 ×6) | |
| triple (gap 3, 3 records) | 171 | **CRC 170 / 171** | class 1, no magic 170 / 171 | class 1 at **1144 ×112, 952 ×43** (lattice) |
| quad (gap 4, 4 records) | 49 | CRC 49 / 49 | no magic 46 / 49 | no magic 48 / 49 → pos 3 at 1144 ×45 |

Judge1 is the same picture (singles: class 1 2,967 of which 2,782 no-magic, CRC 754, LEN 167; triples: CRC-seeded, ending at 568 / 1144). Onset class vs the comb phase: class-1-no-magic R **0.79 / 0.81**, class 2 R 0.78 / 0.78, class 3 R 0.57 / 0.59 — all at the same phase; the CRC-fail onsets are only partly on the comb (they also seed the off-comb cascades).

So the comb frame is a **full-length slice with no frame magic anywhere in it** — the deframer emitted 191 words of garbage for that slot, and the seam checker counted it as `magic_bad` at the pins (§3). It is not a displaced frame: the byte stream is not shifted, the next frame parses. That is a demodulator-level event (frame sync / decode failure for one or two frames), not a byte-plane deletion.

**The k×192 lattice on 146.** The displacement class is present on this receiver too: class-1 records that do carry a magic sit at 568 ×137, 1144 ×99, 664 ×17, 952 ×7, 1152 ×5, 1136 ×5 (judge1) and 1144 ×180, 952 ×143, 568 ×9 (judge2) — 243 / 338 on the 192-byte lattice (deletions 960 / 384 / 576 / 1152 B = 5 / 2 / 3 / 6 × 192). The exception is 664 (deletion 864 B = 4.5 × 192, 17 records on judge1, one lineage of events) — recorded, not explained. The 146 daemon's own re-anchor counter agrees (`rxresync2 … top=568:130,1144:93,664:15,952:6` on judge1; `1144:176,952:142,376:79,568:76` on T19). These are the runs ≥ 3 (311 / 280 per leg ≈ 0.43 / 0.39 /s, ~1,060 / 900 slots ≈ **0.12 / 0.10 pp** of PER) and they are **not phase-locked** (R 0.04): the forward residual's fabric-deletion class, living on 146 at the forward rate, separate from the comb.

## 5. Q4 — arithmetic: what is 20.382 ms? [inferred unless marked]

Measured period (judge legs): **P = 25.38486 frames = 20.38226 ms = 49.0623 Hz**; ±0.2 ppm bootstrap, ±1 ppm split-half [silicon]. In other units: 313,071.5 ± 2 symbols; 1,252,286 samples at 61.44 MHz; 782,679 cycles of 38.4 MHz; 5,009,143 cycles of 245.76 MHz; 78,268 bytes of air data (0.25 B/symbol); 38,788 bytes of host frames (1,528 B/frame); 78,186 B at 3,080 B/frame. Pre-fix legs: 25.39003 frames = 313,135.3 symbols — the shift is **64 ± 3 symbols = 256 samples = 4.16 ± 0.15 µs** (≈ 2 TX-plane words of 2.086 µs, ≈ 1 RX-plane word of 4.204 µs; the precision does not split those).

Clock facts used below, from the repo (correcting the first pass's internal conflict, reviewer finding 2): `two_jup/lvds_61p44_fdd_jupiter.json` has `deviceClock_kHz` 38,400, `clkPllVcoFreq_daHz` 884,736,000 (= 8,847.36 MHz) and `clkPllHsDiv` 0 (= ÷4), so **hsDigClk = 2,211.84 MHz**. The first pass's §5 table used 184.32 MHz for the same quantity (2,211.84 / 12 — an arithmetic slip) while its §5.1 used 2,211.84 MHz; 2,211.84 MHz is the repo value and the table row is corrected below.

| candidate | value | vs 20.38226 ms / 25.38486 fr | verdict |
|---|---|---|---|
| RX DMA transfer, `-M 16` × 1,528 B (`bringup_r2r3.sh`, `qpsk_hw.h`) | 16 frames = 12.847 ms | P / 16 = 1.587 | out |
| RX carve lap, 2 areas × 16 | 32 frames = 25.694 ms | P / 32 = 0.793; lag-32 autocorr −0.007 / −0.011 | out |
| S2MM boundary discard (old forward comb) | one per transfer = 16 frames | same; and the checker upstream of the DMA sees the loss (§3) | out |
| ByteRxFifo 64 × 64-bit = 512 B | 0.335 frame | no cadence; upstream witness (§3) | out |
| TX transfer 3,080 B; `TX_SLOTS` 8 × 4,096 B stride; polled inflight ≤ 2 | 1 frame / 8 frames = 6.42 ms | P / 8 = 3.17; no TX-log cadence (§2) | out |
| TX `ByteWordBuffer` 16 × 64-bit (385 ≡ 1 mod 16 → 16-frame family) | 16 frames | lag-16 autocorr −0.003 / −0.010 | out |
| TX pacer / TGEN filler | TGEN not in the path on a daemon leg (`0x158` = DMA source; the `tgen_mode` bit restored at leg end is the checker's mode bit) | — | out |
| host TX offered load, `qpsk_perf -b 15Mbit -l 1400` (`clock_nanosleep` absolute pacing) | 746.67 µs / packet | P = 27.30 packets, non-integer; no TX-log cadence | out |
| Linux HZ on both boards (built `.config`: `CONFIG_HZ=250` + `CONFIG_NO_HZ_IDLE=y`, the arm64 `kernel/Kconfig.hz` default `HZ_250`; `adi_zynqmp_defconfig` itself sets only `CONFIG_NO_HZ=y` and `CONFIG_HIGH_RES_TIMERS=y`, lines 5–6, and no `CONFIG_HZ`) | 4.000 ms | P = 5.0956 ticks | out |
| daemon `-s 5` stats, watchdog 5 s, reader 10 s, RSSI read 10 s | 5–10 s | ≫ P | out |
| 146's daemon TX timing (late submits, queue-empty gaps) | on the comb, R 0.38–0.47 | event-locked to the losses (§2b): an echo, not a source; and the loss is upstream of the host | out |
| 2.575 ppm × f_x = 49.0623 Hz → f_x | **19.053 MHz** | no such clock; 19.2 MHz (= 38.4 / 2) needs 2.5553 ppm, vs 2.5717 ± 0.003 ppm from T19's ring edge (25.3165 ms) — 6σ | out |
| SRO slip period itself (the ring's FULL edge, T19) | 388,850 symbols = 31.53 fr = 25.32 ms | ≠ 25.385 fr; R4D removed it (lag-32 gone) | out |
| 1 M cycles of 38.4 MHz (the old 26 ms lead) | 26.042 ms | 1.28 P | out |
| 2²⁰ samples @ 61.44 MHz / 2²² @ 245.76 MHz | 17.067 ms | 0.837 P | out |
| ADRV9002 AGC gain update: `rx0_agc_gainUpdateCounter` 11,520 + 2 × `slowLoopSettlingDelay` 16, at hsDigClk / `agcClkDivideRatio` with hsDigClk = **2,211.84 MHz** | 11,552 cycles: 835.9 µs at ÷160 if the field were a plain divisor; **668.5 µs (÷128) or 1.337 ms (÷256) if it is a log2 shift** — neither is the beat partner | < P; the ratio is [not in repo]: `adi_adrv9001_types.h:179` declares `uint8_t agcClkDivideRatio` ("AGC module clock divide ratio w.r.t hsDigClk") and the field is **never assigned in the ADRV9001 driver** (`drivers/iio/adc/navassa/`: one grep hit, the declaration) — **ARM-firmware-owned**. The same tree's **ADRV9025 sibling** assigns its identically named field (`adrv902x/.../adrv9025_init.c:402`, from `regDeviceClockDiv`, :225) and uses it as a **log2 shift**: `agcClkRate_kHz = hsDigClk_kHz >> agcClkDivideRatio` (:1575). If the ADRV9001 follows the sibling's semantics the AGC clock is 2,211.84 MHz / 2^k and ÷160 was never a reachable value — which strengthens the retirement | out as the direct source; **excluded as the beat partner by Task 30 [silicon]** (§8) |
| ADRV9002 RX tracking cals on 146: `agc`, `bbdc_rejection`, `rfdc`, `rssi`, `quadrature_fic` (all **enabled** on the shipped config, `knobs_146_final`) | cadence [not in repo] | — | **excluded by Task 30 [silicon]**: all five off → line unchanged (§8) |
| modem RTL counters (census of every `'d` / decimal literal ≥ 10,000 in `s1_rtl/hdlsrc/*.v`) | 12,291–12,332, 24,592–24,665, 49,279–49,332, 65,535, 2,097,151 (a 21-bit `symCtr` mask), 310,391 (a LUT entry `t_0[663]`) | none within 1 % of 313,071 | out |
| 146's DisplayPort pipeline: refresh 60.000 Hz, lines 67.5 kHz, DPDMA 2 IRQ/frame, pixel 148.5 MHz, link 1.62 / 2.7 / 5.4 Gb/s | 16.667 ms / 14.815 µs / … | no low-integer relation to 20.382 ms or to 1,196.377 Hz (§10) | **open as the process, closed as the arithmetic**: untested (Task 36) |
| the forward 8.140 s rate line (Tasks 23/28: 8.140 / 8.160 / 8.160 s on a 0.02 s grid) | 400 × P = 8.1529 s | inside the grid of all three | **noted**: consistent with 400 cycles, unexplained; the forward legs show no fundamental, **at a weak sensitivity**: the only 148-as-RX control (`air2`) has **n = 185 onsets**, R(25.385 fr) = 0.122 against a single-P null95 of 0.127 (band best 20.55 ms at R 0.27 vs null 0.21), so a line carrying up to ~15 % of the forward onsets would be invisible there [silicon, `rev20ms_fix2_checks.py`]. "146-only" for the *comb* is therefore a bound, not a clean negative — unlike the DPDMA's 0 IRQ on 148 (§10), which is |
| mains 50 / 60 Hz | 20.000 / 16.667 ms | 1.9 % off; mains is not 1-ppm stable | out |

Nothing in the fabric, host, DMA or clock-ratio inventory yields the period directly. The quantity that behaves like it — 1 ppm stable within a boot, unchanged by radio re-inits, by the P-C knob set and by a total fabric-lineage swap, moved 10⁻⁴ by a board reboot — is either a beat or a boot-programmed period, and the banked data do not say which.

### 5.1 The beat reading and the direct reading — both open, the AGC partner retired [inferred, with measured anchors]

**Beat mechanics (unchanged).** The loss is scored on 148's frame axis. If 146 runs a periodic process with period T₂ close to, but not equal to, the frame period T₁ = 802.9297 µs, its position **inside the frame** advances by (T₂ − T₁) every frame and sweeps the whole frame once every T₁·T₂ / |T₂ − T₁|. Frames die only when the event lands in a vulnerable part of the frame, so on the frame axis the loss rate is periodic with the beat period and has a duty cycle equal to the vulnerable fraction of the frame.

| | value |
|---|---|
| f₁ = 15.36 MHz / 12,333 (148's frames) | 1,245.4391 Hz |
| beat (measured, judges) | 49.0623 Hz = 20.38226 ms |
| **T₂ (slow partner)** = 1 / (f₁ − beat) | **835.857 µs = 1,196.377 Hz** |
| T₂ (fast partner) = 1 / (f₁ + beat) | 772.50 µs = 1,294.50 Hz — no candidate |
| vulnerable fraction of the frame (window FWHM 6.52 / 20.38) | **32 % ≈ 3,945 of 12,333 symbols = 257 µs** |
| beat sensitivity | 1 ppm of T₂ → 24.4 ppm of the beat; the 204 ppm reboot step ↔ **8.4 ppm of T₂ (7 ns)**; the 8 ppm step ↔ 0.33 ppm of T₂ |

**The AGC candidate is retired.** The first pass named 146's ADRV9002 slow-loop AGC update (`gainUpdateCounter` 11,520 + 35 cycles at hsDigClk / 160 = 13.824 MHz → 835.865 µs, the beat to 0.03 %) as the partner. Three things close it: (i) **Task 30 [silicon]** — gain control in `spi` at 34.0 dB and all five RX tracking calibrations off, every write read back, and the line is unchanged (P 25.38480 fr, R 0.7004, PER 2.667 %, §8); as far as these six attributes reach, the tracking loops and the AGC slow loop are not the actor; (ii) **the reviewer's tension (finding 1)**, which stood before the leg: one AGC clock at 13.824 MHz is 72.3 ns = 86.5 ppm of T₂ = **2,110 ppm of the beat**, so any integer change of the counter or its overhead moves the line by ≥ 2,110 ppm, while the observed reboot step is 204 ppm ≈ 8.4 ppm of T₂ — a **clock-frequency** change, not a count change, which the "fitted overhead count" picture did not accommodate; (iii) the asymmetry it leaned on ("only 146 sits under-range") was a sign error (§5.2). The 0.03 % match at ÷160 remains a coincidence on record; the divide ratio was never in the repo, and if the ADRV9001 treats `agcClkDivideRatio` as its ADRV9025 sibling does — a log2 shift (`adrv9025_init.c:1575`) — ÷160 is not a value the field can take at all (§5 row).

**Beat or direct? What each reading has to carry (reviewer finding 8, kept explicit).**

| banked fact | beat reading (a 146 cadence at T₂ = 835.857 µs) | direct reading (a 146 process with period 20.382 ms) |
|---|---|---|
| 6.5 ms window (≈ 5.7 ms after removing one frame) | a 257 µs region of the 803 µs frame (32 %), swept once per beat | a process active ≈ 5.7 ms of every 20.38 ms (28 % duty) |
| broad, one-sided-rising histogram; singles + doubles on the comb, runs ≥ 3 off it | fits (a region of the frame, hit one or two frames deep) | fits (an active window ≥ 2 frames long) |
| 1 ppm stability within a leg; identical to 2.4 ppm across four legs / 2 h 10 min | a hardware-timed cadence on 146 | a hardware-timed period on 146 |
| unchanged by two ADRV9002 re-inits (3b) and by P-C (Task 30) | the partner is not re-seeded by the radio init | the process is not owned by the radio init |
| 204 ppm step at the fix flash + reboot; 8 ppm at the W1 flash + reboot | **8.4 ppm / 0.33 ppm of T₂** — the size of a crystal's thermal shift or a PLL re-lock, nothing needs re-programming | **204 ppm of the process period** — too large for a crystal (tens of ppm total); needs a re-programmed divider, PLL word or mode at that boot |
| phase drift < 0.03 cycle over 719 s (35,276 cycles); split-half 0.7–1.1 ppm; 1.2 ppm judge1 → 3b (75 min) | the ratio of the partner's clock to 148's 38.4 MHz must hold to **< 35 ppb over 12 min** (29–45 ppb split-half; 49 ppb over 75 min) — demanding for two independent oscillators, not impossible in a still lab | **< 0.85 ppm** — ordinary for two crystals |
| 148's frame rate | both scale with the ratio f_process / f₁: the beat with gain 24.4, the direct process with gain 1 |

Neither reading is excluded by a banked number. The direct reading is the easier one on the clocks and the harder one on the reboot step; the beat reading the reverse. No banked instrument measures the two boards' clock ratio independently, so the 35 ppb question cannot be settled from the archive. This is the ambiguity Task 36 inherits: if the display is the actor, the arithmetic in §10 says it would have to act as a beat, which brings the 35 ppb requirement with it.

Two clocks that do **not** fit as T₂, for the record: an AGC counter at 0.576 MHz (a TX-block clock in the register map; would give 20.0 ms directly, 1.9 % off) and 11,520 cycles at 61.44 / 15.36 MHz (187.5 µs / 750 µs — beats of 0.24 / 1.2 ms).

### 5.2 Receiver level: the "146 under-range" inference, with the numbers — and a sign correction [silicon numbers, inferred thresholds]

Reviewer finding 5. The first pass wrote "146 is the under-range receiver (RSSI 24.6 vs 27.8 dB)" without a threshold and with the sign wrong. The ADRV9002 driver's `rssi` and `decimated_power` are magnitudes **below full scale**: `adi_adrv9001_rx.h:199` — "Value returned is in mdBFS. If all samples are zero, a '200000' is returned" (200 dB below full scale reads as `200.00 dB`), printed by `adrv9002.c:1747/1753` as `%u.%02u dB`. A larger number is a **weaker** signal.

| receiver (legs) | `decimated_power` reads | `rssi` reads | `hardwaregain` | n |
|---|---|---|---|---|
| **146** as RX, reverse legs (judge1, judge2, 3b) | 22.50–23.25 dB → **−22.5 to −23.3 dBFS** (one 16.75 read on each judge) | 24.48–24.82 dB | 34.000 on 132 / 132 (index 255 = `maxGainIndex`) | 132 |
| **148** as RX, forward legs (07:39, 07:50, 08:46, 09:02, 09:15, 16:13, 16:20) | 24.75–26.25 dB → **−24.8 to −26.3 dBFS** | 27.10–27.99 dB | 34.000 on 242 / 242 | 242 |

The AGC power detector on both boards is enabled (`rx0_agc_power.powerEnableMeasurement = Y`) with `underRangeHighPowerThresh` = 10 and `underRangeLowPowerThresh` = 4 — per `adi_adrv9001_rx_gaincontrol_types.h:80-81` the "detect lower 0 threshold, 0–127" and the "lower 1 threshold, valid offset 0–15", i.e. **−10 dBFS and −14 dBFS** [inferred: the header gives the roles, the ADRV900x convention gives the sign]. Both receivers sit **8.5–16 dB below both under-range thresholds** with the gain index pinned at 255 on every read (146: 132 / 132; 148: 242 / 242). So: both receivers are under-range and railed; **146 is the stronger of the two by ≈ 3 dB, not the weaker**. The asymmetry claimed in the first pass is withdrawn — and is moot after Task 30, which switched the AGC's slow loop off with no effect.

## 6. Q5 — stability across images and within one boot [silicon]

| leg (146 image) | P (frames) | P (ms) | R | split-half P | boot/split spread |
|---|---|---|---|---|---|
| 06:44 before2 (vendh `3378861d30bd`, daemon without resync) | 25.39003 | 20.3864 | 0.232 | 25.390023 / 25.390024 | 0.03 ppm |
| 10:51 T19 (W1 `2728dab3979a`) | 25.38983 | 20.3862 | 0.143 | 25.389814 / 25.389832 | 0.7 ppm |
| 14:23 judge1 (W1+R4D+R1 `9acbe2ebe1db`) | **25.38486** | **20.3823** | 0.700 | 25.384818 / 25.384847 | 1.1 ppm (bootstrap 0.22 ppm) |
| 14:38 judge2 (same boot) | **25.38483** | **20.3822** | 0.732 | 25.384837 / 25.384820 | 0.7 ppm (bootstrap 0.14 ppm) |
| 15:38 Task 29 judge3b (same boot; after the 15:00 `restore-t22` and Task 29's two arms = **two full profile reloads** of 146's ADRV9002, one at-arm lock collapse) | **25.38483** | **20.3822** | 0.707 | (`comb_period_ms.txt`; PER 2.825 %, onsets 15,502 — the comb at 2.2× the judges' rate) | 1.2 ppm from judge1 |
| 16:33 Task 30 P-C (same boot; gain control `spi`, five tracking cals off, §8) | **25.38480** | **20.3822** | 0.700 | (`comb_period_ms.txt`; PER 2.667 %, onsets 11,791) | 2.4 ppm from judge1, 1.2 ppm from 3b |

Sub-window periods (7 windows per leg) stay within ±0.0001 fr (4 ppm) of the leg value on every leg. On 146's own host clock (`t_mono_ns` regression) the period differs from the 148-frame conversion by −0.45 / +0.15 / +3.0 / +0.01 ppm — one real-time period, both clocks agree.

`bringup_r2r3.sh:70-74` writes `stream_config` + `profile_config` at every arm — `adrv9002.c:4808 → adrv9002_init → adrv9002_setup` (ARM image load, `InitAnalog`) — so judge3b's unchanged period means **a full ADRV9002 re-initialisation does not re-seed the period**; Task 30's unchanged period means the RX tracking loops do not set it either; only the two board reboots (each with a BOOT.BIN change) did. Task 29's report gives 146's uptime as 1 h 11 m at 15:2x (booted by the 14:11 flash, no unlogged reboot); the boot lasted through Task 30.

Digits: **identical to 6 significant digits within one boot** (judge1, judge2, judge3b, Task 30: 2.4 ppm over 2 h 10 min, no reboot, two radio re-inits and one radio knob set between them); **identical to 5 digits across the vendh → W1 lineage swap** (8 ppm, one flash + reboot between them); **different in the 4th digit across the fix flash** (204 ppm, one flash + reboot). The T19 line at 20.386 ms is the same line as the 06:44 one (R 0.14 under the ring comb; band best 25.38983), so the line pre-dates R4D+R1 and the R4D+R1 change coincides with, but need not cause, the 204 ppm step: a total fabric replacement moved it 8 ppm, a small RX-chain patch "moved" it 196 ppm — the step is far more plausibly the reboot than the RTL. No RTL counter of 313,071 or 313,135 symbols exists (§5), and the valid-density changes R4D/R1 make (±2.5 ppm each) are 80× too small. A period this stable is hardware-timed [silicon]. That it is *146's* process, fixed at *146's* boot, is **[inferred]** — an inference from coincidence, not a measurement: the two steps (204 and 8 ppm) coincide with the two 146 flash + reboots, the no-step cases with 146's radio re-inits and the P-C knob set, and 148 was not rebooted between any of these legs while its PS-clock / frame-clock ratio stayed constant to < 1 ppm (§2, the period on 148's CLOCK_MONOTONIC), which leaves 146 as the board whose clocks changed; nothing banked measures either board's clock against an external reference. This is the "clock/timer, not RF" branch of the brief — with the owner on 146 by that inference.

Also on record: the comb's **event rate** (its modulation depth) is not constant. On judge1 the onset rate stepped from 19–41 per 10 s to 126–167 per 10 s at 14:32:35 (interval 41 of 46) and stayed there; period and phase did not move (sub-windows 5–7: P 25.38480 / 25.38470 / 25.38462, phase 0.122 / 0.120 / 0.123). Judge2 ran at 88–176 per 10 s throughout; 3b and Task 30 at 26 / 25 onsets/s. The process is always ticking; how often a tick kills a frame varies 4× on a minute scale with nothing in `rssi.jsonl` moving (§7).

## 7. Q6 — RSSI / gain vs loss [silicon]

`rssi.jsonl` (10 s cadence, 146, 48 reads per judge leg; 46 inside the live window):

| | judge1 | judge2 |
|---|---|---|
| `in_voltage0_rssi` min / max / sd | 24.477 / 24.819 / 0.074 dB | 24.514 / 24.719 / 0.056 dB |
| `hardwaregain` | **34.000 dB on 48 / 48** (gain index 255, the max-gain rail) | 34.000 on 48 / 48 |
| `decpwr` | 22.5–22.75 dB on 47 / 48, one read at 16.75 | 22.5–23.25 on 47 / 48, one read at 16.75 |
| r(rssi, onsets per 10 s), n = 46 | −0.32 | +0.06 |
| r(decpwr, onsets) | −0.31 | +0.14 |
| onsets in the interval with the 16.75 dB read | 137 (median 33.5) | 106 (median 126.5) |

No consistent sign, no gain motion, RSSI flat to 0.1 dB while the event rate moved 4× (§6). The RF level is not the modulator. Judge3b: rssi 24.500–24.719 (sd 0.061), decpwr 22.50–22.75, gain 34.000 on 36 / 36 — the same picture. **On the Task 30 leg the 10 s reader is blind by construction**: with `rssi_tracking_en` = 0 the `rssi` attribute returned **24.619 dB on 36 / 36 reads** (frozen at its last tracked value) and `decimated_power` returned **0.00 on 36 / 36** (the driver's own comment at `adrv9002.c:1741`: "it might depend on proper AGC parameters"); `hardwaregain` 34.000 on 36 / 36 as commanded. So the P-C leg has no RF-level witness of its own; the seam checker (share 0.97, §3) and a loss profile identical to 3b stand in for it.

## 8. Task 30 — P-C on the receiver: the radio's loops are not the actor [silicon]

Run `two_jup/comb/runs/20260905_163044_w1_t30_pc` (wrapper `two_jup/rxfix/pc146leg_go.sh PROBE=C DUR=480 EXP=9acbe2ebe1db PIGGY=1`, i.e. `w1leg_go.sh MODE=air LEG=B BOARD=146 DUR=480 R4D=1 RSSI=1 FIXCTL_BASE=0x0` with `RX_ATTR_POKE` applied to 146 after the health gate and before the scored window; ledger `Task 30: PREREG` 16:30:44, `Task 30: SCORED` 19:40).

**What was written, and read back** (`cap/attr_poke.txt`, `attr_midwin.txt` at 16:35:52 mid-window, `attr_restore.txt` at 16:41:34):

```
in_voltage0_gain_control_mode          automatic -> spi     mid-window: 'spi'        restored: 'automatic'
in_voltage0_hardwaregain               34.000000 dB kept    mid-window: '34.000000'  restored: '34.000000 dB'
in_voltage0_agc_tracking_en            1 -> 0               mid-window: '0'          restored: '1'
in_voltage0_bbdc_rejection_tracking_en 1 -> 0               mid-window: '0'          restored: '1'
in_voltage0_rfdc_tracking_en           1 -> 0               mid-window: '0'          restored: '1'
in_voltage0_rssi_tracking_en           1 -> 0               mid-window: '0'          restored: '1'
in_voltage0_quadrature_fic_tracking_en 1 -> 0               mid-window: '0'          restored: '1'
```

`attr_write_fails=0`; the controller's independent readback at 19:34 (automatic, five cals = 1, 34.0 dB) confirms the restore. Leg health: stall watchdog wall 468 / 464 s, `poll_read_failures` 0, no `MID_CAPTURE_WEDGE`, watchdog relaunches 0 / 0, deliver rate pre 1,011 / post 1,016, `gate_pass=1` — clean and credited (ledger 19:40). Those two deliver-rate figures are **gate readings, not frame rates**: `deliver_rate()` differences one 5-s `stats:` line across a 6-s sleep, so each is k × (one 5-s delta) / 6 and the true delivered rate on this leg is ~1,220–1,245 f/s (WEDGE_TIMER_AUDIT.md §6b). The same caveat applies to the `post rate 1016 f/s` line quoted below, which is used here only as a direction-correct witness that delivery continued across the end-of-file tail.

**The `[WEDGE truncated]` label on this leg, stated rather than left as a contradiction.** Every scorer prints it (`comb_period_ms.txt`: `live=486/493s [WEDGE truncated]`; `accept_analyze.py`: `live 486s/493s [WEDGE truncated]` and `wedges during captures: 1`). The label is the live-window rule of `accept_analyze.analyze()` / `common.live_window` firing on the **last 5 s of the file**, not on a link event [silicon, `frames.bin` per-second census]: clean frames run at 1,207–1,219 /s (records 1,244–1,246 /s) through t = 487 s, then from t = 488 s to the end of the file at 493.1 s `crc_ok` drops to 185 and then **0 /s while records continue at 480 /s** — the last clean bin ≥ 25 % of peak is 487, so `live_end` = 488 − 2 = 486 and `wedged` = (488 < 493.1 − 3) = true. That tail is the post-traffic quiesce, not a wedge: the wrapper's own end-of-window witnesses were taken across it — `post rate 1016 f/s (6 s dma_rx_ok delta after the traffic window)`, and the fabric packet counter `0x104` advanced 594,447 from `CAP_START` (16:33:12) to the post snap (16:41:10) = **1,245.3 f/s over 477.4 s**, the in-window fabric rate (1,246.7 /s, §3); a 5 s fabric outage would have read ≤ 1,237 — while `capture_r3.log` records no `MID_CAPTURE_WEDGE` and the stall watchdog completed its window. The ledger attributes the identical signature on the Task 32b leg to the flush / quiesce order at end of file (line 1173, verified there against `0x104` and `rstcs`); on this leg the attribution rests on the witnesses just listed and is [inferred]. The label therefore does not contradict "clean and credited"; the scored window (15–486 s) is unaffected either way.

**Pre-registered (ledger, before the leg; the reviewer's completion made R primary):** P1 (radio-side actor) = R at 25.385 fr < 0.05 regardless of PER; P2 (falsifier) = R ≥ 0.5; AMBIGUOUS 0.05–0.5 → one re-run; PER reported alongside.

**Result — P2 fires.** `comb_period_ms.py cap/frames.bin`: **BEST P = 25.38480 frames = 20.3822 ms, R = 0.7004**; PER **2.667 %** (15,644 / 586,602, lost frames in the denominator), live 486 / 493 s; onsets 11,791; run bins 1 / 2 / 3–4 / 5–20 = 8,367 / 3,096 / 321 / 7; fail class MAGIC 12,874 · LEN 380 · CRC 2,055 · ZEROTAIL 4; NEVER_SENT **0 / 15,644** (§2); seam-checker share **0.97**, r 0.91 (§3); ring witnesses identical to every fix-image leg (occupancy 22–23, `push_on_full` 0, extras 389 / 10 s); host `crc_fail` 0.371 %, `magic_bad` 2.216 % — the leg-3b profile.

**`accept_analyze.py` scoring (the run-dir `accept.txt`).** The 19:33 scoring had invoked `accept_analyze.py` from the wrong path (it lives at `two_jup/accept_analyze.py`, not `two_jup/comb/`), so until 20:36 the run dir's `accept.txt` held only the Python "can't open file" error and the PER above came from `comb_period_ms.py` / `comb_census.py` alone. The controller re-ran it from the real path (commit `22eb13c`); `accept.txt` now reads: `cap: live 486s/493s [WEDGE truncated]  PER=2.667% (15644/586601)  CP95UL=2.708%  lag33=-0.014  bins={'1': 8367, '2': 3096, '3-4': 321, '5-20': 7, '21-100': 0, '>100': 0}`; `POOLED live-window: PER=2.667% (15644/586601) CP95UL=2.708%`; `wedges during captures: 1`; `GATE (<1% at CP95 upper limit, live-link): NOT MET`. The denominator differs by one from the comb tools' 586,602 (an off-by-one between the two tools' slot counts; 15,644 lost in both); the run bins agree exactly with `comb_census.py`. The `[WEDGE truncated]` / `wedges: 1` lines are the end-of-file artefact explained above.

148's TX-plane piggy witness (`cnt_mux` slots 8–15 once per 10 s, `chk148.jsonl`): `ep_gt1k` **+5 (9 → 14) across the 36 reads**, 16:32:59 → 16:38:49 (+4 over either 35-read sub-window, which is the count the ledger quotes as "+4 over 36 reads"); the prediction < 10 per 10 s holds either way. 146's own TX log: the echo of §2b at the same R and lag as on the judges.

**What it excludes [silicon]:** the ADRV9002 RX tracking calibrations (`agc`, `bbdc_rejection`, `rfdc`, `rssi`, `quadrature_fic`) and the AGC slow loop, *as reachable through these six sysfs attributes*, are not the actor, not the beat partner and not the modulator: period, phase concentration, PER, fail-class mix and run-length mix are all unchanged. Step C (the `gainUpdateCounter` bring-up) was not run — it had no remaining prediction. The reboot branch of the first pass's P2 (a plain 146 reboot without a flash) remains a valid next step after Task 36 (§11).

**A bound on "as far as these six attributes reach", from the other direction [log, `ATARM_CLASS.md` §5.1 and §9]:** the poke is not a null operation on the radio. Every `*_tracking_en` write goes through `adrv9002_update_tracking_calls()`, which moves **all channels, RX and TX, to CALIBRATED** and back — five such round trips of 146's transmitter in a row — and on this leg the **far** receiver (148, listening to 146) went into a carrier-reset storm back-extrapolated to **−4.84 s before 146's rotate** (`rstcs0` = 1,099 at 192/s); `cap/frames_peer.bin` holds **207,305** records against 31,802–39,039 on the un-poked judge legs. That is the 146→148 direction and it lands ~4.8 s *before* the scored window opens, so no 146-RX number in this section moves — but it is a second, independent reason `frames_peer.bin` is not the peer-direction control (§0), and it means the intervention cycled 146's radio through CALIBRATED on every channel, which is wider than "six sysfs attributes" suggests.

**What it does not exclude:** anything in the ADRV9002 not reachable through those attributes (the ARM firmware's own scheduled work, the SSI/clock chain), the modem fabric's RX path (no DDRCAP-class tap exists on the 146 lineage), and every 146 PS-side periodic process — which is where §10 goes.

## 9. The class

> **A 146-local periodic process at 20.382 ms (49.06 Hz) on 148's frame axis — either a direct process with a ≈ 5.7 ms active window or a 146 cadence at 835.857 µs beating against the frame rate — during whose active phase the 146 demodulator loses the frame at 24–33× its background rate: born at or upstream of the RX byte pins [silicon], hardware-timed (1 ppm) [silicon], owned by 146 with its period fixed at 146's boot [inferred from coincidence, §6] (204 ppm re-seed at a 146 reboot; unmoved by radio re-inits, by the radio's tracking loops and by the fabric lineage).** Not the Rate_Handle ring, not 146's host/DMA, not 146's host timing (§2b), not 148's TX host or TX plane, not RF level, not the ADRV9002's RX tracking loops or AGC slow loop. Owner unnamed; the DisplayPort pipeline is the one candidate on the table (§10), untested.

Excluded, each with a number:

| candidate | verdict | evidence |
|---|---|---|
| 148 TX host starvation / cadence | **excluded** | NEVER_SENT 0 / 35,666 over three legs; 0 lost frames on a > 20 µs gap; gap-train R 0.04 = null; TX-clock period = frame period to < 1 ppm |
| 148 TX fabric plane (ByteWordBuffer) | **excluded** | `air2` 148 `ep_gt1k` 0.19 /s on idle frames; Task 30 piggy `ep_gt1k` +5 (9 → 14) over 36 reads / 350 s on data frames vs 49 /s needed |
| 146 host / DMA byte plane (ByteRxFifo, S2MM boundary, carve) | **excluded** | seam checker at the pins carries 0.88–0.97 of the host loss on four legs, r 0.86–0.99; DMA geometry 12.85 / 25.69 ms |
| 146 host timing (daemon TX late submits, queue-empty gaps) | **excluded as a source; explained as an echo** | on the comb (R 0.38–0.47) but 98–99.9 % event-locked to individual losses within 12 ms (lag median 5.5 ms from the loss's processing stamp; the stall itself is one submit ≈ 0.8 ms late, ≤ 1.7 ms) on six legs incl. ring-comb legs; late submits precede the next onset only at chance; single-threaded daemon; its own design note predicts it (§2b) |
| Rate_Handle ring edge (the T19 comb) | **excluded** | push_on_full 0 on the fix image; 25.32 ms ≠ 20.38 ms; the 20.38 line pre-dates the fix (06:44, 10:51) |
| the k×192 fabric deletion class (forward residual) | **excluded as the comb** | present on 146 (243 / 338 lattice records, runs ≥ 3 at 0.4 /s) but R 0.04 at P; comb frames carry no displacement |
| RF level / AGC railing / fades | **excluded as the modulator** | RSSI sd 0.06 dB, gain 34.0 on 132 / 132 reads, r ±0.3 inconsistent; rate stepped 4× with RSSI flat; both receivers equally under-range (§5.2) |
| RF environment (interference at 49 Hz) | excluded | 1 ppm period stability over 700 s and a 204 ppm re-seed at a 146 reboot are not properties of an external source |
| **ADRV9002 RX tracking cals (5) + AGC slow loop on 146** | **excluded [silicon, Task 30]** | all six attributes written and read back; P 25.38480, R 0.7004, PER 2.667 %: unchanged |
| the AGC gain-update counter as the beat partner (first pass's candidate) | **retired** | Task 30; and a count change moves the beat ≥ 2,110 ppm vs the 204 ppm observed; the under-range asymmetry was a sign error |
| a fabric counter | no candidate | RTL literal census (§5); the lineage swap left the period within 8 ppm |
| a 146 host timer | no candidate | HZ 250, no 20 ms loop in `qpsk_tun.c` / `qpsk_perf.c`; and the loss is upstream of the host anyway |
| **146's DisplayPort pipeline** (DPDMA 120 IRQ/s, 1080p fbcon, VPLL 891 MHz, PS-GTR link) | **open — the one candidate with every required property; untested** | periodic, boot-seeded, 146-only, lineage-independent [silicon]; no low-harmonic arithmetic to 20.382 ms (§10); Task 36 decides |
| other 146 PS-side periodic work (kernel timers, driver polling, DDR refresh) | not inventoried | no `/proc/interrupts` / `timer_list` diff banked beyond the DPDMA line; next inventory if Task 36's P6 fires (§11) |

## 10. DisplayPort — the finding, what is periodic in it, the arithmetic, and what would decide it

**The finding [silicon; controller's read-only probes on both boards, 19:36–19:41, link idle; ledger `Task 36: PREREG`].** `/proc/interrupts` over 60 s: 146's `fd4c0000.dma-controller` (the ZynqMP DisplayPort DMA, `xilinx_dpdma`) fires at **120.011 IRQ/s**; 148's has fired **0 times since boot**. 146: `card0-DP-1 status=connected enabled=enabled`, an active CRTC at **1920×1080** driving fbcon on `zynqmp-dpsubdrm`, VPLL running at **890,999,848 Hz** feeding `dp_video_ref`. 148: DP disconnected, disabled, VPLL off. A monitor is plugged into 146's DisplayPort. Properties it shares with the comb: periodic; boot-seeded (the VPLL and the pixel clock are programmed at boot and never by the radio or the daemon); 146-only; lineage-independent (the PS does not change with the PL image). The property the first draft of this finding also credited — "shows up on the host (146's TX-submission timing carries the comb)" — is **withdrawn** by §2b: that signature is the daemon's reaction to the loss.

**What is periodic in a DP pipeline** [inferred; the mode timing was not read. VPLL / 6 = 148.499975 MHz is the CEA-861 1080p60 pixel clock (148.5 MHz) to 0.2 ppm, so the 2200 × 1125 1080p60 timing is assumed below; a reduced-blanking or 59.94 Hz mode would need a different VPLL]:

| element | period / rate | source |
|---|---|---|
| vertical refresh | 148.499975 MHz / (2200 × 1125) = **59.99999 Hz = 16.66667 ms** | VPLL reading, CEA timing |
| horizontal line | **67,499.99 Hz = 14.8148 µs**; active 1080 lines = 16.000 ms, blanking 45 lines = 0.667 ms | same |
| DPDMA interrupts | one VSYNC (`XILINX_DPDMA_INTR_VSYNC`, bit 27) + one `DESC_DONE(n)` per active channel per frame (`xilinx_dpdma.c:1602-1631`) → **2 IRQ/frame with one plane = 120.0 /s at 60 Hz** | driver source |
| DPDMA descriptor fetch + frame read from DDR | 1920 × 1080 × 4 B = 8.29 MB per frame → **498 MB/s continuous** (373 MB/s at 24 bpp) — structured at 60 Hz and 67.5 kHz, not bursty at 20 ms | arithmetic |
| audio | none active (fbcon only; the audio channels are enabled only by an audio client, `zynqmp_disp.c:556-580`); if any, 44.1 / 48 kHz | driver source |
| link idle / blanking symbols | BS/BE at every line (67.5 kHz); link training and status polling are HPD-event-driven, not periodic | DP 1.2 / `zynqmp_dp.c` |
| PS-GTR line rate | 1.62 / 2.7 / 5.4 Gb/s (`zynqmp_dp.c:923-929`), symbol clock 162 / 270 / 540 MHz; the negotiated rate is **[not in repo]**; 1080p60 24 bpp fits 2 lanes at 2.7 Gb/s | driver source |

The measured 120.011 IRQ/s reads either as 60.0055 Hz × 2 (92 ppm above 60.000) or as 7,200 interrupts counted over a `sleep 60` that ran 60.005 s — the count cannot resolve the refresh below ~100 ppm, so the VPLL value (60.000 Hz to 0.2 ppm) is the better number.

**The arithmetic search** [inferred] for 20.38226 ms / 49.0623 Hz (direct) or a 1,196.377 Hz partner (beat, §5.1) among them:

| candidate | value | vs the comb | verdict |
|---|---|---|---|
| refresh, direct | 16.667 ms | P / 16.667 = 1.223; 49.0623 Hz is neither m × 60 nor 60 / m | out |
| n × refresh as the beat partner | n = 20: 1,200.000 Hz → beat **45.439 Hz = 22.007 ms** (8 % off, 80,000× the 1 ppm precision); n = 19 / 21: 9.48 / 68.7 ms | out |
| the refresh that *would* beat to 49.0623 Hz | n = 20 → **59.8188 Hz** (−3,019 ppm from 60.000); n = 24 → 49.849 Hz; n = 25 → 47.855 Hz | none is a mode this VPLL can produce (59.94 Hz needs 148.352 MHz = VPLL 890.1 MHz, not 891.0; 59.82 Hz is no standard timing) | out |
| line rate 67,500 Hz | / 1,196.377 = 56.42; / 49.0623 = 1,375.8; nearest f₁ multiple 54 × 1,245.44 = 67,253.7 (Δ 246 Hz) | no integer relation | out |
| audio 48 / 44.1 kHz | / 1,196.377 = 40.12 / 36.86; / 49.0623 = 978.3 / 898.9 | not integers; no audio active | out |
| DDR contention from the DPDMA stream | continuous at 498 MB/s, modulated at 60 Hz / 67.5 kHz | inherits the refresh / line arithmetic; as a period it is 16.7 ms, not 20.4 | out as a direct period |
| link symbol clock 270 / 540 MHz | 5.50 M / 11.01 M symbols per 20.382 ms; 225,681 / 451,363 per 835.857 µs | no counter of that size known in the DP or GTR blocks | — |

**What a 6.5 ms window per cycle would be in each reading** [inferred]: as a beat with a DP-derived partner, the window is a 257 µs region of the modem frame (32 %) — the partner would have to be a ~1.2 kHz event, i.e. something happening 20 times per refresh, which no DP structure provides (1080 lines, 45 blanking lines, 1 VSYNC, 1–6 descriptor completions per frame); as a direct 20.38 ms DP process, 6.5 ms ≈ 439 lines ≈ 41 % of a DP frame, which matches neither the 16.0 ms active nor the 0.67 ms blanking interval; as DDR contention, a 6.5 ms burst every 20.4 ms (32 % duty) is not the shape of a continuous scan-out.

**Verdict of the arithmetic:** no periodicity of a 1080p60 DisplayPort pipeline produces 20.382 ms directly or a 1,196.377 Hz partner on any low-integer relation; the closest low harmonic (20 × refresh) needs a 59.819 Hz refresh, 3,000 ppm from what the VPLL is running. If the display is the actor, the coupling is not the vertical refresh at a low harmonic — it is something this desk cannot enumerate from the banked facts (a non-integer intermodulation, an audio/aux cadence not present in the probes, or DDR/AXI arbitration shaping something else's period). **The mechanism is not claimed.** The finding stays on the table on its four shared properties, and the test (§11) is cheaper than any further arithmetic.

**The two banked facts that could have decided it, and why they do not** [inferred]:

1. *The 204 ppm reboot step vs a VPLL re-program.* A DP-derived period is set by the VPLL word (a fixed FBDIV + fraction from the 33.33 MHz PS reference — identical every boot unless the mode or the word changes) and by the mode timing. A reboot-to-reboot change of 204 ppm (direct reading) has no DP mechanism short of a mode re-negotiation, and the nearest mode step (60.00 → 59.94 Hz) is 1,000 ppm, not 204; a change of 8.4 ppm (beat reading) is the size of the PS reference crystal's thermal shift across a power cycle, which any PS-clocked process would show. So the step argues weakly against the direct DP reading and not at all against the beat one — but the **pre-fix boot's VPLL and mode were never read**, so whether the display changed at that reboot is [not in repo]. Not decisive.
2. *Phase drift < 0.03 cycle over 719 s vs a free-running 60 Hz.* No DP structure gives 20.382 ms directly, so a DP actor would be a beat, and a beat inherits the 35 ppb requirement of §5.1: the PS-reference-derived VPLL and 148's 38.4 MHz device clock would have to hold their ratio to 35 ppb over 12 min and 49 ppb over 75 min. Two free-running crystals in a still lab can do that or not; nothing banked compares the two boards' clocks independently. Not decisive.

Neither fact decides. The DPDMA IRQ rate falling to ≈ 0 when the display is removed, followed by one reverse leg, is the test.

## 11. The ONE rig test — Task 36, "display off" (pre-registered by the controller at 19:42, not yet run)

**Test.** On 146, blank the display or unplug the DisplayPort cable (the controller's blank write was denied by the permission classifier at 19:44 and, per the rail, not retried — this is an **operator action**), then verify on 146 that the `fd4c0000.dma-controller` line in `/proc/interrupts` has stopped advancing (≈ 0 /s over 60 s; with the cable pulled, `card0-DP-1` reads `disconnected`); then ONE reverse leg on the fix image, no flash, no radio pokes: `w1leg_go.sh MODE=air LEG=B BOARD=146 DUR=480 R4D=1 RSSI=1 EXP=9acbe2ebe1db FIXCTL_BASE=0x0`, 148 on `9f13705d9fb0`. Display restored before the r3 restore.

**Score.** `comb_period_ms.py cap/frames.bin` (BEST line in 25.0–25.8 fr) and `rev20ms_period_phase.py` (R at 25.385 fr, FWHM, floor); `accept_analyze.py` PER with lost frames in the denominator; `chk.jsonl` seam share; `rev20ms_txlog_self.py` for the echo (§2b), expected to vanish with the losses.

**Pre-registered predictions (numbers, not adjectives).**

* **P5 — the display is the actor:** **R at 25.385 fr < 0.05** (the absent-line criterion; null ≈ 0.03) **and PER ≤ 0.30 % at CP95UL** (off-comb floor 1.0 onsets/s ≈ 0.11 % plus the k×192 class ≈ 0.12 %), against 0.97 / 1.32 / 2.83 / 2.67 % on the four fix-image legs. Then the identification step is free and reversible: plug the display back in, one more leg → the line returns at 25.385 ± 0.001 fr (the same boot; the VPLL word is unchanged) — a line that leaves and returns with the cable is the identification, mechanism still to be named (§10's arithmetic says it is not the refresh at a low harmonic, so the first look is the DDR/AXI side: `/proc/interrupts` and the PL AXI monitors during a leg with and without the display).
* **P6 — falsifier:** **R ≥ 0.5** with the DPDMA rate confirmed ≈ 0 during the window. Then the display is out, and with it the only PS-side candidate on the table. Next, in order: (a) the plain **146 reboot without a flash** (the first pass's P2 branch, still valid): P moves by ≥ 50 ppm → a boot-seeded 146 period (the inventory is then 146's PS: `/proc/interrupts` and `/proc/timer_list` diffs over a leg, the DDR controller's refresh/ZQ cadence, the ARM firmware's scheduled work); P = 25.3848 ± 0.0003 → image-fixed → the modem fabric after all, and the 146 lineage needs a DDRCAP-class tap (none exists today). (b) In either branch the beat/direct question of §5.1 stays open until a 146 clock-ratio witness exists.
* **AMBIGUOUS 0.05 ≤ R < 0.5:** one re-run, same configuration; a second ambiguous result is reported as such, not rounded.
* **Abort branches:** a wedge within 60 s of the display change, twice → report; the display change is reversible at any point. No image change, no radio pokes, no flash.

**Cost.** ~12 board-minutes (bring-up ≈ 3 min + 480 s leg + score) for P5/P6; the plug-back identification leg another ≈ 12; the reboot branch ≈ 15.

## 12. Reproducing every number

```
# Q1 census with the PEER log (148's TX log on a reverse leg) -- judges, before2, Task 30
python3 two_jup/comb/comb_census.py two_jup/comb/runs/<run>/cap/frames.bin \
    --failhdr two_jup/comb/runs/<run>/cap/failhdr.bin --txlog two_jup/comb/runs/<run>/cap/txlog_peer.bin
# period refinement, phase histograms, sub-windows, harmonics (5 legs)
python3 two_jup/comb/rev20ms_period_phase.py OUT.json
# 148 TX-log cadence, join of lost seqs, period on 148's clock (3 legs)
python3 two_jup/comb/rev20ms_txlog_peer.py OUT.json
# checker vs host per 10 s, RSSI vs loss, failhdr anatomy / lattice / onset class x phase
python3 two_jup/comb/rev20ms_chk_rssi_failhdr.py OUT.json        # judges (RUNS dict; 3b / Task 30 by overriding RUNS)
# 146's OWN TX log: comb R, band scan, lag vs RX onsets, event-lock test, frames_peer / rssi census (6 legs)
python3 two_jup/comb/rev20ms_txlog_self.py OUT.json [judge1 judge2 judge3b t30_pc t19_w1 before2_vendh]
# Task 30 line, and the accept_analyze scoring (the tool lives in two_jup/, not two_jup/comb/)
cat two_jup/comb/runs/20260905_163044_w1_t30_pc/comb_period_ms.txt
python3 two_jup/accept_analyze.py two_jup/comb/runs/20260905_163044_w1_t30_pc/cap/frames.bin   # = the run dir's accept.txt
# fix2: late-submit anatomy on 146's TX log (interval, slip, gap, lags to the previous / next onset) + air2 sensitivity
python3 two_jup/comb/rev20ms_fix2_checks.py OUT.json [t30_pc judge1 judge2 judge3b]
```

Banked outputs: `two_jup/sdd_archive/2026-09-04-rxfix/t34_evidence/` (`t34_period_phase.json`, `t34_txlog_peer.json`, `t34_chk_rssi_failhdr.json` with the 46-interval tables, `t34_window_stats.json` with the split-half / bootstrap / 50-bin histograms, `census_peertx_*.json`, from fix round 1 **`t34_txlog_self.json`**, and from fix round 2 **`t34_fix2_checks.json`**). Source facts: `host_app_k5/qpsk_hw.h` (slot geometry), `qpsk_tun.c` (RX -M path, txgap design note `:575-590`, single event loop `:2904-3006`, resync), `qpsk_perf.c:158-194` (pacing), `two_jup/bringup_r2r3.sh:171-174` (-M 16, RXQ=1), `two_jup/comb/knobs_146_final/knobs.txt` and `knobs_148_final/knobs.txt` (AGC config, thresholds), `/mnt/onetb/scratch/adi-linux-jupiter/linux/arch/arm64/configs/adi_zynqmp_defconfig` (NO_HZ, HIGH_RES_TIMERS only) + the built `.config` (`CONFIG_HZ=250`, `NO_HZ_IDLE` — the `kernel/Kconfig.hz` arm64 default), the ADRV9001 API under `drivers/iio/adc/navassa/` (`adi_adrv9001_types.h:179` `agcClkDivideRatio`, never assigned there) and the ADRV9025 sibling `drivers/iio/adc/adrv902x/devices/adrv9025/private/src/adrv9025_init.c:225,402,1575` (same field name, assigned and used as a log2 shift); `adi_adrv9001_rx_gaincontrol_types.h:80-81` thresholds; `adi_adrv9001_rx.h:174,199` RSSI / decimated-power units; `adrv9002.c:1740-1753` the sysfs reads), `drivers/dma/xilinx/xilinx_dpdma.c:39-50,1602-1631` and `drivers/gpu/drm/xlnx/zynqmp_dp.c:923-929`, `zynqmp_disp.c:556-580` (DP pipeline), `two_jup/lvds_61p44_fdd_jupiter.json` (clocks), `jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/*.v` (literal census).

**No fix is proposed here. Nothing in this fix round was measured on a board by this desk; the Task 30 and DisplayPort numbers are the controller's, cited from the ledger and the run directory.**
