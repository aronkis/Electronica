# Calibration-source proof of the burst disruption (2026-07-20)

Artifacts for the tone/tap experiments that localize the ~1.489 s "tick" burst
loss on unit **148** to the ADRV9002 **BBDC rejection tracking calibration** —
a transceiver calibration issue, not fabric, not a signal-domain defect. See the
addendum "2026-07-20 — tone + tap-blind localization" in `../ESCALATION_ADI.md`.

## Figure
`tick_calibration_proof.png` — four panels:
1. The burst is real & live on 148 (forward QPSK; ~5e-4 aggregate BER incl.
   thin-margin non-tick loss). `witness_acc.log` is the source `-S` log.
2. The BBDC cal is active & correcting: |residual DC| at the AGC-out tap =
   **0.8 (tracking ON) → 178 (tracking OFF)**, ~214×.
3. The burst is NOT in the delivered IQ: the tick is metronomic/LO-driven at
   0.67/s so ~8 events must land in a 12 s window regardless of SNR, yet the
   AGC-out tap shows **no** coherent lag-256 repeat (synthetic true-repeat
   reference spikes to coherence 1.0; the real tap never does). → a read-pointer
   / SSI sample-delivery *index* jump, invisible to any IQ snoop.
4. Tones attempted (negative "if possible"): a tone cannot probe this fault — no
   modem-lock witness that the tick fired, AND the cal state during capture was
   abnormal (tap |DC|=195 with tracking ON vs 0.83 on QPSK, no toggle response).
   No signal-domain conclusion is drawn from the tone.

## Scripts (run from two_jup/; set OUT=<dir> to redirect captures)
- `phaseA_tap_tick.sh` — arm forward OTA QPSK, verified lock, pin 148 gain,
  capture the modem-consumed AGC-out tap (rx2-lpc, 0x10C mode 0) + the raw
  rx-lpc branch, BBDC on and tracking-off. The positive control.
- `phaseB_tone.sh` — 146 emits a pure CW tone via the hardware DDS (gain 0 +
  `_raw=1`; gain set AFTER rf_enabled), 148 captures the tap. Lock-free.
- `detect_tick2.py` — coherent lag-256 repeat detector (matched to a duplicated
  256-sample block). `--selftest` validates it on injected repeats.
- `analyze_tone2.py` — per-block peak-transient spectral search at the tick rate.
- `make_figure.py` — regenerates the figure from the phaseA/phaseB captures.

## Key numbers
- forward BER ~5e-4, ~4–5 lost frames/s (148); reverse/clean 146 ~2e-6.
- BBDC on/off DC: 0.8 → 178 LSB at the AGC-out tap.
- tick rate 0.672 Hz (period 1.489 s) = the BBDC cal iteration period.
- IQ captures (23.04M samp / 12 s, 1.92 MSPS): no coherent 256-repeat.
- tone: peak/median 11.4M, f0 ≈ −43 kHz; tick-rate SNR ≈ 0.1 (null).

## Honest limitations
- The tone (result #3) yields **no** signal-domain conclusion: a tone can't lock
  the modem (no tick witness) and the cal state during the tone captures was
  abnormal (tap |DC|=195 with tracking ON vs 0.83 on QPSK, unmoved by the
  toggle). It stands only as the negative answer to "use tones if possible" —
  this index-domain fault has no simple-waveform handle on the lean image.
- The load-bearing "not-in-data" evidence is the **phaseA** control: the tick is
  metronomic (~8 events / 12 s, SNR-independent) yet produces zero coherent
  256-repeats in the IQ. The direct causal link (disabling
  `bbdc_rejection_tracking_en` stops the tick) is the prior 780 s single-variable
  A/B in this doc.
- The lean image strips the P1D sync-state telemetry that originally imaged the
  +256 insertion; that is why no on-chip observable of the insertion survives.
