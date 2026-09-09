# Two-Jupiter channel verification — 1.5 & 2.0 GHz, both channels (2026-07-04)

Setup: A=10.0.0.148, B=10.0.0.146, jupiter_240k5 image, 1.92 MHz LVDS, DDS tones (+100 kHz).

## Reliable findings (consistent across gain/freq conditions)
- **Both new frequencies work.** LOs tune to 1.5 and 2.0 GHz cleanly; tones propagate.
- **Channel 2 is rock-solid connected, BOTH directions, BOTH frequencies** — clean 96–99 dB
  single tones at default gain, no fuss:
  - CH2 148→146: 98.1 dB @2.0, 96.8 dB @1.5
  - CH2 146→148: 97.9 dB @2.0, 96.3 dB @1.5
- **All four physical paths carry signal** — every path shows a strong tone under some gain,
  so nothing is physically disconnected.
- **Inter-board CFO** (independent Jupiter LOs): ~4.7 kHz @2.0 GHz, ~3.5 kHz @1.5 GHz.

## The problem: 148's Rx1 (channel-1 receive on the new board)
- CH1 148→146 (148 Tx1 → 146 Rx1) is clean (98 dB @2.0).
- CH1 146→148 (146 Tx1 → **148 Rx1**) is flaky: a weak tone gets buried under 148 Rx1's
  high DC/artifact floor; only a near-full-scale tone shows (98.9 dB but the Rx saturates).
- 148's **unconfigured Rx2 is cleaner than its armed Rx1** — so this is specific to 148 Rx1
  (calibration/state or that RF port), not a general board problem.
- CH1 also showed frequency-dependent flakiness (pass/fail swapped 1.5↔2.0), consistent with
  a marginal Rx1 + fixed-gain saturation rather than a clean channel.

## Implication for the modem
The `jupiter_240k5` modem uses **channel 1** (Rx1 = in_voltage0, BIST at 0x9D000000). So the
modem's receive into 148 rides on the problematic Rx1. Options:
1. **Fix 148 Rx1** — proper Rx calibration (init-cals + QEC tracking in the right ENSM
   state; the arm's quad-tracking enable was denied in rf_enabled), and check the CH1
   146→148 SMA/cable at the bench.
2. **Run the modem on channel 2** — reliably clean both directions, but requires the modem
   HDL/config to use Tx2/Rx2 (a rebuild or channel remap).
3. Investigate why CH1 is marginal while CH2 is pristine (cabling difference? Rx1 hardware?).

## Frequency plan (new)
FDD carriers → **1.5 GHz and 2.0 GHz** (500 MHz separation, off the 2.4 GHz Wi-Fi band).
Suggested: one direction @2.0, other @1.5, per channel.

Scripts: two_jup/tone_path.sh (channel-aware), tone_check.py. Captures: two_jup/p_*.iq, agc_*.iq.
