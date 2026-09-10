# In-fabric programmable traffic generator (`qpsk_traffic_gen`) — design

2026-08-17. Approved through brainstorming; supersedes nothing — Layer B
(`two_jup/layerb_run.sh`) remains the scoring methodology and is reused, not replaced.

## Problem

Layer B proved the batched RX DMA innocent in loopback (buckets 0/0/0/1, integrity check
passed) but its stimulus was the host TX feeder — which under-fed ~50 %, could not be
paced, and polluted every rate-dependent question. The campaign needs a stimulus whose
**rate, inter-frame gap, and payload length are exact, swept from software, and
independent of host scheduling** — driven through the *real* TX byte path on hardware,
so we can measure where the system breaks instead of inferring it. The Layer-A ROM is
fixed-function and out of scope by decision.

## Decisions taken (operator, during brainstorming)

1. Generator lives **in fabric**, not in the host daemon.
2. "Packet length" = **payload fill N within the fixed 1528 B frame** (air geometry is
   netlist-fixed; a true variable frame needs a rebuild per geometry and is out of scope).
3. Gap is **fixed per run, swept across runs** (no per-frame jitter mode in v1; the open
   fault is periodic, and deliberate alignment beats accidental aliasing).
4. Scoring is **host-side only, reusing the Layer B `-S` scorer** (fabric RX taps are
   Track E's observatory, explicitly a separate project).
5. **No hardware CRC** (Approach 1): the scorer consumes pre-CRC raw slices via
   `rx_raw_tap`, so a constant CRC field costs nothing today. A CRC engine is a named
   bolt-on if the production `-G` accept path ever needs to be driven from the generator.

## Architecture

One platform-side Verilog module, **`qpsk_traffic_gen`**, spliced in the BD between
`byte_breakout` (AXIS→pins shim fed by `tx_byte_dma`) and the DUT's byte-TX input pins —
the TX-direction mirror of the skid splice, inserted by the proven
`patch_complete_tcl.py` pattern into a fresh lean-lineage build. **The DUT netlist is
untouched**: no MATLAB regen, no checkhdl, no slx hazards, and the DCP rail-census gate
remains comparable to lean (PARITY_OK is expected and required).

Modes:
- **Pass-through (reset default):** all pins combinationally wired through; the image is
  behavior-identical to lean until explicitly enabled.
- **Generate:** module drives `{byte_data, byte_valid, byte_first}` into the DUT under
  the DUT's real `byte_ready` handshake, and holds `ready` low toward `byte_breakout`
  (host TX submissions stall harmlessly at the DMA).

Everything downstream is the real path: ByteWordBuffer → in-fabric FEC encode →
modulation → loopback (`0x114=0`) or air → RX → byte plane → DMA → host scorer.

Clock domain: the byte pins' IPCORE_CLK (8 ns). Frame time ≈ 803 µs ≈ 100.4 k clks;
`gap[31:0]` spans 0 … ~34 s.

## Register interface

One new dual-channel `axi_gpio` (all-outputs) at **`0x9D400000`**, attached by growing
the existing CPU interconnect (precedent: `matlab_processors.tcl` NUM_MI growth).

| reg | field | meaning |
|---|---|---|
| `0x9D400000` (ch1) | `[0]` enable; `[15:4]` fill_len N bytes (0–1516, clamped in RTL); others reserved-0 | control |
| `0x9D400008` (ch2) | `gap[31:0]` | clks from frame-end to next frame-start; 0 = max offered load |

Properties: `axi_gpio` outputs **read back** → every sweep point is verified by readback
(the write-only `0x158` lesson). Seq resets to 1 on each enable rising edge; no seq
readback (the scorer spans by seq).

## Frame content and FSM

- Header: byte-identical to `qpsk_frame_build()`'s layout per `host_app_k5/qpsk_frame.h`
  — magic `0x51 0x4B` ("QK") at [0..1], length at [2..3], seq at [4..7]; the CRC field is
  a fixed constant (frames intentionally fail the `-G` CRC gate; the `-S` scorer is
  pre-CRC).
- Payload: N bytes of xorshift32 PN seeded from seq, **bit-compatible with
  `qpsk_seq_payload()`** (same state update, same byte-extraction order); zero-pad to
  1528 B.
- FSM: IDLE → EMIT (191 × 64-bit words under `ready` handshake, `byte_first` on word 0)
  → GAP (count `gap` clks) → EMIT … Enable deassertion mid-frame **completes the frame
  before stopping** — no partial frames, ever.
- `gap=0` = maximum offered load; the TX chain's own flow control becomes the limiter,
  and that saturation boundary is itself a measured break-point.

## Host-side addition

**`QPSK_SEQ_RXONLY=1`**: `-S` mode skips TX submits and acts as a pure scorer (a few
lines in `qpsk_seq.c` / `qpsk_tun.c`). Removes the only daemon interaction hazard: in
loopback the same board scores while the generator owns TX, and `-S`'s TX would
otherwise push against the intentionally-stalled path.

## Sweep harness

**`two_jup/tgen_sweep.sh`** walks a `{fill, gap}` grid. Per point:
write regs → **readback-verify** → enable → dwell (default 60 s) → disable → bank one
CSV row: `{fill, gap, offered_rate, SEQRX ok/lost/biterr, SEQDMA buckets, Δ0x104,
Δ0x108, Δ0x1C0}` (fabric deltas via the reset-aware idiom). Scoring: `-S` with
`QPSK_SEQ_RXONLY=1`, restarted per point with `-d dwell` for a clean per-point SEQRX
summary. Loopback is primary; the harness is not loopback-specific and drives air runs
unchanged.

Methodology:
1. fill=1516, walk gap downward → the knee where delivered diverges from offered (or
   buckets / `0x1C0`-freeze fire) is the rate break-point.
2. hold a safe gap, walk fill 1516→1 → length sensitivity.
3. Any point that reproduces the byte-plane wedge on demand is banked as a scripted
   repro — this harness doubles as the wedge-reproduction instrument.

## Safety rails

- enable=0 at reset; production-equivalent until explicitly enabled.
- Per-point health gate asserts framesync **and `0x1C0` advance** (sync alone lies —
  2026-08-15 lesson).
- Harness exit path: enable=0, daemons restored, watchdogs verified up.
- Standard flash rails; e49c011b rollback stays banked on-board.

## Build and validation order

1. **Pre-build TB (the 3 h de-risk):** iverilog TB drives the module and dumps emitted
   frames; a ~20-line C utility linking the actual `qpsk_seq.c`/`qpsk_frame.h` emits
   golden frames; byte-compare. **Positive control:** corrupt one byte in a TB frame and
   confirm the compare flags it. No Vivado build until byte-identical.
2. **Build:** lean recipe (`QPSK_LEAN=1 QPSK_FRAME=f1536 QPSK_SPS=4 QPSK_FRAMESTAT=1`),
   splice with a `TGEN_WIRE_OK` marker, timing gate, DCP rail census (PARITY_OK vs lean
   required).
3. **On silicon, strictly ordered:** flash under rails → **pass-through equivalence**
   (normal loopback PER run must match the lean baseline before generate mode is ever
   enabled) → generate-mode smoke (large gap, fill=1516, expect ~100 % ok at low rate)
   → sweeps.

## Out of scope (named, so it does not creep)

Per-frame gap jitter (LFSR mode); hardware CRC; fabric RX seq-checker (Track E);
variable air-frame geometry; 146 instrumentation (frozen by standing decision).

## Deliverables

`jupiter_240k5_byte/rtl_sim/qpsk_traffic_gen.v` (module + TB) · golden-vector C utility ·
`two_jup/skidfix/patch_tgen_tcl.py` (splice) · `two_jup/skidfix/run_tgen_build.sh`
(driver, lean recipe + gates) · `QPSK_SEQ_RXONLY` host patch · `two_jup/tgen_sweep.sh` ·
results doc `two_jup/TGEN_SWEEP.md` once data exists.
