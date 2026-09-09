# DMAC-in-the-loop simulation — results (2026-08-28, sim track)

Harness (all under `jupiter_240k5_byte/rtl_sim/`, no rig interaction):

| file | what |
|---|---|
| `dmac_src/` | the 27 ADI `axi_dmac` sources + `inc_id.vh`/`resp.vh` (byte-identical to `jupiter_byte_rxfifo4k_build/.../library/axi_dmac` and canary); ONE shim: `request_arb.v:716` generate block labelled `g_src_stream` (for the witness hierarchical refs). ADI common/util_axis_fifo/util_cdc are pulled from the build tree by `-y`. |
| `wrap_byte_dmac.v` | real `axi_dmac` with the exact `rx_byte_dma` BD parameter set (SYNC_TRANSFER_START=1, CYCLIC=1, CACHE_COHERENT=1, AXCACHE 1111, AXPROT 010, 64/64, TYPE_SRC=1 stream, TYPE_DEST=0 MM, defaults LENGTH_WIDTH 24, FIFO_SIZE 8, MAX_BYTES_PER_BURST 128). Witness taps: data_mover `needs_sync/active/pending_burst/xfer_req`. Modelling simplification: one clock for s_axis/m_dest/s_axi (silicon: adc_1_clk / sys_250m / sys_cpu); ASYNC CDC stages kept. |
| `sim_byte_dmac.cpp` + `run_dmac_sim.sh` (`obj_dmac/`) | stream generator straight into `s_axis` (upstream model `wait` = infinite buffer, or `fifo` = drop-oldest C++ model), host model, DDR model, scorer. |
| `dmac_src/egress/egress_glue.v` + `wrap_byte_dmac_rtl.v` + `sim_byte_dmac_rtl.cpp` + `run_dmac_sim_rtl.sh` (`obj_dmac_rtl_{orig64,v4}/`) | **the real byte-RX egress RTL** copied verbatim from the flashed-lineage `TxRxCompo_ip_src_TxRxComposite.v` (ipshared/973a): `_tc` clock-enable block, Ser*RT regs (enb_1_2_0), `TxRxCompo_ip_src_ByteRxFifo.v` (ORIGINAL 64-word, from beatfix ipshared/2a8c) or `ByteRxFifo_v4.v` (rxfifo4k BRAM drop-in), the 4-stage delayMatch chains to the pins, breakout TLAST gate, Option-E tuser mask. Serializer is emulated (word held, tog flips once per word, never backpressured — as the RTL comments state). |
| host model | replays `qpsk_tun.c` verbatim: RXQ=0 `rx_arm` (CONTROL 0/1, IRQ_MASK, DEST, X_LENGTH=M·1528−1, FLAGS 0, SUBMIT; poll TRANSFER_DONE bit0; re-arm after REARM clk = carve_zero etc.), RXQ=1 `rx_arm_queued`/`rx_q_submit`/`rx_q_on_complete` (SUBMIT-busy spin, per-ID DONE bitmap, drain then re-queue). AXI-Lite access +40 clk each, poll every 245 clk (2 µs). |
| scorer | slots of 191 words per area; header magic + full-body seq check; seq holes (drops in denominator), hole-length bins, slot position of each hole, junk slots; word reconciliation offered = fifo_dropped + accepted, accepted = ddr_written + in_flight. |

Word cadence 545 clk/word (1180 f/s × 191 words at 122.88 MHz). Every run: 1000 frames offered (62 transfers at −M16).

## Commands

```
cd jupiter_240k5_byte/rtl_sim
MODE=rxq1 NFRAMES=1000 ./run_dmac_sim.sh                       # DMAC alone, ideal upstream
FIFO=orig64 MODE=rxq0 REARM=36864 NFRAMES=1000 ./run_dmac_sim_rtl.sh   # real egress + real DMAC
FIFO=v4     MODE=rxq0 REARM=491520 NFRAMES=1000 ./run_dmac_sim_rtl.sh
# knobs: M, PERIOD, PREARM (arm phase), REARM, DRAIN, POLL, AXILAT, MASKUSER, JITTER_EVERY/JITTER_DELTA, CE_DIV
```
Outputs in `dmac_runs/` (DMAC alone) and `dmac_runs_rtl/` (real egress).

## Results — real egress RTL + real DMAC (`run_dmac_sim_rtl.sh`)

| run | FIFO | mode | knobs | PER | holes | words: offered / fifo_drop / accepted / written |
|---|---|---|---|---|---|---|
| rxq1 | orig64 | RXQ=1 | −M16 | **0.000 %** (992/992) | none | 191000 / 0 / 191000 / 190992 |
| rxq1_M32 | orig64 | RXQ=1 | −M32 | 0.000 % | none | same |
| rxq1_ph110 | orig64 | RXQ=1 | arm mid-frame | 0.000 % after arm | 191 words dropped ONCE at arm (the in-progress frame), sync wait 77k clk | 191000 / 191 / 190809 |
| rxq0 | orig64 | RXQ=0 | re-arm 20 µs (measured class) | 0.000 % | none; engine idle 2.95k clk per boundary, sync wait 14 clk | 191000 / 0 / 191000 |
| rxq0_rearm10k | orig64 | RXQ=0 | re-arm 100 µs | 0.000 % | none | |
| rxq0_rearm20k | orig64 | RXQ=0 | re-arm 200 µs | 0.000 % | none | |
| **rxq0_rearm30k** | orig64 | RXQ=0 | re-arm 300 µs | **5.787 %** (57/985) | **57 holes, ALL length 1, ALL at slot 0 of the transfer** (0.98 frame/transfer) | 191000 / 11078 / 179922 |
| rxq0_rearm40k | orig64 | RXQ=0 | re-arm 400 µs | 5.787 % | identical signature | |
| v4_rxq0_rearm40k | **v4 4096** | RXQ=0 | re-arm 400 µs | **0.000 %** | none | 191000 / 0 / 191000 |
| v4_rxq0_rearm400k | v4 4096 | RXQ=0 | re-arm 4 ms | 0.000 % | none | |
| v4_rxq1 | v4 4096 | RXQ=1 | | 0.000 % | none | |
| rxq1_jit50p | orig64 | RXQ=1 | every 50th frame 192 words | 14.9 % | holes 2..14 frames, ALWAYS starting at slot 0; junk slots from the slip to the transfer end | 191020 / 19 / 191001 |
| rxq1_jit50m | orig64 | RXQ=1 | every 50th frame 190 words | 19.8 % | same shape | 190980 / 3610 / 187370 |
| rxq1_ce2 / rxq0_ce2 | orig64 | both | clk_enable at 1/2 duty | 100 % junk | **accepted = 2 × offered: every word taken twice** (pins update only on enb, the DMAC samples every clk) | 191000 / 0 / 382000 |
| DMAC alone (`run_dmac_sim.sh`), all modes/depths/phases/M | — | — | | 0.000 % | none | |

Witness in every steady-state run: `blocked_cycles_waiting_for_sync = 0`, sync wait 14 clk (= SOF-prime guard 6 + delayMatch 4 + 4); handoff RXQ=1 = 0 (data_mover `active` never falls), RXQ=0 ≈ 2.95k clk (24 µs) with the 20 µs host model.

## Verdict against the pre-stated criteria

1. **"RXQ=1 loses exactly one frame per transfer boundary via SYNC_TRANSFER_START discard" — REFUTED.** In the real RTL `data_mover.v:114-116` `s_axi_ready = pending_burst & active & ~abort & (~needs_sync | s_axi_sync)`: the engine **holds tready LOW** while waiting for a frame start, it never consumes-and-discards. With exact 191-word frames and X_LENGTH = M·1528 the transfer boundary always lands on a frame boundary, the next head word carries `outFirst=1` (the FIFO presents it valid-independently), and both RX modes are lossless at any M and any arm phase. The queued handoff has zero idle cycles.
2. **RXQ=0 > RXQ=1 ordering — only above a threshold.** Loss appears when the engine's ready-low interval exceeds the 64-word FIFO (≈ 64 × 545 clk ≈ 280 µs, measured between 200 and 300 µs): the FIFO drops OLDEST words, the in-progress frame is destroyed, the engine re-syncs on the next frame start → **exactly one lost frame per transfer, always at slot 0, hole length 1** — this IS the silicon comb signature (bins '1'-dominant, transfer cadence). The host's measured re-arm class (~20 µs) is far below the threshold, so in the model RXQ=0 is lossless; a 300 µs+ gap (e.g. a host nap/scheduling stall at the boundary) produces it.
3. **The 4096-word FIFO (v4 RTL) absorbs ready-low gaps up to 4 ms → 0 loss.** Consistent with the mechanism above, **inconsistent with this morning's silicon A/B** (v5 image: 14.18/8.63 %, no gain). Therefore the silicon comb is NOT a FIFO-overflow-during-ready-low event and NOT a DMAC sync discard. The model reproduces the *signature* two ways (FIFO overflow, host gap) but neither survives the silicon evidence, so the mechanism sits in something this harness does not contain: the host/DDR side (slot reads vs. landed data, carve timing), the real serializer's frame word count (a word-count irregularity gives junk-to-end-of-transfer runs, not single holes — also ruled out by the bins), or a clock-enable/beat duplication (CE_DIV=2 shows total duplication, not 9 %).
4. **Option E (tuser masked after the first transfer) is NOT needed for the DMAC handoff** — the handoff is already lossless; masking tuser in RXQ=1 with the real RTL was not exercised further because criterion 1 failed (nothing to fix on that path). Do not build Option E on the strength of this sim.

## Sharp predictions for the hardware probe (v2 injector, witness counters)

- Continuous pacing (word_gap ≈ 535, gap = word_gap), RXQ=1, −M16: `acc_beats` per transfer = 3056, `acc_user` = 16, host sees 16 good frames → if the host still reports the comb, the loss is downstream of the DMAC's acceptance (DDR/host).
- If instead `acc_beats` < 3056 per transfer with `ovf` climbing, the gap between transfers is ≥ 280 µs on silicon (not the 20 µs class) — then the 4096 FIFO must have fixed it, which it did not → re-check that the v5 image actually had the 4096 FIFO in the datapath.
- Bursty pacing (v1 behaviour) stays lossless in all modes (already measured 08-18).

## Not done / caveats
- Captured-IQ stimulus (b) through the full modem netlist: not run (clean-stream verdicts made it unnecessary for the mechanism question; the modem-side word count per frame is the remaining unknown and is better measured by the probe's `acc_user` vs 0x104).
- Single clock domain; DDR always-ready; serializer emulated (tog/held-word contract from the RTL comments, not the real bit-level serializer).
- `ByteRxFifo_v4.v` was built in the egress as-is (it is the rxfifo4k drop-in; v5 differs only in the debug word on `ovf`).
