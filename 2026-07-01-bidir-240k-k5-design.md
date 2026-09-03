# Bidirectional On-Chip QPSK FEC Link — 240 ksym / K=5 Redesign

**Date:** 2026-07-01
**Status:** Approved design (user-approved in session), pre-implementation
**Location note:** lives beside the build kits because the repo master
(`/home/tcollins/dev/qpsk_ai`) is off-limits by standing constraint.

## 1. Goal

Both boards run the full QPSK Tx+Rx composite over the real two-board FDD RF
link, and **each board's own on-chip BIST reports live coded BER < 0.01% with
> 5000 packets, both directions simultaneously**.

- Link A: ZedBoard Tx1 @ 2.40 GHz → Jupiter Rx1 @ 2.40 GHz
- Link B: Jupiter Tx1 @ 2.45 GHz → ZedBoard Rx1 @ 2.45 GHz
- Gate (per direction, measured in one common FDD window):
  `BER = errors_reg / (packets_reg * 120) < 0.01%` AND `packets > 5000`.

## 2. Why this design (root causes being fixed)

Session-proven facts driving every decision below:

1. **Tx frame-cadence bursts** — at the accidental 480 ksym (2× design rate)
   the modulator overdrives the msggen-ROM/packetizer bit path, producing
   intermittent irregular inter-frame gaps; over long captures ~30–45% of
   frames are genuinely undecodable (clean constellation, wrong/shifted
   emission). Kills any >5000-frame soak and the on-chip BIST alike.
2. **On-chip Rx acquisition gap** — both boards' BIST read ~45% on air that
   decodes at 0% offline. The Rx loop constants (CFC change-detect threshold,
   carrier/Gardner bandwidths) are normalized-per-symbol values designed for
   240 ksym; at 480 ksym the CFC detector fires rstCS on ~28% of block
   boundaries (measured: threshold 750 Hz vs 852 Hz estimator jitter). A
   single-constant retune (threshold 0.0125) did NOT fix the BIST → stop
   retuning outside the envelope; restore the envelope.
3. **ZedBoard capacity** — K=7 Viterbi does not fit xc7z020
   (68,216 LUT needed vs 53,200; proven in Vivado placement). K=5 decoder is
   ~2^(K−2) smaller (~5–6k LUT) and fits.
4. **HW-specific, sim-invisible failure class** — the DAC-mux gate, the
   cadence bursts, and the acquisition gap were all invisible to RTL sim and
   host models. Therefore the build carries **on-chip Rx observability taps**.
5. **Operational traps (now known):** ADRV9002 Tx tracking cals drift
   (Jupiter Tx drifted to −89 kHz LO error and killed link B until re-cal);
   `dac_data_sel` resets to 0x0 (DDS) and must be poked to 0x2 (fabric) at
   every arm; on-board captures must go to `/dev/shm` (tmpfs), never `/tmp`
   (SD-card ext4 — drops DMA blocks and fakes burst errors).

## 3. Target configuration

| Item | Value |
|---|---|
| SSI / profile | 1.92 MHz (ZedBoard CMOS + Jupiter LVDS — the only common rate) |
| Samples per symbol | **8** (was 4) → true **240 ksym** air |
| Modulation | pi/4-Gray QPSK, sqrt-RRC rolloff 0.5 (rcosdesign span 4, now 8 sps) |
| FEC | **rate-1/2 convolutional K=5, `poly2trellis(5,[35 23])`**, hard Viterbi, traceback 25 |
| Packet | 13-bit Barker preamble + coded payload; info = 120-bit 'ADI Hello World' + PN pad + 4 tail bits |
| Numerology | info = 1084 bits (120 message + 964 PN pad) + 4 tail = 1088 encoder input → **2176 coded bits = 16 cols × 136 rows**, then + 64 deterministic filler bits → **payload stays 2240 bits** (Rx deinterleaver consumes the first 2176); frame stays **13 Barker + 1120 payload symbols = 1133 symbols** — no Bit-Packetizer/frame-geometry change; golden CAP_OUT recomputed offline by `packet_k5.m` |
| Interleaver | 16-column block, column-major (perm `r*16+c` Tx, `c*ROWS+r` Rx), ROWS recomputed for 2176 |
| Scrambler | OFF both ends (proven contract) |
| Tx bit source | **pre-coded ROM** (packet encoded+interleaved offline, baked into msggen ROM as packed uint32 words) — keeps the proven approach, avoids in-FPGA-encoder bug class |
| Rx chain | demod → deinterleave → K=5 Viterbi → BIST vs hardcoded 'ADI Hello World' |
| BIST | existing register map preserved (packets 0x104, errors 0x108, rstCS 0x110, rx_input_select 0x114, tx_source_select 0x118, tx_data_source 0x11C, RxAlign skip 0x138, caps 0x13C/0x140/0x144) |

## 4. HDL changes (one build per board)

### 4.1 Rate restoration (both boards, Tx and Rx)
- Model `SamplesPerSymbol` 4 → 8 at 1.92 MHz SSI. Tx RRC/interpolation and Rx
  front-end (decimation, Gardner) follow from the parameter.
- Consequence A: modulator bit-consumption halves → the msggen-ROM/packetizer
  path is no longer overdriven → uniform 1133-sym frame cadence (sim gate
  verifies zero underrun over a long run).
- Consequence B: all Rx loop constants return to their validated normalized
  design point. **Revert CFOChangeDetectThreshold to stock 0.0015625** — no
  bespoke retunes ride along.

### 4.2 FEC K=5 migration
- Offline (MATLAB): encoder/interleaver script produces the new pre-coded
  packet, ROM words, and golden CAP_OUT (first 32 recovered info bits).
- Rx: swap Viterbi trellis to `poly2trellis(5,[35 23])`, TB 25; deinterleaver
  permutation recomputed. BIST reference unchanged ('ADI Hello World').

### 4.3 Rx observability taps (both boards)
- BRAM capture RAM (≥16k complex samples) on the Rx's **post-carrier-sync
  symbol stream**, freeze/arm + read via AXI at free offsets (≥0x150).
- Status/event capture: frame-sync strobes, carrier-sync reset (rstCS)
  event **counter**, latest CFC frequency estimate register.
- Purpose: if on-chip BIST < offline decode on the same air, read what the
  receiver actually saw — no more blind 1.5 h iterations.

### 4.4 ZedBoard resource plan (the one design risk)
- Budget: xc7z020 = 53,200 LUT. Estimate: ~48k base composite + ~5–6k K=5
  Viterbi ≈ 53–54k → **borderline**. Mitigations, in order:
  1. Strip the byte-DMA Tx path + debug blocks from the ZedBoard composite
     (~5–6k LUT recoverable, measured this session).
  2. Taps live in BRAM (15% used), near-zero LUT.
  3. Fallback: K=4 (`poly2trellis(4,[17 13])`, ~3k LUT) — decision point only
     if placement fails.
- Jupiter (xc7z035): ample headroom, no action.

## 5. Components / deliverables

1. `packet_k5.m` — offline contract generator: K=5 encode + interleave +
   PN pad, emits ROM uint32 words, golden CAP_OUT, and a `.mat` reference
   air for sim/offline gates.
2. Build kits `/mnt/onetb/scratch/qpsk_variants/zed_240k5/` and
   `.../jupiter_240k5/` — full Tx+Rx composite each (FDD needs both sides on
   both boards), overlays applied to kit copies; **repo master untouched**.
3. Arm/ops scripts (per board): profile load → tracking cals on → LOs →
   atten/gain → `dac_data_sel=0x2` (ZedBoard tx DAC = iio:device6,
   Jupiter = iio:device5; regs 0x418/0x458 via `direct_reg_access`) →
   reset-before-select arm (base=1; 0x11C=0; 0x118=0; 0x114=1; rstCS pulse) —
   **every setting read back and checked**.
4. Soak harness: BIST windowed read (delta errors / delta packets), LO
   readback, per-window CSV; offline spot-check captures to `/dev/shm`.
5. Updated memory notes at each proven stage.

## 6. Staged verification (each rung gates the next)

| Stage | Gate |
|---|---|
| S1 sim | checkhdl 0; iverilog decode of generated Tx RTL air → golden CAP_OUT at 0% ; **zero FIFO underrun / uniform frame cadence** over long sim; Rx model decodes reference air |
| S2 build | Vivado placement fits (see 4.4); timing MET (clk_fpga_0 / clk_pl_0) |
| S3 deploy | flash + cold-cycle (ZedBoard via HA switch.board_3; Jupiter reflash+reboot), arm script readbacks all pass |
| S4 offline air | capture to /dev/shm → offline decode: 240 ksym confirmed, regular 1133-sym spacing (std ≈ 0), ~0 coded errors → **proves Tx cadence fix before judging any receiver** |
| S5 on-chip | per direction: BIST vs offline decode of simultaneous air; disagreement → read taps (4.3), targeted fix |
| S6 FDD soak | both directions simultaneously, ≥60 s windows: coded BER < 0.01% AND > 5000 packets per direction; compare S5 single-direction vs S6 FDD for cross-coupling regression |

## 7. Risks & fallbacks

- **ZedBoard placement misses** → mitigations 4.4 (strip byte-DMA → K=4).
- **8 sps changes timing closure** → RRC at 8 sps is longer; watch S2 timing.
- **On-chip BIST still short at 240 ksym** → taps give ground truth; fix is
  then evidence-driven, not another blind retune.
- **Cal drift mid-soak** → arm script re-cals every arm; soak harness logs
  rssi + CFC estimate per window; window-level outliers investigated via taps.
- **Jupiter has no remote power** → reflash+reboot is the recovery path
  (proven safe); ZedBoard has HA cold-cycle.
- **Board wedge on capture** → /dev/shm only, ≤2M samples per pull.

## 8. Out of scope

- Scrambler re-enable, 15.36 MHz LVDS rate, TDD, antenna/OTA characterization.
- Repo-master integration (TestQPSKTwoBoardLink.m etc.) — a later step once
  the scratch kits prove the gate.

## 9. Success criteria (restated)

Simultaneous FDD run where **Jupiter BIST (link A) and ZedBoard BIST (link B)
each report coded BER < 0.01% over > 5000 packets**, with LOs read back from
hardware, at 240 ksym, K=5, on the builds produced by this design.
