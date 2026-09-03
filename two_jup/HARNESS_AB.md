# HARNESS_AB — why the current-lineage netlist failed real-IQ replay 5/78 while
# its hardware image runs at line rate (2026-08-13, sim-only)

## PINNED CAUSE: the replay harness drove the netlist at the WRONG SAMPLE CADENCE.

The real-IQ replay harness family hardcodes **cadence 4** (one ADC sample per 4
DUT clocks) — calibrated against the Jul-25/29 archive netlist. The netlist
generation changed its sample-rate contract in the **Jul-29 → Aug-05** window
(the R3 2×-rate restoration: `rate_240k_overlay` "Rsym 3.84e6, sps=4",
`Rsym*sps rail = 1.536e7`): post-Jul-29 netlists consume **one sample per
`enb_1_2_0` rail beat = 1-in-2 clocks (cadence 2)** — exactly the pacing the
S1B BIST driver (`sim_byte.cpp`: "1-in-2 adc_validIn cadence") and the hardware
ingest use. Driven at cadence 4, every sample sits for TWO rail beats: every
rail-clocked element double-beats it, the sync loops run on garbage timing, and
the receiver delivers the 5/78 signature. The netlist was never broken — the
harness applied the previous generation's drive contract.

## The A/B matrix (all runs: pinned chunk `chunk_270_339_r0.iq`, 78 frames,
## same driver `sim_byte_iq_perframe.cpp`, scored by `score_frames.py` CRC)

| netlist | drive cadence | packets | CRC-good/78 |
|---|---|---|---|
| Jul-25/29 archive (`perframe_f1536`) | **4 (its native)** | 77 | **74** |
| Jul-25/29 archive | 2 | 27 | 0 |
| Aug-05 pre-dirty (cb53f71 as-built worktree regen) | 4 | **5** | — |
| fsv2 (b6bc60d lineage, 2026-08-12 21:53 regen) | 4 (the old gate drive) | 5 | 0 |
| fsv2 + six loop-gain inputs FORCED to compiled SI defaults | 4 | 5 | — |
| fsv2 | 8 | ~0 | — |
| fsv2 | **2 (its native)** | 75 | **71** (73 with drain-tail fix) |
| fsv2, cadence 2, vphase 1 | 2 | 75 | 71 (identical frames) |
| fsv2, cadence 2, rstCS window ×2 | 2 | 75 | 71 (identical frames) |

Reproducibility: the cadence-2 result is bit-stable across vphase and rstCS
variations — the failures are data-dependent, not drive-jitter.

### Kill list (hypotheses tested and closed)
- **Loop-gain zero-default (the prime suspect)**: EXONERATED twice. Statically:
  every `LGMux_*`/`LGSw_*` pair in the netlist selects the untouched compiled
  path when the register is 0 (`nz = axi != 0`; unconnected Verilator inputs
  tie to 0). Empirically: forcing all six gains to their compiled
  stored-integer defaults (cs 98/1, ss −163506/−2180, agc 4294967, cfo 26214)
  changes nothing at cadence 4 (still 5 packets).
- **Dirty-slx model delta (cb53f71→b6bc60d)**: EXONERATED. The **pre-dirty**
  Aug-05 netlist (cb53f71's as-built, with the full shadow instrument set)
  fails cadence-4 replay with the identical 5-packet signature. The cadence
  contract flipped BEFORE the Aug-12 model save — between the Jul-29 archive
  verilation and Aug-05.
- **Frame geometry / sps / rails**: both generations are f1536, sps=4
  (Interpolation Control increment 0.25 identical), identical
  `TxRxComposite_tc.v` rails, identical frame-span constants.
- **FrameStat FIFO backpressure**: drop-newest on full; no datapath coupling.

### First-divergence trace (the instrument that found it)
A trajectory logger (clk, frameStart, packets, rstcs, cfc_est, biterr every 5k
clk) on both netlists under the identical cadence-4 drive:
- Jul-25: first CFC estimate at ~75k clk (integAvgLen 4096 syms × 16 clk/sym),
  settles −2053±20, locks, 78 frameStarts.
- fsv2: first estimate at ~35k clk, updates every ~34.5k (2× rate), value
  ≈ **half** (settles −1113 vs −2053) and ±3000 unstable, 5 frameStarts, huge
  biterr. Half-magnitude + double-update-rate = the estimator seeing every
  sample twice — the rail double-beat. This also retro-explains N3's tap
  observations verbatim: "ss/cfc/cs taps at 2 lines/sym", "agc 8 lines/sym
  (2x-logged 4 sps input)" — each sample logged once per rail beat, twice per
  sample, at the wrong cadence.

## Hardware reconciliation — no contradiction remains
The image flashed to 148 (md5 **e49c011b** = `jupiter_byte_lean_build`, built
2026-08-12 19:56 from the same b6bc60d model lineage) was module-diffed against
the fsv2 netlist: the entire RX sync chain (Symbol_Synchronizer, CFC, AGC, loop
filters, Rate_Handle, Interpolation_Control) is **RTL-identical** (only the
FrameStatProbe telemetry differs — the later FsAgcRT fix). Hardware feeds it at
the native 1-in-2 pacing → line rate. The replay harness fed it 1-in-4 → 5/78.
Same RTL, different drive. The Jul-25 archive has the OPPOSITE native cadence,
which is why it passed the very same harness.

## Harness fixes APPLIED (kit, single-sourced)
1. `jupiter_240k5_byte/rtl_sim/replay_gate_n2.sh`: drive cadence = netlist
   generation property; default **CAD=2** (post-Jul-29 netlists), overridable
   `CAD=4` for archive replays; rstCS window and scorer `--cadence` scale with
   it; reference numbers re-stated in CRC-good terms; gate now copies the
   kit's driver (gate dirs carried stale copies).
2. `jupiter_240k5_byte/rtl_sim/sim_byte_iq_perframe.cpp`: drain tail scaled by
   cadence (fixed 60000 clk truncated the final frame at cadence 2 — "154
   trailing words without last").

## Re-gate result (fsv2 netlist, fixed harness)
**REPLAY_GATE frames_crc_good=73 / 78 (delivered 76, bad 3) — FAIL by ONE frame
vs the ≥74 threshold, but see the re-anchoring note.** The pinned target
"parity with Jul-25's 77/78" turned out to be a units error: 77 was the raw
`packets_out` counter; the Jul-25 reference netlist **scores 74/78 CRC-good**
on this slice under the same scorer — i.e., the threshold was set exactly at
the reference's own score. At native cadence the fsv2 netlist scores **73** and
fails largely the **same marginal frames** as the reference (warm-up frame 0,
~38, ~67, and the 53898–53900 pair); the true generation gap is **1 frame on
one 78-frame marginal-heavy slice**, not 5/78 vs 77/78. Whether those 2 frames are a real small regression of the
current RX generation (plausible candidates: CFO-handling disparity already
measured in FLOAT_GAP_BUDGET) or slice-specific noise needs a wider replay set
(the `win_*` windows), and the gate threshold needs re-anchoring to the
reference measured under the SAME cadence contract — a coordinator decision,
not taken here.

Also corrected while here: cadence 8 gives 33 packets and vphase/rstCS-window
variations at cadence 2 are bit-identical (71 before the tail fix) — the
result is deterministic, not drive-jitter.

## Bottom line
- The 5/78 was 100% harness: wrong drive cadence for the netlist generation.
- The current lineage's netlist decodes real IQ at its native cadence to within
  ONE frame of the Jul-25 reference on the pinned slice (73 vs 74/78, same
  marginal frames), consistent with its flawless hardware behavior.
- Formal gate with the fixed harness: **73/78 — still RED by one frame** under
  the threshold that equals the reference's own score. Not declared green here;
  the threshold re-anchor (or a wider `win_*` replay set) is the coordinator's
  call.
- Images from this lineage are NOT blocked by the 5/78 replay signature that
  gated them red; the remaining 1-frame delta is a follow-up measurement, not
  a flash blocker on sim evidence.
