# TX byte-in plane — netlist reproduction (2026-08-28, off-rig sim track)

Harness (all in `jupiter_240k5_byte/rtl_sim/`; no rig interaction):
- Netlist: `s1_rtl_beatfix3` (the flashed lineage per `docs/evidence/NETLIST_PROVENANCE.md`; the probe images are that lineage) through `wrap_byte_bf2.v` (`wrap_byte_ce`, cadence 2, fixctl=0), internal loopback (`rx_input_select=0`), `tx_data_source=1`.
- `gen_txplane_frames.c` (links the daemon's `qpsk_frame.c`/`qpsk_seq.c`): idle len-0 keepalive frames and fill-1516 data frames byte-identical to the daemon (`qpsk_frame_encode`, PN pad, real CRC; whitening via `QPSK_WHITEN=1` exactly as the daemon), and the TGEN exact format (CRC constant). Daemon transfers = 385 words (3080 B: 1528-byte frame + zero pad, `byte_first` on word 0 — the MM2S/TLAST contract, `qpsk_tun.c:539-561`).
- `sim_byte_txplane.cpp` (+ `_taps.cpp` with `--public-flat-rw` for the ByteWordBuffer/ByteBitShifter internals): arrival models `cont` (source always valid, DUT ready paces), `rate R [J]` (one transfer released per 1/R frame periods + jitter), `gap G` (valid low for G clks after each transfer's last accepted word = inter-transfer silence at the input).
- `txplane_score.c`: port of `rx_seam_checker.v` (frame = user word + 190; magic `QK`, len ≤ 1516, CRC32 over 0..12+len−1 with the CRC field zeroed; `--dewhiten` mirrors `decode()`; `--tgen` accepts the constant). Window: first 20 good frames skipped, trailing zero frames after the source ends excluded (`--skipgood/--nf`).
- Cost: ~15 k clk/s per sim (both -O3 and flat-rw builds); one 385-word transfer is consumed per **98,664 clks** (measured in `r_src.txt`), so 400 frames ≈ 40 M clks ≈ 45 min alone, ~1.8 h with 10–16 sims sharing 12 cores. Second node HDL-dev-2 (10.0.0.11) staged at `~/txplane` (same Verilator 5.020) for the fine threshold sweep; results are pulled back into `txplane_runs/hdldev2/`.
- Commands: `./run_txplane.sh <cell> <content> <whiten> <nwf> <NF> <mode> [p1 p2]` (see `txplane_runs/CELL_MAP.txt`); raw per-cell outputs in `txplane_runs/<cell>/` (`r_rxw.txt`, `r_src.txt`, `r_ev.txt`, `score.txt`).

## Matrix — content × arrival (`txplane_runs/MATRIX1.txt`, 400 frames per cell unless noted)

| cell | content | whitening | words/frame | arrival | scored | crc_ok | crc_fail | **magic_bad** | short/orphan | seq lost |
|---|---|---|---|---|---|---|---|---|---|---|
| c01 | idle len0 (Test A content) | off | 385 | line-rate continuous | 370 | 370 | 0 | **0 (0.00 %)** | 0/0 | 0 |
| c06 | fill 1516 | off | 385 | continuous | 370 | 370 | 0 | **0** | 0/0 | 0 |
| c07 | idle len0 | ON | 385 | continuous | 142 (partial, rerun to 400 in progress) | 142 | 0 | **0** | 0/0 | 0 |
| c08 | fill 1516 | ON | 385 | continuous | 146 (partial, rerun in progress) | 146 | 0 | **0** | 0/0 | 0 |
| c05 | idle len0 | off | 385 | rate 1.02× (faster than line) | 146 (partial) | 146 | 0 | **0** | 0/0 | 0 |
| c04 | idle len0 | off | 385 | rate 1.00× + jitter ≤ 0.2 frame | 144 (partial) | 144 | 0 | **0** | 0/0 | 0 |
| c02 | idle len0 | off | 385 | rate 0.98× (underrun every ~50 frames) | 144 (partial) | 140 | 0 | **4 (2.6 %)** | 0/0 | — |
| **c03** | idle len0 | off | 385 | **rate 0.95× (underrun every ~20 frames)** | 370 | 350 | 0 | **20 (5.4 %)** — exactly one per underrun | 0/0 | 3 |
| c09 | TGEN exact format | off | **191** | continuous | 362 | 112 | 0 | **250 (61.7 %)** | 0/109 orphan words | ~half |
| c10 | TGEN exact format | off | **191** | gap 100 k clk (~50 % duty, Test-B-like) | 361 | 180 | 0 | **181 (44.7 %)** | 0/109 | ~half |

## Inter-transfer gap sweep (`txplane_runs/GAPS.txt`, 40 frames, original 16-word ByteWordBuffer vs 64-word candidate)

| gap after each transfer (clk @122.88 MHz) | original (g) | candidate 64-deep (f) |
|---|---|---|
| 2000 (16 µs) | **clean** (22/22) | — |
| 3500 (28 µs) | every transfer corrupted (11 bad / 11 ok / half the seqs lost) | — |
| 4500 (37 µs) | every transfer corrupted | **clean** (22/22) |
| 6000 (49 µs) | every transfer corrupted | **clean** |
| 8000 (65 µs) | every transfer corrupted | **clean** |
| 15000 (122 µs) | — | 8 bad / 14 ok (marginal) |
| 20000 (163 µs) | every transfer corrupted | every transfer corrupted |
Fine threshold sweep (orig 2250–3250, candidate 10 k–14 k) running on HDL-dev-2 → `txplane_runs/hdldev2/GAPS_FINE.txt`.

## What the netlist says

1. **Reproduced, and the mechanism is named.** With the daemon's own frame format and continuous line-rate arrival the TX byte-in plane is clean (0/370, both contents, whitened or not). Garbage-header frames appear **only when the ByteWordBuffer runs dry**: every tap event is `ALIGNLOSS: buf=0 avail=0 first=0 bitIdx=64 start=0` — the ByteBitShifter needs its next word mid-frame, the 16-entry buffer is empty, it drops to `aligned=0` and shifts zeros for the rest of that air frame (the all-zero frame the checker classifies as magic_bad); the next `start` re-aligns on the waiting `First` word. One bad frame per underrun event (c03: 20 underruns → 20 bad; c02 partial: 3 → 4), and with a gap on every transfer, every frame (g2–g6).
   - **Hypothesis test — 16-word ByteWordBuffer sizing: CONFIRMED as the limiting element.** Effective cover at the input is between 2000 and 3500 clk (16–28 µs; the `readyNext = count ≤ 6` threshold with the 8-deep ready history means the buffer holds only ~7–14 words when the source is back-pressured, so cover is *less* than 16 × 256 clk = 33 µs). The 64-deep copy (`s1_rtl_txfix/.../ByteWordBuffer.v`, threshold 54) extends cover to ≥ 8000 clk and < 15000 clk (65–120 µs), and A/Bs clean on the identical stimuli that break the original.
   - **wordFirst framing: NOT implicated** — never a `start && avail && !first` event, no short frames, no orphan words in any 385-word cell.
   - **Underrun-filler transition logic: NOT implicated as a separate defect** — the "filler" is exactly the unaligned zero-shift state above; it does not corrupt neighbouring frames beyond the frame in which the underrun occurred (c02/c03: no extra bad frames beyond one per event).
2. **Content vs arrival: arrival-dependent only.** Whitened vs unwhitened, idle vs fill: identical (0 %). The corruption fraction is a pure function of how often the source lets the input go silent for > ~20 µs: c03 5.4 % at 1 underrun/20 frames reproduces hardware Test A's 5.13 % — i.e. the hardware daemon's MM2S delivery leaves a > 2–3 k clk hole once every ~20 transfers (host re-arm latency / pacing jitter), which the sim can only assume, not measure.
3. **Hardware Test B was an instrument artefact, not evidence.** The fabric TGEN emits 191-word frames with `first` every 191 words; the DUT consumes 385 words per air frame, so two TGEN frames are packed per air frame, half the seqs vanish, orphan words appear, and 45–62 % of headers are garbage in sim (c10/c09) — matching the hardware 46.6 %/68.6 %. Test B says nothing about host vs fabric sources; strike it from the attribution.

## Budget attribution — changed, say so plainly

- "≈5 % made in the TX byte plane with no RF": **confirmed and now mechanistic** — ByteWordBuffer underrun on inter-transfer input silence > ~20 µs; each event costs exactly one air frame (garbage header at the decoder output). The host-side MM2S delivery timing is the *trigger*; the 16-word buffer is the *defect*.
- "~4 pp more over the air": **unchanged by this work** (not modelled; the sim has no RF). Note that 146's TX plane has the same defect, so the over-air forward number contains 146's own underrun rate plus RF.
- "5.9 % in the RX byte plane, RXQ=0 only": **unchanged** (RX side, not exercised here).
- "nothing in DMA/DDR/host": **unchanged for the RX delivery plane**; on the TX side the host's transfer cadence is what exposes the buffer defect, so "host is not the source" should read "host timing is the trigger, fabric buffer is the defect".
- Test B's 47–69 % and the inference "fabric source worse than daemon" are **withdrawn** (format mismatch artefact).

## Candidate fix (sim-only, NOT built)
`s1_rtl_txfix/hdlsrc/commhdlQPSKTxRxLoopback/ByteWordBuffer.v`: depth 16 → 64, ready threshold 6 → 54 (same 8-deep ready history). A/B on identical stimuli: gaps 4500/6000/8000 clk go from every-frame-corrupt to 0/22; the cover limit moves to ~12–15 k clk. Whether 64 is enough depends on the real host gap distribution (unmeasured); 256 would cover ~0.5 ms. Alternative/complement: keep the MM2S engine fed (queued TX transfers) so the input never idles. No Vivado build started, per directive.

## Pending (results land automatically)
- nemo: c02/c04/c05/c07/c08 reruns to 400 frames → appended to `txplane_runs/MATRIX1.txt` (units `txplane-c*`).
- HDL-dev-2: fine gap threshold sweep h1–h5 (orig 2250–3250 clk) and k1–k3 (candidate 10–14 k clk) → pulled every 5 min into `txplane_runs/hdldev2/GAPS_FINE.txt` (unit `txplane-pull-*`).
