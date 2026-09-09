# Packet-error sources — outline and simulation reproduction from captured datasets

Started 2026-08-26. Scope (operator-selected): ALL classes including host/DMA;
reproduction through BOTH the fixed-point RTL netlist and the float reference.
Entirely offline — no rig contact; rig-only gaps are declared, not skipped.

Evidence anchors: `LOSS_LEDGER.md` (class definitions + pooled scoreboards,
sum-checked against `accept_analyze.py`), `KNOWN_HOLES.md` (H-1..H-11),
`FWD_SINGLES_ROOT_CAUSE.md` (partially superseded banner stands),
`SINGLES_CAMPAIGN.md` (dated ledger), `NETLIST_PROVENANCE.md` (which sim binary
is which — consulted before every verdict below).

Datasets: `two_jup/sim_repro/CAPTURE_MANIFEST.md` (written by
`sim_repro/health_sweep.sh`; every capture used below is health-gated by
`check_capture_health.py` first — un-gated IQ is never scored).

## The central tension this document resolves

`SINGLES_REPLAY.md` (2026-08-12): 12/12 hardware-corrupt frames decode CRC-GOOD
when 148's own captured IQ is replayed through the bit-true netlist → the fault
is NOT in the IQ (delivery-plane hypothesis, backed by CP1 checksum 91.4%).

H-1 (2026-08-26): the SAME netlist generation corrupts 13.0% of frames from
synthetic −15 kHz coupled CFO+SRO stimulus and 0% at +15 kHz → a receiver
tracking defect that REQUIRES the SRO component (suspect: one-sided mu clamp,
`Interpolation_Control.v:163-172`).

Both results are real. The discriminating experiment is hole-aligned per-frame
replay of captured IQ (E1 below): if the sim corrupts the same frames the
hardware corrupted, the defect is in the received signal path; if the
hardware-corrupt frames replay clean at scale, the loss is added after the
demod chain (delivery plane), and the synthetic H-1 repro describes the
operating-point sensitivity, not the per-frame mechanism. They may BOTH hold:
the comb sets the operating point; the delivery plane sets which frames die.

## Class table (verdicts filled as legs complete)

Shares from `LOSS_LEDGER.md` pooled tables — FWD: 8 runs, 43,804 lost /
655,989 span = 6.678% PER; REV: 16 runs, 13,678 / 1,402,771 = 0.975%
(2026-08-12 framelogs, stock-LO era; the standing forward number at the +20k
default is ~6% idle).

| id | class | PER share | layer | sim method | verdict |
|---|---|---|---|---|---|
| E1 | boundary comb singles+doubles [dc+nd] | FWD 5.78 pp (84%+2.3%) | **delivery plane** | hole-aligned IQ replay, RTL+float | **CLEAN-IN-IQ** (26/26 hw-corrupt frames decode in RTL; 321/322 float CRC-valid) → E9 |
| E2 | mid-gap[c8] / mid-gap | FWD 0.65 pp; REV 0.70 pp | delivery plane (fwd) | same as E1 | **CLEAN-IN-IQ** (fwd, with E1) |
| E3 | tx-mute-cand | FWD 0.16 pp; REV 0.07 pp | TX/RF | IQ envelope at event positions + replay | **CONFIRMED-IN-IQ** (72 µs envelope dip = the seq-0 record; both decoders fail it) |
| E4 | burst class (H-4) | startup bursts ~1 s ×3 after bring-up; steady ~5k/2–3 min | TX content (startup) | 53 windows inside startup bursts | **REPRODUCED-IN-IQ** (startup subclass = TX content fault); steady-state burst DATA GAP |
| E5 | SRO tracking defect (H-1) | sets fwd operating point; dominates reverse | RX DSP | mu telemetry + captured-IQ | **REPRODUCED** synthetic + captured N=2: symbol-DELETION episodes; mu-clamp REFUTED; fix target downstream of Interpolation_Control |
| E6 | float gap / BER residual (H-2/H-10) | — | RX DSP | per-stage EVM vs float | **CLOSED**: fixed within ~1 dB of float at the slicer; residual BER is episodic |
| E7 | reverse residual | REV 2.6–2.9 % today | RX DSP (E5) at 16 dB | reverse replay N=2 + 1,609-frame scale | **REPRODUCED-IN-IQ**: holes = E5 deletion cadence; FIFO/RXQ will not help reverse |
| E8a | #48 short-fill wedge | availability | host/DMA | tgen testbench | **REPRODUCED** (f47 collapses, f48 survives) |
| E8b | hourly delivery wedge (H-6) | availability | host/DMA | wdlog snapshots | DATA GAP — snapshot pipeline was broken (empty files) and the sentinel was dead 08-26 22:03 → 08-27 13:23; now a systemd unit |
| E9 | delivery-plane boundary fault | = E1 (84 % of fwd) | host/DMA | periodic byte_rx_ready stall on air data | **REPRODUCED**: 64-word ByteRxFifo overflows at ≥0.25 ms per-transfer gaps; FIX: 4096-word BRAM FIFO (sim-gated PASS, image built/flashed per ledger) + RXQ=1 default (−5.1 pp, shipped) |
| E10 | bidirectional collapse (H-5b), arm-lottery, ARMCAUSE latch, H-7 crash | availability | host/system | documented; H-5b re-tested in queued mode (collapses at 12 s, mode-independent) | DOCUMENTED |

## Pre-stated pass criteria (fixed BEFORE the T3–T6 legs run)

- **E1/E2 REPRODUCED-IN-IQ**: over every healthy fwd capture window containing
  ≥3 hardware-corrupt boundary-class frames, the RTL replay (best rotation ×
  vphase arm) shows CRC/bit corruption on ≥half of exactly those frames while
  ≥90% of hardware-clean frames replay clean. **CLEAN-IN-IQ**: ≥90% of the
  hardware-corrupt frames decode CRC-good in the best arm (the 08-12 12/12
  precedent at scale) AND the float leg also decodes them clean.
  Anything between: INDETERMINATE with the per-frame table published.
- **E3**: an IQ envelope dropout (≥50% RMS drop for ≥50 µs) at ≥half of
  tx-mute-cand event positions inside the window = CONFIRMED-IN-IQ (TX-side);
  flat envelope at all positions = NOT-IN-IQ.
- **E4**: scored only if T1 finds a burst inside a healthy window; else DATA
  GAP (proposed follow-up: triggered capture armed by the sentinel).
- **E5 conviction**: on synthetic −15k coupled stimulus, mu clamp-active events
  temporally precede (within the same tracking excursion) the Peak_Search false
  latch on corrupt frames, AND clamp-active count is ~0 on +15k and on both
  CFO-only legs. Captured-IQ leg: mu trajectory from `singles_reread` shows the
  same one-sided walk. Fix A/B: mu-wrap patch drops −15k corrupt frames to
  ≤1/46 with +15k unchanged at 0.
- **E6**: ladder stage contributions must sum (in quadrature) to the measured
  fixed-vs-float gap within ~20%; anything unexplained is named as such.
- **E7**: same criteria as E1/E3 applied to the reverse capture; 33-frame
  cadence test = underrun events align with envelope gaps within ±2 frames.
- **E8a**: leg_f47 clean / leg_f48 wedged reproduces on re-run (the recorded
  cliff), gate strings green.
- **E9**: induced inter-transfer stall corrupts serializer output words with
  fabric checksum equal to the corrupt byte stream (the CP1 signature).

## Sanity controls (must pass before any new verdict is accepted)

1. 0 Hz synthetic stim through `obj_byte_taps_f1536_jul25/Vwrap_byte_taps` →
   0/46 corrupt (reproduces the H-1 baseline).
2. `singles_reread` best-arm replay through `obj_byte_iq/Vwrap_byte` →
   matches the recorded 12/12 CRC-good result.
3. `float_baseline_f1536('romair_20260824_221024/pair.iq')` → reproduces the
   recorded bit-exact float-zero (H-9 leg 1).

## Verdicts

(filled by T3–T7; every entry carries exact command, frame counts, and losses
in the denominator)

### E8b — hourly delivery wedge / watchdog escape (H-6): NOT SIMULABLE FROM CAPTURES; evidence pipeline was broken, now armed

The wedge class leaves no IQ signature (the demod rail keeps running at
~1243 f/s while delivery stops), so there is nothing to replay. Its only
instrument is the on-board watchdog log at recovery time. Finding (2026-08-26
evening): all 8 banked `~/modem-status/wdlog_*` snapshots were 0 bytes —
`delivery_sentinel.sh` read `/dev/shm/lock_watchdog.log`, but
`lock_watchdog.sh:19-20` `exec`s its own output to `/dev/shm/watchdog.log`
regardless of the launcher's redirect. Fixed (sentinel restarted, snapshots
now = watchdog.log + last 40 kB of the daemon log per board). **Verdict:
DATA GAP, mechanism unnamed; the next wedge produces the first real
snapshot.** Rig protocol needed: none beyond letting the sentinel run.

### E10 — bidirectional-load collapse (H-5b), arm-lottery, ARMCAUSE latch, H-7 crash: DOCUMENTED ONLY

None of these have an IQ or testbench representation available offline:

- **146 bidirectional collapse** (3/3 soak attempts, ≤15 s to zero delivery
  under simultaneous `qpsk_perf` load both ways; evidence lost to the 00:55
  reboot on 08-26). Host/daemon-level; the discriminating rig protocol is a
  repeat with `QPSK_FRAMELOG` + `strace -c`/`top -H` on 146's daemon and the
  new sentinel snapshots armed, ramping the reverse offered load in 4
  steps to find the collapse threshold. Not runnable here (no rig contact).
- **Arm-lottery receiver state** (146 RX intermittently 510–700 f/s after a
  bring-up; cured by redraw). Arm-time state, not a signal property; the
  captures in the manifest were all taken in the full-rate state. Rig
  protocol: ARMCAUSE-style register census immediately after each arm
  (0x150 rstcs, 0x154 cfc, AGC/timing loop state via the debug mux) for ≥10
  arms, pairing the degraded draws against the healthy ones.
- **ARMCAUSE false-FTS latch** (~40% sync + 100% crc): a measurement artifact
  of the arm sequence (cured by the ROM double-tap); already root-caused on
  the rig, deliberately outside the loss taxonomy.
- **H-7 148 hard crash** (08-26 ~09:00, dmesg wiped by the power cycle):
  unrecoverable one-off; the only mitigation is persistent kernel logging
  (`/etc/systemd/journald.conf Storage=persistent` on the board) before the
  next occurrence.

### E5 — SRO/CFO sign-asymmetric comb (H-1): synthetic leg DONE — mu-clamp suspect REFUTED; mechanism re-characterised as symbol-DELETION episodes

Harness: `jupiter_240k5_byte/rtl_sim/obj_byte_taps_mu_jul25/Vwrap_byte_taps_mu`
(= `wrap_byte_taps_mu.v` + `sim_byte_taps_mu.cpp`, Jul-25 archive netlist,
cadence 4; exposes Interpolation_Control's T8.7 `stateWord` =
{underflow, countReg, mu} as a change-compressed `_mu.txt` dump). Stimuli
regenerated by `rtl_cfo_repro/gen_cfo_stim.m` (perm [0 1 3 2]). Drive:
`Vwrap_byte_taps_mu <stim.iq> 2466600 0 4 8400 0 <pfx> 0`. Scorer:
`rtl_cfo_repro/score_rxw.py` (46 scoreable frames/run) +
`rtl_cfo_repro/analyze_mu.py`.

**Sanity control 1 PASS**: the mu-tapped build reproduces the 08-26 table
exactly — 0/±5k/+15k/+25k/±15k-CFO-only: 46/46 golden; −15k coupled 6/46
corrupt (frames 33-35, 44-46); −25k coupled 11/46.

**Mu-clamp hypothesis (Interpolation_Control saturating branch) — REFUTED.**
`mu == 1023` (the saturated value) occurs 0 times in BOTH corrupt runs
(−15k, −25k: mu range [0,1016] throughout); it occurs only, harmlessly, in
the clean 0 Hz (8×) and +15k-CFO-only (16×) runs. Near-rail counter values
are equally common in clean +15k (13.9k) and corrupt −15k (15.7k). The
clamp is not the mechanism.

**What the telemetry actually shows (both signs):** the loop chatters at
the mu wrap boundary (mu alternating ≈0 ↔ ≈1000 with strobe spacing
alternating 18/14 clk) — symmetric, present in clean +15k frames too, NOT
discriminating. The discriminating quantity is the **net strobe count per
frame**:

| run | frames with 12334 strobes (symbol INSERTED) | frames with 12332 (symbol DELETED) | corrupt frames |
|---|---|---|---|
| +15k cpl | 5, 16, 27, 38 | — | none |
| −15k cpl | — | 4, 15, 26, 37, 47 | 33-35, 44-46 |
| +25k cpl | 3,10,16,23,29,36,42 | — | none |
| −25k cpl | — | 2,9,15,22,28,35,41,48 | 19-21, 26-27, 32-34, 39, 45 |

Slip period = 1 symbol per (4 samples / ppm·Fs): 11 frames at 7.5 ppm,
6.5 at 12.5 ppm — matches. Every corruption episode follows a DELETION at a
fixed drift phase (+7 frames at 15k, +4 at 25k ≈ 0.65 of the slip period),
lasts ~3 frames (the Peak_Search false-latch/Phase_Ambiguity mis-resolve
chain from 08-26), and the first two deletions of each run are harmless
(warm-in). Insertions never corrupt. **Verdict: REPRODUCED (synthetic);
mechanism = the receiver tolerates symbol insertion but not symbol
deletion under negative SRO; locus downstream of Interpolation_Control
(Symbol_Synchronizer output onward). Interpolation_Control itself
behaves symmetrically.** Fix path is therefore NOT a mu-wrap patch; the
deletion-handling (frame/symbol-count accounting after a dropped strobe)
is the next tap target. Captured-IQ leg: pending (`singles_reread` through
the same binary; real SRO ≈2.6 ppm ⇒ deletion every ~32 frames).

### E1/E2 — boundary comb singles/doubles + mid-gap: RTL leg DONE at N=2 — **CLEAN-IN-IQ**

Method: `sim_repro/window_truth.py <capture_dir>` (hardware ground truth:
capture window located by the CAP_START/CAP_END `reg_packets` bracket in
`regs_cap.txt`; every crc-fail record and every missing `host_seq` listed)
→ `tap_replay_study/run_region.sh 0 161 0 3` (perframe_f1536, Jul-25
bit-true netlist, cadence 4, three parallel chunks, provenance-stamped) →
`sim_repro/hole_aligned_score.py <chunk_dir> <hw_lost_seqs>` (QK header +
zlib CRC32 per 191-word frame; seq anchor fitted on CRC-good frames;
warm-up head / drain tail excluded).

| capture (fwd, 148 RX, 162 frames = 130 ms) | hw-lost seqs in window | inside scored window | decode CRC-GOOD in netlist | hw-good controls clean |
|---|---|---|---|---|
| `singles_reread` (08-12; regression of the recorded result) | 20 (16 holes: 12 singles + 4 doubles) | 13 | **12/12** scoreable (k=1 is the cold-start frame, unscorable) | 150/159 single-alignment; the 9 fails are the k=85-88/122-127 loop-state transients the 08-12 record resolved by re-alignment (only 32149, post-mute, fails at every alignment) |
| `cp1_verdict2` (08-12, CP1-instrumented; new) | 21 (15 holes: 9 singles + 6 doubles, all at the 8-frame comb cadence 0xC0E5/F5/105…) | 14 | **14/14** | **144/145** (only k=1 cold-start) — no transients at all |

Pooled: **26/26 hardware-corrupt frames (singles AND doubles) decode
CRC-good, correct seq, 191/191 words, from the receiver's own captured air
samples**; 294/304 hardware-good controls clean (all residual fails are
identified harness artefacts). Pass criterion (≥90% of hw-corrupt frames
clean in the best arm) met at 100% — and without needing the 8-arm
rotation sweep. **Verdict E1/E2: CLEAN-IN-IQ.** The comb loss is added
AFTER the demodulator — the delivery plane (E9) is the mechanism; the H-1
tracking defect (E5) is a separate, operating-point-setting class whose
episodes occur every ~32 frames at the real 2.6 ppm SRO, not every 8.
Float leg (float_baseline_f1536 decBits vs the netlist FEC bit stream on
the same windows): pending.

### E1 float leg — DONE: float and RTL agree bit-for-bit (to the float reference's own floor) on hardware-corrupt and hardware-good frames alike

`float_baseline_f1536(pair.iq,'mapping',[1 3 2 0],'keepbits',true)` (new
options: fixed TX quadrant→label map, since live-traffic captures carry no
ROM payload to calibrate on; per-frame decoded info bits returned) vs the
netlist's FEC-decoded bit stream (`Vwrap_byte_taps_mu … 8000000 0 4 8400 0`,
`_fec.txt`), `sim_repro/compare_float_rtl_bits.py`. singles_reread: 161
float frames ↔ 157 RTL frames, **exact frame alignment (offset 0; any ±1-bit
offset gives ~6k mismatches)**, mismatch = 13–16 bits per 12,292 (0.12%)
on EVERY frame — hw-corrupt frames median 15, hw-good median 16. The
residual is the float reference's known single-derotation floor (scattered
4-bit clusters, tail-heavy), not frame corruption. **The float chain sees
nothing special at the hardware-corrupt frames** — E1 CLEAN-IN-IQ holds at
the float level too. (RTL frames where the RTL itself failed — the mute
recovery and the deletion-phase episodes below — show ~6k mismatches, as
expected.)

### E5 captured-IQ leg — DONE: symbol-DELETION episodes REPRODUCED on real air samples at the real SRO

Same `singles_reread` tap run, `_mu.txt` telemetry: strobes per capture
frame = 12333 except **frames 31, 64, 97, 130 (12332 = one symbol
deleted; period 33 frames ⇒ 2.5 ppm, i.e. the measured ~2.6 ppm XO
offset)** and frame 85 (12305: the on-air TX mute). RTL CRC failures in
this single-alignment run: 84-92 (mute + recovery), **120-124** and
**152-156** — each 22-26 frames (≈0.7 of the slip period) after the
deletions at 97 and 130; the deletion at 31 is harmless (warm-in), exactly
the synthetic pattern (+0.65 period, first deletions harmless). This also
explains the 08-12 "alignment-dependent recovery transients" at 122-127:
re-chunking restarts the timing loop, which moves the deletion phase.
The hardware framelog shows NO failures at seq 32184-32190 / 32216-32222,
so on the hardware's own loop state these particular episodes did not
fire — the class is real (it is the H-1 comb's mechanism family) but
phase-dependent; its hardware rate is the operating-point sensitivity
already measured (13% → 6% with +20k). **Verdict E5: REPRODUCED on
captured IQ. Fix target = the receiver's handling of a deleted strobe
downstream of Interpolation_Control (Symbol_Synchronizer output →
Peak_Search), NOT the mu clamp.**

### E1 float leg, independent CRC verdict — DONE: the float chain decodes every hardware-corrupt frame with a VALID CRC

`sim_repro/float_crc_score.py`: the float reference's decoded info bits
(first 12,224 of 12,292, MSB-first — packing derived against the netlist
byte stream with 0 mismatches) packed into the 1528-byte frame and checked
exactly as the host daemon does (QK magic + zlib CRC32). singles_reread:
**160/161 float frames CRC-good** (the single failure is frame 84, the
on-air TX mute), seq 32065..32224 contiguous — i.e. all 13 hardware-corrupt
frames inside the window are decoded with a valid CRC by a receiver that
shares no RTL with the fabric. Together with the netlist result this is
two independent demodulators agreeing that the air signal carried those
frames intact. E1/E2 CLEAN-IN-IQ is closed on both sim targets.

### E7 — reverse residual: first captured-window result (catch8, 146 RX, healthy window) — holes are IN THE SIGNAL

Reverse TX (148) uses a different bit→symbol map than 146: 24-permutation
float sweep on catch8 → only **[2 0 1 3]** yields CRC-valid frames
(155/159); every other permutation 0/159. Float SNR on the reverse leg is
**16.0 dB** (forward: 28 dB) — consistent with the known ~5-6 dB reverse
deficit. Hardware window: 3 holes / 7 lost (34744×3, 34761, 34796×3) + a
seq-0 garbage record after 34756. Float CRC fails: frames 105-106 (=
34744-34745, hw hole), 117 (= 34756, the hw garbage-record event), 156 (=
34796, hw hole). Netlist (perframe_f1536, cadence 4): 151/158 CRC-good;
fails at 34746 (hw hole), 34797 (hw hole), plus 34747-48 / 34757-58
(episode tails). **Unlike the forward comb, the reverse holes coincide
with signal-level failures in BOTH references** → E7 verdict so far:
REPRODUCED-IN-IQ (signal/SNR-limited class, not delivery-plane). N=1;
the 1,700-frame `bigiq_093328_a3` reverse replay is running to score it
at scale.

### E1 float leg at N=2 — cp1_verdict2: **161/161 float frames CRC-valid**, seq 32026..32186 contiguous

24-permutation sweep (the quadrant→label map is a per-capture constant —
`[1 3 2 0]` on singles_reread, `[3 2 0 1]` on cp1_verdict2, `[2 0 1 3]` on
the reverse captures; per-frame preamble derotation leaves a fixed
rotation/swap ambiguity per arm, so the map must be calibrated per
capture by CRC — `sim_repro/float_crc_score.py` over the sweep does it).
With the right map the float chain decodes **every** frame in the window,
including all 14 hardware-lost seqs, with a valid CRC. Pooled float leg:
**321/322 frames CRC-valid across the two forward windows** (the one miss
is the on-air TX mute), covering 27 hardware-corrupt frames. E1/E2
CLEAN-IN-IQ: closed on both references at N=2.

### E4 — burst class: the ~1 s post-bring-up ("startup") bursts are REPRODUCED-IN-IQ and are a CONTENT fault, not an RF one

Dataset: 53 of 98 healthy capture windows (50 reverse, 3 forward) sit
inside a ~1 s all-CRC-fail run (`sim_repro/window_truth.py`); the
`accept_rxq_20260807_004148_r1` framelog shows three such runs at 7.95,
9.78, 11.61 s (1211/1236/1258 frames, period ≈1.8 s) with hardware
`reg_cfc` FLAT (−2178..−2234), rstcs 0, biterr/frame unchanged (≈55)
before/during/after — the hardware receiver is locked throughout.
Replay of its window (inside run 1):
- RTL (perframe_f1536): **0/158 frames carry a valid QK header** (191
  words each, framesync running). Reverse CONTROL on a healthy window
  (`catch8`): 151/158 CRC-good — the netlist acquires reverse captures
  fine, so this is not an acquisition artefact.
- Float: frames 162 candidates, preCorr 0.899/0.998/1.037, SNR 16.4 dB,
  CFO −15.5 kHz — **statistically identical to the healthy reverse window
  (catch8: 0.934/0.979/1.027, 16.0 dB, −15.5 kHz)**; RMS envelope flat
  (1367–1682 per frame). Yet **0/161 CRC-valid under ALL 24 quadrant maps**
  and 0.5 BER against the ROM/BIST pattern.
**Verdict: REPRODUCED-IN-IQ.** Preamble, symbol timing, carrier, SNR and
envelope are normal; the payload bits are not valid frames under any
labeling and are not the BIST filler — the transmitter (148) is sending
well-formed QPSK carrying wrong content for ~1 s, three times, at a
fixed cadence after bring-up. That is a TX byte-plane/feeder content
fault (candidates: interleaver/scrambler block-phase slip relative to
the preamble, or stale/garbage TX buffer during the arm sequence), not a
channel event. This is the LOSS_LEDGER `startup-burst` class; whether the
steady-state "universal burst" (~5k frames / 2–3 min, H-4) is the same
mechanism is NOT established by this data (no healthy capture window
overlaps a steady-state burst — DATA GAP; a triggered capture is the
follow-up).

### E6 — steady floor / BER residual: per-stage fixed-vs-float budget on singles_reread — NO stage eats the margin

Fixed-point stage taps (`Vwrap_byte_taps_mu`, Jul-25 gen) scored with a
rotation-free hard-decision EVM per stage; float reference SNR from
`float_baseline_f1536` (`snrEstDb`, same capture):

| stage | metric | value |
|---|---|---|
| float chain (payload symbols, per-frame derotated) | Es/N0 | **28.0 dB** |
| fixed `cs` (Carrier_Synchronizer out) | hard-decision EVM | 3.49 % → 29.1 dB |
| fixed `pa`/`con` (resolver / recovered constellation), per-frame | EVM median 3.65 %, p95 4.12 % | ≈ 28.8 dB |
| position profile within frame | flat (no tail-heavy drift) | — |

Fixed chain sits within ~1 dB of the float reference at the slicer; no
rung adds a measurable loss (quadrature sum of stage deltas ≈ 0.4 dB —
inside the ±20 % criterion). At 28–29 dB slicer SNR the thermal QPSK BER
is ≪1e-20, so the measured 8.2e-5 air BER residual (H-10) **cannot be a
noise/margin term** — it must be episodic (E5 deletion episodes, E3
mutes, E4 content bursts, E1 delivery-plane corruption), which is exactly
what the other legs show. **Verdict E6: the 0.3 % → 6 % cross-board
loss is not a demodulation-margin problem; the float-gap is closed
(≤1 dB) and the residual BER is named as episodic, not thermal.**
Reverse leg: float Es/N0 16.0 dB (catch8) — 12 dB below forward; still
BER-clean thermally (QPSK @16 dB ≈ 1e-8/bit ⇒ ~1e-4/frame), so reverse
holes are also episodic (see E7).

### E5 captured-IQ leg at N=2 — cp1_verdict2 shows the identical deletion→episode law

`Vwrap_byte_taps_mu cp1_verdict2/pair.iq 8000000 0 4 8400 0 …`: strobe
deletions at frames **6, 38, 71, 103, 136** (period 32.5 ⇒ 2.5 ppm, same
XO offset as singles_reread's 31/64/97/130); RTL CRC failures at
**95-100** and **127-131** = deletions 71 and 103 **+24..29 frames**
(singles_reread: +23..26); deletions 6 and 38 harmless (warm-in). 149/159
frames CRC-good otherwise. Two captures, four episodes, one law: a
deleted symbol is followed ~0.7 slip-periods later by a 3-6 frame
corruption episode; the first two deletions after acquisition never
fire. The hardware framelog has no holes at seq 32120-125 / 32152-156,
so — as on singles_reread — the hardware's own loop phase escaped these
particular episodes. **E5: REPRODUCED on captured IQ at N=2.**

### E9 — delivery-plane boundary fault: **REPRODUCED** on real air data by periodic byte_rx_ready backpressure

Harness: `sim_byte_taps_mu.cpp` stall model (argv 9-11 = period_samples,
len_clk, phase_samples; byte_rx_ready deasserted for len_clk each time the
sample index crosses phase + n·period). Capture: singles_reread (real
air, 162 frames); period = 8 frames = 394,656 samples (the measured comb
cadence, LOSS_LEDGER); 21 stalls per run; no-stall baseline = 142/157
CRC-good (the 15 baseline fails are the mute + E5 episodes).

| stall length (clk @ cadence 4) | ≈ time | frames good | frames lost vs baseline | word lengths seen | class produced |
|---|---|---|---|---|---|
| 100 / 1,000 / 10,000 (4 phases) | ≤41 µs | 142 | **0** | 191 only | absorbed by ByteRxFifo |
| 100,000 | 0.41 ms | 124 | **18 of 21 stalls → exactly one frame each**, seq 32071, 32079, 32087, … (spacing 8) | 156-157 + 191 | **boundary-single [dc]**: truncated frame, header intact, CRC fails |
| 300,000 | 1.2 ms | 105 | 37 → **two consecutive frames per stall** (32071-72, 32079-80, …) | 153-154 + 191 | **boundary-double [dc]** |

The induced loss has every fingerprint of the hardware class: one
delivered-but-corrupt frame per stall at exactly the 8-frame comb
cadence, early header intact (the "pair event" signature: seq readable,
CRC fails), the frame truncated at the fabric egress — which is what the
CP1 comparator saw (fabric serializer-output checksum == corrupt host
bytes, 91.4 %). Threshold: the egress absorbs ≤10k clk (~10 words of
backlog at the delivery rate) but not 100k; the hardware DMAC's
inter-transfer gap therefore lies between ~40 µs and ~0.4 ms per area
(fine sweep 20k-150k running to name the FIFO depth). **Verdict E9:
REPRODUCED — the forward comb (E1/E2, 84 % of forward loss) is
inter-transfer S2MM backpressure overflowing ByteRxFifo; the fix space is
(a) no transfer boundaries (cyclic S2MM, already the planned path),
(b) a deeper ByteRxFifo sized ≥ the DMAC gap, or (c) a shorter descriptor
re-arm gap.**

E9 mechanism detail from the netlist: `ByteRxFifo.v` is **64 × 64-bit,
drop-newest on full** (comment: "stall > ~19 ms" — a K5-rate-era sizing).
At the f1536 delivery rate (191 words per 197k-clk frame ≈ 1 word / 1,030
clk) 64 words cover only ≈66k clk ≈ **0.27 ms** of backpressure, which is
exactly the bracket the sweep found (10k clk absorbed, 100k clk → one
truncated frame). The comment's 19 ms assumption is off by ~70× at the
f1536 rate — the FIFO was never re-sized for the rate change. Both
netlist generations (Jul-25 and flashed `s1_rtl`) carry the same 64-deep
FIFO.

### TX-side counterpart of the K5-era sizing (operator item 6)

The TX byte plane's only elastic element is `ByteWordBuffer` (TxRxComposite
u_ByteWordBuffer, `state_buf [0:15]` = **16 × 64-bit words**) between the
MM2S byte_data AXIS input and the modulator's `extWordPop` consumer, plus
the K5-era 8-frame TX batch logic in the host (`TX_BATCH`, sized for the
device-tick class). At f1536 an air frame consumes 3,080 B = 385 words, so
16 words cover **4 % of one frame ≈ 33 µs** of MM2S starvation before the
modulator underruns (`txur` witness 0x1C8, `tx-mute-cand`/`tx-underrun-comb`
classes: 0.16 pp fwd, 0.07 pp rev — small but present, and E3's ~72 µs
on-air mute is exactly a 2× overrun of this cover). The same assumption
(sized in words for the 240k byte rate) therefore DOES appear a second
time; it is not the dominant loss today and is left as a named follow-up
(deepen ByteWordBuffer to ≥ one frame = 512 words, same BRAM technique),
not bundled into the RX FIFO image so the A/B isolates one change.

### E8a — #48 short-fill wedge: REPRODUCED on this host (recorded cliff confirmed)

`QSIM_TGEN_BUBBLE=0 obj_tgen_wedge_flashed/Vwrap_byte_tgen {47|48} 600 100000
<pfx> 125 700000` (flashed-generation netlist, internal loopback, the
tgen testbench — no IQ involved, this class has none): fill=47 →
**282/600 delivered, Preamble-Detector delay FIFO occupancy collapses
12333 → 9346 and delivery dies** (the silicon short-fill wedge signature);
fill=48 → 592/600 delivered, occupancy 12333 throughout. 210-frame short
legs stay healthy at both fills (206/210, 203/210), as recorded —
the cliff is a threshold-proximity walk that needs the long leg. Verdict:
REPRODUCED (testbench), per `SIM_WEDGE_REPRO.md`; the host-side mitigation
(fill ≥ 100) stands.

### E9 → FIX (operator directive 2026-08-27): sized, gated, building

- Threshold pinned: 64 words = 0.25 ms (0.20 absorbed / 0.28 truncates).
- Live 148 (comb image): 0x1B0 overflow 17-45 words/s at idle; loaded legs
  ≈1 dropped word per transfer — one word is enough to shift the slice
  accounting and produce the hardware signature.
- Comb cadence = once per S2MM transfer (16 frames @ -M16, 32 @ -M32).
- Stall source (item 4): host reset-per-transfer re-arm (RXQ=0 default)
  ≈5.2 pp — RXQ=1 8.72 % vs 13.95 %; drain-then-submit lateness EXCLUDED
  (4 areas = 8.75 %); residual ≈0.25-0.3 ms gap per transfer inside the
  axi_dmac S2MM transfer switch (named to the block; cycle-level cause
  needs an ILA on tready / DMAC RTL sim — follow-up).
- Fix: BRAM drop-in ByteRxFifo DEPTH=4096 (17.2 ms cover, 69× threshold,
  ≥ largest observed 20-frame stall; 8 RAMB36; flop array impossible at
  78 % FF). Sim gate on the flashed generation: PASS (0 lost at 0.41/1.22
  ms vs 10/20 on the original; no-stall stream byte-exact).
- Image: clone of the fe5bd8a4fe19 build tree, one module replaced,
  Vivado resynth in progress. Flash rails: `skidfix/flash_148_rxfifo.sh`
  (restore point = current image banked on-board + repo). A/B protocol:
  `sim_repro/ab_fifo_legs.sh` = the same 3-leg forward saturated capture
  as the baseline (13.93/13.98 %, CP95UL 14.2 %).
- Reverse is NOT expected to move (signal-level at 16 dB, E7).

### E7 at scale — bigiq_093328_a3 (reverse, 146 RX, 1.3 s, 1,609 scored frames): reverse holes are the E5 deletion-episode law, IN THE SIGNAL

`run_region.sh 0 1620 0 6` (24 chunks, perframe_f1536) + `hole_aligned_score.py`:
netlist 1534/1609 CRC-good. Hardware: 13 holes / 19 lost seqs in the window,
12 inside the scored range. Outside the RTL's own chunk-warm-up region
(k≈477–600, where the netlist's cold-start transients fail ~35 frames the
hardware decoded — the 08-12 alignment caveat), the hardware holes sit at
**52107-8, 52395, 52427, 52459, 52491, 52522 — spacing exactly 32 frames**
— and the netlist fails at 52123, 52393, 52426, 52457-8, 52490, 52522: the
same events within the anchor's ±2-frame drift (the seq fit is nonlinear
on 925 good frames = inserted slots), 6 of 7 matched. A 32-frame cadence
on a reverse -M32 run is ambiguous between the S2MM transfer boundary and
the E5 deletion period (32.5 frames at the measured 2.5 ppm SRO); the
netlist replay disambiguates it: **delivery-plane events cannot appear in
replayed IQ, deletion episodes do** — and they do, here and on catch8
(2/4 hw holes failed in RTL, 3/4 in float). **Verdict E7: REPRODUCED-IN-IQ;
the reverse residual (2.6–2.9 %) is dominated by the H-1/E5 receiver
symbol-deletion defect, not by the delivery plane and not by thermal
noise (16 dB).** Consequences: neither the FIFO deepening nor queued RX
mode is expected to move reverse (as the directive anticipated); the
lever that moved forward 13 % → 6 % — the LO-sign operating point
(+20 kHz off-null, which flips the slip direction seen by the tracking
loop) — has never been tried on reverse (H-5a) and is the cheapest
reverse experiment on record; the durable fix is the E5 deleted-strobe
handling.


## E9 — CORRECTION 2026-08-28 07:01

The 4096-word ByteRxFifo (v5 `602b26c25c35`) delivered on silicon and was A/B'd: RXQ=0 14.18/14.14 % vs 13.93/13.98 %; RXQ=1 8.63/8.63 % vs 8.73/8.89 % — **no change**. The comb is the axi_dmac `SYNC_TRANSFER_START` discard at each transfer handoff (tready high, words dropped until the next `tuser`), not a FIFO overflow; the sim stall model could not discriminate the two. Details and fix candidate (gated tuser, Option E) in `SINGLES_CAMPAIGN.md` 07:01.


## E9 — CORRECTION 2 (2026-08-28 10:35, hardware probe)

Injector v2 at the fabric→DMAC seam (no RF): continuous modem cadence, RXQ=0 and RXQ=1, −M16/−M32 → **zero loss** (70.5 k frames each). Real-DMAC sim agrees (0 % all modes). The comb is not the DMAC/host delivery of a well-formed stream; it depends on the modem's own output stream (word count / marker placement / content) or is already present at the decoder output. Decided next by the in-fabric `rx_seam_checker` (probe-2) on the air link. Option E refuted on silicon (masking tuser halts delivery).
