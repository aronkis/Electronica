# EVM BUDGET — forward weak-link (Task C2)

Measured EVM decomposition for the two-Jupiter 240 ksym/s QPSK link, forward
direction (146 TX @2.00 GHz → **148 RX**, the weak-link unit). Answers: *what
sets the ~20 % RMS EVM, and is any of it recoverable in fabric / loop tuning?*

Companion to [LINK_CHARACTERIZATION.md](LINK_CHARACTERIZATION.md) (BER / bucket
mix — owned by another workstream; not edited here) and
[DEBUGGING.md](DEBUGGING.md) (the BBDC-tick symptom row). Instruments:
`evm/evm_from_tap.m` (on-chip debug tap, `0x10C` mux) and `evm/evm_ideal_ref.m`
(ideal float chain), shared metric core `evm/evm_metrics.m`. Method self-test:
`evm/evm_selftest.m` → PASS (AWGN+phase-noise theory within 5 %, all 4 quadrants).

Image `md5=dcf5c5fb29e6509723b35f476a0a1bfa` (lean/rxfix). All forward captures:
`rstcs` (`0x150`) = `0x1` stable, zero delta pre/post — no CFO-step reset touched
any window incl. the tick window.

## Capture inventory (evidence IDs; binaries untracked in `two_jup/evmcap/`)

| ID | dir | tap board | modes | N (complex) | role |
|---|---|---|---|---|---|
| **fwd1** | fwd | 148 | 0,1,2,3 + raw | 4.0 M (~2.1 s) | forward budget (spans ≥1 BBDC tick) |
| **rev1** | rev | 146 | 0,1,2,3 + raw | 2.0 M | reverse ref + gate run 1 |
| **rev_gate2 / rev_gate3** | rev | 146 | 3 + raw | 2.0 M | gate runs 2, 3 |

## Repeatability gate (prerequisite — PASS)

3× back-to-back **reverse mode-3** captures (reverse is tick-free, so σ isolates
true instrument+HW repeatability; **mode 2 was unusable** — see caveats).

| run | RMS EVM % | final sym-rate | nFrames |
|---|---|---|---|
| rev1 | 19.987 | 240 000 | 269 |
| rev_gate2 | 20.171 | 240 000 | 265 |
| rev_gate3 | 20.128 | 240 000 | 272 |

mean **20.095 %**, **σ = 0.097 %** (« 1 % gate), sym-rate identical across runs.
Comparisons below are trustworthy to ≈0.1 % absolute.

## The budget (forward)

Terms combine in **quadrature**. Anchored on **HW mode-3** (the constellation
tap — what actually ships); cross-checked against the ideal float chain. Only
`floor ⊕ tick` carries EVM power; every other mechanism measured **negligible**,
listed with its evidence rather than as a table line a reader would sum.

| Contributor | Forward EVM (quadrature) | Evidence | Verdict |
|---|---|---|---|
| **RF / SNR additive floor** | **≈ 19.96 %** | fwd1 mode-3 excised; = mag 14.1 % ⊕ phase 14.1 % | **DOMINANT (~99 % of EVM power)** |
| **BBDC tick** (forward-only) | 1.8 – 5.2 % | fwd1 mode-3 all−excised (3 fr) / ideal all−excised (5 fr) | 2nd; episodic, low-confidence magnitude (n≈1 episode / 2 s) |
| Carrier-loop BW | ~0 on-air | step c: HW mode-3 already at plateau | negligible (see rec.) |
| Symbol-timing jitter | ~0 (< σ) | step a: full-HW mode-3 ≈ ideal | negligible |
| AGC + En14 quant | ~0 (< σ) | step e: mode-0 19.87 vs raw 20.34 | negligible |

**Reconciliation (HW mode-3, forward):**
`total 20.05 % = floor 19.96 % ⊕ tick 1.82 %` ✔
**Cross-check (ideal float chain):**
`total 20.32 % = floor 19.65 % ⊕ tick 5.20 %` ✔

### Dominant contributor: the RF / SNR additive noise floor
- fwd1 mode-3 magnitude-EVM **14.1 %** ⊕ phase-EVM **14.1 %** = 19.94 % — **equal
  mag/phase terms are the exact additive-AWGN signature** (Es/N0 ≈ 14 dB).
- **LO phase noise specifically ruled out:** phase-error PSD log-log slope
  **−0.10** (white), not −2 (1/f²); and the loop-BW sweep floors regardless of
  BW rather than continuing to fall (steps b, below).
- **Fabric ruled out:** HW mode-3 (20.09 %) ≈ ideal float chain (20.34 %) — the
  fixed-point carrier/timing recovery adds nothing measurable over ideal float.

### Punchline — EVM vs the BER asymmetry
Forward floor (excised **19.96 %**) ≈ reverse (**20.0 %**): **bulk EVM is
identical both directions.** The forward weak-link BER (~1.4e-4 vs reverse
~2e-6) is therefore **not** a higher noise floor — it is the **forward-only BBDC
tick** (device-side, unit 148, ~1.5 s), consistent with DEBUGGING.md and
ESCALATION_ADI.md. The floor is a link-budget/RF-front-end property, not fabric.

## Diagnosis detail (steps a–f)

- **a — fabric vs RF.** FWD hw_m3 20.09 ≈ ideal_raw 20.34; REV hw_m3 19.99 ≈
  ideal_raw 20.06. Fabric contributes ~0 both directions.
- **b — loop-BW sweep** (fwd raw, `evm_ideal_ref` loopbw 0.001→0.05, log-spaced):
  RMS 46.7 %→plateau ~20.0 % for BW ≳ 0.006; **mag-EVM flat at 14.12 %** (loop
  cannot touch amplitude); phase-PSD slope **−0.10** (white). Knee ≈ **0.008–0.012**.
  The "optimum" 0.0324→19.85 is a 0.19 % dip inside single-capture tick-noise —
  not a trustworthy argmin (float@0.05 climbs back to 20.10).
- **c — loop-BW mismatch.** Ideal@shipped-0.005 = 20.34; HW mode-3 = 20.09
  (**below** the forced-0.005 float point, at the plateau). Hardware pays **no**
  loop-BW penalty.
- **d — timing.** Direct mode-1 probe (HW timing + ideal carrier, coarse CFO
  removed): 23.07 % → 10.9 % quadrature. **Not trusted / not budgeted** — a
  confounded *upper bound*: mode-1's tap holds at ~2×Rsym (documented ambiguity,
  `evm_config_240k.m`), and the excess is **phase-only (mag unchanged at 14.0)**,
  i.e. phase-scatter from the duplicate-collapse, not ISI. The reliable bound is
  step a: mode-3 *includes* HW timing yet equals ideal, so timing ≤ fabric ≈ 0.
- **e — AGC + En14 quant.** Mode-0 (AGC-out, En14 tap) 19.87 vs raw rx-lpc 20.34,
  same float chain → delta imaginary (< σ). Negligible.
- **f — tick excision.** fwd1 ideal: all 20.32 / excised 19.65 (5 flagged) →
  5.20 %; mode-3: all 20.05 / excised 19.96 (3 flagged) → 1.82 %. n≈1 episode in
  the ~2 s window ⇒ magnitude low-confidence, but the *presence* and
  forward-only-ness are robust and match the known 148 BBDC tick.

## Recommendation → feeds C4 (0x170–0x184 on-air loop-BW sweep)

**Do not bank a fixed EVM gain from loop-BW tuning.** The float sweep's apparent
~0.5 % headroom at 0.005 is an artifact of forcing that BW on the float chain;
the **hardware already operates at the plateau** (step c), so expected on-air
improvement is **≤ ~0.3 %, plausibly ~0**. C4 should sweep the new registers
across **~0.004–0.015** (bracketing the 0.008–0.012 knee) and **verify EVM/BER
empirically** rather than assume a gain. **The real lever is the RF/SNR floor**
(front-end gain/NF, antenna/cabling, quiet-pair frequency per PORTING.md) — and,
for forward BER specifically, the device-side BBDC tick (ESCALATION_ADI.md), not
anything tunable in fabric or the carrier loop.

## Caveats
- **Mode 2 (post-carrier-sync tap) is unusable** here: frame-sync failed
  (nFrames=0, 100 % EVM). Its duplicate-collapse under-decimates to ~2×Rsym with
  noisy hold boundaries (run-length σ≈3.0) — the documented mode-1/2 hold-factor
  ambiguity (`evm_config_240k.m`). **Mode 3** (1 sample/symbol, high confidence)
  is the trustworthy hardware EVM tap and is what the budget uses.
- Tick magnitude rests on ~1 episode per forward capture — treat the 1.8–5.2 %
  range as indicative. The dominant-contributor conclusion is independent of it.
