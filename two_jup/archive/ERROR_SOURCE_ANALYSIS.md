# Error-Source Analysis — same-place? / missing-frames? / sim-vs-hardware?

**Status: FIX DEPLOYED + ACCEPTANCE PASSED on live silicon (148).**
Date: 2026-07-09/10. Link: two-Jupiter K5 QPSK byte link, 240 ksym, K=5 [35 23] rate-1/2, 148←146 @2.00.

## DEPLOYED FIX + ACCEPTANCE (2026-07-10)

Built rxfix byte image (`CFOChangeDetectThreshold` 0.0015625→0.0125, deadband ±697→±5577 Hz;
BOOT.BIN 7203552 B md5 8d6b82ff597e), flashed board **148 (receiver)** with backup
(`/boot/BOOT.BIN.prerxfix`) + size-check; 146 kept on its old (Tx-capable) image.

**Acceptance (live poll on the rxfix RX, same flooring link):**
| metric | pre-fix good-lock | pre-fix thrashing | **post-fix (148 rxfix)** |
|---|---|---|---|
| `rstcs` (CFO-step reset) rate | 1–4/s | **52/s** (3101/60s) | **0/s** |
| BER | 2–3e-3 | 3.6e-2 | 2.98e-3 |
| frame yield | ~83% | **40%** | **93.5%** (11880/12708) |
| ROM-golden cap_out | golden | garbage | **0x04922282 golden** ✓ |

**`rstcs` collapsed to 0** → the CFO-step detector no longer false-fires → the reset storm (which is
*driven* by those resets) is **eliminated by construction** → the intermittent 3.6e-2 / 40%-yield
loss-of-lock regime is gone. Causal gate (rstcs, per review) PASSED on live silicon — the only venue
that was ever trustworthy for this sim-invisible failure.

**Honest caveat:** the good-lock **residual BER ~2–3e-3 is unchanged** — a *separate, milder*
SNR/phase-noise limit on the NOISY frames, not the reset storm; this fix does not target it. The
original SSH-blocker (intermittent loss-of-lock / 40% frame loss) is resolved; a residual floor remains.
**Remaining:** reflash 146 for the reverse direction (bidirectional).

---

---

## Headline (what changed)

The prior investigation concluded the ~1.9e-3 floor was **fast LO phase noise** that an ideal
receiver could not beat. **That specific conclusion is now disproven.** Its load-bearing step —
"the receiver-input constellation floors at ~20% EVM for all loop bandwidths, therefore the BER
floors" — conflated an **EVM floor** with a **BER floor**. It is not one:

- 20% EVM ≈ 11.5° RMS phase error ≈ ~1e-4 *uncoded* QPSK symbol error, which rate-1/2 K=5
  Viterbi crushes to ~0 over a 1024-bit frame (AWGN curve: coded BER ~0 at ≥9 dB; 20% EVM ≈ 14 dB).

**Direct proof (Phase 1a):** an ideal float receiver (`k5_240/decode_ref_k5.m` — RRC MF + Gardner
timing + 4th-power CFO + ideal carrier sync + float Viterbi, scored against the exact `-B`
reference) decodes the flooring capture **`floor_148.iq` to BER = 0, 43/43 CLEAN**, with the QPSK
quadrant resolving to **identity (rot=0, swap=0)** and a measured **residual payload EVM of 20.1%**
(matching the independent `blind_evm.py`). So the *same 20%-EVM samples* the hardware floored on
decode perfectly with an ideal receiver.

**Tool validated (negative control):** injecting calibrated AWGN into `floor_148` produces a clean
FEC waterfall — added-noise −2 dB → BER 1.79e-3, −4 dB → 8.9e-3, −6 dB → 6.8e-2 — with NOISY frames
appearing at graded BER. The scorer counts bit errors correctly; the 0-BER on the un-noised capture
is real, not a blind spot.

---

## What is PROVEN now

1. **The prior EVM→BER inference is invalid.** 20% EVM is FEC-recoverable; it is not a BER floor.
2. **An ideal receiver decodes this specific 20%-EVM flooring capture to 0 BER** (floor_148 and
   floor_148b, 43/43 CLEAN each). Reproducing the HW 1.9e-3 required *adding* ~2 dB of noise to the
   capture — i.e. the capture, as decoded ideally, is materially cleaner than the HW floor condition.
3. **The HW floor is real on-chip decode error, not host/DMA loss (Alt B ~ruled out).** With the far
   end sending the ROM golden message during flooring (`floor_romgate.txt`), the **on-chip**
   `bit_errors` counter (post-Viterbi, pre-DMA) climbs 0x C499B→C4C04 (+105 over ~1 s ≈ ~4e-3) while
   `cap_out` stays correct (0x04922282). The floor is **payload-independent** (golden floors too) and
   lives in the decode, not the byte-DMA/host path.
4. **No framing/word slip.** HW `-B` buckets: ROTATED = 0 across all 10575 frames; MISS = 0.5%.
5. **The deployed RTL is bit-exact clean on good captures** (harness sound): `sim_byte_iq` golden
   control = 218/220 CLEAN, BER 0 (linkB_s4d and gold_148, cadence=2, no decimation).

## What is NOT yet established (positive claim HELD)

**"The floor is a deployed-receiver implementation loss"** is a *different, stronger* claim than
"an ideal receiver decodes this capture cleanly," and `floor_148` alone cannot carry it:

- **Alt C — temporal / representativeness (OPEN):** `floor_148` is 43 frames (~0.2 s) captured
  *after* the `-B` BER window, on a separate pre-AGC DMA — **not sample-paired** with the 10575-frame
  1.9e-3. It may have caught a good stretch. (A 7–9 dB implementation loss would also be
  extraordinary — fixed-point/hard-decision costs ~1–3 dB, not 9 — so a loss that large is itself a
  flag that the capture may not represent the floor.)
- **The same-samples discriminator (IN PROGRESS):** the bit-exact deployed RTL on the *identical*
  `floor_148` file removes the temporal confound. First pass went 100% PHASE (cold-start absolute-
  quadrant mis-lock) — **inconclusive**, reproducing neither the HW 1.9e-3 nor the ideal 0. An
  input-side quadrant sweep (pre-rotate I/Q by 0/90/180/270° × I/Q-swap, feed each to the RTL, score
  best-of-8 vs the `-B` reference) is running to force the correct quadrant and reveal whether the
  deployed decode path floors or decodes clean on these exact frames.

---

## The three questions — current answers

### Q1 — Do the bit errors always occur in the same place?
- At the **sample/channel level: there are no errors to locate** — an ideal receiver gets 0 on the
  captured samples. The impairment present (20% EVM phase smear) does not, by itself, produce bit errors.
- At the **hardware level** the floor is real on-chip decode error (item 3), but the **HW per-offset
  map was not persisted** (`floor_148_ber.txt` grep dropped the data rows). **[PENDING Phase 2]**:
  a real HW per-offset map. Because `-B` transmits an identical frame every time, a uniform map ⇒
  random; sharp spikes ⇒ a deterministic decode/design stage.

### Q2 — Are we missing frames?
- **No framing/word slip** (ROTATED = 0) and **not a DMA/host loss** (on-chip decoder errors, item 3).
- **[PENDING Phase 2]** the three-number anchor — expected-frames (window ÷ frame period) vs
  Δ`packets_out`(0x104) vs `frames_scored` — to quantify any modem-lock-loss vs pure bit error. The
  existing `floor_regs.txt` has only a single (non-differenced) snapshot (`pkts=0x3114`,
  `frames_scored=10575`), so no delta is yet available.

### Q3 — Reproduce in simulation from captured data and compare to hardware?
- **Q3a (decode-independent floor?) — ANSWERED:** No. An ideal float receiver decodes the captured
  samples to 0 BER (item 2). The corruption is not irrecoverable channel/LO impairment.
- **Q3b (does the deployed design reproduce the HW byte errors on identical samples?) — IN PROGRESS:**
  golden control validates the harness (item 5); the floor replay is quadrant-confounded; the
  input-quadrant sweep is the pending discriminator.

---

## Artifacts
- `k5_240/decode_ref_k5.m` — ideal float receiver scored vs the `-B` reference (+ payload EVM, negative-control-validated).
- `k5_240/awgn_k5.m` — K=5 AWGN BER-vs-Eb/N0 anchor (3.6e-2@3dB, 1.6e-3@5dB, 2.1e-4@6dB, 1e-5@7dB, ~0@≥9dB).
- `two_jup/floorcap/floor_148_decref_k5.mat`, `floor_148b_decref_k5.mat` — per-frame/per-offset results (both 0 BER).
- `jupiter_240k5_byte/rtl_sim/score_rxw_ref.m` — offline `-B` scorer for RTL `_rxw.txt` (word-rotation + PHASE only).
- HW ground truth: `two_jup/floorcap/floor_148_ber.txt` (BER 1.9e-3, buckets), `floor_romgate.txt` (on-chip golden floor), `floor_regs.txt`.

## Localization — the error source is the CARRIER PHASE-RECOVERY LOOP

Stage ablation of the float receiver on floor_148 (turn each capability OFF, decode, score):

| config | BER | clean% | verdict |
|---|---|---|---|
| FULL (CFO+PLL+preamble) | 0 | 100% | ✓ |
| **PLL only** (no CFO, no per-frame preamble phase) | **0** | **100%** | ✓ PLL alone suffices |
| no PLL (CFO + per-frame preamble) | — | 0% (all PHASE) | **collapses** |
| per-frame-preamble only | 0.35 | 0% | collapses |
| CFO only / none | — | 0% | collapses |

**The continuous carrier PLL is necessary AND sufficient.** A per-frame *constant*-phase
preamble correction is NOT enough → the impairment is a phase trajectory that varies *within*
a frame and must be **tracked**, not reset per frame. This is the deployed receiver's carrier loop
(`Carrier_Synchronizer.v` = `Phase_Error_Detector` + `Loop_Filter` + `NCO`; separate
`Phase_Ambiguity_Corrector.v` does the quadrant).

**Loop-bandwidth is the likely knob.** Float PLL loop-BW sweep vs decoded BER on floor_148:

| Norm loop BW | clean% |
|---|---|
| 0.001 | **74.4%**  ← ≈ HW 71.2% |
| 0.002 | 97.7% |
| 0.005 – 0.10 | **100% / BER 0** (sweet spot) |
| ≥ 0.20 | 0% (too wide) |

BW 0.001 reproducing the HW 71% is a strong signal the **deployed loop is running too narrow**.
The deployed loop is a hand-built fixed-point PI PLL with baked-in gains (`Loop_Filter_block.v`
integral gain const = 98, En26); a subagent is reconstructing it in MATLAB to (a) compute its
effective BnTs, (b) confirm it reproduces the ~71% floor, (c) show that widening it to BnTs≈0.02
clears it — which would prove the fix.

**Corrected prior mistake:** the old loop-BW sweep saw residual EVM stay ~20% for all BW and
concluded "not loop-trackable." But 20% *tracked* EVM is the FEC-correctable regime; the loop's job
is to keep the constellation there, and an ideal loop (BW 0.005–0.1) does. EVM floor ≠ BER floor.

## COURSE CORRECTION (2026-07-09, later) — loop-BW hypothesis NOT established; fix target reopened

Extracting the DEPLOYED loop-filter gains from `Loop_Filter_block.v` refutes "too narrow":
- proportional Kp = 98·2⁻¹⁶ ≈ 1.50e-3 ; integral Ki = 2⁻¹⁶ ≈ 1.53e-5 ; Ki/Kp ≈ 0.0102
- ratio ⇒ designed damping ζ≈0.7 and BnTs≈0.0077 — **already in the 0.005–0.1 working range**,
  not the ~0.001 I hypothesized (and this trace still omits the detector·NCO gain that sets the
  actual closed-loop BW). **Bandwidth is not an established lever in either direction. No gain
  retune / no deploy until the floor is reproduced.**

Two structural problems with the offline localization:
1. **Float-stage ablation can't localize a fixed-point HW stage.** "PLL necessary in an otherwise
   *ideal* chain" doesn't say the HW's fixed-point *carrier loop* is the broken stage vs its timing /
   AGC / phase-ambiguity resolver / Viterbi — none of which the ablation touched.
2. **floor_148 is almost certainly a CLEAN BURST (unrepresentative).** HW steady state is ~80%
   instantaneously clean (t=45–55 s trace) ⇒ ~20% bad-frame rate; floor_148 is 43 frames with ZERO
   bad. If independent, P = 0.8⁴³ ≈ 7e-5. Either the errors are **bursty** and floor_148 landed in a
   clean run, OR the fixed-point path botches ~9 of these exact frames the ideal recovers — opposite
   implications, and floor_148 alone cannot separate them. The link **improving over 60 s** leans
   toward an **intermittent** mechanism (cycle-slip / loss-of-lock / phase-ambiguity re-lock), whose
   fix would be slip robustness, not a gain tweak.

## ROOT CAUSE (confirmed 3 ways) + PRE-EXISTING FIX that was reverted out

**Mechanism:** the `Coarse_Frequency_Compensator`'s **CFO step-change detector** resets the
carrier loop (`internalRst`) whenever the pre-carrier-loop coarse-CFO estimate's first-difference
exceeds ±3277 (En21 ≈ **697 Hz**, threshold const in `CFO_step_change_detector.v`). At the flooring
condition it false-fires → carrier loss-of-lock **reset storm** → floor.
Confirmed independently by: (1) **host-proxy** — ideal receiver decodes the representative HW-floored
window (esrc_148_long, HW 3.6e-2) to **0/220 CLEAN**, real CFO stable 26 Hz; (2) **HW register** —
`rstcs`(0x150)=`RstCsCounter(CFO-step-detector)` read **3,101** false firings/60 s while the real CFO
was 26 Hz; (3) **prior `jupiter_t8pn/RXFIX.txt`** — same "CFC-JUMP RESET-STORM", fix validated on real
captured air (BER **10.9%→0.87%**, resets **9→1**).

**The fix pre-exists and was deliberately reverted out of the byte kit.** `apply_rxfix.m` /
`CFC_JUMP_MGMT` raise `CFOChangeDetectThreshold` 0.0015625→**0.0125**; `commhdlQPSKTxRxParameters.m:45`
shows the byte kit **REVERTED it to stock** on the theory "at the 240-ksym design point stock is
validated." That theory is **empirically disproved** by this floor (240 ksym is even further below the
native 1.92-Msym design rate than the 480-ksym link the fix was made for).

**Sim-verification is impossible (known):** the failure is a **live bistable reset-storm** that is
"functional-sim-invisible" (RXFIX.txt) — my careful phase-noise RTL sweep confirmed it: at the faithful
20% EVM the static Tap-A replay's estimate jitter is only ~412 Hz (0.6× the 697 Hz threshold) → rstcs=0;
it needs ~28% EVM to fire. So the static replay under-produces the live jitter ~40% and can't enter the
storm. The trustworthy gate is therefore a **live measurement**, not a sim.

**Deploy plan (gated on the live check):** restore `CFOChangeDetectThreshold` (calibrated value — 0.0125
prior/480-ksym vs the subagent's byte-kit-calibrated ×2≈6554; live jitter picks it) + flip the 4 build
gates that enforce stock → `build_byte_image.sh` (~1.5 h) → reflash both boards (backup BOOT.BIN,
size-check) → re-measure `-B` BER + `rstcs`. **Live check (running):** rapid-poll `rstcs`/`cfc` to (a)
confirm live step-to-step jitter exceeds 697 Hz (resolving the sim gap), (b) confirm reset↔bad-frame
co-occurrence, (c) calibrate the threshold. Reflash blocks on this; the bedrock result (ideal 0/220 on
the representative floored window) already proves the deficiency is in the deployed receiver regardless.

## RESOLVED — fixed-point receiver deficiency, reproduced on a REPRESENTATIVE window

`capture_esrc.sh` caught the link in a thrashing regime and settled it decisively:
- **HW on esrc_148_long (220-frame representative window):** BER **3.6e-2**, CLEAN **1.8%**,
  NOISY 48%, PHASE 22%, MISS 28%; **Δpackets_out ≈ 5175 / ~12700 expected (~40% frame yield)**;
  **Δrstcs = 3101 carrier resets in 60 s (~50/s)**; `cfc` wandered −29k → +86k Hz. The BER trace was
  flat at 3.6e-2 — this window **never acquired lock**.
- **Ideal receiver on the SAME samples:** BER **0**, **220/220 CLEAN**, coarse CFO only **26 Hz**,
  payload EVM 20.3%.

⇒ The captured signal is perfectly trackable; the HW's ±100 kHz `cfc` wander and 3101 `rstcs` are the
**fixed-point loop THRASHING**, not the carrier moving. The deficiency is **definitively in the
deployed receiver**, reproduced on a representative window (not a 43-frame fluke). Mechanism =
**spurious carrier loss-of-lock / re-lock**: the ideal float PLL has no reset logic and holds through
20% EVM; the HW's lock-detect resets the loop ~50×/s → thrashing → 40% frame yield → floor. Explains
the bimodality (floor_148 acquired & held at 71% clean; esrc never did).

**Q2 (missing frames?) ANSWERED:** yes — ~60% of expected frames never emitted (loss-of-lock), plus
50% of scored frames MISS/PHASE. Not a host/DMA loss (ROTATED 0), not clean-with-bit-errors — it is
carrier lock loss. **Fix target = the carrier-sync reset / lock-detect logic (`RstCsCounter` / the
`internalRst` that resets `Carrier_Synchronizer`), not the loop-filter gains.**

## (superseded) decisive experiment — fixed-point vs ideal on lock-anchored, representative samples
- **Long acquisition-anchored HW capture** (`capture_esrc.sh ACQ=1`, running): a representative
  ~220-frame window both receivers can decode FROM acquisition, plus the frame-accounting triple,
  real per-offset map, and the per-frame error time-structure (bursty vs steady).
- **Acquisition-runway splice** (RTL subagent): prepend a clean lockable capture ahead of floor_148 so
  the fixed-point RTL loop+resolver warm up, then score only the floor_148 frames.
- **Read:** RTL/HW-representative botches ~20% where ideal gets 0 ⇒ fixed-point deficiency reproduced,
  localize next. Ideal *also* ~80% clean on the long capture ⇒ SNR/intermittent-limited, not an
  ideal-beats-fixed-point gap. Only THEN is a fix target defined.

## Next / open
1. RTL input-quadrant sweep on floor_148 (running) — deployed decode path: floors or clean on these frames? Also unblocks RTL verification of the fix.
2. Deployed-loop reconstruction (running) — confirm BnTs, reproduce the 71% floor, quantify the gain change.
3. Phase 2 (prepped, not run): long representative capture + frame-accounting + real per-offset map (settles Alt C).
4. Implement the loop-BW fix in the model → regenerate HDL → Verilator-verify clean on floor_148 → (bitstream rebuild + deploy = final HW step).
