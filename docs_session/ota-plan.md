# OTA (Antenna) Link Bring-Up — Golden-First, Model-Based

## Context

The two-Jupiter link is **proven at 0.000% BER bidirectionally over cables** (gather-fix image `753760ad`, arm discipline documented in memory). Over **antennas it has never decoded** (~600 attempts, 0 golden): wideband QPSK arrives spectrally clean at good level (LNAs found/enabled: `agpio4-7`, +17 dB; RSSI 17 dB post-reposition) yet the payload symbols are scrambled to ~43% coded BER, while a CW through the same path is pristine (29 Hz wide). Eliminated already: level, CFO (wide-range measured −5.4 kHz, trimmed from clean boot), Tx port select (tx_a verified), Rx LNA A/B configs, FPGA data source (host-DMA fails identically; near-end SSI tap simultaneously golden), image (stock fails too), chip state (power-cycled), ISI as a 7-tap complex channel (99.8% residual — though that fit's sync is suspect).

Goal (user): **address the antenna-specific implementation. Start from the golden receiver and transmitter to verify the link is possible; then move to the deployed HDL version. Use model-based design verified against real captures.**

Strategy: golden MATLAB Tx (via host-DMA) + golden offline Rx first — instrument and adapt until OTA golden-to-golden closes (proves feasibility + names the required fix). Then reproduce and verify the fix in the HDL-faithful model against real captures. Only then build/deploy HDL.

**Key assets (all exist):**
- `two_jup/golden_tx.iq` — clean golden waveform (proven over cable, self-tests 19/19)
- `k5_240/soak_decode_k5.m` — golden offline Rx (proven 43/43 over cable); `soak_dumpbits_k5.m` (per-frame bits)
- `two_jup/golden_ota.iq` — cable reference capture (decodes 0.000%); `separated.iq`, `soak/fail_*.iq` (100 OTA fail captures)
- Host-DMA Tx: DAC mux `0x418/0x458=0x0` + `iio_writedev -c ... voltage0 voltage1` (proven)
- `two_jup/xcorr_gold.m`, `determine_source.m` (correlation/decomposition starting points)
- Reproducible HDL build: `jupiter_240k5/build_gather_clean.sh` + kit; S1 gates (`checkhdl_gate_240k5.m`, iverilog)
- HDL-faithful fixed-point Rx sim (S1-era harness in `jupiter_240k5/s1_rtl/`, memory: "faithful fixed-point HDL-Rx sim clean at zero offset")

---

## Phase A — Golden-to-golden OTA: characterize, then close the link (no HDL builds)

### A1. OTA channel sounding (new tool: `two_jup/sound_channel.m`)
1. Transmit `golden_tx.iq` via host-DMA on 146 Tx1 @2.0 GHz (clean-boot protocol; CFO trim +5.42 kHz at boot; LNAs on; ch2 killed).
2. Capture long (≥2 s) on 148; handle capture decimate-by-2 and **wide-range CFO** (±50 kHz 4th-power — the ±8 kHz masks were a proven blind spot).
3. Frame-synchronous LS deconvolution against the known golden frame waveform → **channel impulse response h(t) per frame**: delay profile, and frame-to-frame variation (static vs time-varying).
4. Run the identical tool on `golden_ota.iq` (cable) as the control.

**Gate A1:** classify the OTA channel: (i) static linear ISI → A2; (ii) fast time-varying or (iii) non-linear/unexplained → A3 + physical iteration.

### A2. Equalized golden receiver (new: `k5_240/soak_eq_k5.m`)
- Extend the golden Rx with a **preamble-trained per-frame LS equalizer** (train ONLY on the 13-sym preamble + decision-directed extension; never on payload reference — the genie trap is documented). Length guided by measured h(t).
- Decode the existing OTA fail captures + fresh A1 captures.

**Gate A2 (the feasibility verdict):** equalized golden-to-golden OTA < 0.01% coded BER ⇒ **the OTA link is possible**; record required equalizer complexity. If it fails → A3.

### A3. Contingency: waveform-level search (still golden/host-DMA, MATLAB-generated)
- Variants transmitted via host-DMA: RRC beta/span changes, +IF band offset (dodge a bad spectral region), half-rate (120 ksym) golden. Any variant that closes OTA identifies the sensitivity.
- Physically iterate antenna geometry guided by h(t) (with user), including a 1-antenna-per-board test (disconnect extras — 4 live antennas may create the anomaly).

## Phase B — Model-based reproduction + fix selection (MATLAB/Simulink vs real captures)

### B1. Model ↔ hardware fidelity gate
- Feed **real captures** into the HDL-faithful fixed-point Rx model (S1 sim harness): cable capture (`golden_ota.iq`) must decode golden; OTA captures must reproduce the on-chip failure (no-lock/43%). This validates the model as the debug vehicle.

### B2. Channel-in-the-loop reproduction
- Fit measured h(t)/impairment into a channel block; model-Tx → channel → model-Rx must reproduce 43%.

### B3. Fix selection in the model (cheapest-first)
1. **Rx acquisition/AGC tuning** — loop bandwidths, modem AGC threshold `thr` (currently 0.0015625, tuned for cable levels; known OTA-margin issue) — parameter-only, cheapest HDL impact.
2. **Tx waveform change** (if A3 found one) — Tx-filter/rate params, cheap regen.
3. **Preamble-trained equalizer stage** in the Rx (before/at symbol sync) — only if A2 proves it's required; costliest RTL.

**Gate B3:** the chosen fix decodes **real OTA captures** in the model at <0.01%.

## Phase C — Deploy to HDL + OTA gates

### C1–C2. Implement + build
- Apply the model-verified fix as a kit overlay (`jupiter_240k5/assemble_*`, keep the gather); S1 gates (checkhdl + iverilog golden `CAP_OUT 0x04922282`); build via `build_gather_clean.sh` flow; deploy to 148 first (146 keeps the known-good image until 148 passes).

### C3. OTA link gates (full discipline)
- Clean-boot single-arm protocol; canonical arm order (0x000 → 0x118/0x114 → DAC mux → rstCS); receiver-side minimal arm for Rx-only tests; ch2 killed (DDS tone); LNAs set per link budget; CFO trim from boot; **BIST anti-mirage check** (rx_input default=0 is internal: verify air decode with a far-Tx-off control every time).
- Gates: 148→146 then 146→148, offline <0.01% AND BIST golden.

### C4. FDD + soak
- Simultaneous FDD @2.40/2.45 (no RF blocker exists — measured), then the soak harness (`soak_harness.sh`, classification already built) for the final <0.01% statistics both directions.

---

## Execution discipline (hard-won, do not re-learn)
- **State:** reboot-fresh before any verdict; never retune LO/ensm on a live chain; single-arm per boot. Profile + ch2-kill + LNA re-enable after every boot.
- **Measurements:** wide-range CFO only; captures are 2×-duplicated (decode at dec2); BIST mirage control (far-Tx-off) before trusting golden; on-chip caps: stable-wrong = consistent decode of wrong stream, varying = no lock.
- **Infra:** scp+askpass (never cat) for binaries; `matlab -batch` single-line or .m files; `setsid nohup` for anything long-lived; check liveness by log freshness (pgrep self-matches); never touch repo master (`/home/tcollins/dev/qpsk_ai`); work in `/mnt/onetb/scratch/qpsk_variants/`.
- **Boards:** 148/146 gather `753760ad`; backups on-board + `two_jup/gather_BOOT.BIN`; no remote power (user).

## Verification summary
1. **A-gate:** golden Tx → OTA → (equalized) golden Rx < 0.01% ⇒ link physically possible, fix identified.
2. **B-gate:** HDL-faithful model decodes the same real OTA captures with the fix.
3. **C-gate:** deployed HDL: bidirectional OTA BIST golden + offline <0.01%, then FDD + soak.
