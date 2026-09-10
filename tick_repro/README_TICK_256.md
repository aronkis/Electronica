# Reproducing the 256-sample (+32 symbol) insertion in Simulink

This package hands you everything to repeat, in Simulink, the board-148 device
tick that corrupts the 240 ksym/s forward link: a **deterministic +256-sample
(+32-symbol) insertion into the consumed RX sample stream** at the ADRV9002 BBDC
tracking-cal cadence (~1.5 s). See `two_jup/ERROR_TAXONOMY.md` for the full
attribution.

## The one thing to understand first

**The insertion is NOT in the captured air samples.** The tick enters *below
RTL*, at the fork between the capture net (`Receiver.v: debugI1 = dataInI`) and
the datapath that feeds the AGC — so a raw capture replays **bit-perfect**, while
the live receiver mangles the same instants. That is why you cannot reproduce it
by replaying a capture: **you inject the splice yourself** and watch the receiver
react. The netlist proof of this (`k5_240/gen_hdlD2.py`, `splice_score.m`)
already shows a +256-sample splice → exactly 2 lost frames per transition,
content-independent.

## What the tick does to the receiver (the observable to reproduce)

At each insertion the **Peak Search** latched offset steps **101 → 133
(+32 symbols = 256 samples @ sps=8)**, holds ~0.165 s (~35 frames — Timing
Adjust re-syncs at 133 and frames decode there), then steps back −32. The damage
is **exactly 2 frames** per +32 transition (the straddler + one casualty); the
−32 recovery is benign. Timing Adjust arms on the reported offset and fires sync
only when its frame-position counter *equals* the accepted offset, so a displaced
offset misses the compare for 1–3 frames → downstream starves → the episode.

Your Simulink testbench should reproduce: **Peak Search offset stepping +32 at
the splice, and Timing Adjust missing sync for ~2 frames.**

## Modem state (set the Simulink RX up with exactly these)

| Quantity | Value | Source |
|---|---|---|
| Symbol rate `Rsym` | 240 000 sym/s | `evm/evm_config_240k.m` |
| Samples/symbol `sps` | 8 | `commhdlQPSKTxRxParameters` |
| Sample rate `Fs` | 1.92 MHz | `Rsym*sps` |
| RRC | `rcosdesign(0.5, 4, 8)` (β=0.5, span=4) | config |
| Preamble | 13-bit Barker, π/4-Gray QPSK | `commhdlQPSKTxRxParameters.preambleSymbols` |
| `DataBitsPerPacket` | 2240 | config |
| Frame length | **1133 symbols = 9064 samples** | `NPreambleSym + 2240/2` |
| FEC | K=5 conv, gen `[35 23]` octal, rate-1/2, +4 tail | `frame_config_k5.m` |
| Interleaver | block 136×16 | `frame_config_k5.m` |
| **Insertion** | **+256 samples (= +32 symbols) at the fork** | tick mechanism |
| Insertion content | statistically normal — repeat / noise / phase-rot all reproduce | netlist splice battery (P1E) |
| Cadence (live) | ~1.5 s (BBDC cal) — irrelevant in sim; inject once | ERROR_TAXONOMY |

### Hardware/session state of the reference capture (`fwd1`)
- Board **148 RX**, forward link **146 TX @ 2.000 GHz → 148 RX @ 2.000 GHz**
  (reverse LO 1.900 GHz). Image `dcf5c5fb29e6509723b35f476a0a1bfa`.
- `rx_input_select` (0x114) = 1 (air), `tx_data_source` (0x158) per capture,
  arm `rstcs_end` = 8400 clk (the proven replay arm pulse).

## Files in this package

- **`README_TICK_256.md`** — this file.
- **Raw capture (the clean air stream to splice):**
  `../two_jup/evmcap/fwd1/raw.iq` — int16 interleaved I,Q, **4 000 000 complex
  samples @ 1.92 Msps**, 148 RX forward, air-clean. (Not copied here to avoid
  duplicating 16 MB — point the testbench at it.)
- **`make_spliced_iq.m`** — inserts +256 samples at a chosen sample offset into a
  raw `.iq`, writes the spliced `.iq`. (Pure MATLAB; mirrors the validated
  `jupiter_240k5_byte/rtl_sim/iq_perturb.py --insert` logic.)
- **`tb_tick_256_k5.m`** — the Simulink testbench, two stages:
  - **STAGE A** (self-contained, **validated on real data**): synthesizes a
    clean QPSK frame stream, inserts **+32 symbols** at a frame boundary, and
    recovers frame starts by differential-Barker correlation → an unambiguous
    **+32-symbol frame-spacing step**. This is the cause of the tick. *(Note: a
    tracking symbol synchronizer absorbs the discontinuity and does NOT show the
    clean step — which is why the RTL's specific Interpolation-Control +
    Peak-Search architecture is needed to see the receiver's mis-sync reaction.
    The RTL timing recovery passes the sample-level +256 to the PD as a
    +32-symbol offset — so a +32-symbol insertion is the faithful abstraction,
    exactly what `k5_240/pd_harness_k5.m` replayed from hardware.)*
  - **STAGE B** (needs a P1D-assembled loopback model loaded): drives the **real
    RTL Preamble Detector** — extracted with `pd_harness_k5.m` mechanics — with
    the baseline vs +32-inserted symbol streams, so the RTL PD reproduces the
    Peak-Search offset step in Simulink. **Authored against the proven pattern;
    run it in your MATLAB/Simulink. If your PD build's outport names differ,
    adjust the marked "OFFSET OUTPORT" selector.**
- **Golden reference for scoring:** `jupiter_240k5_byte/rtl_sim/rx_words_golden.hex`
  (ROM BIST words) or the built-in `-B` seed `0x1a5` reference.

## Two reproduction paths

1. **Proven netlist path (cross-check, already validated):**
   ```
   cd jupiter_240k5_byte/rtl_sim
   ./build_replay_iq.sh                      # once
   ./replay_capture.sh ../../two_jup/evmcap/fwd1/raw.iq      # baseline: decodes clean
   matlab -batch "make_spliced_iq('../../two_jup/evmcap/fwd1/raw.iq','/tmp/fwd1_spliced.iq',2000000,256,'repeat')"
   ./replay_capture.sh /tmp/fwd1_spliced.iq  # spliced: 2 lost frames at the transition
   ```
   The verdict diff between the two runs is the tick, reproduced bit-true.

2. **Simulink path (this deliverable, for interactive debugging):**
   ```
   matlab
   >> make_spliced_iq('two_jup/evmcap/fwd1/raw.iq','/tmp/fwd1_spliced.iq',2000000,256,'repeat')
   >> tb_tick_256_k5   % builds the harness, runs baseline+spliced, plots offset step
   ```
   Open the generated `tb_tick_256` model to step through the Preamble Detector /
   Timing Adjust and watch the +32 offset displacement break sync.

## Splice parameters that reproduce (from the netlist battery)

`make_spliced_iq(raw, out, n0, 256, mode)` with `n0` on a frame boundary or
mid-frame; `mode ∈ {repeat, noise, phase90, zeros}` — all four reproduce the
2-frame loss (content-independent, as the netlist battery proved). Use
`n0 = 2000000` (the sample the netlist battery spliced at) to match the published
result exactly.
