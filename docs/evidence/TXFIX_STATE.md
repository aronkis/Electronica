> Evidence ledger, moved verbatim from `two_jup/TXFIX_STATE.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# TXFIX fix variants — what they change, build history, silicon state (controller, 2026-09-03 12:52)
Provenance: [RTL] = read in the netlist (file:line); [sim] = Verilator gate (two_jup/TXFIX_SIM_GATE.md); [vivado] = build logs on hdl-dev-2; [silicon] = board 148 logs; [inferred] = controller reasoning.

## 1. What each variant changes in the RTL (jupiter_240k5_byte/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/, patched by two_jup/skidfix/txfix_inject.py; cumulative F1 ⊂ F2 ⊂ F3)
- **F1 — gate the pop-enable clear on the frame boundary.** [RTL] `Data_Bits_FIFO.v:272-289`: the latch that enables RAM pops was cleared on ANY `enb_1_2_0` tick where the delayed frame count read 0 (`Compare_To_Constant1_out1 = Delay3_out1 == 2'b00`, :270). F1 moves that clear inside the `sampleCount == 0` branch (`Compare_To_Constant3_out1`, :220), so a zero seen mid-frame can no longer stop the pops. On every tick where the count is nonzero the logic is identical (`Compare_To_Constant2_out1 ≡ ~Compare_To_Constant1_out1`, :248 vs :270), which is why the golden digest is unchanged [sim G3: streams byte-identical].
- **F2 — F1 + guard the frame counter against wrapping.** [RTL] `RAM_Frame_Status_Indicator.v:66-94`: the 2-bit `frameCount` had unguarded ±1 (3→0 on a push-wrap, 0→3 on a pop-wrap). F2 saturates it at both rails (simultaneous push- and pop-wrap stays a no-op). This removes the way the mid-frame zero arises. F1 alone is insufficient [sim G8]: under the natural abort the frame-boundary reload can still sample a wrapped zero and ~1 pop per event is lost (pops 24,639 vs 24,640 — a slow bit slip).
- **F3 — F2 + throttle the producer (fullRAM runaway fix).** [RTL] `Bit_Packetizer.v` end: `dataReady = DataReadyPaceCmp_out1 & Logical_Operator2_out1` (= ~fullRAM), so the producer's ready drops while the RAM is full instead of a frozen pace toggle leaving it stuck high; `MATLAB_Function1.v`: the 16-bit occupancy `count` saturates instead of wrapping past 65,535. Effect: the existing back-pressure works, so the +26 preamble slots over-pushed per frame self-limit at the full threshold (overshoot 1 bit [sim G11]) instead of running away and over-writing ~16k RAM bits [sim G12 on F1/F2]. **F2 vs F3 differ in exactly this one thing.** No variant corrects the over-push at its source (that would change the data plane and the golden digest) [inferred, plan decision]. F3b (16-bit threshold margin) exists as an injector flag and is NOT needed [sim G11].

## 2. Vivado build history (host hdl-dev-2, Vivado 2025.1, JOBS=6) [vivado]
| variant | launched | finished | duration | outcome |
|---|---|---|---|---|
| F1 | never | — | 0 | Disqualified by sim gate G8 (12:3x) BEFORE any kit was made or any build time spent; the plan's second build was decision-gated on G8. |
| F2 | 12:37:00 | (running) | — | Kit made 12:36:30-12:37:00 (injector eef5d48, zips=2 verified); IMPL_STRATEGY=explore; in synthesis at 12:50; estimate routed ~13:25. |
| F3 attempt 1 | 10:09:34 | 10:13:05 | 3.5 min | Died in the ADI axi_adrv9001 IP synthesis on a Vivado temp-file error (`./.Xil/.../genlib`); environmental, no image. |
| F3 attempt 2 | 10:15:12 | 11:45:23 | 90 min | Image md5 873902b705fb produced, but ROUTED WNS −0.392 ns / TNS −17.7 / 56 endpoints, all in the tx_checker instrument counters (fill_reg[3] → bit_errors/frame_errs, 24-25 logic levels), not in the fix; discarded, never flashed (kept on hdl-dev-2 as BOOT.BIN.attempt2.wnsfail). |
| F3 attempt 3 | 11:48:00 | 12:32:41 | 45 min | IMPL_STRATEGY=explore (ExtraTimingOpt place, AggressiveExplore route, phys_opt pre/post); routed WNS +0.095 ns, TNS 0; post-synth modem WNS +1.544; no latch inference; banked as boot_known_good/BOOT.BIN.148.txfixF3.f6a8c3ea119c. |
Build flow change made today: `txfix_build.tcl` now refuses to bootgen a routed-WNS-failing implementation (`TXFIX_ROUTED_TIMING_FAIL`).

## 3. Silicon state [silicon]
- 10:16-10:32 baseline on 638b36de3493 (positive control): fresh arm ARM_OK fps=1247, 420-row 0x108 timeline → BURSTS n=7 (~120 s spacing). The witness sees the beat.
- 12:36 F3 f6a8c3ea119c flashed under full rails: readback matched 12:37:45, GATE_PASS ×2 (ARM_OK fps=1248, capTAP 0xBCF94856 both passes — pre-registered prediction upheld), witness tOff 12314 steady; FLASH_DDRCAP2_OK; rollback 638b36de3493 verified on board.
- 12:41-12:54 F3 420-row timeline [silicon]: TIMELINE_OK secs=420 (792 s wall), gaps=0, pre/post capTAP golden, **BURSTS n=0**, 0x108 total errors over the window = 0 (baseline image on the same day: n=7 bursts, ~55-100 errs/s quiet). Caveat: 0x108's liveness on the fixed image is not independently demonstrated (post-arm errps=0 on both gate passes); the primary evidence is the sel6 512 MB witness launched 12:55 (unit txfix-wit-F3-125517): stall runs + per-frame offset-map lookups across all frames. Verdict rules: PASS = BURSTS n=0 AND `"stalls": []` on a credited capture (pre/post golden AND bytes=536870912) AND gate golden; see ledger PREREG.

## 4. Claim boundary once the silicon run is in [inferred]
Entitled on a PASS: on the fixed image, with the same witnesses that saw the beat (7 bursts) and the stalls (6 runs) on the unfixed image, no bursts over ≥ 3 beat periods, no constant-symbol stall runs in 512 MB, golden word and frame rate unchanged. Not entitled: that the sim scorer would detect a stall on a fixed tree (the G6 latch-force control is unresolved — a scoring-criterion artefact, sim-only); anything about F1/F2 on silicon; that the 120.2 s trigger is understood (it is not; the fix removes the abort path regardless of trigger). Follow-up for confidence: a longer soak.

## 5. RESULT (2026-09-03 12:57) [silicon]
**F3 PASSES the pre-registered silicon acceptance.** Flash OK (GATE_PASS ×2, fps=1248, capTAP golden); 420-row timeline BURSTS n=0 (0x108 = 0 throughout — corroboration, liveness caveat above); 512 MB sel6 witness credited (536,870,912 B, pre/post golden), stalls=0, Tier-2 PASS, and the content-level check: 5,449 frames all at offset 0 in the injective map with 0 transitions, max constant-symbol run 7, tOff steady 12314. Same witnesses on the unfixed image today: 7 bursts / window, 4–6 stall runs and 4–5 offset transitions per 512 MB. Claim (within the boundary of §4): on F3 the 120.2 s transmit stall and its data displacement are absent over ≥ 3 beat periods, with the golden word and frame rate unchanged. F3 stays on 148, banked as VERIFIED. F2: bitstream banked only, not flashed (ruling). Follow-ups: longer soak; 0x108 liveness demonstration on the fixed image; the 120.2 s trigger mechanism (open); G6 control redesign.

### 5a. Phase-timed witness (13:07–13:12) [silicon]
Because the beat is arm-locked (baseline: first burst 79 s after ARM_OK, then every 120.2 s), a fresh arm on F3 was followed by two 512 MB sel6 captures started at ARM_OK+76 s and +196 s, i.e. 4.4 s windows over the two expected burst onsets. Both credited (full size, pre/post golden). F3p1: 5,447/5,447 frames at offset 0; F3p2: 5,450/5,450 at offset 0; 0 transitions; 0 stall runs; max constant run 7. The content-level witness therefore covers the burst phase directly and does not depend on the 0x108 counter. Script: two_jup/txfix_phase_witness.sh; data: two_jup/txfixwit/*_F3_phase/.

## 6. ADDENDUM (2026-09-03, final-review documentation round) — corrections, §5 and §3 left as written

This block is **appended**, not a rewrite. The bodies of §3 and §5 above are unchanged; read them
through the corrections here.

**(a) `0x108` did not read zero. Read it as "cumulative 67, constant → delta 0".** Two phrases above
are stale and are corrected here, not in place:
- §5's "0x108 = 0 throughout", and
- §3's (12:41-12:54 line) "0x108 total errors over the window = 0".

The evidence is `two_jup/beattl/20260903_124118/errps.csv`: 420 data rows, and the `errs` column
holds the **constant cumulative value 67 on every one of them**. The **delta over the window is
zero**, which is the quantity both sentences meant and the quantity `BURSTS n=0` rests on — so the
F3 PASS and the burst verdict are **unaffected**. Only the description of the register value was
wrong.

**(b) The 67 is weak but real liveness evidence, which §5's caveat missed.** `arm148_mode1.sh`
writes only `0x10C 0x60003` (iq_debug_mux select) and then *reads* `0x104`/`0x108`; **nothing in the
arm path writes `0x108` or resets the BIST**, so the counter is free-running and **not reset by an
arm**. The two timelines confirm it: the baseline run's first row is already **222,137** at 10:18
after a 10:16 arm (rising to 2,087,524), while F3's first row is **67** at 12:41 after the 12:37
boot and two gate arms. Those 67 counts accumulated on `f6a8c3ea119c` during the post-boot arm
transients — **the counter did count on the fixed image**. A counter dead at reset would read 0, not
67. It is *weak* evidence (a small sample during transients, not a controlled injection) but it is
real, and §5's caveat should be read as qualified by it rather than as "liveness undemonstrated".

**(c) The `0x108` feed is timing-clean on the flashed image.** The paths that failed timing in **F3
attempt 2** — `fill_reg[3]` → `bit_errors`/`frame_errs`, routed WNS **−0.392 ns** (§2 table above) —
**are** the `0x108` feed: the tx_checker instrument counters. That image was never flashed. The
flashed attempt-3 image closes them at **+0.095 ns**, and the unfixed comparison image
`638b36de3493` closed them at **+0.105 ns**. The counter's feed is therefore timing-clean on *both*
images in the n=7 vs n=0 comparison, so that difference cannot be a setup-violation artefact on the
instrument.

**(d) "frameCount pinned at 3" is the pre-throttle state.** Any statement that `frameCount` is
pinned at 3 describes only the state **before fullRAM throttling engages**; once fullRAM throttles,
the counter **oscillates 2↔3**. (Recorded here for the record — no such phrase was found in §1-§5 of
this file at the time of the correction round; see the final-fix report.)

**(e) Still open.** `beat_timeline.sh` populates no packets column on either image, so a *low-rate*
counter fault and a clean link are still not fully distinguished by that instrument alone, and no
known error was ever injected on `f6a8c3ea119c`. Ruling [12:55] stands: the **sel6 witness is the
primary silicon evidence**; the `0x108` null is corroboration.

## 7. PER attempt (13:15–13:36) [silicon]
`ber_loopback_gate.sh DUR=180` (148 internal digital loopback, byte-DMA TX source, lvds_1p92_mhz profile) on F3 and, as a pre-registered control, on the unfixed 638b36de3493 (reflashed under full rails in between):
| image | sent | rx_ok | crc_drop | rx/tx | -B frames | BER | CLEAN |
|---|---|---|---|---|---|---|---|
| F3 f6a8c3ea119c | 77,064 | 6,854 | 149 | 0.089 | 7,006 | 0 | 99.6 % |
| unfixed 638b36de3493 | 77,177 | 6,846 | 152 | 0.089 | 6,999 | 0 | 99.6 % |
Identical. The 91 % loss is the gate's own rate-limited whole-frame swallow (host offered rate ≫ modulator drain at this profile), not the fix: **no byte-DMA regression on F3**, and **no PER number for the beat from this tool** — a paced or over-RF RXONLY measurement (dropped frames in the denominator, ≥ 10 min) is the way to get one. F3 reflashed afterwards (unit txfix-flash-F3b-133610), board left in mode-1 by the chain's gate.

## 8. Over-RF PER ballpark (14:13–14:51) [silicon] — runbook two_jup/PER_BALLPARK_RUNBOOK.md, shipped defaults (RXQ=1, LO_A_RX=2000020000, LO_B_RX=1900040000), accept_analyze.py on the TX sequence span (lost frames in the denominator)
| leg | TX image | live window | PER (miss/span) | CP95 | >100-frame events | note |
|---|---|---|---|---|---|---|
| forward 146→148 | 146 vendh ec414d2df8bc (UNFIXED) | 722 s | **10.974 %** (96,598/880,208) | 11.04 % | **18** — bursts at 120.3/242.1/362.0/483.8/603.7 s, 3-4 events of 1,203-1,277 frames each (the §87 states) | the beat ≈ 2.5 pp of the 11 % |
| reverse 148→146 | 148 txfixF3 f6a8c3ea119c (FIXED) | 719 s, wedge-truncated (2nd wedge on this leg) | **3.873 %** (33,954/876,794) PROVISIONAL | 3.91 % | **0** | formally UNINFORMATIVE by pre-registration (wedge); the wedge-aware window is reported with that label |
| forward 146→148 AFTER | 146 txfixF3vendh 6b4744ca73f8 (FIXED) | 722 s | **8.056 %** (70,909/880,208) | 8.11 % | **0** (21-100: 3) | prediction 0 events / 8.5 ± 0.7 % MET; −2.9 pp vs before; singles/doubles unchanged; total confounded with fresh placement, burst-class disappearance is not |
August references (fe5bd8a4fe19, -d 68): forward 8.732 %, reverse 1.391 %.

## 9. CLOSING (written 2026-09-04 13:40 at the operator's request; nothing new was run — every line below is from the 09-03 ledger two_jup/sdd_archive/2026-09-03-txfix/progress.md, this file's §3–§8, and the banked artefacts)

### 9.1 F3 verdict — the sel6 offset-map census
- **It ran.** Unit `txfix-wit-F3-125517`, capture `two_jup/txfixwit/20260903_125517_F3/cap/F3.bin`, credited (536,870,912 B, pre/post capTAP golden). Scorer `two_jup/sel6_stall_geometry.py` → `F3_stalls.json`: `n_frames 5449, stalls []`. Controller content check: 5,449/5,449 frames resolve in the injective offset map at offset 0, 0 offset transitions, max constant-symbol run 7 (runs > 50 = 0), tOff distinct 1 (12314), demod period 12320. Phase-timed repeat (§5a, unit at ARM_OK+76 s / +196 s = the arm-locked burst onsets): F3p1 5,447/5,447 and F3p2 5,450/5,450 at offset 0, 0 transitions, 0 stall runs.
- **Positive control fired.** The same scorer on the unfixed image's sel6 captures — `two_jup/beatcap/20260902_184821_sel6` and `20260902_185552_sel6` (the 09-02 captures; no unfixed sel6 capture was taken on 09-03, the 09-03 baseline run was the 0x108 timeline) — gives 4–6 constant-symbol stall runs and 4–5 offset transitions per 512 MB (§87 geometry: one constant hard symbol from mid-frame to frame end, new offset = old − L). So the census detects the defect on the unfixed image and finds none on F3. [silicon]
- **Against the §4 claim boundary:** (a) no bursts over ≥ 3 beat periods — the 420-row timeline spans 792 s wall = 6.6 beat periods with BURSTS n=0, and the two phase-timed 512 MB windows sit on the first two burst onsets after a fresh arm: MET; (b) no constant-symbol stall runs in 512 MB — three credited 512 MB captures, 0 runs each: MET; (c) golden word and frame rate unchanged — capTAP 0xBCF94856 on both gate passes, fps 1248 (baseline 1247): MET. The pass does NOT rest on 0x108: the 0x108 timeline is corroboration only (its value was the constant cumulative 67, delta 0 — §6a/§6b), per the 12:55 ruling.
- Not claimed (unchanged from §4): the 120.2 s trigger mechanism; anything about F1/F2 on silicon; a soak longer than ~13 min.

### 9.2 F3 disposition — what is on 148 now
- F3 `f6a8c3ea119c` was reflashed once on 09-03 (after the §7 control) and stayed on 148 until **2026-09-04 00:10:47**, when the SEQ-BIST campaign flashed **`BOOT.BIN.148.seqbist.a1ff3c876d91`** (unit `flash148-seqbist`, exit 0; SEQBIST ledger line 146). The SEQ-BIST image is the SEQ-BIST kit built ON TOP of the txfixF3 tree (F3 included, WNS +0.112), plus the TGEN v2 / rx_seq_checker instruments.
- **148 today [record, last flash event 09-04 00:10]:** `a1ff3c876d91`. Banked restore point on 148: `boot_known_good/BOOT.BIN.148.txfixF3.f6a8c3ea119c`, on-board copy `/root/BOOT.BIN.f6a8c3ea119c.bak`. No flash of 148 has been ledgered since (the RXFIX campaign has flashed nothing; its Task 9 is build-only). 146 likewise: `3378861d30bd` (seqbist on txfixF3vendh) since 09-04 03:35, rollback `6b4744ca73f8`.
- Not verified now: a live md5 read of /boot on 148 was not taken for this section (operator asked for record only).

### 9.3 F2
- **Synthesis finished:** hdl-dev-2, 12:37 → 13:22:31 on 09-03 (45 min, IMPL_STRATEGY=explore), routed WNS **+0.056 ns**, TNS 0.
- **Banked:** `boot_known_good/BOOT.BIN.148.txfixF2.5e3f58955f02` (md5 5e3f58955f022454f2cfbacfe1e41c8a), 09-03 13:23.
- **Never flashed.** Ruling 09-03 12:57 (ledger line 166): "F2: bank the bitstream with its routed timing, DO NOT flash (operator preference; F3 clean; attribution value already established in sim)". No F2 flash appears in any ledger since. F1 was never built for silicon (disqualified in sim by G8).

### 9.4 One-line status
**120.2 s transmit beat: CLOSED on silicon [silicon, 2026-09-03] — F3 (frame-boundary-gated Data_Bits_FIFO pop-enable clear + saturating frameCount + fullRAM throttle) removes the transmit stall: 0 stall runs / 0 offset transitions in 3 × 512 MB sel6 witnesses (16,346 frames, two at the arm-locked burst phases) and 0 bursts in 6.6 beat periods, against 4–6 runs / 4–5 transitions per 512 MB and 7 bursts per window on the unfixed image with the same witnesses; link-level confirmation: forward-leg >100-frame loss events 18 → 0 and PER 10.97 % → 8.06 % after fixing 146's transmitter (§8, capture_r3 -d 600, lost frames in the denominator). Open, not needed for the fix: the 120.2 s trigger mechanism [inferred: frameCount ufix2 wrap on the +26 slot/frame RAM drift].**
