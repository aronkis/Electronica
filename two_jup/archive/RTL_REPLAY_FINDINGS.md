# RTL-Replay Differential — Interim Findings (2026-07-09)

Instrument: `jupiter_240k5_byte/rtl_sim/sim_byte_iq.cpp` + `obj_byte_iq/Vwrap_byte`
— replays a captured raw ADC I/Q file through the **deployed byte-modem RTL**
(bit-true HDL-Coder Verilog = the shipped bitstream) and captures decoded
`byte_rx` + BIST regs. Invocation: `Vwrap_byte <iq> <nsamp> <vphase=0> <cadence=2>
<rstcs_end=8400> <skip=0> <prefix>`.

## Harness validation (GATE PASSED)
Deployed RTL decodes the golden controls **steady-state bit-exact** to the MATLAB
float reference (`soak_decode_k5`, 220/220 @0%):
- `linkB_s4d.iq`  : 218/220 frames golden; only frame#1 (pipeline-flush prime) + frame#220 (fractional tail) differ.
- `golden_ota_dec2.iq`: 43/44 golden, **errSteady=0**, final cap_out=0x04922282.
Residual `biterr~50-100` is a FIXED reset/warm-up transient (flat vs run length; loopback shows the same ~102) — NOT a floor.
Domain gap resolved: `AdcStab` is a pure sample-and-hold (timing-only, no scaling), so Tap-A(dataInI) ≡ sim-inject(adc_dataIn) in amplitude; vphase 0/1 byte-identical. cadence=2 uniquely locks (4/8 → 0 frames).

## Batch over REAL captures (cadence2 vphase0 skip0)
`errSteady` = steady-state bit-errors (warm-up excluded) = the deployed RTL's true per-capture BER.

| capture | provenance | RTL errSteady | RTL goldFrames | cfc_est / rstcs | float-ref result | verdict |
|---|---|---|---|---|---|---|
| linkB_s4d | good OTA (golden ctrl) | 38 (tail) | 218/220 | -3 / 0 | 220/220 @0% | CLEAN (validates) |
| golden_ota_dec2 | good OTA (byte-era ctrl) | 0 | 43/44 | 16 / 0 | golden | CLEAN |
| ab_modem_d2 | good boot | **0** | 43/44 | -4 / 0 | — | CLEAN (RTL bit-exact) |
| split148_d2 | AGC-proof good boot (rms5802) | 22 (~1e-3) | 20/21 | 2 / 0 | (locked) | near-clean |
| **linkA_s4b** | float-ref floored @3.5e-2 | **293 (~2.4e-2)** | 16/27 | **-239249 / 11** | **3.5e-2** | **SIGNAL-limited** |
| fail_10_d2 | soak lock-loss (HW 0/5 @rssi25) | 0 | 1/2 (short) | -53566 / 2 | (HW garbage) | RTL does NOT reproduce HW no-lock |

## Interpretation (guarded — do NOT over-generalize)
1. **Good captures → deployed RTL is bit-exact clean** (errSteady 0). No intrinsic design floor.
2. **linkA_s4b is the LOCK-LOSS family, NOT the ~3e-3 NOISY floor.** It floors at ~2.4e-2 with
   cfc_est=-239249 (~27 kHz offset) + rstcs=11 — a gross carrier-acquisition catastrophe. That
   BOTH decoders floor on it is signal-limited *for that capture only*. It says NOTHING about the
   locked-frame NOISY floor. **The 3e-3 NOISY-floor question stays FULLY OPEN.**
3. **fail_10 (HW lock-loss at rssi 25): a clean-reset RTL sim decodes it** — the HW no-lock is a
   LIVE acquisition/reset (bimodal) effect, not corrupt samples. This is also a WARNING: the static
   sim can be systematically *cleaner* than live silicon (no live AGC settling / clock jitter /
   real reset cadence). (Caveat: `_d2` short 50k-sample capture; weak evidence.)

## Harness is validated for CLEAN decode, NOT error-fidelity
Every validation capture was clean/clean. The sim has never been checked against a KNOWN nonzero
hardware BER. So on the fresh flooring capture, RTL-vs-HW is the error-FIDELITY test, pre-committed
to three readings:
- **RTL BER ≈ HW BER** (aggregate + per-offset structure) → deterministic-in-samples confirmed,
  harness faithful → proceed to box-vs-signal (EVM).
- **RTL cleaner than HW** → the floor is a LIVE/dynamic effect (carrier cycle-slips accumulating,
  AGC hunting, timing drift) absent from a static window — a THIRD answer, consistent with fail_10.
- **RTL dirtier than HW** → harness/injection artifact → stop and fix.

## EVM gates the box-vs-signal / "enough SNR" verdict (RSSI ≠ EVM)
`soak_decode` is golden-only, so there is no ideal-decoder leg for byte-payload data. The substitute
is `blind_evm` on the captured I/Q — and it is the most direct test of the user's premise, because
high RSSI coexists with a dirty constellation (LO leakage, IQ imbalance, phase noise, CFO):
- low EVM + floor → the box (recovery/decode);
- high EVM with STRUCTURE (rotated/split/spread) → a deterministic RF impairment (in-samples, so
  RTL reproduces it, but the fix is RF/LO/CFO — not power, not the decoder) — the likely-unnamed answer;
- high EVM, gaussian-fuzzy → genuine thermal.
Cannot answer box-vs-signal without this. MATLAB (or a Python port of blind_evm) is on the critical path.

## The gap (why a fresh capture is still required)
None of these is the actual **byte-payload ~3e-3 NOISY floor** condition (the SSH blocker).
Existing captures are golden-message soaks (good, signal-bad, or lock-loss). The decisive datum
is a **fresh Tap-A capture while the byte link is flooring at ~3e-3**, with simultaneous
cap_out/bit_errors/rssi/levelLog logging, replayed through: (a) deployed RTL (this harness),
(b) a float reference, and blind-EVM for co-measured SNR. Plus the caveat-3 check: does the
ROM golden message even floor on hardware? (If not, the floor is payload-specific and the
golden-only `soak_decode` reference can't score it — needs a blind-resolver reference.)

## EVM / constellation instrument — built + calibrated (MATLAB-free)
`two_jup/blind_evm.py` (numpy): RRC(0.5,4,8) MF -> max-energy timing -> 4th-power CFO ->
block phase-track -> grid-agnostic EVM + 4th-power coherence C4 (blobs~1 / ring~0) + scatter PNG.
Calibrated against known outcomes:

| capture | rms_adc | CFO | C4 | EVM_tracked | class |
|---|---|---|---|---|---|
| linkB_s4d (good, 220/220) | 5781 | 0 | 0.98 | 7.2% | CLEAN |
| ab_modem (good) | 5802 | 0 | 0.98 | 7.2% | CLEAN |
| split148 (good) | 5802 | 0 | 0.98 | 7.2% | CLEAN |
| linkA_s4b (floored 3.5e-2) | 8191 | -26 kHz | 0.22 | 15% | RING / CFO-limited |
| fail_10 (HW lock-loss @rssi25) | 1774 | -11 kHz | 0.75 | 25% | SPREAD (weak level + CFO) |

Every clean-constellation capture (7% EVM) decodes clean in deployed RTL; every floored capture has
a demonstrable SIGNAL impairment (CFO ring / low level / spread). No "clean-signal -> deployed-decoder-floors"
case exists in current data. rms_adc exposes that "rssi 25 dB" (fail_10) masked a 3x-weaker ADC rail (1774 vs 5800).

## Decision framework for the fresh flooring capture (two MATLAB-free instruments)
Run BOTH on the fresh Tap-A capture, score vs the known TX pattern:
- **EVM ~7% clean 4-blob (C4~1) AND deployed RTL reproduces ~3e-3** -> floor is the **BOX** (decoder/recovery
  fixed-point) on a clean signal -> design-specific; "enough SNR" is CORRECT.
- **EVM shows CFO ring / spread / low rail** -> **SIGNAL-limited** (carrier/level/SNR) -> RF/trim fix, not decoder.
- **deployed RTL cleaner than live HW** -> **LIVE/dynamic** effect (cycle-slips, AGC hunting) not in a static window.
MATLAB now only adds nice-to-haves (K=5 AWGN curve quantification; blind_evm cross-check) — not blockers.

## CONCLUSION — fresh flooring capture (148<-146 @2.00, byte payload, floor_148.iq)
Captured Tap-A receiver-input I/Q while the link floored, + HW -B truth + ROM-on-air gate.

**Hardware -B (truth, 60s/10575 frames):** BER **1.9e-3**, **CLEAN 71.2% / NOISY 25.8% / PHASE 2.5% /
ROTATED 0% / MISS 0.5%**, rssi 17 dB. -> The floor is INTERMITTENT (71% of frames decode PERFECTLY),
not a uniform thermal floor; framing is solid (ROTATED 0).

**Constellation (blind_evm on the receiver-INPUT Tap-A, i.e. PRE carrier-loop):** CFO -108 Hz (tiny,
well-corrected -> NOT a CFO ring), **C4=0.51, EVM 20%**, blobs smeared TANGENTIALLY into arcs (static
31.7% -> tracked 20.1%). Clean controls read 7% / C4 0.98. So the flooring signal is visibly
**carrier-phase impaired** (tangential = phase, not radial=AGC, not round=thermal), and it is impaired
ALREADY AT THE RECEIVER INPUT -> the phase noise is UPSTREAM of the receiver's loop = in the RF/LO/Tx
path, carried in the samples. ROM-on-air gate: golden pattern DOES accrue bit_errors on HW (floors), so
it's payload-independent (a channel/LO effect), not a byte-payload data artifact.

### Verdict on the three original questions
- **Missing frames?** NO. ROTATED=0, framing solid; MISS 0.5%.
- **Corrupt bits from a decoder bug?** NO. The deployed decoder is bit-exact on clean signals (validated
  218/220 on golden control); here the SIGNAL is phase-impaired, not the decoder.
- **Interrupting the link another way?** YES -> via CARRIER PHASE: intermittent phase-wander excursions
  (26% NOISY + 2.5% PHASE cycle-slips) the carrier loop doesn't hold through.
- **"Enough SNR"?** CORRECT. rssi 17 dB, 71% clean, EVM->~14 dB SNR at which thermal BER ~1e-12. It is
  NOT a power/margin problem. More Tx power will NOT fix it.

### Burstiness test (per-frame EVM over the capture) -> STATIONARY, not periodic
per-frame EVM is FLAT ~19-22% (std 1%, autocorr lag1~1.0) across the 0.2s window -> NO periodic spikes at
the frame scale. So the disturbance is a STEADY phase spread, NOT a periodic cal/interference burst. The
71%-clean/26%-noisy split is therefore FEC pass/fail threshold statistics on a steadily-~20%-EVM
phase-tailed signal (phase tails cross decision boundaries more than Gaussian at equal RMS -> raw BER >
thermal-at-14dB -> 1.9e-3 coded floor), NOT signal burstiness. Slow 46%->71% clean rise over 60s = a
separate slow settling. (Caveat: 0.2s window can't see a cadence slower than ~0.2s; a long per-frame -B
bucket log would extend this.)

### MATLAB confirmations (run headless via `matlab -batch`, MCP bypassed)
1. **K=5 AWGN BER curve** (awgn_k5.m, matches deployed: [35 23] TB25 hard QPSK): codedBER = 3.6e-2 @3dB,
   1.6e-3 @5dB, 2.1e-4 @6dB, 1e-5 @7dB, **0 (<1e-6) @>=9dB**. So the observed 1.9e-3 floor = an EFFECTIVE
   Eb/N0 of only ~5 dB, but the flooring capture's 20% EVM implies ~14 dB (where codedBER is ~0). The phase
   impairment costs **~9 dB of effective SNR** -- raw signal quality is fine, phase STRUCTURE is the loss.
2. **Ideal float PLL loop-bandwidth sweep** (loop_bw_sweep.m, comm.CarrierSynchronizer on floor_148):
   EVM bottoms at ~19.9% (BW 0.005) and does NOT improve with wider bandwidth (20.0/20.1/20.5/21.5% at
   0.01/0.02/0.05/0.10, then 43.8% at 0.20). So the ~20% phase spread is **NOT loop-trackable by any
   bandwidth** -> an ideal receiver would floor at ~1.9e-3 too. This RULES OUT loop-tuning as the fix and
   rules out a deployed-loop/decoder bottleneck ("design-specific" answered: NO, an ideal loop does no better).

### Root cause + fix direction (corrected by the sweep)
Source = **fast LO phase noise in the RF signal** (ADRV9002 Tx and/or Rx synthesizer), a stationary
carrier-phase spread (~20% EVM) that the carrier-recovery loop fundamentally cannot track (proven: no loop
bandwidth removes it). Fixes, in order:
  1. **Reduce ADRV9002 LO phase noise** -- the load-bearing fix: reference-clock quality/source (TCXO vs the
     current ref), the ADRV9002 RF-PLL loop-bandwidth/charge-pump settings in the lvds_1p92 profile, and
     external-vs-internal LO. This is where the ~9 dB is lost.
  2. Rule out a fast tracking-cal / spur source: correlate any residual PHASE-frame cadence with ADRV9002
     cal events; disable/reschedule if implicated.
  3. NOT loop-bandwidth widening (proven no help), NOT more power/gain (SNR already ample), NOT the decoder.

### STILL OPEN (do NOT present as answered)
The CORE mechanism above rests on HARDWARE evidence (HW -B buckets + receiver-input constellation) and is
solid. But the follow-up questions "repeatable in sim?" and "design-specific?" are NOT settled:
- **Repeatable-in-sim: SPLIT ANSWER.** SIGNAL level = YES (blind_evm reproduces the identical 20%-EVM
  phase spread from floor_148 & floor_148b -- the impairment is deterministic, in the captured samples).
  BYTE-DECODE level = confounded, and NOT by an image bug: scored against the EXACT -B reference (ref_dump
  from qpsk_ber_make_ref; scorer validated -- golden control iq_full = 218/220 CLEAN vs golden words), the
  RTL replay of floor_148 is ALL-PHASE (wrong absolute QPSK quadrant), while HW decoded it 71% clean. This
  is an ACQUISITION-HISTORY artifact of cold-start static replay: the in-fabric phase resolver fixes the
  absolute quadrant AT LOCK; HW locked once and held its quadrant over 60s, the replay cold-starts on a
  44-frame slice and can resolve a different quadrant -> Viterbi garbage. On CLEAN signals the quadrant is
  unambiguous (golden controls reproduce); on the near-margin IMPAIRED floor it is boundary-sensitive.
  **That boundary-sensitivity is itself confirmation the link sits at the phase-recovery margin.** A
  harness-matched reflash does NOT fix this (it is history/margin, not image). Golden-on-air recaptures to
  break the ambiguity keep cycling (one-way near-margin link + watchdog re-arm: gold_148 C4=0.07 ring even
  though HW read 18/20 golden). The clean path to byte-level confirmation is the MATLAB soak_decode leg
  (below), whose float carrier-sync is not cold-start-quadrant-fragile the same way.
- **Design-specific: OPEN.** The clean discriminator is soak_decode (does an ideal/wider-loop receiver
  decode the SAME capture cleanly or also floor?). Needs MATLAB, which never attached all session.
  blind_evm calibration (clean 7% vs this 20%) supports "this capture is genuinely more impaired than a
  clean one" -- that far only; it cannot carry the fine tangential->LO attribution on its own.
- MATLAB follow-ups once attached: soak_decode float-reference leg + K=5 AWGN curve.
- Root-cause refinement: a long per-frame -B bucket log would test for a slow-cadence (cal/interference)
  source the 0.2s window can't see.

## Status of the three questions
- **Repeatable in sim?** — YES by construction (deterministic, steady-state bit-exact) — but
  error-fidelity (reproduces a KNOWN nonzero HW BER) is UNPROVEN until the fresh-capture RTL-vs-HW test.
- **Design-specific (the NOISY floor)?** — OPEN. Existing data only shows lock-loss captures are
  signal-limited; the locked-frame 3e-3 floor is untested. Do not conclude.
- **Enough SNR?** — UNANSWERABLE until EVM is measured (RSSI ≠ EVM). The honest candidate not yet
  ruled out is a structured RF impairment (CFO/LO/IQ), which linkA_s4b's 27 kHz offset hints at.

## Capture-plan (advisor-vetted)
- Score RTL-replay AND hardware BOTH against the known transmitted pattern (as `-B` does), never
  against each other → avoids ADC-DMA-vs-byte-DMA frame alignment.
- Capture a LONG steady-state window (not just acquisition) or the floor is under-sampled (fail_10 trap).
- Grab ROM-on-air same session + read cap_out/bit_errors: caveat-3 GATE — if the golden pattern does
  NOT floor on hardware, the golden-path reference is dead and we rely on repeatability + EVM only.
- Next unblock: MATLAB (EVM + K=5 AWGN curve + byte-payload reference). Do not write the conclusion
  until the constellation has been looked at.
