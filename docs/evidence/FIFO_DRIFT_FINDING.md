> Evidence note, moved verbatim from `jupiter_240k5_byte/FIFO_DRIFT_FINDING.md` on 2026-09-09.

# Follow-up: Bit Packetizer "Data Bits FIFO" slow drift (pre-existing, sps-independent)

Found during Task A3 (sps=4 rate rung). **Not introduced by A3** — it is a property of the
stock/shipped Bit Packetizer and is present at sps=8 too.

## Symptom
`sim_byte_gate_k5` at the full `T=0.030` s runs ~100 frames at sps=4 (frame period 295 us)
and trips the sim-only assertion
`.../Transmitter/QPSK Tx/Bit Packetizer/Data Bits FIFO/No HDL/No HDL/Assertion`
at `t = 0.0253751 s` = **frame ~86**. sps=8 in the same `T` runs only ~50 frames
(frame period 590 us) and never reaches it, which is why the historical sps=8 gate is green.

## Why it is a slow drift, not a rate error (verified on the compiled sps=4 model)
- `SamplesPerSymbol` resolves to 4 at the Bit Packetizer; dataReady `CountMax` = 1; the
  HDL Counter runs at 1/15.36e6. So the producer pace is correct and, with the modulator
  draining 2 bits/symbol at Rsym=3.84e6, **write rate == read rate = 7.68e6 bit/s**.
- The in-fabric FEC Tx encoder is beat-aligned to the same dataReady enable as the ROM
  message generator (`fec_tx_encoder_overlay_k5`), so the byte path and ROM path fill the
  FIFO at that identical pace.

## The arithmetic (sps-independent)
Per frame = 1133 symbols = 13 preamble + 1120 payload symbols.
- dataReady fires every `sps/2` rail beats; a frame is `1133*sps` rail beats, so
  **enables/frame = 1133*sps / (sps/2) = 2266** — the SAME at every sps.
- payload bits consumed from the FIFO per frame = **2240** (13-symbol preamble is sourced
  separately and does NOT read the FIFO).
- Net **+26 enables/frame** occur during the 13-symbol preamble window
  (13*sps / (sps/2) = 26). With a continuously-ready producer these become 26 written-ahead
  bits/frame that are not yet drained, so the fill creeps up ~26 bits/frame.
- FIFO depth ~ one frame (~2240 bits): **2240 / 26 ≈ 86 frames** → matches the observed
  assertion frame exactly. Because 2266 and 26 are sps-independent, the overflow frame
  number is the same at sps=4 and sps=8.

## Why the shipped k5 HARDWARE link runs for hours unaffected (best hypothesis)
The fill governor differs between the sim harness and the real system. The model harness's
byte source (`sim_byte_gate` `ByteSrc`) is **always ready** — it presents a new word on
every `byte_ready`, so the producer never stalls and the +26/frame lead accumulates
monotonically. The real byte-DMA source has **gaps / idle frames** (host backpressure, the
DMA not continuously streaming): during those idles the producer stalls while the modulator
keeps draining, so the FIFO flushes and the accumulated lead resets before it can reach the
~86-frame ceiling. Net: continuous-feed sim accumulates; gappy real DMA self-flushes.

## Implications / action for the follow-up owner
- The A3 gate normalizes to a comparable **frame count** per rung (sim_byte_gate `T` is
  sps-aware: sps=8 stays 0.030 s, sps=4 -> ~0.0148 s, both ~50 frames). This is the brief's
  sanctioned reduced-frame-count mechanism and is sufficient to validate the sps mechanics.
- **Before trusting long continuous runs in HW** (especially f1536's larger frames, which
  change the 2240/2266 numbers), verify the hypothesis: either (a) confirm the real DMA has
  idle gaps that flush the FIFO, or (b) add a proper fill governor / deepen the FIFO / gate
  the producer on FIFO-not-full so the +26/frame lead cannot accumulate under a
  continuous feed. A back-to-back continuous-feed HW soak (no idle frames) would reproduce
  the sim behavior if the hypothesis holds.
- To reproduce in sim: run `sim_byte_gate_k5` with `setenv('BYTEGATE_T','0.030')` at sps=4
  (100 frames) -> asserts ~frame 86; at `0.015` (~50 frames) -> passes.
