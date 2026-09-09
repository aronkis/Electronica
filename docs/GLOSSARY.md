# GLOSSARY

One-line definitions of the terms and jargon used across this repo. Deeper
context: [ARCHITECTURE.md](ARCHITECTURE.md), [DEBUGGING.md](DEBUGGING.md),
[`../two_jup/ERROR_TAXONOMY.md`](../two_jup/ERROR_TAXONOMY.md).

### Waveform & modem stages

- **240 ksym** — the symbol rate: 1.92 MHz SSI ÷ 8 samples/symbol.
- **sps** — samples per symbol (8 here). **SSI** — the Synchronous Serial
  Interface between the FPGA and the ADRV9002 (1.92 MHz).
- **π/4-Gray QPSK** — the modulation; 2 bits/symbol, Gray-coded, π/4 rotated.
- **sqrt-RRC (β=0.5)** — the root-raised-cosine pulse-shaping filter, roll-off 0.5.
- **Barker** — the 13-symbol known preamble prepended to every frame for sync.
- **K5 / [35 23]** — the rate-1/2 constraint-length-5 convolutional code,
  `poly2trellis(5,[35 23])`. **TB / TB=25** — Viterbi traceback depth.
- **136×16 interleaver** — the block interleaver that spreads coded bits; ping-pong
  (air frame N carries the encode of byte frame N−1).
- **CFC** — Coarse Frequency Compensator (removes bulk CFO). **SS** — Symbol
  Synchronizer (Gardner timing loop). **CS** — Carrier Synchronizer (a PLL whose
  **NCO/DDS** derotates the carrier). **FTS** — the Frequency-and-Time
  Synchronizer subsystem holding SS+CS. **IC** — the SS's interpolation-control
  (timing) loop.
- **Gardner** — the timing-error-detector algorithm the SS uses.
- **Phase-ambiguity resolver** — resolves the QPSK 4-fold (±90°/180°) phase
  ambiguity to the correct quadrant using the preamble (`resolver_lookback_fix`).
- **byte plane / byte-DMA** — the in-fabric data path that carries host bytes
  (vs the pre-coded ROM/BIST source); selected by `tx_data_source` (`0x158`).

### Frequencies, RF, radio

- **CFO** — Carrier Frequency Offset (Tx/Rx LO mismatch). **CFOChangeDetectThreshold**
  — the modem parameter that triggers a carrier-sync reset on a detected CFO step;
  set too low it false-fires (see `rxfix`).
- **quiet pair** — the FDD frequency plan (fwd 2.00 / rev 1.90 GHz) chosen by RF
  survey to dodge 148's 2.10 GHz Tx-LO leakage (board-A/B-specific).
- **ENSM** — the ADRV9002 ENable State Machine (`calibrated`/`rf_enabled` modes).
- **LVDS profile** (`lvds_1p92_mhz.{bin,json}`) — the ADRV9002 stream/profile
  config that sets the 1.92 MHz SSI, 8-sps/240-ksym rung.
- **BBDC** — Baseband DC (offset) rejection. Its **tracking cal** on unit 148 is
  the source of the **tick**.
- **near-end / internal loopback** — ADRV9002 `rx0_near_end_loopback`: a unit's Tx
  looped to its own Rx through the ADC path, no cable/air.
- **rssi / level** — received signal strength; `level` is reg `0x15C`.

### The tick and error classes

- **the tick** — 148's BBDC rejection tracking cal fires every ~1.5 s and inserts
  256 samples (= **+32 symbols**) into the RX stream to the modem. Per-unit,
  chip-level, both RX paths, absent on 146, OTA-only. The forward-BER floor.
- **mosaic window** — the single physically-inserted frame per tick that is
  information-theoretically unrecoverable (what remains after `p1e_comp` recovers
  the displaced frame).
- **stale-grid / deint stale-grid** — the deinterleaver window displaced by the
  tick's +32 symbols; the casualty class `p1e_comp` (patch D / P1E-v3) cancels.
- **splice** — a testbench that injects a +256-sample insertion into a captured
  stream to reproduce the tick offline.
- **Class 1–4** — the error taxonomy: 1 = tick episodes, 2 = between-episode
  scatter, 3 = rare frame mangling, 4 = acquisition wedge. See DEBUGGING.md.
- **reset storm** — a burst of spurious carrier-sync resets (~52/s) from a too-low
  `CFOChangeDetectThreshold`; fixed by `rxfix`. Watched via `rstcs`.

### Images, fixes, builds

- **rxfix** — the CFO reset-storm fix (`CFOChangeDetectThreshold 0.0015625→0.0125`).
- **pifix** — restores the demod decision boundary to the 45° grid + corrects the
  carrier-sync loop gains (killed a ~2–3e-3 floor).
- **resolver_lookback_fix** — the phase-ambiguity fix (git `8033363`).
- **tafix / timing_adjust_fix** — the Timing-Adjust offset-tracking fix (Class-1).
- **p1e_comp / patch D / P1E-v3** — the fabric compensation for the tick's +32-symbol
  displacement (acc-position-qualified deinterleaver skip).
- **timing_hardening** — the anti-wedge clamps that make the Class-4 timing-loop
  deadlock impossible by construction.
- **lean image** — the current shipped image (`dcf5c5fb`): a debug-strip of P1E-v3
  that removes instrumentation to restore timing margin while keeping all fixes.
- **P1B/P1C/P1D/P1E** — successive telemetry/probe generations added during the
  tick investigation (P1D = the consumed-path offset telemetry; P1E = the comp).

### Instrumentation & taps

- **cap_out / `0x04922282`** — the BIST golden readback that proves a correct
  decode of the ROM vector.
- **rstcs (`0x150`)** — carrier-reset firing counter (reset-storm indicator).
- **packets_out (`0x104`)** — frame counter used as a liveness/lock signal.
- **mux modes (`0x10C`)** — the IQ tap selector: 0 AGC-out, 1 post-SS, 2 post-CS,
  3 constellation. **dual-DMA tap** — routes that mux to the 2nd rx-DMA channel.
- **Tap-A** — the safe `iio_readdev` capture path (vs the modem S2MM path, which
  wedges the board above 512 KB).
- **canary / shadow** — debug instruments (shadow copies of loop state, divergence
  counters) at `0x170-0x1A0`; **stripped in the lean image**.
- **verified-lock** — the deterministic acquisition procedure (watchdog → probe →
  reset/re-arm retry) in BRINGUP §3 that makes lock reliable.

### Data plane & host

- **golden vector / golden_k5.mat** — the fixed BIST payload the ROM source
  radiates; decodes to `cap_out=0x04922282`.
- **whitener (`QPSK_WHITEN`)** — the optional host-side data whitener; must match
  on both ends (low-entropy payloads get RF-corrupted without it).
- **CLEAN / NOISY / PHASE / ROTATED / MISS** — the `-B` per-frame result buckets:
  clean decode, decoded-with-errors, quadrant-mislocked, rotated, and lost/unaligned.
- **-B / -F / -S** — `qpsk_tun` modes: `-B` full-packet BER, `-F` forward tun
  daemon, `-S` loss-proof sequence-stream scorer.
