# NEXT STEPS after the RXFIX campaign (2026-09-04 21:00) — forward comb FIXED on 148; reverse leg open

**State:** 148 runs `boot_known_good/BOOT.BIN.148.rxfixr4b.9f13705d9fb0` (F3 + SEQ-BIST + W1 witness + RXFIX_R4B), forward PER 8.309 → 0.224 % [silicon] with the 25 ms comb absent; rollbacks 2728dab3979a (W1) and a1ff3c876d91 (SEQ-BIST) banked. 146 runs 3378861d30bd (no W1, no steering). Record: two_jup/RXFIX_STATE.md ("SILICON VERDICT"), ledger two_jup/sdd_archive/2026-09-04-rxfix/.

1. **Reverse leg (146 RX, FULL edge, 3.7 → ~1.4 % today).** R4B is 148-only (positive SRO regresses it, +10 ppm sim 4.99 → 6.65 %); R4D (extra pop) is REFUTED — the Preamble_Detector realignment FIFO deletes the +1 valid and Timing_Adjust desyncs from Peak_Search. Options, operator's call: (a) bring the F3 lineage into the Verilator harness (8 extra top-level ports tie-offs, first-ever F3 sim, its own baseline), then gate R4D + enSlack (fixctl bit 3 = PD FIFO slack) on n_p10 — ~2–3 h desk + legs; (b) a push-side drop scheduled into the next preamble (needs the same harness); (c) leave 146 as is. Before any 146 flash: W1 on 146 first (the FULL-edge witness has never fired anywhere) and the sign cross-check re-read.
2. **Never deploy R4B on a board whose SRO sign is unmeasured** (fresh pair: measure the RX-LO residual sign first; the fast-XO receiver gets R4B). CURRENT.txt keeps role A = SEQ-BIST for that reason.
3. **Residual 0.22 % forward** = the pre-existing burst/RF class (5–20-frame bursts 220 → 161 per 10-min leg); not the comb. Next instrument: the checker's interval histogram against RSSI/AGC events.
4. **Instrument gaps:** push_on_full never exercised (sim or silicon); pop_on_empty's arm-transient liveness read the same 44 across a re-arm on R4B (labelled NOT EXERCISED); 0x104 is not behind the W1 freeze (census-vs-frames pairing is a bound, not exact); `chk_lost_slots` is not a counter on these images; `slackleg_go.sh` shares the DRA address-select — never add a second concurrent reader.
5. **Housekeeping:** docs/PROVENANCE.md "current image" is stale (lean dcf5c5fb); sro_sim leg data files are untracked (compact _res/_skipwin/_seq files committed for R4B/R4D only); the seq 133/134 loss on n_m10 is a deterministic pre-arm receiver event on that stimulus, not a fix target.

## SEQ-BIST overnight 2026-09-03/04 (read first) — state at 03:1x
- Report: two_jup/OVERNIGHT_20260904_SEQBIST.md (timeline, every number labelled); ledger two_jup/sdd_archive/2026-09-03-seqbist/progress.md; plan ~/.claude/plans/happy-bubbling-owl.md.
- Images: 148 = seqbist a1ff3c876d91 (flashed 00:10, rollback txfixF3 f6a8c3ea119c banked); 146 = txfixF3vendh 6b4744ca73f8 (seqbist 3378861d30bd built+banked, flash pending). Keeper hold + SENTINEL_STOP + RIG_LOCK in place; sentinel stopped; plain daemons must be restored and the hold released at the end (or by 06:30).
- Established tonight [silicon]: fabric-only path works (checker tracks 0x104 to 0.01 %, both positive controls pass); fabric loopback loss floor 0.058 % (filler-adjacent single slots, no 26 ms structure); on-air comb NOT from host DMA knobs, radio AGC/tracking cals, host payload (whitening null, credited), host TX starvation (desk), or SRO; self-reception of any byte-plane (TGEN) stream fails to hold sync while the ROM path self-couples at 1,246 f/s (CFO and payload entropy excluded; TX attenuation probes running).
- 05:3x MECHANISM FOUND [silicon]: TX clean (sel8 desk); the receiver's valid chain deletes one symbol every ~32 frames at the inter-node sample-rate offset (≈2.5 ppm; the old ≤ 0.06 ppm bound is retracted) between the interpolator and the correlator (Symbol_Synchronizer/Rate_Handle) — comb period = 1/(12,333 × SRO). Rig handed back 04:46 (plain daemons, hold released, sentinel ok). 06:3x [correction 2026-09-04, RATE_HANDLE_FIX_SURVEY.md]: mechanism: one-sided symbol deletion at the inter-node SRO, deleting stage being re-localised (Rate_Handle full edge vs Preamble_Detector realignment FIFO); the ring is guarded — see two_jup/RXFIX_STATE.md and the RXFIX ledger (two_jup/sdd_archive/2026-09-04-rxfix/progress.md) for the current localisation state (COMB32_SRO_SIM_2p5.md: −2.5 ppm → period 32.375, 4.1 % loss; +2.5 ppm → 0 loss — numbers unaffected). Next: (1) FIX = make Rate_Handle elastic: guard the ring and re-centre its occupancy by asserting the sample_discard/insert mechanism upstream (a SAMPLE, never a symbol) whenever occupancy leaves the mid-band, or replace the rigid 1-in-4 pop with an occupancy-driven pop; (2) originally-planned fix = elastic symbol-rate handling (absorb the offset as a SAMPLE discard/insert inside the interpolator path, never a symbol deletion downstream) — sim-gated on the SRO harness at ±5 ppm, built with the seqbist BD so the checker judges it at the decoder pins, then capture_r3 PER; (3) cheap cross-check: does a device-clock trim on 146 (if the ADRV9002 driver exposes one) move the comb period as 1/SRO predicts.

## Current state
- **148 is running F3 `f6a8c3ea119c`** (`boot_known_good/BOOT.BIN.148.txfixF3.f6a8c3ea119c`),
  banked VERIFIED, armed mode-1, idle. GATE_PASS ×2 (`fps=1248`, capTAP `0xBCF94856`); 420-row
  `0x108` timeline `BURSTS n=0` over 792 s; credited 512 MB sel6 witness `stalls=0`, 5,449/5,449
  frames at offset 0, max constant-symbol run 7, `tOff` 12314 steady. [silicon]
- **Rollback bank `638b36de3493`** (DDRCAP-v2, unfixed) verified on-board as `.bak`; second-level
  bank `1cd0cd752aa6` (txmark). `638b36de3493` is now **the only image on which the beat can still
  be observed** — reflash it (full rails) before any further trigger hunting.
- **146 untouched** throughout the campaign, as required.
- **Sentinel + keeper are STOPPED** (`~/modem-status/SENTINEL_STOP` present). The link is out of
  service. **Operator decides when to restart**:
  `systemctl --user start sentinelkeeper-004023.service` and remove `~/modem-status/SENTINEL_STOP`.
- **F2**: sim-clean (G9/G10 PASS, `zeroEvents=0`) and its Vivado build (`IMPL_STRATEGY=explore`,
  JOBS=6) was launched 12:37 and still running at write-up. **Bank only — do NOT flash** [Ruling
  12:57]: F3 is clean on silicon and the F1/F2/F3 attribution is already settled in sim.
  → *Controller: append the F2 BOOT.BIN md5 + routed WNS here and a `BUILT, NOT flashed` row in
  `boot_known_good/README.md` when the build lands.*
  **F2 md5: `5e3f58955f02` · routed WNS: `+0.056 ns`** — build landed and banked as
  `boot_known_good/BOOT.BIN.148.txfixF2.5e3f58955f02` (`IMPL_STRATEGY=explore`); the
  `boot_known_good/README.md` row records it as **BANK-ONLY, not flashed and not to be flashed**
  [Ruling 12:57]. Filled 2026-09-03 from that README row.
- **F1 was never built.** Disqualified by sim gate G8 (`zeroEvents=14`, `pops` 24639 not 24640)
  before any Vivado time was spent.

## Follow-ups, in priority order
1. **Longer soak on F3** — the largest gap. Total observation on the fixed image is under 15 min.
   Pre-registration sketch below.
2. **Strengthen the `0x108` liveness evidence on `f6a8c3ea119c`.** *(Corrected 2026-09-03: this item
   previously said "the counter read exactly zero for 792 s". It did not — `beattl/20260903_124118/
   errps.csv` holds a **constant cumulative 67 on all 420 rows → delta 0**. The `BURSTS n=0` verdict
   is unaffected, since it rests on the delta.)* The timeline's `n=0` remains *corroboration only*,
   but the counter is no longer un-evidenced: it is **not reset by an arm** (`arm148_mode1.sh`
   writes only `0x10C 0x60003`), so those 67 counts accumulated on F3 between the 12:37 boot and the
   12:41 start — weak but real proof it counts on this image — and its feed paths close at
   +0.095 ns on the flashed image (they were the −0.392 ns failures in attempt 2). What is still
   missing is a *controlled* demonstration: `beat_timeline.sh` populates no packets column, so a
   low-rate fault and a clean link are not fully distinguished. Either populate that column or
   inject a known error and watch the counter move. In all cases quote `0x108` only as a
   120-bit-window counter delta — never as a frame error rate, PER or BER, on either image.
3. **Redesign the G6 control [sim, host-only].** A raw latch write lands outside the 12,320-entry
   tap3 vocabulary, so the strict scorer returns `None` and the control cannot separate "clean
   displacement" from "lost demod lock". Either force through a natural RTL transition instead of a
   register poke, or diff the g6 run byte-for-byte against G0's baseline around the force point.
   Until this is closed, detector liveness on the fixed trees is inherited from G1+G3, not shown.
4. **Resolve the fullRAM underflow direction (G12) [sim, host-only].** Over-push runaway on F1/F2 is
   confirmed; the underflow direction is **not**. Needs per-clock (not change-detection) sampling
   around the drain event on an untrimmed-NF re-run — the current evidence is 2 samples with
   `near_65536_seen=False`. Does not affect F3 (G11 clean, overshoot 1).
5. **The 120.2 s trigger remains unidentified.** Every structure found ticks at 0.761 s / 1.52 s /
   3.04 s; 120.2 s is 40-80× slower. Purely scientific now — the fix removes every abort path found
   regardless of what schedules them — and it requires reflashing `638b36de3493` to study.
6. **Merge/PR decision.** Branch `per-under-1pct-2026-07` is **NOT pushed** and nothing is merged —
   the whole campaign is local-only. *(Corrected 2026-09-03: this line previously read "is pushed",
   which was false.)* Verify before acting:
   `git rev-list --count origin/per-under-1pct-2026-07..HEAD` (non-zero = unpushed commits; it read
   38 at the time of this correction and grows with every commit, so do not trust a quoted number).

## Pre-registration sketch for the longer soak (to be finalised before running)
- **Image**: `f6a8c3ea119c` (F3), already flashed — no flash cycle needed. Fresh arm first
  (`baseline_arm148.sh`, must print `ARM_OK fps≥1120` + capTAP golden) so the soak shares the
  post-arm phase of the accepted run [same rule as R2].
- **Duration**: **N = 8 h** proposed (≈ 240 beat periods; the accepted run covered ~6.6). Minimum
  useful N = 2 h (60 periods). Choose N up front and do not extend to chase a result.
- **Witnesses — the same two, unchanged**, so the comparison is against today's numbers:
  (a) continuous `0x108` timeline via `beat_timeline_go.sh` at the ~2 s ssh cadence, chunked into
  420-row segments so a single failure does not lose the run; (b) periodic 512 MB sel6 DDRCAP
  captures via `txfix_witness_go.sh`, scored by `sel6_stall_geometry.py` + `ddrcap2_pc.py --sel 6`
  + the per-frame tap3 offset-map lookup.
- **Capture cadence**: one 512 MB sel6 capture at t = 0, then **every 60 min** (8 captures over 8 h,
  ≈ 35 s of air time sampled in total). Each capture must be *credited*: `bytes=536870912` **and**
  pre/post capTAP golden, or it is UNINFORMATIVE and re-taken once on the same arm.
- **PASS (conjunctive, pre-registered)**: zero bursts across the whole timeline (`beat_detect.py
  --per-second`, Δ≥5000 for ≥2 consecutive rows), no poll gap > 4 s [R3], `"stalls": []` and zero
  offset transitions on **every** credited capture, max constant-symbol run < 50 (a whole-frame
  stall would be a ~12,320-symbol run — this is what closes the frame-identity limit, since a
  displacement of D ≡ 0 mod 12,320 reads as offset 0), capTAP golden and `fps ≥ 1120` at every arm.
- **FAIL**: any burst, any stall run, any offset transition, or a gate/capTAP failure → FINDING, the
  image's VERIFIED status is qualified, no retry loop.
- **UNINFORMATIVE**: board unreachable (PHYSICAL ATTENTION), timeline abort, or an uncredited
  capture that fails its one re-take.
- **Positive control**: the soak has none of its own — 148 will be running the fixed image. The
  control it inherits is today's baseline on `638b36de3493` (`BURSTS n=7`, 4-6 stall runs per
  512 MB) taken on the same day with the same scripts. If the soak instead reflashes the unfixed
  image for an interleaved A/B, that is a *different, heavier* experiment: full rails per flash, and
  a fresh pre-registration.
- **Rails**: 148 only, 146 never; sentinel stays stopped for the duration; all long runs as
  `systemd-run --user` units with `watch_unit.sh` watchers and `lanes.json` entries (register the
  growing output file, **not** the log — these harnesses write only at exit [R5/R7]); polls ≥ 1 s;
  never kill an arm.
