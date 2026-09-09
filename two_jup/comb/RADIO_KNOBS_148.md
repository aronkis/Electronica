# ADRV9002 radio knobs on 148 (10.0.0.148) — read-only enumeration [silicon]

SEQ-BIST Task 8a step 1. Unit `knobs148-8a` (`launch_rig_unit.sh knobs148-8a
two_jup/comb/radio_knobs_probe.sh IP=10.0.0.148 OUT=two_jup/comb/knobs_148`),
one ssh, exit 0, 2026-09-03T22:12:19-04:00. Raw output: `two_jup/comb/knobs_148/knobs.txt`.

**Nothing was written to the board.** Every `*reg_access` / `direct_reg_access` node and
every trigger-shaped node (`initial_calibrations` writes, `*_calibrate`, `*_reset_luts`,
`*_resetOnRxon*`, `stream_config`, `profile_config`, all `*_direction` GPIO nodes) was
listed but **never cat'd** — a bare read of `direct_reg_access` returns whatever address
was last written, and DRA traffic with no arm in flight has hung a board before.

State at enumeration time: link **down by design**, `qpsk_tun` **not running** on 148.
So the gain figures below are the idle/no-traffic values; the probe run scripts re-read
them live, after bring-up and inside the health-gated window (§P-A below).

## Device identity

| fact | value |
|---|---|
| phy device | `/sys/bus/iio/devices/iio:device2`, `name = adrv9002-phy` |
| debugfs | `/sys/kernel/debug/iio/iio:device2/` |
| bringup hardcode | `bringup_r2r3.sh:67` hardcodes `iio:device2` — **CONFIRMED correct on 148** by name lookup. (It is still a hardcode; the probe scripts discover it by `name`.) |
| fabric/modem device | `iio:device0` = `mwipcore0:mwipcore_regs` (this is what `0x104`/`0x108`/DRA refer to — a *different* device from the phy) |
| others | 1 xilinx-ams, 3 axi-adrv9002-rx-lpc, 4 rx2-lpc, 5 tx-lpc, 6 tx2-lpc |

## RX gain control — the P-A knob (exists, as expected)

| path (under `/sys/bus/iio/devices/iio:device2/`) | current value |
|---|---|
| `in_voltage0_gain_control_mode` | **`automatic`** |
| `in_voltage0_gain_control_mode_available` | **`spi pin automatic`** |
| `in_voltage0_hardwaregain` | **`34.000000 dB`** (5 reads 1 s apart, no traffic: 34.000000 every time) |
| `in_voltage0_ensm_mode` / `_available` | `rf_enabled` / `calibrated primed rf_enabled` |
| `in_voltage0_rssi` | `27.782 dB` (no traffic) |
| `in_voltage0_digital_gain_control_mode` / `_available` | `spi` / `automatic spi` |
| `in_voltage0_interface_gain` / `_available` | `0dB` / `0dB` (single-valued — not a usable knob) |
| `in_voltage0_rf_bandwidth` / `_sampling_frequency` | `40000000` / `61440000` |
| `in_voltage1_gain_control_mode` (RX2, unused) | `spi` — the manual mode string is proven writable on this driver |

**The manual mode string is `spi`, not `manual`/`mgc`.** `mgc` is AD9361 vocabulary and does
not appear in `_available`; writing it would fail. `pin` is the GPIO-controlled variant and is
not wanted here.

`bringup_r2r3.sh:75` sets `echo automatic > $P/in_voltage0_gain_control_mode` on **every arm**,
so `automatic` is the shipped default and a later bring-up restores it even if a restore is missed.

## RX tracking calibrations — the P-B knobs (they exist)

Boolean `_tracking_en` nodes on the phy, RX channel 0 (the forward-leg receive channel):

| path | current value |
|---|---|
| `in_voltage0_agc_tracking_en` | **1** |
| `in_voltage0_bbdc_rejection_tracking_en` | **1** (baseband DC-offset tracking) |
| `in_voltage0_rfdc_tracking_en` | **1** (RF DC-offset tracking) |
| `in_voltage0_rssi_tracking_en` | **1** |
| `in_voltage0_quadrature_fic_tracking_en` | **1** (QEC, fast-attack/FIC) |
| `in_voltage0_quadrature_w_poly_tracking_en` | 0 (already off) |
| `in_voltage0_hd_tracking_en` | 0 (already off) |
| `in_voltage0_bbdc_rejection_en` | (present; not part of P-B — it is the feature enable, not the tracking scheduler) |
| `in_voltage0_dynamic_adc_switch_en` | (present, not read as a knob) |
| `initial_calibrations` / `_available` | `off` / `off auto run` — init cals are **already off**; only *tracking* cals run |

There is no `in_voltage0_quadrature_tracking_en` on this driver; QEC is split into
`quadrature_fic_tracking_en` and `quadrature_w_poly_tracking_en`.

**P-B set = the five that are currently 1** → write 0 to each, restore 1 to each.

TX side on 148 (context; 148 barely transmits on LEG=A): `out_voltage0_{quadrature,
lo_leakage,close_loop_gain,loopback_delay,pa_correction}_tracking_en` are **all already 0**,
`out_voltage0_hardwaregain = 0.000000 dB`, `out_voltage1_hardwaregain = -40.000000 dB`.
So there is no TX tracking process running on 148 to turn off. (On **146**, the transmitting
board of the forward leg, these are unmeasured — see P-D in the pre-registration.)

## AGC scheduler parameters (debugfs, read-only — candidate period sources)

`/sys/kernel/debug/iio/iio:device2/` exposes the full AGC config. The periodic ones:

| node | value |
|---|---|
| **`rx0_agc_gainUpdateCounter`** | **11520** |
| `rx0_agc_agcMode` | 1 |
| `rx0_agc_config` | `peakWaitTime: 4, maxGainIndex: 255, minGainIndex: 187` |
| `rx0_agc_attackDelay_us` | 10 |
| `rx0_agc_slowLoopSettlingDelay` | 16 |
| `rx0_agc_peak.agcUnderRangeLowInterval` | 50 (Mid 2, High 4) |
| `rx0_agc_power.powerMeasurementDelay` / `Duration` | 2 / 10 |
| `rx0_agc_enableFastRecoveryLoop` / `enableSyncPulseForGainCounter` | N / N |
| `rx0_gain_control_pin_mode` | `min 187 max 255 step 1` |
| `rx0_cals_internal_path_delay_ns` | 2294 (rx1: 2311) |
| `pll_lo1_calibration_mode` / `pll_lo2` / `pll_aux` | 0 / 0 / 0 |
| `fh_min_rx_gain` / `fh_max_rx_gain` | 187 / 255 |

[inferred, and deliberately NOT claimed as the mechanism] `gainUpdateCounter = 11520` is the
AGC's periodic gain-update tick. It is the only explicitly periodic RX number in the enumeration.
Its period depends on the AGC clock, which this interface does not expose: at the 61.44 MHz RX
sample rate 11520 ticks would be 187.5 µs, not 26.04 ms, so **the arithmetic does not by itself
produce the measured 26.0489 ms** — 26.0417 ms would need a 442.368 kHz AGC clock, and no
divider from 61.44 MHz or 38.4 MHz gives that integrally. The probes are the test; this
arithmetic is recorded so a future reader does not re-derive it and mistake it for evidence.

## What does NOT exist

* No single "tracking calibrations" master switch — only the per-function `_tracking_en` booleans above.
* No exposed AGC-clock or tracking-cal scheduler *period* attribute (so the 26 ms period cannot
  be read off; it can only be tested by turning the processes off).
* No `manual`/`mgc` gain-control mode string (it is `spi`).
* `in_voltage0_nco_frequency` returns `Unknown error 524` (ENOTSUPP) on this profile.

## Safety facts established for the probe runs

* `capture_r3.sh`'s `rearm_byte()` touches only the **fabric** device-0 DRA and the TX
  debugfs DRA — it does **not** write `gain_control_mode` or any `_tracking_en`. Verified by
  reading `capture_r3.sh:73-79`. This is what makes the post-re-arm hook position safe.
* `capture_r3.sh` step 3 **kills both watchdogs** before the window, so no watchdog relaunch
  can re-arm and reset the attribute mid-window.
* Restore safety net: `bringup_r2r3.sh:75` re-asserts `automatic` on every arm. It does **not**
  re-assert the `_tracking_en` values (they come from the profile load at `:70`, which every
  `arm_rom` does perform) — so a missed P-B restore would be cleared by the next full bring-up
  but must not be relied on. The run script restores explicitly, under a trap, and reads back.
