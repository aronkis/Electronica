# Parallel campaign: PER localization + float baseline, one shared image event — design

**Date:** 2026-08-24
**Branch:** `per-under-1pct-2026-07`
**Status:** design approved (operator, 2026-08-24)

## Goal

Run the two open threads in parallel on shared hardware:

1. **PER thread** — localize the ~13.1 % forward singles comb to a named stage (RF chain
   vs SSI ingress vs ADC→demod ingress), the campaign's actual goal (<1 % both
   directions, ARQ off; currently NOT met).
2. **Float thread** — restore IQ capture on 148 and complete the float baseline: a
   per-frame float-vs-hardware comparison on the same over-the-air signal.

The threads converge on one experiment (A3 below): with a working tap, the float receiver
becomes the PER thread's sharpest discriminator.

## Standing facts this design builds on (all measured, all committed)

| fact | source |
|---|---|
| Forward delivered PER **13.107 %** (10181/77674, CP95UL 13.347 %), singles-comb shaped | host framelog, `accept_analyze.py`, `r3cap/fwdbase_20260823_080537` |
| Forward air BER **~8.2e-5**, rstcs=0 — bits fine, frames not | on-board BIST counters, same signal |
| Batched DMA at line rate, radio removed: **0.62 %** | Task 3b, `tgen_sweep` `KEEPM=1` |
| Comb does NOT reproduce in FPGA-internal loopback | Task 3 (single-packet) + 3b (batched) |
| ⇒ the loss lives in what air adds: RF chain, SSI ingress, or the **ADC→demod ingress stage** — the last never tested (loopback injects at the modulator; offline replay uses the external-ADC port) | `SINGLES_CAMPAIGN.md` |
| 148's `rx-lpc` IQ tap carries a **ramp test pattern** (0x101 staircase). Image-specific: 146 (never reflashed) is clean, same command, same moment. Survived a reboot; not the mux, not #48, not ADRV9002 SSI test modes (all refuted by measurement) | `SINGLES_CAMPAIGN.md` 2026-08-24 |
| Float receiver `float_baseline_f1536.m` is **G1-clean** (0 bit errors on synthetic, 24-way mapping self-identified, margin 12068) but **fails at ≤9 dB Es/N0** (G2); CFO fabrication fixed and ruled out as the driver | float-baseline plan Tasks 1–3 |
| `check_capture_health.py` (BW ~22 MHz AND envelope autocorr < 0.9) validated on known-good and known-bad captures; wired into both capture harnesses | commit `71e9a0b` |
| Banked image `tgenrx 87355641f018`: built 08-18 from the lean+TGEN lineage, gates green (`TGEN_WIRE_OK`, `TGEN_RX_WIRE_OK`, `RAIL_GATE PARITY_OK`), never flashed. **Predates the beat-ILA/BEATOBS/BEATFIX overlays** — the lineage suspected of breaking the tap | `tgenrx_build.status` |

## Architecture

Two lanes, one hardware pivot.

```
Lane B (offline, starts now):   G2 bounded diagnosis ──┐
Lane A (hardware):  flash tgenrx ── tap health-check ──┴── ROM-on-air capture ── float decode
                                        │                        │
                                        │                        └── per-frame float-vs-hardware verdict (A3)
                                        └── TGEN rate-controlled PER runs + SSI near-end loopback (A4)
```

The rig is a hard mutex (one harness at a time). Lane B never touches hardware.

## Lane A — hardware

### A1. Flash the banked tgenrx image onto 148

- Image: `jupiter_byte_tgenrx_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN`,
  md5 `87355641f018`. Zero new builds.
- Full rails: image md5 readback after copy, rollback image staged on-board, two-pass
  health gate (fsync ≥ 1120 f/s, wcnt tracking, 0x1C0 delta), TGEN GPIOs read back zero
  (pass-through default), witness reads before any rollback.
- **The flash itself waits for the operator's explicit go at execution time** (standing
  policy). 146 is never touched.
- Accepted regression, named: BEATFIX (fixctl contract) is removed. It was proven
  PER-neutral (v3 A/B: no significant delta, clean fractions identical), and the beat's
  damage mechanism is understood; nothing measurable is lost.

### A2. Tap verdict — pre-stated, binary

Immediately after flash + bring-up, one gated capture (framesync ≥ 1120 f/s verified at
capture time) through `check_capture_health.py`:

- **PASS** (occupied BW ~22 MHz, envelope autocorr < 0.9): IQ capture is restored, and
  the ramp is confirmed as a beat-overlay-lineage defect (it exists in that lineage and
  not in this one). Proceed to A3.
- **FAIL** (still the 2.88 MHz / 0.999-at-lag-256 ramp): the ramp predates the beat
  overlays — record that (it re-aims any future diagnosis at the earlier lineage), and
  the float thread falls back to Aug-12-capture-only scope (EVM bound, no bit-scored
  BER). The PER thread continues unaffected — its instruments (counters, framelog, SSI
  loopback) never touch the tap.

No reinterpretation after the fact.

### A3. The convergence experiment: one signal, three scorers

With a working tap: **ROM/BIST-on-air capture** (via `capture_rom_air.sh`, which keeps
every transmitted frame equal to the known reference), scored three independent ways on
the same air signal:

1. **On-board BIST counters** (0x104/0x108 deltas) — hardware bit truth.
2. **Host framelog** — delivery truth (which frames arrived).
3. **`float_baseline_f1536`** on the captured IQ — the algorithmic ceiling.

The per-frame question that finally becomes answerable: **do the frames the hardware
loses decode in float?**

- **Float recovers them** → the samples were good and the hardware receiver dropped
  them: implementation gap, and specifically in the ADC-ingress/demod path the
  campaign has never tested. This names the stage.
- **Float loses them too** → the samples themselves are bad: channel/RF. The fabric is
  exonerated at f1536 air conditions.

Run validity gates (all required, any miss → run recorded invalid, no verdict):
- `check_capture_health.py` PASS on the capture,
- measured SNR ≥ the receiver's validated floor (from B1),
- `hypStable=1` with `hypMargin` reported (an unstable mapping identification means the
  sweep fitted noise).

### A4. Tap-independent PER legs (run whenever the rig is otherwise idle)

- **SSI near-end loopback comb test.** The beat campaign's proven discriminator: TX
  routed back at the SSI near end — RF removed, SSI and ADC ingress exercised. Scored by
  counters/framelog with `singles_cadence.py`. Verdict rule: comb present → SSI/ingress
  implicated and RF exonerated; comb absent → RF/channel implicated.
- **TGEN rate-controlled PER points** on the new image (the injectors come free with it),
  `KEEPM=1` so batched DMA is engaged, extending Task 3b's ladder on this lineage.

## Lane B — offline (starts immediately)

### B1. G2 bounded diagnosis + validated-SNR floor

- Instrument the receiver's loop states at 9 dB Es/N0 (where BER is 16.7 % but the
  mapping is still correct — the decode is broken before the sweep gets confused).
- Test the two named suspects: the K5-inherited carrier/symbol loop bandwidths
  (`evm_config_1536k` values tuned at a 64×-slower link) and the flat
  `precorrthresh=0.5` accept gate.
- **Timeboxed.** Whatever the outcome, the receiver ships with an explicit
  **validated-SNR floor**: the lowest Es/N0 at which the AWGN ladder is clean. If the
  diagnosis lands, the floor drops; if not, it stands at 12 dB and the campaign moves
  on. Every air result reports measured SNR against the floor.
- Rationale for not requiring a full fix: the air captures the campaign needs are
  high-SNR (hardware achieves 8.2e-5 on them). The cliff is an instrument limitation to
  be stated, not necessarily removed.

### B2. Fixed-leg prep — stretch only

An IQ-fed Verilator wrapper against the v3 netlist stays **out of scope** unless A3
produces frames whose float-vs-hardware disagreement demands bit-level fabric replay.
(`wrap_byte_bf2.v` is BIST-ROM-driven; the IQ wrappers are K5-geometry — this is real
harness work and is not started speculatively.)

## Metrics discipline (binding, unchanged)

No PER/BER claim without the exact command, the sample/frame count, and confirmation of
what is in the denominator. BER and frame recovery reported separately. Pre-stated
verdict rules are not revised after seeing data; a rule that turns out mis-specified is
reported as mis-specified (precedent: Task 3's PARTIAL).

## Non-goals

- Reverse direction / 146 (frozen; never flashed).
- The wedge/#48 class and the arm lottery (worked around via `GATE_DIR=A`, not fixed).
- Beat trigger origin (harmless, observable, parked).
- Naming/fixing whatever sources the ramp in the beat-overlay lineage (recorded; chased
  only if A2 FAILs and even then only as diagnosis, not a build).
- A full G2 fix beyond the timebox.
- Folding BEATFIX into a future image (parked with the beat work).

## Risks, honestly

1. **The banked image may have the same tap defect.** Covered by A2's FAIL branch — the
   outcome is informative either way, and the PER thread doesn't stall.
2. **Flashing loses BEATFIX.** Accepted; proven PER-neutral. Re-flashing v3 later
   restores it (image banked, rollback staged).
3. **The tgenrx image is 6 days old** and predates the BEATFIX byte-plane work; its
   behavior on air was verified 08-18 (pass-through equivalence PASS, fwd PER 8.35 % in
   the then-current band) but the channel has drifted since. Baseline comparisons use
   its own fresh numbers, not cross-image ones.
4. **2-frame mapping calibration may be weak on noisy air frames.** Mitigated:
   `hypMargin` is visible and the validity gate invalidates unstable runs.
5. **Arm lottery** may cost bring-up retries; known, `GATE_DIR=A` suffices for
   forward-only work.
6. **MATLAB trial license** — functional, banner only.

## Definition of done

- A2 tap verdict recorded (either branch).
- A3 delivered: per-frame float-vs-hardware table on at least one healthy ROM-on-air
  capture, with the discriminator verdict (implementation-gap vs channel) stated — or,
  on the A2 FAIL branch, the SSI-loopback verdict (A4) standing in as the localization
  result.
- B1 delivered: a validated-SNR floor with the AWGN ladder evidence, and the G2 cliff
  either explained or explicitly bounded.
- All results in `SINGLES_CAMPAIGN.md` with commands, counts, denominators.
