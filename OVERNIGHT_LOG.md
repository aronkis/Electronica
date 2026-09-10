# OVERNIGHT LOG — 2026-08-17/18 — TGEN + Layer-B hardware debug

**Directive:** finish the TGEN plan (Tasks 7–9 + final review), then fully debug Layer B
on hardware across configurations (rate × gap × length sweeps); fix and re-verify any
issues found. Fully autonomous; commits at each milestone.

**State at start (18:5x EDT):**
- Branch `per-under-1pct-2026-07`, HEAD `ec74d34` (pushed). TGEN plan T1–T6 complete,
  review-clean (ledger: `.superpowers/sdd/2026-08-17-traffic-gen/progress.md`).
- 148 flashed with TGEN image `c183d42911b3` at 18:39, all rails green
  (readback verified, NAK=4, HEALTH_GATE_PASS fsync=1260 wcnt=1259, GPIO readbacks
  0x9D400000/0x9D400008 both zero = pass-through default). 146 = TMR `433fd8dab393`,
  frozen, never flashed.
- Task 7 implementer subagent was reaped before its equivalence run; flash chain had
  already completed. Controller (this session) takes over T7's remaining steps.

---

## Timeline
- 20:25 T7 equivalence run 1: **MID_CAPTURE_WEDGE** (delivery flatlined 12 s, aborted,
  data discarded) — the known #48 byte-plane wedge class; occurred with the TGEN image
  in pass-through, consistent with class being image-independent. Log banked:
  `t7_equiv_r1_wedged.log`.
- 22:39 T7 equivalence retry (wedge retry 1/1, allowed by brief) launched detached,
  PID-based watcher armed (first watcher had a self-matching pgrep bug — never fired;
  the ~2h gap between wedge and retry is that bug's cost, caught by the 15-min cron).
- 22:47 **T7 equivalence PASS**: fwd PER 8.35 % (5508/65927, CP95-UB 8.57 %) inside the
  8.2–8.4 % brief band → TGEN splice passively transparent. Commits ca53a5a (results)
  + b61eb45 (review fixes: explicit 0x1C0-delta health-gate assertion, band provenance).
  Task review: spec ✅, 0 Critical, 3 Important (all addressed/adjudicated); scoped
  re-review in flight.
- 22:49 **T8 generate-mode smoke run 1: FAIL — but hardware exonerated.** Scorer showed
  ok=0 junk=75717; forensics on /dev/shm/seq_raw.log hex dumps found 21,619 non-zero
  junk frames tracking the tgen enable window exactly, with BIT-PERFECT content:
  magic "QK", len 1516, sequential seqs, CRC-const 21 4E 47 54. Root cause: the scorer's
  qpsk_frame_decode computes real CRC32; the generator (by design, Approach 1) writes
  the constant 0x54474E21 → every frame fails decode → never anchors → all junk.
  The T4 scorer patch (QPSK_SEQ_RXONLY) was incomplete — it disabled TX but never taught
  the scorer to accept generator frames.
- 22:58 **Fix committed (1fd6db2)**: qpsk_seq.c TGEN structural accept (magic + len +
  CRC-const gate on QPSK_SEQ_RXONLY), scores payload bits vs regenerated PN(fill)+pad,
  anchors/attributes like decoded frames; selftest extended with positive + negative
  controls (both pass). Deployed to 148 (BUILD_OK, NAK-stat preserved); 146 untouched.
- 23:01 T8 smoke re-run launched with fixed scorer.
- 23:14 **T9 rate sweep complete** (fill=1516, 60 s/point, CSV tgen_sweep_20260817_230559.csv):
  250 f/s → 6.0 % (outage-dominated); 624 f/s → 0.39 % (pure singles, cleanest point);
  1038 f/s → 7.0 % + first scattered/biterr class (35 frames, BER 9.0e-5); 1221–1245 f/s
  → 66.8–68.5 % COLLAPSE with generator seq span at 1870 f/s > line rate → the DUT
  byte-TX interface over-asserts ready and swallows whole accepted frames (direct
  reproduction of the FIFO-swallow mechanism). Class-B ~1 s outages episodic (absent in
  the 624 f/s run). Length sweep (fills 1516/700/100/1 at gap=100000) now running.
- 23:18 **T9 length sweep**: fill=700 clean (0.44 %); fill=1516 rerun showed outage
  episodes (5.4 % — bimodality confirmed at identical config); fill=100 7.4 %;
  **fill=1 collapsed the link** (1262→53 f/s) and the wedge PERSISTED through tgen
  disable AND a full bring-up restore (148 dma_rx_ok=9 post-restore) — #48 signature,
  now with a deterministic-looking trigger. Committed harness+CSVs+analysis (a1673e1).
- 23:21 Fill bracket (0/2/16/1, 20 s) ran on the still-wedged link — inconclusive for
  fill=2/16 (order contamination); fill=0 passed some frames at degraded rate.
- 23:24 Rebooted 148 to clear the wedge (image c183d42911b3 unchanged); restore +
  two-pass verify + clean-order bracket queued.
- 23:31 **Clean-order bracket (healthy link, verified 1245 f/s first): fill=16 wedged
  the link MID-POINT** — 1,436 frames delivered clean for ~3 s, then collapse; fill
  2/0/1 afterward dead (contaminated). Trigger = SHORT-FILL CONTENT (≤16 B), not
  fill=1 specifically; frames are fixed 1528 B on the wire regardless of fill, so the
  wedge is content-dependent (header len field), not timing. Safe boundary bracketed:
  16 < fill_safe ≤ 100 (fill=100 and 700 ran full points at rate). Wedge = #48 class:
  survives bring-up, cleared only by reboot. Confirmation cycle (reboot → restore →
  single fill=16 point) launched for determinism (would be repro 3/3).
- 23:35 fill=16 confirmation on verified-healthy link: wedged within the first second
  (0 frames delivered, post-point fsync 4/s) — **3/3 deterministic**. Evidence committed
  (b39a359); task #48 updated with the on-demand trigger.
- 23:40 **Rig fully restored and verified**: reboot + restore, 148 fsync=wcnt=1245 f/s,
  146 fsync=1245 f/s, air link healthy, TGEN image (pass-through) still on 148,
  watchdogs up. Final whole-branch review dispatched (15 commits, bcabdd2..b39a359).
- 23:54 Outage statistics (10×60 s at the operating point): outages quantized at
  EXACTLY 1.00 s (n×620 frames), episodes of 3–4 at the 1.85 s beat, 6/10 windows;
  singles floor stationary at 0.41 %. Word-count cross-check LOCALIZES class-B to the
  TX byte-ingestion seam (DUT transmits filler during outages; RX delivery healthy).
  Committed + pushed (5e0f493).

---

## FINAL SUMMARY (2026-08-18 ~00:00)

### What was accomplished
1. **TGEN plan finished end-to-end** (Tasks 7–9 + final whole-branch review, verdict
   MERGE-READY, one fix wave applied). Branch pushed: ec74d34 → 5e0f493 (18 commits).
2. **Task 7 — flash + pass-through equivalence PASS**: image c183d42911b3 on 148 under
   full rails; fwd PER 8.35 % (5508/65927, CP95-UB 8.57 %) inside the 8.2–8.4 % brief
   band. One #48-class wedge run discarded per protocol (allowed retry used).
3. **Task 8 — generate-mode smoke**: run 1 exposed a REAL BUG in the T4 scorer patch —
   the scorer could never accept the generator's constant-CRC frames (21,619 bit-perfect
   frames scored junk). Fixed in qpsk_seq.c (structural accept + selftest positive AND
   negative controls), deployed, re-verified on hardware: **instrument bit-exact —
   BER 0.000e+00 over 292 M bits, buckets 0/0/0/0, loss-proof identity holds.**
4. **Task 9 — sweeps across configurations** (rate axis 250→1245 f/s, length axis
   1516/700/100/1, brackets, 10× repeats). Layer-B loss fully decomposed into FIVE named
   classes with scaling and localization (table in two_jup/TGEN_SWEEP.md):
   - singles floor 0.4–0.8 % (stationary);
   - class-B outages: EXACTLY 1.00 s dead windows, episodes of 3–4 at a 1.85 s beat,
     localized to the TX byte-ingestion seam (DUT transmits filler; RX delivery healthy);
   - overrun swallow: 66–68 % loss at offered ≥ ~1200 f/s — DUT byte-TX over-asserts
     ready above line rate (generator span 1870 f/s > 1245 f/s line) and swallows whole
     frames — the air-campaign FIFO-swallow mechanism, now reproducible with 2 register
     writes;
   - scattered==biterr identity (exact in every run): the host scattered-DMA slice class
     is the ONLY bit-error source; fabric datapath BER is 0.000 in all runs;
   - **short-fill wedge: fill ≤ 16 deterministically wedges the DUT within seconds
     (3/3), content-dependent (header len field — frames are fixed 1528 B on the wire),
     #48 class, survives full bring-up restore, reboot-only recovery.** Task #48 now has
     an on-demand trigger — exactly what the planned ILA/observatory build needs.
5. **Fixes shipped and re-verified on hardware**: qpsk_seq.c TGEN accept (1fd6db2, smoke
   re-run green); T7 review fixes (explicit 0x1C0-delta flash gate, band provenance);
   final-review fix wave (d1C0 parse bug, rtl_sim/*.bin gitignore, whiten-off comment).
   Selftest suite passes (test_seq OK incl. new tgen legs).
6. **Rig restored and verified healthy at end**: both boards 1245 f/s on air, TGEN image
   in pass-through on 148 (rollback at /root/BOOT.BIN.e49c011b.bak), 146 untouched
   (TMR 433fd8dab393), watchdogs up. Three reboot+restore cycles were needed during the
   night to clear deterministic wedge repros — all verified by uptime + live rate probes.

### Passing tests
- host_app_k5 test_seq (qpsk_seq_selftest incl. TGEN positive/negative controls): OK.
- T7 equivalence: PASS in-band. T8 smoke (post-fix): instrument-valid, BER 0.000.
- All sweep rows keep the loss-proof identity (span == ok+biterr+lost).
- Final whole-branch review (bcabdd2..b39a359): MERGE-READY, 0 Critical.

### Remaining items / morning queue
- **Class-B fingerprint hunt**: what produces EXACTLY 1.000 s stalls at a 1.85 s beat at
  the TX byte seam? (No 1 s constant in the scorer path; delivery watchdog is 10 s and
  never fired.) Candidates: DMA descriptor/timer on the TX feed, fabric-side counter.
- **Wedge boundary bisect**: safe fill bracketed to (16, 100]; bisect if useful, and use
  the deterministic trigger with the ILA/observatory image to catch the wedge live (the
  cleanup plan's Track E/F — this instrument removes their trigger problem).
- **Overrun-swallow fix design** belongs after observation (five refuted-fix lessons);
  the TB + tgen now give both sim and silicon repro paths.
- Deferred cosmetics: tgen_sweep.sh d1C0 delta is wrap-naive (irrelevant at 60 s dwells);
  per-point gate uses 0x104 not fsync (note-level).
- Session hygiene (pre-existing): a T4-era subagent set ~/.claude/settings.json
  PostToolUse=[] (disclosed earlier, unrestored) — you may want your clang-format hook
  back. hdl-dev-2 still missing from canonical HOSTS.md on picard.

### Where everything lives
- Evidence ledger: `two_jup/TGEN_SWEEP.md` (gates, sweeps, loss-class table).
- CSVs: `two_jup/tgen_sweep_20260817_23*.csv`. Harnesses: `two_jup/tgen_sweep.sh`,
  `two_jup/t8_smoke_tgen.sh`. Scorer fix: `host_app_k5/qpsk_seq.c`.
- Branch `per-under-1pct-2026-07` @ 5e0f493, pushed. Plan/spec under docs/superpowers/.
- 09:02 **RX-seam dual-injector build launched** (`jupiter_byte_tgenrx_build`, Layer B
  spec fix): `qpsk_traffic_gen_rx` at the DUT-byteRX→DMA seam (post-demod,
  fabric-to-processor boundary) + second GPIO @0x9D410000, TX-seam injector retained.
  TB gate green first run (golden byte-exact under stalls, last@word190, user=0,
  dut_ready-stall, pass-through mirror, corruption control). Commit 313590f, pushed.
  BUILD ONLY — flash requires separate authorization.
- 09:0x LAN activity dashboard live at http://nemo.local:8090/ (activity.json +
  update_dashboard.sh; hourly cron refresh + on-task-finish updates; server restarted).

## Night session 2026-08-18/19 (operator away until 07:00 EST, full hardware autonomy)

Queue: envelope sweep -> TX-checker legs (gated on build5+sweep) -> RX-seam zero-loss
SOAK (3x600s) -> A-analogue burst-timed floor v2 -> 120s-beat 100ms fine structure ->
Simulink prefix analysis (~02:47). 30-min nanny cron armed. Morning report accumulates
here as results land.
- 00:1x **INCIDENT: 146 DOWN** — the killed fill=1 retest interrupted a 146 arm
  mid-profile-write; 146's kernel/IIO wedged, ssh hung, then ping dead. Jupiter has no
  remote power: 146 needs a PHYSICAL POWER CYCLE (morning action). Flash5's bring-up
  hung 42 min on the dead board; chain killed cleanly. **148-only contingency active**:
  image 9259cfade5b4 accepted loopback-grade (fsync 1246, GPIOs+checker zero at idle);
  air-mode health gates deferred until 146 returns. All remaining queue items are
  loopback/148-only and proceed.

## MORNING REPORT — 2026-08-19 07:00 (night session summary)

### FIRST ACTION NEEDED FROM YOU
**Power-cycle 146** (kernel IIO wedge from an interrupted profile write at ~00:10;
ssh hung then ping dead; Jupiter has no remote power). Everything blocked-on-146
below unblocks after that + one restore_known_good.

### Completed and banked overnight (all pushed, HEAD 6a8dafe)
1. **RX-seam ENVELOPE (task #52) — the Layer B boundary NEVER loses.**
   Rate axis: bit-exact zero-loss at 620/1229/7477/12861 f/s delivered in full;
   flow-controlled saturation at ~16,520 f/s (~25.2 MB/s) flat to 4.4x overload,
   lost=0 everywhere (backpressure, never drops). Length axis: fills 0/16/48/100/700
   all bit-exact zero-loss at full rate (wedge boundary irrelevant post-demod).
   Holes: arm-lottery triple-misses only; fill=1 scorer-death open question
   (local ASan exonerates scorer logic; instrumented retest queued).
2. **TX-side Layer B (task #53, DONE) — PASS both legs.** In-fabric checker
   (tx_seam_checker @0x9D420000, image 9259cfade5b4): 34,267 frames continuous-valid
   (host DMA) + 19,199 gapped-valid, 0 bit errors — bit-exact from host memory to the
   modulator's doorstep in both cadences.
3. **Simulink prefix (3,106 frames, 11 h)**: idealized-clock model shows NONE of the
   silicon beat signatures (floor 0.0000/frame, no fsync excess, no burst candidates;
   FIFO fill drift present but harmless). Combined with the RTL study: the 120 s beat
   origin is squeezed to the REAL SSI clock chain; the arm's adrv9001 SSI pokes
   explain the arm phase-lock.
4. **RTL sim wedge study FINAL (commit 67b6df8): VERDICT REPRODUCED** — 47/48 cliff
   exact in sim; mechanism = preamble-detection starvation via timing-loop walk on
   low-transition payloads; FIFO-guard hypothesis refuted; product fix direction =
   scrambler/transition-density assurance, now with a sim positive control.
5. **Degraded-mode beat data**: at the 341 f/s degraded cadence the burst process runs
   at ~6.7 s period (vs 119.75 s at 1245 f/s) — the beat scales with link/clock state,
   further supporting the SSI-clock origin.
6. **#48 sharpened substantially**: fresh queued arms fail ~40-100% and worsen with
   accumulated state; double-tap + daemon-prime + reboot are individually insufficient
   — only the full two-board bring-up reliably recovers. Stale-DDR replay on arm
   directly observed repeatedly. This is now the dominant operational defect.

### Blocked on 146 power cycle
- Zero-loss SOAK 3x600s (arm requires full bring-up).
- A-analogue burst-timed floor v2 (radio provisioning).
- Canonical 119.75 s beat fine structure (needs 1245 f/s state).
- fill=1 instrumented retest.

### Rig state at handoff
148: image 9259cfade5b4 (both injectors + TX checker), loopback, degraded cadence
(341 f/s), watchdog off — will be normalized by the first restore after 146 returns.
146: DOWN (needs power cycle). Dashboard: http://nemo.local:8090/

## COMPACTION CHECKPOINT — 2026-08-19 ~08:0x EDT (authoritative resume state)

GIT: branch per-under-1pct-2026-07, everything through d721cad pushed; this checkpoint
commit follows. One local edit pending commit: two_jup/soak_night.sh recovery switched
from reboot+daemon-prime to full restore_known_good (146 is back).

RIG: 146 power-cycled by operator ~07:5x, confirmed up. IN FLIGHT RIGHT NOW (harness
task bf5ddg1z9): restore_known_good x2 -> both-board verify (expect ~1245/1245 on 148,
fsync ~1245 on 146) -> relaunch two_jup/soak_night.sh (zero-loss soak 3x600s,
restore-based retry). Check `ps -eo pid,cmd | grep soak_night` + rxseam_soak_status.txt
(SOAK_V2_DONE marker) on resume. 148 image = 9259cfade5b4 (BOTH injectors + TX checker:
tgen TX @0x9D400000/8, tgen RX @0x9D410000/8, checker counters RO @0x9D420000/8).
146 = TMR 433fd8dab393, NEVER flash.

RESUMED QUEUE after soak (in order):
1. A-analogue floor v2: two_jup/layerA_ber_analog.sh, dwells timed BETWEEN 120s bursts
   (first burst arm+153s, then every 119.75s; place 60-80s windows in quiet zones),
   repeats. -30dB TX atten locks; RSSI ~37dB expected.
2. Canonical 119.75s beat fine structure: two_jup/layerA_burst_fine.sh (0.1s x 3000
   samples) but ONLY on a verified-1245 f/s canonical link (the 03:26 run was degraded-
   mode 341 f/s -> 6.7s period; canonical anatomy still unmeasured). Re-add restore at
   end (script has it stripped for the 146-down night).
3. fill=1 instrumented retest: RESTORE_PER_POINT=1 GAPS=200000 FILLS=1 rxseam_sweep.sh
   + capture 148 dmesg, /dev/shm/rxs.log, df /dev/shm (scorer-death mechanism; local
   ASan already exonerated scorer logic).

KEY RESULTS BANKED (all in two_jup/TGEN_SWEEP.md + LAYERA_BER.md, pushed):
- Layer B RX boundary: NEVER loses. Bit-exact zero-loss at 620/1229/7477/12861 f/s and
  fills 0/16/48/100/700/1516; flow-controlled saturation ~16,520 f/s (~25.2 MB/s) flat
  to 4.4x overload, lost=0 everywhere. 60s PASS banked; SOAK-grade pending (running).
- TX Layer B: PASS both legs (34,267 continuous + 19,199 gapped frames, 0 bit errors,
  in-fabric checker). Optional phase 2: internal ByteWordBuffer tap.
- Wedge (fill<=47): REPRODUCED in RTL sim, mechanism = preamble-detection starvation
  (timing-loop walk on low-transition payloads); product fix = scrambler; sim positive
  control exists (SIM_WEDGE_REPRO.md, wedge_repro/ harness).
- 120s beat: origin squeezed to real SSI clock chain (PL time-base scan negative, DUT
  counter-pairs negative, cals exonerated, both idealized-clock sims show NO signatures,
  beat period scales with link state: 119.75s @1245fps vs ~6.7s @341fps). Instruments:
  schedulable ILA (arm t+115s after a burst) or SSI-domain telemetry.
- #48 arm lottery = DOMINANT operational defect: fresh queued arms fail ~40-100%,
  worsen with accumulated state; double-tap/daemon-prime/reboot individually
  insufficient; ONLY full two-board bring-up recovers. Stale-DDR replay on arm directly
  observed. Triggers on demand: TX fill<=47 (wedge), tgen_rx dut_ready stall (fixed in
  image), scorer arm-cycling.
- Layer A: digital floor 3.7e-6 (deterministic 218,534-err arm transient; 120s bursts);
  analogue locked -30dB but bimodal, no stable floor yet (item 1 above).

PROCEDURES THAT MUST SURVIVE (in scripts, but the WHY matters):
- Zero-loss/seam runs need: fresh scorer per run + FULL arm batch (0x000+muxes+0x110)
  between scorer start and enable + double-tap; write tgen knobs only while disabled;
  never run two rig harnesses concurrently; restore after every session.
- Watcher discipline: NEVER pgrep patterns that appear in your own cmdline (5 self-kill
  incidents); use explicit PIDs from ps or marker-files in logs.
- The rxseam verdict awk: PASS needs ok>=0.9*offered*dwell (expf var, not exp).
- 146 arm interruption mid-profile-write = kernel wedge = physical power cycle only.
INFRA: dashboard nemo:8090 (focus.txt + update_dashboard.sh at every transition);
hourly dashboard cron active (a0e9b417-successor ec4cd8e2); night nanny deleted.
Session crons die with session — recreate on resume if needed.

================================================================================
COMPACTION CHECKPOINT — 2026-08-19 ~18:1x  (read this first on resume)
================================================================================

RIG STATE: 148 = BUILD-1 beat-ILA image **4a98855d7421** (flashed, healthy 1242 f/s
after 2-pass restore). 146 = TMR 433fd8dab393, 1246 f/s, NEVER flash. Rollback backup
/root/BOOT.BIN.e49c011b.bak verified on 148. Nothing running on the rig or nemo.
Everything committed + pushed through the "Build 2 DUT-port BLOCKED" commit.

WHERE WE ARE — the 119.75 s "beat" hunt (Layer A):
- Beat LAW nailed: bursts at **arm + 34.75 s + n*119.75 s** (10 ms-exact across arms,
  free-run refuted). Two alternating species ~293.2k / ~215.0k errs, byte-identical
  across FPGA-internal loopback, SSI near-end loopback (RF excluded), and 146.
- Driver/SPI side REFUTED (SPI flat through bursts). Idealized-clock sims (RTL+Simulink)
  show NO signature. Sole suspect: the SSI-derived CLOCK CHAIN / a periodic event in the
  clock-common domain.
- **KEY NEW RESULT — first direct ILA waveforms (build-1 beat-ILA image, via XVC):**
  received data is CLEAN. Post-symbol-sync constellation during BOTH bursts is pristine
  (~40 dB EVM, 0/4096 soft-error symbols) while the post-Viterbi comparator counts
  ~49k err/s. => corruption is injected AFTER symbol decisions, in the RX PROCESSOR
  (FEC deinterleave/Viterbi, byte assembly, or comparator framing). SSI valid cadence
  perfect + input RMS flat at onset (no gross clock/valid dropout in a 133 us window).

XVC INFRASTRUCTURE (all working, committed):
- host_app_k5/xvc_server.c: /dev/mem debug_bridge XVC daemon. Fixes that made it work:
  (1) IR-capture spoof 0b001001 at each Shift-IR entry (soft TAP illegally captures IR
  contents -> hw_server "No devices"); (2) single-client + SO_RCVTIMEO **5 s** (a killed
  hw_server left a half-open socket that blocked accept forever; fork was tried+reverted).
  Enumeration deterministic. Build on-board: gcc -O2. Bridge @ 0x9D440000:2542.
- two_jup/beat_capture.sh (single vivado session, fresh daemon, hw_server/cs_server kill,
  on-board ms-precision force at arm+34.90s / +154.65s) + beat_capture.tcl (pwidth catch
  for PROBE_WIDTH; run1 raw 133us, run2 capture-qualified). Captures banked under
  two_jup/r3cap/beatcap_20260819_141043/{run1_raw,run2_qualified}.csv.
- Build-1 image beat-ILA: 16 probes on adc_1_clk (0 trig,1 status,2-6 byte plane,
  7 valid_out_rx,8/9 rxIN IQ,10/11 iq_debug_mux loop tap,12/13 raw SSI IQ,14 valid_in,
  15 byte_valid_in), depth 4096, debug_bridge XVC @0x9D440000, burst_det arm/force GPIO
  @0x9D430000. err_cnt tied 0 (soft-force only).

BUILD 2 STATUS = BLOCKED, awaiting operator go on the ALTERNATIVE:
- Goal: hardware error trigger so ILA centers on a REAL error (not time-scheduled).
- DUT-port path (dut_bit_err_out via model overlay) is DEAD: this ADI target has a
  CLOSED IOInterface catalog — no 'External Port', no free 32-bit OUT slot (all four
  16-bit IP Data OUT slots consumed by iq_debug taps). Edits REVERTED; base kit clean.
  beatila_errport_overlay.m left on disk unused. run_beatila2_build.sh has an ERRSRC
  hard-fail gate (keep or delete when the approach changes).
- **VIABLE ALTERNATIVE (not yet built):** mark_debug the internal bit_errors_out net,
  add it as an ILA probe, trigger the ILA on its LSB transition under a SCHEDULED ARM at
  ~t+34.5s -> first real error in the armed window = burst onset. No model/port change;
  BD/XDC + synth rebuild (~3h). Optionally add a few internal FEC/framing nets via
  mark_debug in the same build for finer localization (cheap while touching synth).

SIM-REPRODUCTION VERDICT (banked, LAYERA_BER.md): build-2 probes localize the STAGE but
CANNOT seed a testbench (internal state — loops, deinterleaver buffer, Viterbi metrics,
descrambler LFSR — is uncaptured & impractical via ILA; 133us << 803us frame). AND both
idealized-clock sims likely can't reproduce it anyway (clock chain is the suspect). So:
localize on HARDWARE first; only then pick the follow-on tool (CDC-aware multi-clock sim
if clock-domain, or a small targeted state-capture build if deterministic-digital).

OTHER OPEN (unchanged): #48 arm-lottery (miss = 12-frames-then-wedge, stale ring replay);
wedge scrambler fix unbuilt; Layer B seam is MERGE-READY (soak-grade zero-loss, verdict
patch verified); A-analogue floor still unmeasured (path ~11 dB weak, blocked on bench).
Parked queue behind the beat work: A-analogue v2 retry, beat fine structure (0.1s poll),
fill=1 instrumented retest.

DASHBOARD nemo:8090 live (focus.txt current). Watcher discipline: NEVER pgrep a pattern
present in your own cmdline (self-kill/self-match; use [b]racket or explicit PID).
Restore is often TWO passes to clear the 571 f/s half-rate mode.

================================================================================
NIGHT 2026-08-19->20  ROOT-CAUSE PROGRESS (read STAGE_LOCALIZED.md for full detail)
================================================================================
Operator go: "build-2 mark_debug rebuild ... get to the bottom of the receiver error
exactly ... use hardware ... run builds in parallel." Away until 07:00.

BREAKTHROUGH (zero rebuild): the shipping DUT already has an RX pipeline forensic
harness AXI-readable on the flashed build-1 image. cap_in/cap_deint/cap_out (0x13C/
0x140/0x144) are RAW packed coded/decoded bits per frame (bit p = p-th bit). Poller:
two_jup/stage_poll.c (+layerA_stage_poll.sh arm-health-gated + two-pass restore,
analyze_stage_poll.py / analyze_hirate.py).

FINDINGS (all committed: 641e7d0 b2ed25f 40c24c0 2006a41):
- STAGE: corruption injected at the FEC-decoder INPUT = QPSK_Demodulator (post-
  symbol-sync soft, pre-FEC). All 3 caps diverge together (cap_in dirty), frame
  cadence pinned 1244/s, cap_cad intact -> pure bit-VALUE corruption. All 5 prior
  refuted fixes aimed DOWNSTREAM (byte plane/FIFO/DMA/skid) -> why they failed.
- STRUCTURE (1kHz poll): each burst = 3-4 HELD ~1s corruption windows spaced ~1.83s,
  each holding a DIFFERENT constant ~50%-decorrelated wrong coded word. Species A=4
  windows, B=3 -> 293k/215k~=4/3 (count-of-windows). bit_errors_out 0.3% was a
  windowed undercount; true per-window corruption ~50%.
- REFUTED on raw bits: serial shift, u0/u1 pair swap, QPSK carrier-phase rotation.
  Loop telemetry NORMAL in-window: rstcs_count=0 (no carrier reset), cfc_est stable
  (no CFO step).
- RTL: QPSK_Demodulator = soft IQ -> Baseband hard-decision (u_0,u_1) -> Serializer
  (2->1 bit via 1-bit phase counter on enb_1_2_0, NOT re-synced to startIn) -> bitsIn.
IN FLIGHT: capture_window_iq.sh -- rx2-lpc soft-constellation (mux=2 post-carrier)
IN-WINDOW vs GAP snapshot to split timing(spread) vs carrier(rotation) vs digital
(tight+correct but bits wrong). Then a TARGETED build. Rig 148 healthy (gated+2-pass
restore). 146 TMR frozen. Deliberately NOT building blind (the 5-failed-fix pattern).

================================================================================
MORNING HANDOFF 2026-08-20 ~01:00  (night of 08-19)  -- READ STAGE_LOCALIZED.md
================================================================================
RESULT: the 119.75s "beat" receiver error is ROOT-CAUSED by direct observation to a
DIGITAL fault in the QPSK demodulator's coded-bit-formation / FEC-input stage
(Serializer 2->1 bit, or startIn frame-sync phase), driven by the SSI-derived
enb_1_2_0 enable/framing network. The ENTIRE demod datapath is PROVEN CLEAN during
corruption. All five prior refuted fixes acted downstream (byte plane/FIFO/DMA) -- now
explained.

EVIDENCE CHAIN (all committed; commits 641e7d0..bddbcc8; data in two_jup/r3cap/):
1. cap_in/deint/out AXI forensic (shipping image, no rebuild): all 3 FEC-stage caps
   diverge together during bursts, cap_in (FEC input) dirty -> injection at/before FEC
   input. Frame cadence + cap_cad intact -> pure bit-VALUE corruption.
2. 1kHz structure: each burst = 3-4 HELD ~1s windows (species A=4, B=3 -> 293k/215k
   ~=4/3). Held constant ~50%-decorrelated wrong coded word per window.
3. [MUX-VERIFIED: control shows mux0!=mux2; re-test with mux2 set FRESH before
   the force reproduces clean in-window -> not a mux artifact] XVC ILA, VERIFIED in-window (cap_in=0x7871AA08) vs golden gap: post-carrier soft
   (mux2) AND decisions (mux3) constellations PRISTINE & identical to gap (EVM ~1%,
   0deg rotation, 0 extra spread). Refutes carrier cycle-slip (no rot) + timing slip
   (no spread). => fault is AFTER the clean decision, in coded-bit formation.
4. rstcs=0, cfc stable in-window -> no carrier reset / CFO step. Raw-bit tests refute
   serial-shift & pair-swap & QPSK rotation of cap_in.

REMAINING FORK (for the FIX): (A) Serializer bit-mangle vs (B) startIn phase-shift.
Existing instruments can't split (cap_in only 32 bits). Split needs ONE ILA capture of
FEC-input nets (startIn/bitsIn/enb_1_2_0/Serializer HDL_Counter/u) during a window --
mark_debug on Hier-4 generated nets; recipe design in STAGE_LOCALIZED.md.

WHY NO BUILD RAN OVERNIGHT: the zero-build forensic path reached the root cause faster
than any build could; the only remaining build (internal-net observability) needs a
mark_debug flow unproven in this repo (real net-survival risk over an unattended 3-4h
build), and the FIX touches the generated Serializer/framing RTL -> needs the Simulink
model. Judged higher-value to deliver the complete result + ready recipe than to risk a
fragile blind build. Farm idle, ready for a supervised build at your call.

FIX CANDIDATES (design only, NOT built -- validate on-air after): (1) re-sync Serializer
HDL_Counter to startIn each frame; (2) register/CDC-harden enb_1_2_0 & In2 at the
Serializer; (3) synth-constrain the enable net to stop the AXI-decoder re-hosting
(witness forensic ebbf4eb). Recommend the observability ILA FIRST to pick A vs B.

RIG: 148 = build-1 beat-ILA image 4a98855d7421, healthy 1244 f/s, watchdogs UP both
boards. 146 = TMR 433fd8dab393, frozen. New instruments: two_jup/{stage_poll.c,
layerA_stage_poll.sh, analyze_stage_poll.py, analyze_hirate.py, capture_window_iq.sh,
beat_capture_win.sh, analyze_winiq.py}.

================================================================================
COMPACTION CHECKPOINT — 2026-08-22 ~04:0x  (READ THIS FIRST ON RESUME)
================================================================================
Campaign goal unchanged: delivered PER < 1% BOTH directions, ARQ OFF, 146<->148.
STATUS: NOT MET. Forward ~12.4%, reverse last-measured ~1.72%. See "PER TRUTH" below.

--------------------------------------------------------------------------------
THE HEADLINE (3 days of work, honestly stated)
--------------------------------------------------------------------------------
The 119.75 s "beat" is SOLVED end to end: localized -> mechanism confirmed on
silicon -> fix designed -> fix sim-validated -> fix verified on air. BUT the beat
turned out NOT to be the forward-PER dominator. The live forward loss (~12.4%) is
the long-catalogued SINGLES-COMB class, now EXPERIMENTALLY PROVEN INDEPENDENT of
the beat (A/B with a working on/off switch, gap bins singles-dominated with zero
burst-class runs in ANY leg incl. legacy). That independence is the real new
knowledge; the fix is correct but not (yet) worth PER points.

--------------------------------------------------------------------------------
VERIFIED ON HARDWARE (all data committed, pushed through 4e448ac)
--------------------------------------------------------------------------------
1. MECHANISM (capture beatcap_20260820_221515 + m7_readout_correlate.py):
   during a VERIFIED corruption window (cap_in=0x7871AA08) the coded-bit stream is
   100.00% (512/512) VALUE-PERFECT golden ROM bits at a SHIFTED cyclic offset
   (5917); golden-gap control 99.80% at startOut-anchored offset 11856.
   => COHERENT SEQUENCE SHIFT (right bits, wrong position). Every in-band state
   conserved (pacer 0 violations, phase contract 0/2048, serializer
   decision->dataOut 0.0%/2044, Gardner dither normal, fill {0,1}).
2. FIX WORKS ON ITS OWN MECHANISM (beatfixver_20260821_185935, image 198ade9f234a):
   fixctl=3 -> biterr_total = 0 over 340 s in EACH of two legs = ZERO errors
   through SIX scheduled beat slots, while the fixctl=0 control leg showed the
   canonical bursts (293280/215131/293183) at the same slots with the 4+3+4
   window staircase. Stepping events STILL FIRE under the fix (cap_in window steps
   at exact slot times) but are HARMLESS -> damage decoupled from trigger.
3. SECONDARY ARM HARMFUL: fixctl=4 (enb-grid pacing) = sustained 69,725 err/s,
   dominant cap_in 0xAB7A4307 (= the Model-6c-a phase-class kill value). Eliminated
   with on-silicon evidence. Travis's "explicit contract > implicit agreement"
   architectural call vindicated.
4. v3 IMAGE SOUND: fe5bd8a4fe19 flashed clean (health 1259/1258), netlist sim
   re-gate FLASH_GATE_PASS on all legs, A/B ran 4/4 clean with the fix arm's
   host_seq metric reading correctly (v1/v2 framing defect closed).

--------------------------------------------------------------------------------
PER TRUTH (metrics discipline: exact harness, full denominators, nothing excluded)
--------------------------------------------------------------------------------
Harness: two_jup/beatfix_accept.sh -> capture_r3.sh SIDE=A (146 TX -> 148 RX),
ARQ OFF, accept_analyze.py host_seq-gap metric, 68 s live windows, dropped frames
IN the denominator. Alternating arms control for channel drift.
  beatfix_accept_20260822_020917 (v3 image, 4/4 runs clean):
    r1 fixctl=0 : PER=12.370%  (8147/65863)  CP95-UB 12.623%
    r2 fixctl=3 : PER=12.222%  (8067/66005)  CP95-UB 12.474%
    r3 fixctl=0 : PER=12.488%  (8241/65992)  CP95-UB 12.743%
    r4 fixctl=3 : PER=13.211%  (8719/66000)  CP95-UB 13.471%
  => NO significant fix delta. Clean fractions IDENTICAL ~87.9% all four runs.
  Gap bins: singles+doubles dominated, ZERO burst-class runs in any leg.
REVERSE: not measured this session; last accepted ~1.72% pooled (CP95-UB 1.78%).
BASELINE DRIFT: forward was 8.2-8.3% weeks ago, now ~12.4% -- channel/rig
degradation on top of the comb class. Re-anchor the baseline before any new claim.

TWO RETRACTIONS (mine, corrected here so nobody builds on them):
 (a) The v1 fix-arm "fabric-clean 88.45% -> 99.73%" was an ARTIFACT of the rotated
     framing, NOT a fix effect. v3's identical ~87.9% across arms disproves it.
 (b) The "~0.3% projected forward PER" built on (a) is WITHDRAWN. No PER
     improvement from the beat fix has been demonstrated.

--------------------------------------------------------------------------------
RIG STATE
--------------------------------------------------------------------------------
148 = BEATFIX v3 image fe5bd8a4fe19 (fix PRESENT but fixctl=0 default =
      byte-identical legacy behavior; enabling is a single AXI write, no reflash).
146 = TMR 433fd8dab393 (untouched; policy: 146 is never flashed without an
      explicit operator decision).
Rollback backup on 148: /root/BOOT.BIN.e49c011b.bak (verified).
A restore x2 was running at checkpoint time (both boards had settled into the
known half-rate mode after the session; restore is often TWO passes). VERIFY
fsync ~1245 on both + watchdogs up before trusting any new measurement.

--------------------------------------------------------------------------------
THE FIX (what it is, how to use it)
--------------------------------------------------------------------------------
Explicit downstream PHASE CONTRACT ("position is data"), model-level overlay
jupiter_byte_lean_build/beatfix_overlay.m (tracked copy two_jup/skidfix/), env-gated
QPSK_BEATFIX, byte-identical model when unset.
  - 14-bit BIT-INDEX tag (12320 positions) generated at the F&TS output
    (post-Rate_Handle -- the frame decision does not exist upstream of it in this
    generation), 4 matched enb delays to the demod-output alignment.
  - BfContract derives FEC frame start from tag==K, K SELF-CALIBRATED (latched at
    the next LEGACY frame start on fixctl bit0 rising edge) -> no tuned constant.
  - v3 CRITICAL DETAIL: every gate uses vEdge = vout & ~voutPrev (pcFirstBit).
    vout is a 2-BEAT LEVEL per coded bit; gating on the level gave a 2-beat start
    pulse (FEC framed one bit late = the 0xA90B79F1 species) AND per-bit false
    violation counting. This single root cause explained BOTH v1/v2 defects.
  - Runtime control fixctl @ AXI 0x208: bit0 contract, bit1 serializer re-anchor,
    bit2 enb-grid pacing (HARMFUL -- do not enable). Default 0 = legacy.
    viol_count @ 0x20C, viol_latch @ 0x210 ({delta[15:0], tag_prev[15:0]}).
    USE fixctl=3 (contract + serializer anchor). NOTE: bring-up and mid-run
    re-arms soft-reset the DUT and CLEAR fixctl -> re-assert after every arm
    (beatfix_accept.sh has a 5 s keeper loop for this).

--------------------------------------------------------------------------------
KEY INSTRUMENTS BUILT (all committed, reusable)
--------------------------------------------------------------------------------
two_jup/stage_poll.c            mmap 0x9D000000 fast reg poller (+viol regs)
two_jup/layerA_stage_poll.sh    arm-health-gated stage poll, 2-pass restore
two_jup/analyze_stage_poll.py   burst detect + cap bisection + rate conservation
two_jup/analyze_hirate.py       1 kHz per-frame structure analysis
two_jup/beat_capture_win2.sh    XVC ILA capture, cap_in-verified in-window force
two_jup/xvc_enum_until_ok.sh    XVC enumeration is ~1/3 intermittent: win then REUSE
                                the hw_server session (do NOT restart daemon/servers)
two_jup/beat_capture_beatobs_go.sh  capture that reuses a proven-enumerated session
two_jup/analyze_beatobs.py      decode probes 8/9 packed state vector
two_jup/m7_readout_correlate.py golden-sequence correlation (the mechanism prover)
two_jup/beatfix_verify.sh       slot-level A/B/C legs at scheduled beat slots
two_jup/beatfix_accept.sh       live-link PER A/B with fixctl keeper
two_jup/BEATFIX_DESIGN.md       both fix designs + verification plan
two_jup/STAGE_LOCALIZED.md      THE canonical evidence chain (read this second)
two_jup/MODEL1_ENABLE_INJECT.md Models 1,3,4,5,6,6b,6c,7 + BEATFIX2/3 gates
two_jup/MODEL2_CLKEN_SOURCE.md  clk_enable trace + PPM refutation

--------------------------------------------------------------------------------
REFUTED (do not re-litigate; each cost real time)
--------------------------------------------------------------------------------
- clk_enable glitch / count2 flip: clk_enable is a STATIC held level
  (write_axi_enable resets to 1, never rewritten) -> count2 free-runs; not flippable.
- SSI clock PPM beat: adc_1_clk = BUFGCE_DIV/4 of the recovered SSI clock (single
  coherent clock locally); a 120 s beat needs ~5e-4 ppm vs real +-10-20 ppm; and
  the identical corruption appears in single-clock FPGA-internal loopback.
- Carrier cycle-slip / timing slip: in-window constellation is pristine and
  UNROTATED (EVM 1.0-1.1%, rot +0.02-0.03 deg) vs golden gap.
- Front-end valid-train manipulations (drop/insert/periodic/mid-run delay/vphase):
  ALL absorbed. Receiver.validIn is const-1; adc_validIn only gates the front
  AdcCap re-timer, which resamples onto the enb grid and erases standing offset.
- startIn re-anchor as a GENERAL fix: inert (marker travels with the fault).
- Occupancy-gated pop AND push-slaved pacer: both KILLED at nominal lock
  (pop-beat phase is a load-bearing hidden mod-4 contract; Gardner dithers 3/4/5
  beats and the FIFO+free pacer IS the dither absorber).
- Debug-core insertion in this design: IMPOSSIBLE (Vivado 12-727 -- a debug bridge
  with master interfaces blocks inserted cores; and 16-240 with the BD-native ILA).
  Use model-level overlays onto the existing debugI/Q taps instead.

--------------------------------------------------------------------------------
OPEN / NEXT (priority order)
--------------------------------------------------------------------------------
1. THE SINGLES-COMB CLASS is now the entire forward problem (~12.4%) and has no
   root cause. It is beat-independent (proven). This is the next campaign.
   Start from: gap bins are singles+doubles, lag-33 autocorr ~0.06-0.09, and the
   comb survived every fix so far.
2. Re-anchor the forward/reverse BASELINE (8.3% -> 12.4% drift is unexplained;
   suspect channel/antenna/rig degradation, cf. the standing RF-degradation note).
3. Reverse direction with the fix: needs the overlay ported to the 146 lineage ->
   requires an explicit operator decision (146-never-flashed policy).
4. Beat trigger origin: still unknown (harmless + observable now). The counter is
   silent post-calibration by design (contract ignores the legacy marker); a
   marker-vs-contract disagreement detector is the observability add-on.
5. Fold beatfix_overlay into the Simulink model proper (it is an env-gated bolt-on).
6. Parked: Layer B seam (MERGE-READY), #48 arm-lottery/wedge class, wedge scrambler
   fix, docs/Sphinx pass folding in this campaign.

OPERATIONAL LESSONS (cost real time; keep):
- NEVER pgrep/pkill a pattern present in your own cmdline (bracket it). Cost 2
  self-kills this session alone.
- Watchers must trigger on STRICT terminal markers; helper-log lines match early.
- Restore is often TWO passes; verify fsync>=1000 before believing a measurement.
- The netlist sim gate BEFORE flash paid for itself: caught the v2 defect in sim
  and diagnosed the true root cause instead of burning a flash+capture cycle.
