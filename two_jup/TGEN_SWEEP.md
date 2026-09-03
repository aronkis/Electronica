# TGEN — in-fabric traffic generator: silicon bring-up + characterization ledger

Instrument: `qpsk_traffic_gen` spliced at the TX byte mux on 148 (image `c183d42911b3`,
built 2026-08-17 18:30, gates: TGEN_WIRE_OK, VALIDATE_OK, timing modem_dut +2.874 ns
lean-identical, RAIL_GATE tc 100=100 PARITY_OK). Knobs: `tgen_ctrl_gpio` (dual axi_gpio,
all-outputs, readback-verifiable) — ctrl @ `0x9D400000` (`[0]`=enable,
`[15:4]`=fill_len 0–1516), gap @ `0x9D400008` (inter-frame gap, IPCORE_CLK clks).
Reset default = both zero = pass-through (DUT byte path untouched).

## Gate 1 — flash + pass-through equivalence (Task 7) — PASS

- **Flash** (2026-08-17 18:39, `two_jup/skidfix/flash_148_tgen.sh c183d42911b3`):
  readback VERIFIED `c183d42911b3` on 148, NAK=4, two-pass health gate
  `HEALTH_GATE_PASS fsync=1260 wcnt=1259` (0x1C0-derived, clean 12/12),
  `TGEN_GPIO_OK` both registers read 0 (pass-through reset default).
  Log: `tgen_flash.log`. Rollback image staged at `/root/BOOT.BIN.e49c011b.bak`.
- **Equivalence run** (`SIDE=A bash two_jup/acceptance_rxq.sh 1`, GPIOs untouched):
  - Run 1 (20:25): **discarded** — MID_CAPTURE_WEDGE (delivery flatlined 12 s), the
    pre-existing #48 byte-plane wedge class; not attributable to the tgen image
    (class predates it) but noted that it occurs under the tgen image too.
    Log banked: `t7_equiv_r1_wedged.log`.
  - Run 2 (22:39–22:47, warm, `QPSK_RX_QUEUED=1`, +20k, -M32, steady t>=15 s):
    **PER = 8.35 % (miss 5508/65927), CP95-UB = 8.57 %**, lag33 = 0.308,
    bins {1: 2804, 2: 1146, 3-4: 71, 5-20: 18, >20: 0}.
    Capture: `two_jup/r3cap/accept_rxq_20260817_223859_r1`. One transient 4 s
    delivery stall mid-capture, self-recovered (no abort).
- **Verdict:** 8.35 % sits inside the plan's stated acceptance band of **8.2–8.4 %**
  (Task 7 brief: "PER within the lean band (8.2–8.4 % at last measurement)"). The
  underlying lean point measurements were 8.23 / 8.32 / 8.27 % (three ~65 k-frame runs,
  2026-08-15, run-to-run spread 0.09 pp); 8.35 % is 0.03 pp above the highest point
  value, well within that spread. The wider 8.0–8.6 % window quoted at dispatch time was
  the controller's failure threshold (>10 % or <6 % ⇒ hard fail), not the pass band.
  The splice does not change passive behavior.
  **Silicon gate 1 PASS — generate-mode smoke (gate 2) is unlocked.**

Sample-count discipline: 65,927 delivered-window frames, misses counted in the
denominator via host_seq gap analysis (`acceptance_rxq.sh` steady-state window);
single warm run — equivalence-grade, not soak-grade.

## Gate 2 — generate-mode smoke (Task 8) — instrument VALIDATED; first Layer-B findings

Point: fill=1516, gap=200000 clk (~416 f/s offered), 60 s dwell, internal loopback
(`0x114=0` via the bringup-sequenced batch), scorer `QPSK_SEQ_RXONLY=1 -S -M 16`.
Script: `two_jup/t8_smoke_tgen.sh`. Runs: `two_jup/r3cap/t8_smoke_20260817_2*`.

**Run 1 (22:49) — scorer defect found, hardware exonerated.** ok=0 junk=75717; hex
forensics showed 21,619 junk frames tracking the enable window exactly with BIT-PERFECT
content (magic/len/seq-run/CRC-const all exact). Root cause: `qpsk_frame_decode()`
demands a computed CRC32; the generator writes the constant by design, so the scorer
could never anchor. Fixed in `qpsk_seq.c` (commit 1fd6db2): structural accept gated on
`QPSK_SEQ_RXONLY`, payload scored bit-for-bit vs regenerated PN(fill)+pad; selftest
grew positive and negative controls.

**Run 2 (23:01) — with fixed scorer:**
- `SEQRX frames_scored=95034 ok=23869 biterr=0 lost=1437 (194 gaps) dup=0 junk=71165`
- `seq_span=25306 accounted=25306` (loss-proof identity holds), `BER=0.000e+00` over
  291,774,656 scored bits. SEQDMA buckets 0/0/0/0.
- Instrument verdict: **byte-lane packing, PN, header, FSM all bit-exact on silicon.**
  junk=71165 is the expected underrun filler (line rate 1262 f/s minus offered 416 f/s;
  the modulator free-runs frames when the byte FIFO underruns — this also voids the
  brief's "0x1C0 stops after disable" and "d1C0 = ok*191" expectations, which assumed
  a data-gated TX; measured d1C0/191/60 = 1252 f/s = line rate, as the free-run model
  predicts).

**First Layer-B characterization (the actual finding):** 5.7 % of generator frames are
LOST as whole frames — zero bit errors ever — in two distinct classes:
1. **Singles**: 185×1 + 5×2 + 1×3 ≈ 198 frames, ~0.8 %/s steady (3.3–3.4 lost/s at
   412 f/s delivered), no obvious 8/32 periodicity in spacing.
2. **~1-second outages ×3**: n=405/413/421 (0.97–1.01 s at 416 f/s), at t=39.7, 41.6,
   43.4 — **onset spacing ~1.85 s, matching the documented 148-loopback class-B beat**
   (cf. reverse-residual 1.79 s beat). Clustered in one 4 s window of the 60 s dwell.

Interpretation: with no RF, no host TX, and fabric-generated traffic, host-submit and
air are exonerated for these classes — the loss is inside DUT-TX-seam → RX → byte
plane → DMA → host delivery. The rate/length sweeps (Task 9) now measure how each
class scales with offered load and fill.

## Task 9 — first rate/length characterization (2026-08-17 23:05–23:18)

Harness: `two_jup/tgen_sweep.sh` (readback-verified points, per-point health gate,
loopback armed once via the bringup-sequenced batch, watchdog restored at exit).
CSVs: `tgen_sweep_20260817_230559.csv` (rate axis), `tgen_sweep_20260817_231246.csv`
(length axis). 60 s dwell per point. All rows keep the loss-proof identity
(span == ok+biterr+lost).

### Rate axis (fill=1516)

| gap (clk) | offered f/s | delivered ok | lost (gaps) | loss % | biterr=scattered | BER |
|---|---|---|---|---|---|---|
| 400000 | 250 | 14063 | 903 (143) | 6.0 % | 0 | 0 |
| 100000 | 624 | 37268 | 147 (144) | **0.39 %** | 1 | 7.9e-8 |
| 20000 | 1038 | 69553 | 5265 (147) | 7.0 % | 35 | 9.0e-5 |
| 2000 | 1221 | 37309 | 74906 (37261) | **66.8 %** | 3 | 8.0e-7 |
| 0 | 1245 | 35415 | 76861 (35420) | **68.5 %** | 6 | 2.5e-5 |

### Length axis (gap=100000, 624 f/s offered)

| fill | ok | lost (gaps) | loss % | biterr=scattered | BER | note |
|---|---|---|---|---|---|---|
| 1516 | 35379 | 2013 (147) | 5.4 % | 15 | 5.9e-5 | outage episodes present this run |
| 700 | 37252 | 164 (158) | 0.44 % | 1 | 7.9e-8 | clean |
| 100 | 34613 | 2780 (200) | 7.4 % | 17 | 8.0e-6 | outages + 1 dup |
| 1 | 0 | — | — | 0 | — | **LINK COLLAPSE: fsync 1262→~53 f/s for the whole point; wedge PERSISTS after tgen disable (fsync 28/s, wcnt 0) until full bring-up — repeatable wedge trigger candidate** |

### Named break-points and classes

1. **Overrun swallow (rate knee at ~1100–1200 f/s offered):** at gap<=2000 the generator
   seq span runs at ~1870 f/s — ABOVE the 1245 f/s line rate — i.e. the DUT byte-TX
   interface asserts ready faster than the modulator drains and silently swallows whole
   accepted frames (66–68 % loss, 1-ok-2-lost cadence, half the air still filler). This
   is the FIFO-swallow mechanism from the air campaign, now directly reproducible at
   will with two register writes.
2. **Class-B ~1 s outages, episodic:** present in some 60 s runs (250 f/s: ~3 outages;
   1038 f/s; 1516/100000 rerun) and wholly absent in others at the SAME config
   (0.39 % vs 5.4 % run-to-run) — onset spacing ~1.85 s when present (T8). Dominates
   run-to-run variance; needs repeated dwells for statistics, and is the #48 wedge
   family's little sibling.
3. **Singles floor:** ~0.4–0.8 % whole-frame singles at mid rates, present in every run.
4. **scattered == biterr exactly in every row** (1/1, 15/15, 17/17, 35/35, 3/3, 6/6):
   the ONLY bit-error source in loopback is the host-side scattered-DMA slice class —
   fabric datapath BER is 0.000 in all runs (860 M+ scored bits).
5. **fill=1 wedge trigger:** to be confirmed by dedicated repro (fill=0 and fill=100
   were TB-covered; fill=1 was not).

## Short-fill wedge — DETERMINISTIC trigger found (2026-08-17 23:18–23:37)

Evidence chain (all at gap=100000 unless noted, CSVs
`tgen_sweep_20260817_23{1246,2123,2827,3513}.csv`):
- fill=1516 / 700 / 100: full points at line rate, no wedge (6+ runs incl. T8).
- fill=1 (60 s): link collapse 1262→53 f/s; **wedge persisted through tgen disable AND
  a full `restore_known_good.sh` bring-up** (148 delivery dead, fsync 28/s) — reboot
  required. Repro 1.
- fill=16 (20 s, healthy link verified 1245 f/s first): 1,436 frames delivered clean
  for ~3 s, then collapse mid-point. Repro 2.
- fill=16 again after reboot+restore+verify (1242 f/s): wedged within the first second
  (0 tgen frames scored, post-point fsync 4/s). Repro 3. **3/3 deterministic.**

Key inference: tgen frames are ALWAYS 1528 bytes on the wire (fill only changes the
header len field and PN span; the rest is zero pad), so the trigger is
**content-dependent, not timing-dependent** — fabric logic that parses the header
`len` field desyncs/wedges on short lengths. Safe boundary: 16 < fill_safe <= 100.
The wedge is the #48 class (survives bring-up + fabric reset; only reboot clears).

Operational value: #48 previously fired sporadically (wedge lottery); it now has an
on-demand, seconds-scale trigger — two register writes — which is exactly what the
planned ILA/observatory build needs to capture the wedge transition live.
Sweep-harness note: avoid FILLS<=16 in routine sweeps; they end the session.

## Class-B outage statistics — 10×60 s at fill=1516, gap=100000 (623.8 f/s offered)

CSV `tgen_sweep_20260817_234207.csv`. lost per run:
2009, 150, 2633, 154, 2012, 156, 2627, 155, 794, 2629.

- **Clean-run floor** (4/10 runs): 150–156 lost ≈ **0.41 % singles**, gaps avg ~1.0 —
  the singles class is stationary.
- **Outages are quantized at exactly ~620 frames = 1.00 s** at this rate: excess over
  the ~152 singles floor is n×~620 with n = 1 (once), 3 (twice), 4 (three times).
  Episodes contain 3–4 one-second outages (T8 measured the intra-episode onset beat at
  ~1.85 s); 6/10 windows had an episode.
- **Localization (word-count cross-check):** outage runs show junk counts HIGHER by
  ≈ the lost excess (e.g. +2069 junk vs +2477 lost) while d1C0 stays ≈ line rate
  (RX delivery healthy, only ~450-frame word deficit across a 2,480-frame outage run).
  During an outage the DUT is TRANSMITTING FILLER instead of generator frames — the
  stall is at the TX byte-ingestion seam, upstream of air/RX/DMA/host. The exact 1.000 s
  duration and 1.85 s beat are the fingerprints to hunt (no 1 s constants fire in the
  scorer path; the delivery watchdog is 10 s and never tripped).

Season summary of Layer-B loss classes (all with the same instrument, one night):
| class | magnitude | scaling | localization |
|---|---|---|---|
| singles | 0.4–0.8 % | stationary at mid rates | TBD (TX-seam suspect, cf. pair-beat swallow sim) |
| class-B 1 s outages | 0 or 3–4 per 60 s, exactly 1.00 s each, 1.85 s beat | episodic | TX byte-ingestion seam (filler transmitted) |
| overrun swallow | 66–68 % | fires at offered ≥ ~1200 f/s | DUT byte-TX ready over-assertion |
| scattered=biterr | 1–35 per run | grows with rate | host scattered-DMA slice class (only biterr source; fabric BER 0.000) |
| short-fill wedge | total, persistent | deterministic at fill ≤ 16 | fabric len-field parse; reboot-only recovery |

## Wedge boundary bisect — EXACT cliff at fill=47/48 (2026-08-18 07:12–07:5x)

Binary search over (16, 100], gap=100000 (623.8 f/s offered), 20 s dwell per point,
reboot+restore+1245 f/s verification after every wedge. Logs `bisect_f*.log`.

| fill | delivered ok | d104 avg f/s | verdict |
|---|---|---|---|
| 58 | 12,138 | 1310 | SAFE (2.6 % loss, biterr=scattered=8) |
| 37 | 2,143 then collapse | 393 | **WEDGE** (mid-point) |
| 47 | 0 | 132 | **WEDGE** (instant) |
| 52 | 11,289 | 1218 | SAFE (1.3 %) |
| 49 | 12,217 | 1310 | SAFE (2.0 %) |
| 48 | 12,185 | 1309 | SAFE (2.2 %) |
| 47 (repeat) | 0 | 125 | **WEDGE — edge 2/2** |

**Cliff: fill <= 47 wedges (total, reboot-only recovery); fill >= 48 is safe.**
Full boundary picture with prior points: 1 W, 16 W(2x), 37 W, 47 W(2x) | 48 S, 49 S,
52 S, 58 S, 100 S, 700 S, 1516 S. Monotone, no exceptions, 5 wedges / 0 false-safes.

Threshold reading: header(12) + fill(48) = 60 bytes of meaningful content; payload 48 =
exactly six 64-bit words — but safe fills 100/700/1516 are NOT word multiples, so
simple alignment is ruled out; this reads as a minimum-length constant (len >= 48)
in the fabric logic that parses the header len field. That constant is now the
sharpest search key for the RTL hunt / ILA capture.

Rig state after bisect: 148 rebooted+restored, verified fsync=wcnt=1245 f/s; total
reboot cycles this bisect: 3 (after 37, 47, 47-repeat).

## Addendum 2026-08-18 morning — scorer window fix, dwell-dependent cliff, RTL sweep

1. **Scorer accept-path window fix (commit 11feaa5, deployed):** one corrupted-seq frame
   (magic/len/const intact) re-anchored the scorer +16,344 at fill=48 (final review's
   Minor #3, observed live) -> phantom lost + 26 s dup avalanche. Accept gate now
   mirrors the normal path's +/-QPSK_SEQ_WINDOW check; selftest re-anchor guard added.
2. **Post-fix truth:** fill=1516 @624 f/s within-span loss = 83/20,705 = **0.40 %, all
   singles (83 gaps avg 1.0)**, biterr=13~scattered — matches the overnight 0.41 % floor.
3. **The 47/48 cliff is 20 s-dwell-scoped:** fill=48 degraded the link mid-run in BOTH
   60 s dwells (d104 -> ~700 f/s). Safe-at-60s boundary is somewhere in (48, 100];
   700/1516 are proven at 60 s+. Treat fill<=48 as hazardous for long dwells.
4. **Emission-rate caveat:** on a first-pass-degraded link (fsync ~515), tgen becomes
   ready-limited to ~345 f/s at gap=100000 (frame emission stretches with the slowed
   byte-consumption cadence). Always two-pass bring-up before quantitative runs.
5. **RTL sweep of the flashed netlist (s1_rtl): NO module parses magic/len; no 48/60
   constants; tgen FSM timing is fill-independent (only byte values differ). The wedge
   discriminates on DATA VALUES. Only content-sensitive structures: the un-scrambled
   modulated waveform (fill<=47 => >=1469-byte zero run per frame) into the RX sync/
   preamble path, and the framestat checksum overlay. Working hypothesis: FALSE PREAMBLE
   DETECTION inside the zero-run (one-byte-sharp alias threshold; RX-side fsync collapse;
   preamble-FIFO desync surviving soft reset, cleared by PL reprogram; sub-critical form
   = the singles floor). Structurally adjacent TX stall exists (Bit_Packetizer dataReady
   freezes on Data_Bits_FIFO.fullRAM) but has no content path.
   Decisive discriminator: RTL-sim repro (D0 harness, flashed netlist, fill=47 vs 48
   from reset) — full visibility, no ILA needed if it reproduces.

Rig at close: reboot + two-pass restore, verified fsync=wcnt=1244/1243 f/s on air,
tgen pass-through, 146 untouched.

## Layer A internal-loopback canonical point (2026-08-18 ~11:0x, fixed scorer)

fill=1516 gap=100000, 60 s, digital 0x114 loopback: ok=20,629, **lost=84 in 81 gaps
= 0.41 % pure singles** (no outage episode this window), dup=0, biterr=13==scattered
(19,081 error bits all inside those 13 host-scattered frames; datapath otherwise
bit-clean). Layer A loopback is NOT perfect on frame delivery; bit integrity is.
NOTE: run rode the ~345 f/s ready-limited emission mode (pre-arm air link degraded
378 fsync despite two restore passes) — same 0.41 % floor as full-rate overnight runs,
so the floor is robust to emission mode. The degraded-cadence mode itself (byte-TX
consumption ~halved after imperfect bring-up) is now a named, reproducible state.

## RX-seam bring-up — TLAST defect found + fixed; zero-loss check pending fix image (2026-08-18 10:39–11:30)

Image 6846d3a4a265 flashed under full rails (two-pass gate 1254/1254, all four GPIO
regs zero). Zero-loss attempts and their evidence chain:
1. Run 1: ok=1, dup=4,429 — ALL dup seq=13, ALL in t=0–3.8 s (pre-enable), at ~1160/s:
   the queued arm delivered STALE DDR replay ("completions but NO DELIVERY", #48
   signature, directly observed), then silence once the generator took the stream.
2. Clean-precondition rerun (verified 1244/1244 first): same shape (5,545×seq=12 dups
   pre-enable, then total silence). -M 1 variant invalid (queued path requires M>1).
3. Fabric-reset variant: zero delivery of anything.
4. **Daemon-witness discriminator (decisive)**: on a verified-healthy link with the
   daemon delivering (wcnt 1241 f/s, crc_drop +79/s), a 15 s generator window produced
   ZERO const-CRC frames at the host (crc_drop +83 total, dma_rx_ok frozen) and
   delivery did NOT resume after disable.

Verdict: the generator's per-frame TLAST — which this design's S2MM path never sees in
-M mode — terminates/desyncs the queued descriptor chain persistently. Data integrity
is untouched (every delivered generator bit all day scored exact; BER 0.000).
Fix committed 3c329df: dma_last gated behind ctrl[1] (default OFF, markerless stream
like the DUT's own -M behavior); TB gained a last_en-off leg. Fix build launched 11:18
(jupiter_byte_tgenrx_build rebuild); flash awaits operator authorization.
Side catch for #48: stale-DDR replay on fresh arm is now a REPRODUCIBLE observation
(three independent runs), pinned to arming outside the full bring-up sequence.
Rig at close: restored, 1242/1242 f/s, watchdog up, air, both injectors disabled.

## Fix image 4aea5c462a39 (TLAST gated) — flash green; zero-loss STILL FAIL; real culprit named (2026-08-18 13:45–14:2x)

Flash: rails green FIRST pass (1257/1257, all four GPIOs zero). TLAST fix confirmed
effective: stale-dup avalanche gone. But generate mode still delivers NOTHING to the
host, and the daemon-witness discriminator on the new image shows the enable STILL
kills delivery persistently (crc_drop 502/s baseline -> +30/s during ON -> 0/s after
OFF). Mechanism: generate mode holds dut_ready=0 for the whole window — a prolonged
forced stall of the DUT byte-RX drain, i.e. exactly the #48 "drain starves feeder"
wedge-trigger profile. The RX-seam generator's stall-the-DUT design is itself a wedge
trigger. Also: rxseam_zeroloss.sh's fabric-reset pulse resets 0x114/0x158 to defaults
(ROM+loopback) — pre-enable "ADI Hello World" junk explained; pulse to be removed.
Next fix (pending authorization): consume-and-discard in generate mode
(dut_ready = en_d ? 1 : dma_ready) so the DUT never stalls; rebuild + railed flash.

## Pre-flash seam review (2026-08-18 16:5x, user-ordered gate) — no new RTL blocker

Findings: (A) mid-stream-arm rotation already fixed host-side (structural rotation
probe); residual = re-probe only fires pre-anchor -> RULE: restart the -S scorer after
every ctrl toggle (all harnesses already do). (B) burst concern FALSE ALARM: breakout
byte_ready = real DMA tready (combinational), generator handshake compliant; stale
"no backpressure" doc superseded by DMAC_IDENTIFIED.md. (C/D) enable/disable tears one
frame per edge (classifiable) and leaves pass-through word-rotated until re-arm ->
RULE: restore after tgen sessions (standard). (E1) theoretical SYNC_TRANSFER_START/
tuser starvation after a mid-session engine CONTROL reset -> future nicety: pulse
dma_user at generated frame starts; NOT a gate (empirically -M runs marker-less).
(E2) ctrl/gap CDC quasi-static -> RULE: write knobs only while disabled. Verdict:
proceed to flash build3 (2451043705db) with procedures observed.

## LAYER B ZERO-LOSS: PASS (windowed) — 2026-08-18 19:0x, image 87355641f018

Chain: build4 (all three injector fixes: TLAST gated / consume-and-discard /
tuser-on-word-0 for SYNC_TRANSFER_START) + full bringup-sequenced arm in the check
script (the missing PROCEDURE piece: a fresh queued arm on an un-reset fabric replays
stale DDR — the #48 arm behavior — and never delivers; the T8-proven arm batch fixes
delivery instantly, no further RTL needed).

Result (rxseam_check_v5.log, capture rxseam_20260818_190*):
- Generate window (t~10-70 s): ok 1,497 -> 37,011 at the full offered ~620 f/s,
  **lost=0 (0 gaps), biterr=0, dup=0, junk=0 within the window**,
  BER = 0.000e+00 over 452,422,464 scored bits.
- Outside the window (documented artifacts, not seam defects): dup=4,496 all in
  t=0-7.5 s pre-arm (stale seq=13 DDR replay at line rate = #48 arm signature,
  tracked); junk = pre-enable/post-disable loopback filler only.

**The fabric-to-processor boundary is BIT-EXACT with ZERO LOSS at 620 f/s.** The
spec's Layer B number is met in the measurement window. Rate/length envelope sweeps
at the seam are now unblocked. Three-number scoreboard: A-digital 3.7e-6 floor
(+120s beat, separately hunted); A-analogue locked -30dB (bimodal, needs repeats);
B bit-exact/zero-loss (this).
Defect ledger for the record (all injector/procedure, none in the product path):
TLAST desync, dut_ready stall (#48 trigger), SYNC_TRANSFER_START tuser gating,
fresh-arm-needs-fabric-reset procedure. The product-side findings that fell out:
#48 stale-replay arm signature directly observed; sustained-drain-stall wedge
sensitivity; scattered==biterr host class.

## RX-seam ENVELOPE, rate axis (v3, retry-hardened, per-point restore) — 2026-08-18 22:15

CSV rxseam_sweep_20260818_205232.csv. **The seam never loses — it saturates.**
- Bit-exact + zero-loss (lost=0, biterr=0) at every delivering point: 620, 1229, 7477,
  12,861 f/s all delivered at full offered rate.
- **Flow-controlled ceiling ~16,520 f/s (~25.2 MB/s)**: flat across offered 21.9k/33.6k/
  72.7k f/s (4.4x overload) with lost=0 — excess frames are BACKPRESSURED at the
  generator, never dropped. No loss cliff exists on this axis. Ceiling arithmetic
  (~1,032 x M=16 completions/s) implicates host completion processing, not the DMA.
- NO_DELIVERY holes at 311/2025/3941 = arm-lottery triple-misses (8 lottery retries
  absorbed across the axis), not rate physics — bracketed by passing points.

## RX-seam ENVELOPE, length axis (v3) — 2026-08-18 23:1x

CSV rxseam_sweep_20260818_221501.csv, gap=200000 (620 f/s):
fills 700/100/48/16/0 ALL PASS — bit-exact, zero-loss, full rate (~18.8k frames each,
lost=0, biterr=0). The modem's fill<=47 wedge boundary is confirmed irrelevant at the
post-demod seam (fill=16 and fill=0 deliver perfectly). Single hole: fill=1 triple
lottery miss (targeted retest running; 4 triple-misses across 16 sweep points is
consistent with lottery statistics p~6%/point).

**ENVELOPE VERDICT (pending fill=1 retest): the fabric->processor boundary has NO
loss region and NO bit-error region anywhere in the tested envelope** — rate to
12.9k f/s delivered clean, saturation (not loss) at ~16.5k f/s, all frame lengths
0..1516 clean. The only Layer B defect class remaining is the ARM LOTTERY itself
(#48: fresh queued arms fail ~40% and deliver stale/nothing until re-armed).

### Open question: fill=1 scorer death (NOT lottery, NOT scorer logic)

fill=1 at the RX seam: 5 consecutive attempts died with NO scorer summary (unlike
lottery misses, which still report dup/junk counts). Local ASan repro of the scoring
path with fill=1 tgen frames: 50/50 clean — logic exonerated. Rig-side interaction
TBD (candidate: junk-dump flooding -> /dev/shm exhaustion -> OOM-kill if the window
lands word-rotated). One instrumented retest queued (dmesg + rxs.log + df /dev/shm).
All other fills 0..1516 are proven clean, so the envelope verdict stands with this
single instrumented-retest caveat.

## TX-side Layer B (in-fabric checker, image 9259cfade5b4) — BOTH LEGS PASS (2026-08-19 00:5x)

tx_seam_checker @0x9D420000, self-armed on TGEN headers, live-verified (+625 frames/s,
err=0 with the generator on). Legs (30 s each, loopback, 146-down contingency):
- **Leg A continuous-valid (host -> byte TX DMA -> seam): 34,267 frames, 0 bit errors**
  — the TX Layer B spec number: bit-exact from host memory to the modulator's doorstep.
- **Leg B gapped-valid (TX-seam generator, 8-clk bubble cadence): 19,199 frames,
  0 bit errors**, count == offered — pin-level stream integrity clean at the cadence
  the RTL sim proved internally lossy (ByteWordBuffer accept/store divergence is
  post-pin; a definitive internal tap remains optional phase 2).
(First leg attempt scored 0/0 due to a harness read bug — $(($DM addr)) arithmetic
swallowed the command; fixed to $(( $($DM addr) )). Checker cumulative counters had
recorded both legs bit-exact all along.)

## 2026-08-19 — Zero-loss SOAK (3×600 s, soak_night.sh, image 9259cfade5b4)

| dwell | scored | ok | biterr | lost | dup | junk | verdict |
|---|---|---|---|---|---|---|---|
| 1 | 380,782 | 372,713 | 0 | 0 | 0 | 8,069 | **PASS** |
| 2 (after restore recovery) | 386,576 | 365,659 | 0 | 0 | **4,495** | 16,422 | FAIL (dup only) |
| 3 (after restore recovery) | 386,370 | 365,667 | 0 | 0 | **4,500** | 16,203 | FAIL (dup only) |

Headline: **zero loss and zero bit errors across all three 600 s dwells (~1.15 M frames
scored)** — the bit-exact/zero-loss claim holds at soak grade for corruption and loss.
NEW FINDING — duplicate delivery: dwells 2 and 3, both re-armed via full
restore_known_good recovery after an arm-lottery miss, each show ~4.5 k duplicate frames
(bit-exact re-deliveries; nothing missing) and double the junk words of dwell 1.
CHARACTERIZED from scorer EVT logs (both dwells identical structure): every duplicate
falls in t=0.002–11.41 s — the pre-enable window (arm batch + 3 s double-tap wait +
re-batch takes ~11.4 s before the generator enable). Content: one stale copy each of
seq 1–11 plus seq 12 replayed ~4,485× at frame cadence (~800 µs spacing, ≈2.5 ms
inter-arrival as scored). These are the first 12 frames of the PRECEDING lottery-miss
attempt, still in the M=16 S2MM ring: the miss attempts actually delivered 12 frames
into DDR before wedging, and on the next arm the queued DMA re-completes the last
buffer (seq 12) continuously until fresh generator data arrives at enable. Dups stop
at the exact enable instant; the scored dwell itself is 100 % clean (0 dup, 0 lost,
0 biterr after t=11.4 s). Two conclusions: (1) the strict-verdict FAIL is a harness
artifact — scoring opens before generator enable and catches the stale window; the
seam datapath claim is unblemished; (2) this is the sharpest quantification yet of the
stale-DDR replay-on-arm phenomenon (#48 family): the "lottery miss" is not a
no-delivery state — it delivers ~12 frames then wedges, and its ring residue replays
at full cadence on the next arm. Logs: rxseam_soak_{1,2,3}_v2.log, captures under
two_jup/r3cap/rxseam_20260819_{081517,083943}. Arm lottery: dwells 2 and 3 each
needed one full-restore retry (2 misses / 5 arms).
