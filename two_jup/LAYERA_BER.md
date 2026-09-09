# Layer A — in-fabric BER, isolated per spec 2026-08-18 (no Layer B in the loop)

Method (both variants): TX reference = Message_Generator ROM (0x158=0, bringup-sequenced
arm batches only); scoring = fabric counters ONLY (0x104 frames, 0x108 post-Viterbi
bit_errors_out from Capture_Data_Bits); host role = polling two AXI registers; delta
reads; positive control before every reference series (0x158=1 underrun garbage MUST
drive 0x108 high). BER denominator assumption: 12,224 decoded bits/frame (1528 B x 8)
-- the garbage control reads ~51 err/frame, far below a naive 50% of that, so the
comparator evidently scores a windowed region; absolute BER values below carry that
denominator caveat, and comparisons WITHIN this method are exact.

## Variant 1 — digital loopback (0x114=0): intrinsic DSP floor

Run 2026-08-18 ~12:1x, image 6846d3a4a265 (both injectors disabled), logs layerA_digital.log.

| probe | dwell | fps | d108 | err/s |
|---|---|---|---|---|
| CTRL garbage | 15 | 1245 | 952,578 | 63,505 (control PASS) |
| ROM arm1 min1 | 60 | 1244 | 218,534 | 3,642 |
| ROM arm1 min2 | 60 | 1244 | 3,382 | 56 |
| ROM arm2 min1 | 60 | 1244 | 218,534 (BIT-IDENTICAL) | 3,642 |
| ROM arm2 min2 | 60 | 1244 | 3,382 (BIT-IDENTICAL) | 56 |
| ROM long | 300 | 1244 | 818,440 | 2,728 avg |

- **Intrinsic steady-state floor: BER ~= 3.7e-6** (3,382 / 913 M bits per minute).
- **Deterministic arm transient**: first minute after EVERY arm = exactly 218,534 errors
  (repeatable to the bit across independent arms).
- **NOT stable over 5 min**: long dwell accumulated 818,440 (avg 2,728/s vs 56/s steady)
  with framesync at full rate throughout — recurring bit-error bursts in the pure DSP
  domain, no byte plane / DMA / host anywhere. The class-B burst family therefore
  originates INSIDE Layer A. Bit-exact repeatability suggests the bursts are
  deterministic -> sim-tractable and ILA-triggerable.

## Variant 2 — analogue loopback, single Jupiter, radiated antenna coupling (0x114=1)

Run 2026-08-18 ~12:3x, TX1_LO=RX1_LO=1900020000, logs layerA_analog.log.
*** UNCALIBRATED PATH: antenna-to-antenna coupling on the same board (operator-
authorized substitute for the attenuated cable). Coupling magnitude/ripple/multipath
unknown; ~10 cm of real radiated propagation exists (strict spec deviation); BER here
is "RF chain in-loop at an UNCONTROLLED SNR", not a calibrated waterfall point. ***

- **Locked at the FIRST ladder rung, -30 dB TX attenuation** (no stepping needed).
  RSSI stable across all arms: 37.0-37.2 dB (garbage control: 45.8 dB); AGC gain
  reading 34.0 dB throughout. Path characterized: comfortable, stable level.
- Control PASS: 50,926 err/s on garbage (fps 862).
- Reference dwells are **BIMODAL / NON-STATIONARY**:
  | probe | fps | err/s | note |
  |---|---|---|---|
  | lock probe 15s | 1244 | 74 | healthy |
  | arm1 min1 | 434 | 24,567 | degraded mode (~1/3 frame rate, BER ~4.6e-3) |
  | arm1 min2 | 424 | 25,050 | stays degraded |
  | arm2 min1 | 1243 | 3,668 | healthy arm -- profile matches the digital arm transient |
  | arm2 long 120s | 558 avg | 27,704 | degrades mid-dwell |
- **No stable steady-state RF floor was reached**: arms converge either healthy or into
  a ~430-560 f/s degraded mode, and a healthy arm degraded within 2 minutes, at CONSTANT
  RSSI (37 dB) -- the instability is modem convergence on the RF path, not the radiated
  level. The degraded-rate family (~430-590 fps) matches the "imperfect bring-up
  cadence" mode seen elsewhere this week; it is now reproduced with in-fabric scoring
  and zero Layer B involvement.

## Three-number status (no blending)
- A-digital: floor 3.7e-6, deterministic transients, burst-unstable over minutes.
- A-analogue: lock at -30 dB / RSSI ~37 dB, non-stationary, no clean floor yet (needs
  repeats and possibly the cabled path to separate convergence modes from environment).
- B (fabric->processor, zero RF): TLAST defect found+fixed; fix build in flight;
  zero-loss number pending fix flash.

## Burst periodicity resolved — the 120-second beat (2026-08-18 12:44, 1 s-resolution poll)

600 s poll at 1 s deltas, digital loopback, ROM reference, daemon+watchdog dead
(two_jup/layerA_burst_poll.sh; CSV two_jup/r3cap/burstpoll_20260818_124443.csv):
- Bursts at t=88, 209, 327, 448, 567 -> **start-to-start 121/118/121/119 s
  (period ~119.75 s)**, durations 5-8 s, quiet floor 60.6 err/s, fsync full rate
  (1256 f/s) throughout.
- Burst sizes QUANTIZED into two alternating species: ~293.2k and ~215.0k errors
  (A-B-A-B-A), species A bit-identical twice (293,183). Deterministic content.
- Retro-explains: yesterday's 300 s dwell (818,440) = 3 bursts + floor; 60 s windows
  catch a burst with ~50% probability = the "bimodal" run-to-run loss variance
  (6/10 overnight); the 3-4 x 1 s outages at 1.85 s beat are intra-burst fine
  structure. **Class-B is a strictly periodic ~120 s process, not episodic.**
- Prime suspect: ADRV9001 periodic tracking-cal cycle perturbing the SSI-derived
  fabric clock (signal path is digital-only here; clock path is not).
- Operational: (a) time Layer A dwells between bursts or in exact 120 s multiples;
  (b) the ILA trigger is now SCHEDULABLE (arm at ~t+115 s after any burst).

## 146 replication + attribution shift (2026-08-18 13:16)

146 poll (different board, different image build 433fd8dab393, different ADRV9001):
bursts t=87/208/327/447/566 -- SAME 119.75 s period, SAME phase vs arm (+/-1 s of
148's), SAME alternating quantized sizes (293,280/215,030/293,183/215,030/293,183;
values cross-match 148's exact set), same 60.7 err/s floor. CSV
two_jup/r3cap/burstpoll_20260818_131600.csv.

ATTRIBUTION SHIFT: phase-lock to the arm on both boards kills the free-running
transceiver-cal-scheduler hypothesis (arbitrary phase expected). CORRECTION to the
static-scan claim: the width scan only rules out a SINGLE >=34-bit time base; two
small incommensurate frame-scale counters produce a BEAT of arbitrary length --
and the netlist has such a pair (Data_Bits_FIFO 12332 vs End_Generator 12319,
delta 13), the RTL sim independently sees a periodic double-syncPulse in every leg,
and silicon fsync runs ~1256-1257 f/s vs structural 1245 (~11 extra syncs/s).
Working model: deterministic reset-seeded counter-aliasing in the DSP/framing chain;
two alternating burst species = two alignment-crossing events per super-period.
Next: (a) sim agent to characterize the double-syncPulse beat arithmetic (period in
frames, driving counters) and test against 119.75 s; (b) optional cal-toggle run as
cheap falsifier of any residual transceiver role.

## Cal-toggle falsifier (2026-08-18 13:5x) — transceiver cals EXONERATED

All three RX tracking cals disabled via sysfs (agc/bbdc/fic 1->0, verified), 600 s poll
rerun on 148: beat UNCHANGED bit-for-bit (t=88/208/327/448/567, 119.75 s period, same
alternating species 293,183/215,030/293,280/215,131/293,183, floor 60.5 err/s,
fsync 1256.4). Cals re-enabled + verified after. Log burstpoll_notrack.log.
With 146 replication + arm phase-lock + no wide fabric time base + cal-off invariance,
the ONLY standing hypothesis is deterministic counter aliasing in the DSP/framing
chain. Sim (beat arithmetic) + Simulink (1.5-period dwell) both tasked on it.

## BD-level IP width scan (2026-08-18 15:0x) — entire PL lacks a 120 s time base

Instantiated BD IPs (axi_adrv9001, axi_dmac, axi_sysid, cpack/upack, breakouts, gpio)
scanned like the DUT: NO >=34-bit non-address incrementing registers. Combined with the
DUT scan and the RTL study's negative counter-pair search, NO single counter anywhere
in the PL can time 119.75 s. Phase evidence (first burst at poll-t=87-88 in all four
runs, three independent arms, two boards) pins the beat phase to the DUT arm/reset,
i.e. bursts occur at fixed FRAME NUMBERS since reset (first ~frame 190,500, then every
~149,100). Remaining candidate mechanisms: cross-IP/cross-domain period beating (DUT
frame cadence vs SSI/pack word phase), or chip-side behavior that is somehow re-phased
by the arm's axi_adrv9001 register pokes (0x418/0x458/0x044). The Simulink prefix
(pure DSP, ideal clocks) becomes a sharper discriminator: any burst structure it shows
is model-internal; a fully quiet prefix strengthens the cross-domain reading.

## Simulink 12h prefix result (2026-08-19 01:51) + beat-origin synthesis

3,106 frames (0.02x beat period), rapid accel, ~11h wall (SIMULINK_BEAT.md has method):
quiet floor 0.0000 err/frame (silicon ~0.05); sync 0.9987/frame (silicon 1.0088 — NO
fsync excess in the model); no burst structure at the 1,895/3,081-frame candidates;
Data_Bits_FIFO fill drift present (65k overflow-viol beats) but harmless — corroborates
the RTL study's moire re-classification. VERDICT: PREFIX-INCONCLUSIVE for the 149,100-
frame beat by coverage, but every silicon signature is ABSENT in the idealized-clock
model.

SYNTHESIS: silicon-only phenomenon (both boards, cal-off invariant, arm phase-locked)
+ absent in BOTH idealized-clock environments (netlist RTL sim, Simulink model) + no
PL time base => the beat lives in what the sims idealize away: the REAL SSI-derived
clock chain. The arm's axi_adrv9001 SSI-config pokes (0x418/0x458/0x044) plausibly
re-phase an SSI/clocking process without resetting the chip — consistent with arm
phase-lock. Next instruments: ILA on the clock/SSI domain (schedulable trigger at
t+115s), or SSI/clock-counter telemetry across a burst.

## Fine-structure poll (0.1 s, 2026-08-19 03:3x) — DEGRADED-MODE data only

Ran on a post-reboot unprovisioned link that landed in the degraded cadence
(fsync ~341 f/s, not 1245 — no full bring-up available with 146 down). In THIS mode
the burst process transforms: period ~6.7 s, duration ~3.7 s, sizes 68-76k errs,
floor 17 err/s (CSV burstpoll_20260819_032632.csv). The canonical 119.75 s beat's
intra-burst anatomy remains UNMEASURED — needs canonical 1245 f/s state = full
bring-up = blocked on 146 power cycle. The mode-dependence of the beat (119.75 s at
1245 f/s vs ~6.7 s at 341 f/s) is itself a strong clue: the beat period scales with
link/clock state, consistent with the SSI-clock-chain origin hypothesis.

## 2026-08-19 — SSI NEAR-END LOOPBACK: beat PRESENT, species bit-identical

Path: fabric ROM (0x158=0) -> modulator -> TX SSI lanes -> ADRV9002 SSI block
(rx0/rx1_near_end_loopback=1, iio:device2 debugfs) -> RX SSI lanes -> demod ->
in-fabric comparator. RF fully excluded. Script: layerA_ssi_nel.sh; log ssinel_run1.log;
CSV r3cap/ssinel_burstpoll_20260819_090342.csv.

Rails: lock gate PASS (1245 f/s, 51 err/s incl. transient tail); positive control PASS
(0x158=1 garbage -> 63,505 err/s — proves RX content tracks 148's OWN TX source, i.e.
the loopback is real, not 146's air signal). Caveat: the debugfs attrs read back empty
on cat (write took effect per the control evidence; readback quirk noted).

600 s / 1 s poll: five bursts, start-to-start 120/119/121/119 s (= the canonical
119.75 s beat), sizes alternating 293,183 / 215,030 / 293,280 / 215,131 / 293,183 —
THE SAME TWO SPECIES, BIT-FOR-BIT SIZES, as the FPGA-internal digital loopback
(~293.2k / ~215.0k) and as 146. Quiet floor 62 err/s (vs ~56 on internal loopback).

Interpretation: the beat is invariant to whether the sample path traverses the SSI
lanes or stays inside the fabric — both paths share the SSI-derived clock, and the
identical burst species mean the error injection is deterministic in that common
clocked domain. This kills "SSI lane data integrity" (a physical-lane effect would not
reproduce byte-identical burst sizes across paths) and further concentrates the SSI
CLOCK CHAIN / a ~119.75 s periodic event in the clock-common domain as the mechanism.
Next discriminators unchanged: schedulable ILA at t+115 s, SSI/PLL telemetry.

## 2026-08-19 — A-analogue v2 (quiet-zone dwells): NO LOCK, ladder exhausted

layerA_analog_v2.sh: same rails as v1 plus dwells timed into NEL-pinned quiet zones.
Result: no framesync lock at -30/-24/-18 dB TX atten (best: fps=514 half-lock at -18,
RSSI 25.8 dB, AGC gain 34 dB). v1 (2026-08-18) HAD locked at -30 dB (RSSI ~37 dB) —
today's radiated path is ~11 dB weaker at the same settings. Antennas/bench unchanged
per operator; suspect bench geometry / polarization drift or AGC state difference.
Consistent with the banked "bimodal, no stable floor" character of the radiated path.
The quiet-zone dwell method is validated in principle (timing math held) but the
analogue floor remains UNMEASURED. Next options: retry after physical antenna check,
or bank A-analogue as blocked-on-path-stability. Log: layerA_an2_run1.log.

## 2026-08-19 — Axis B (SPI coincidence): CHIP/DRIVER-SIDE REFUTED + phase surprise

layerA_spitrace.sh, digital loopback, 200 s kernel SPI event trace (tracefs) with
uptime-stamped 1 s comparator poll. Capture: r3cap/spitrace_20260819_093722.
- Bursts observed at uptime 22870.73 (size 215,030) and 22990.30 (size 293,183) —
  species sizes byte-exact yet again; measured interval 119.57 s.
- SPI to the ADRV9002 (spi0.0): EXACTLY 2 transfer events/s everywhere — a 1.06 s
  background poller (per-second iio_attr processes reading regs 0x1A2/0x1A3; parent
  loop unidentified, only iiod persistent; NOT burst-correlated). Zero additional
  traffic inside either burst window. NO command, cal, or reconfig reaches the chip at
  burst onset -> driver/software-side event REFUTED; chip-side only survives as an
  SPI-silent autonomous internal event.
- SURPRISE: first burst at arm+34.75 s (ARM_UPTIME 22835.98), vs arm+153 s in the NEL
  run — contradicts the arm-phase-locked claim. Free-running-from-boot hypothesis now
  testable: predicted burst grid 22990.30 + n*119.57 (23109.9, 23229.4, 23349.0, ...).
  A fresh-arm 260 s uptime-stamped poll is running to check grid alignment.

## 2026-08-19 — Grid test: FREE-RUN REFUTED, arm-phase-lock CONFIRMED at +34.75 s exactly

Fresh arm at uptime 23316.67: bursts at 23351.42 (+34.75 s) and 23471.0 (+154.3 s).
Prior run: arm 22835.98, burst 22870.73 (+34.75 s). Offset identical to 10 ms across
independent arms; free-run grid prediction (23349.0/23468.6) missed by 2.4 s -> refuted.
Reconciliation: the NEL run's "first burst at +153 s" was the SECOND occurrence; the
+34.75 s burst was hidden inside the 65 s arm-transient skip. Canonical law:
  burst_n starts at arm + 34.75 s + n*119.75 s   (n = 0,1,2,...)
This 10 ms-grade determinism from the 0x110 arm pulse is itself a mechanism clue
(what deterministic process takes exactly 34.75 s from arm?) and makes SCHEDULED
ILA capture trivial: mid-burst capture guaranteed by soft-force at arm+35..41 s;
true onset capture still needs the hardware error trigger (DUT overlay, build 2).

## 2026-08-19 — Beat-ILA build 1 rail-gate adjudication: PARITY_MISMATCH = replication churn, BENIGN

Image 4a98855d7421 (BD-only ILA/XVC overlay). tc_cells 98 vs lean 100. Cell-level diff:
every differing cell is LUT2 INIT=4'h8 (the rail AND-gating replicas): 89 -> 87, all
other INIT classes byte-identical (1'b0/1'b1/2'h1/4'h2 counts unchanged). Name churn
(dinReg_0_re[2] vs [16] etc.) is merge-target renaming of the same function. Zero
const-folded rails (no POWER/GROUND) in either build; main enb_1_2_0 rail GLOBAL_CLOCK
FO 60790 vs 60789. DUT sequential census -7 FFs (78,675 vs 78,682) — fanout-replica
reduction under 100.00% CLB pressure. BUFG 19 -> 23: +4 from the debug hub, expected.
VERDICT: physical-optimization replication differences, NOT the witness-forensic class
(rail logic re-hosted into foreign decoders). Acceptable for an OBSERVATION image;
caveat carried: this DUT is not placement-identical to the proven 9259cf lineage, so
beat measurements from it are instrument-grade, not certification-grade.

## 2026-08-19 — XVC enumeration failure ROOT-CAUSED: soft TAP captures IR contents (JTAG-illegal)

Chain of evidence (all register-level, on the flashed 4a98855d7421 image):
1. Virtual TAP is otherwise fully compliant: IDCODE 0x0A003093 (present in hw_server's
   device table as "debug_bridge", IR len 6), BYPASS = clean 1-bit delay, post-TLR IR
   capture = 0b001001 (legal xxxx01).
2. The raw axi_jtag engine timing is JTAG-correct (the earlier "stale bit" was the
   legitimate undefined Capture-state TDO; both daemon fixup attempts CORRUPTED correct
   streams and are reverted/disabled).
3. Offline JTAG-simulator decode of the full failing hw_server trace (41k words):
   first divergence = Capture-IR on RE-ENTRY without TLR.
4. Directed test: IR capture returns the CURRENT IR REGISTER CONTENTS, not xxxx01:
   post-TLR capture=0x09; after loading 0x15, next capture=0x15; after loading 0x3F
   (BYPASS), next capture=0x3F. hw_server's IR sanity scan (post-BYPASS) sees capture
   =111111, bit1!=0 -> chain declared invalid -> "No devices detected".
FIX READY (not yet applied, per two-round stop order): daemon-side capture spoof —
the TAP tracker knows Capture-IR->Shift-IR entries; substitute the first 6 TDO bits of
each IR entry with the legal 0b001001. Purely cosmetic to the client; DR data untouched.

## 2026-08-19 — FIRST DIRECT ILA WAVEFORMS of the burst window (beat-ILA image, XVC)

XVC path fully operational after daemon hardening (IR-capture spoof + single-client
SO_RCVTIMEO 5s + single vivado session). Two captures, image 4a98855d7421, on the
canonical 1245 f/s link, digital loopback (0x114=0), iq_debug_mux=1 (post-symbol-sync):
- run1_raw: 4096 samples @ 30.72 MHz = 133 us straddling burst-1 onset (soft-force at
  arm+34.90s; beat law arm+34.75+n*119.75). Trigger at sample 3073 (75% pre).
- run2_qualified: valid-qualified, 133 us effective, at burst-2 (arm+154.65s).
Probes: rx input IQ (8/9), post-symbol-sync loop tap (10/11), raw SSI/ADC IQ (12/13),
byte plane (2-6), valids (7/14/15), burst_det status (1).

FINDINGS (both windows):
- SSI/ADC valid cadence (probe14) is PERFECT: exact 50% toggle, 4096 transitions,
  max zero-run = 1 sample. NO clock/valid dropout at burst onset -> the "SSI clock
  stops/slips" flavor of the hypothesis is NOT what a 133us onset window shows.
- Raw SSI ADC samples: no frozen region (max identical-run = 1), RMS flat across the
  trigger (pre 2153 vs post 2149) -- the input sample stream is undisturbed at onset.
- Post-symbol-sync loop tap RMS flat (11604 both sides) -- loop not visibly kicked in
  this window.
- burst_det window count = 0 (err_cnt tied 0 in build 1, BEATILA_ERRSRC NONE): the
  trigger was pure scheduled soft-force, as designed. No hardware error strobe yet.
CAVEAT: a 133us window is ~0.002% of the ~6s burst; at ~49k err/s that is ~6 error
events, invisible in gross IQ/valid stats. This CONFIRMS THE INSTRUMENT (path, probes,
scheduled capture all work) and rules out a gross onset-instant SSI clock/valid dropout,
but does NOT yet localize the per-error mechanism. That needs BUILD 2: the DUT overlay
exposing dut_bit_err_out so burst_onset_det triggers on a REAL error and the ILA centers
on the actual corrupted sample (not a time-scheduled slice). Deeper capture (16384) and
a slow capture-qualified run across a whole burst are the other levers.

## 2026-08-19 — Constellation verdict: RECEIVED DATA CLEAN, fault is in the RX PROCESSOR

Post-symbol-sync tap (iq_debug_mux=1, probes 10/11) in both burst-window captures:
4 tight QPSK clusters at (+-11600,+-11600), spread/amp 0.007 (run1) / 0.009-0.011 (run2)
= effective SNR ~40+ dB. ZERO of 4096 symbols deviate >0.5*amp in either window;
worst single symbol 3-6% off ideal. Yet post-Viterbi comparator = ~49k err/s in exactly
these windows. => symbols entering the FEC are correct while decoded bits are wrong:
corruption injected AFTER symbol decisions, in the RX processor (FEC deinterleave/Viterbi,
byte assembly, or comparator framing/reference). Consistent with NEL (RF-excluded),
replay-clean, corruption-inside-DUT. Caveat: a framing/sequencing glitch mis-indexing the
deinterleaver would still show clean symbols (as seen) -> that is itself a processor fault.
BUILD 2 (dut_bit_err_out hardware trigger) will center the ILA on a real error to confirm
the feeding symbol is clean and name the exact stage.

## 2026-08-19 — Build 2 DUT-port approach BLOCKED by closed interface catalog

run_beatila2_build.sh (External-Port fix) FAILED at hdlworkflow: 'External Port' is NOT a
valid IOInterface on this ADI reference target. Valid OUT choices are a FIXED catalog:
AXI4-Lite; IP Data Valid OUT; IP Data 0..3 OUT [0:15]; IP Load Tx Data OUT; ADRV9002 DAC
Data I/Q; Byte Ready/Data[0:63]/Valid/Last/User OUT. There is NO generic external port and
NO free 32-bit OUT slot (the four 16-bit IP Data OUT slots are consumed by debugI1/Q1 =
IP Data 0/1 OUT and debugI/Q = IP Data 2/3 OUT, the iq_debug taps). So a new 32-bit DUT
output port CANNOT be surfaced to the IP boundary on this platform. DUT-port path is dead.
Edits reverted (overlay + hdlworkflow); beatila_errport_overlay.m left on disk unused.
VIABLE ALTERNATIVE (no DUT port): mark_debug the internal bit_errors_out net + add it as an
ILA probe; trigger the ILA on its LSB transition under a SCHEDULED ARM at t+34.5s -> first
real error in the armed window = burst onset. Achieves the build-2 goal (center ILA on a
real error) via ILA-side trigger instead of burst_onset_det. Needs a synth rebuild (~3h),
no model/port change. Awaiting go before burning another build.
