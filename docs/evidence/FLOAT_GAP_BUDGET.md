> Evidence ledger, moved verbatim from `two_jup/FLOAT_GAP_BUDGET.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# FLOAT_GAP_BUDGET — per-stage fixed-vs-float margin budget at R3 (f1536)

Track N3 of the 2026-08-12 overnight plan. "Meet floating point performance"
needs a budget, not a vibe: this quantifies, stage by stage, where the
fixed-point f1536 receiver loses EVM margin relative to the float front end's
intrinsic floor on the SAME healthy captures.

**Headline: on 2 of 3 healthy captures the fixed-point chain BEATS the float
reference (by 0.1–2.2 dB); on the third (evm_swap_B) it is ~2.2–2.5 dB worse,
and that loss lives in the front end's CFO handling, not in any DSP stage's
quantization. The internal per-stage quantization budget totals only ~0.65 pp
EVM (quadrature) from AGC output to recovered constellation.**

## Method

Hybrid decode ladder (the `k5_240/hybrid_ladder_k5.m` method — the one that
found the 307 poison — ported to f1536 geometry and scored in EVM instead of
BER):

- **Fixed leg:** `rtl_sim/wrap_byte_taps.v` + `sim_byte_taps.cpp` verilated
  against the **Jul 25 f1536 netlist** (preserved at
  `.claude/worktrees/txmux-localize/jupiter_240k5_byte/s1_rtl_f1536/hdlsrc`),
  binary `rtl_sim/obj_byte_taps_f1536_jul25/Vwrap_byte_taps`. This netlist is
  hardware-validated by the tap_replay_study campaign (77/78 frames on
  `chunk_270_339_r0.iq`); the freshly built `obj_byte_taps_f1536` is NOT
  usable — see Side finding. Drive identical to the campaign: cadence=4,
  vphase=0, rstcs_end=8400, skip=0, dumpsamp=1.
- **Float leg / remainder:** `bs_front_end.m` mechanics (RRC MF ->
  comm.SymbolSynchronizer Gardner -> 4th-power + preamble-refine CFO ->
  comm.CarrierSynchronizer BnT=0.005 -> differential-Barker frame detect ->
  per-frame preamble derotation -> `evm_metrics` RMS EVM), config
  `evm/evm_config_1536k.m`. Implementation:
  `two_jup/floatgap_n3/ladder_f1536.m` (+ `run_all_ladders.m`, `budget.py`).
- **Ladder (direct output comparison variant):** each rung keeps the fixed
  chain up to a stage tap and finishes the receive chain in float; the
  rung-over-rung EVM change (signed quadrature) is that stage's margin cost.
  Rungs: float(raw IQ) -> agc -> rrc -> ss -> cfc -> cs -> pa -> con.
- **Captures:** `two_jup/r3cap/{evm_swap_A,evm_swap_B,cp1_verdict2}/pair.iq`
  (162 healthy frames each, 2026-08-12), 50-frame windows at TWO alignments
  each (frame offsets 0 and 80) per the tap_replay_study traps (chunk warm-up
  frames unscoreable; alignment-dependent loop transients). 6 independent
  runs; all delivered 49/50 packets. First 5 scored frames dropped per rung;
  median per-frame RMS EVM reported (median is robust to the 2 spurious
  detections in the B windows).
- Measured tap rates (not assumed): agc 8 lines/sym (2x-logged 4 sps input),
  rrc 8/sym genuine (the netlist RRC MF is a 2x-interpolating polyphase),
  ss/cfc/cs/pa 1/sym, con 1/sym payload-only.

Raw per-rung median EVM (%), all 6 runs (`floatgap_n3/ladder_all.csv`):

| run              | float | agc  | rrc  | ss   | cfc  | cs   | pa   | con  |
|------------------|-------|------|------|------|------|------|------|------|
| evm_swap_A_o0    | 4.04  | 3.08 | 3.08 | 3.11 | 3.11 | 3.13 | 3.15 | 3.14 |
| evm_swap_A_o80   | 3.68  | 2.87 | 2.86 | 2.90 | 2.90 | 2.95 | 2.95 | 2.95 |
| evm_swap_B_o0    | 2.53  | 3.40 | 3.38 | 3.39 | 3.39 | 3.39 | 3.42 | 3.36 |
| evm_swap_B_o80   | 2.78  | 3.66 | 3.61 | 3.64 | 3.64 | 3.67 | 3.80 | 3.58 |
| cp1_verdict2_o0  | 4.34  | 4.16 | 4.13 | 4.17 | 4.17 | 4.18 | 4.22 | 4.28 |
| cp1_verdict2_o80 | 5.03  | 4.68 | 4.66 | 4.66 | 4.66 | 4.68 | 4.77 | 4.77 |

Fixed-total vs float, in dB (20*log10(float/con); positive = fixed better):
+2.18, +1.92, **-2.48, -2.20 (B)**, +0.13, +0.46.

## Budget table (ranked)

Signed quadrature contribution per stage, median over the 6 runs (EVM
percentage points; + = the fixed stage costs margin). Both alignments agree on
every sign claim except where flagged.

| rank | stage (rung)            | margin cost (pp, quad, median) | consistency | reading |
|------|-------------------------|-------------------------------:|-------------|---------|
| 1    | front end incl. AGC+CFO path (agc rung vs float) | -1.56, **but +2.3 on evm_swap_B** | sign flips BY CAPTURE, not by alignment | dominant term either way; see cross-check |
| 2    | phase-ambiguity resolver (pa) | +0.53 | 5/6 positive | partly instrument artifact: con (downstream of pa) recovers in 4/6 runs, which is physically impossible for a real pa loss — treat as <= +0.2 real |
| 3    | symbol sync (ss)        | +0.44 | 6/6 positive | the largest CONSISTENT real stage cost; runtime-tunable (0x178/0x17C) |
| 4    | carrier sync (cs)       | +0.41 | 5/6 positive | second consistent stage cost; runtime-tunable (0x170/0x174) |
| 5    | coarse freq comp (cfc)  | +0.10 | 6/6 >= 0 | small |
| 6    | packet ctrl/constellation (con) | -0.19 | mixed | nil |
| 7    | RRC matched filter (rrc)| -0.42 | 6/6 <= 0 | fixed RRC costs NOTHING (its 2x-interpolated output actually scores slightly better than the float MF on the agc tap) |

In dB terms the consistent stage costs are tiny: ss ~= 0.08 dB, cs ~= 0.07 dB,
cfc ~= 0.02 dB on a 3.5 % EVM base. **RRC coefficient quantization and CFC
quantization are exonerated.**

## Cross-check

- The rung-to-rung signed contributions telescope exactly to the agc-rung ->
  con-rung total by construction; the internal fixed-chain budget
  (agc tap -> constellation) sums to **+0.65 pp median** (per-run: +0.63,
  +0.67, -0.53, -0.76, +1.00, +0.95) — internally consistent, well within the
  20 % gate for the 4 runs where it is positive.
- The FULL fixed-vs-float gap does **not** reduce to the stage budget: median
  con-vs-float gap is **-1.18 pp (fixed better)**, with capture-dependent sign
  (A: -2.5/-2.2 pp, cp1: -0.8/-1.6 pp, B: **+2.2/+2.3 pp**). The unexplained
  remainder is entirely the rank-1 front-end term, which is **confounded**: the
  agc rung swaps BOTH the AGC implementation AND the float reference's own
  front end (Gardner at 4 sps + single global 4th-power CFO estimate), so it
  measures "fixed front end vs float front end", not AGC quantization alone.
  Named explicitly: **the budget cannot attribute the B-capture loss to a
  quantization stage; the evidence points at CFO handling** — on B the float
  leg measures +5.1/+7.2 kHz CFO (drifting between alignments) while the fixed
  CFC settled at cfc_est = +49/+147 (~ +0.4/+1.1 kHz only); on A/cp1 the two
  legs agree (-3.9 kHz vs -3.2/-3.5 kHz float). The B loss recurs at BOTH
  alignments (trap respected), so it is not a loop transient.
- Sim con-rung EVM (2.9–4.8 %) brackets the hardware EVM measures (2.5–4.6 %)
  on the same links — the replay instrument is calibrated.
- BER/PER context (plan item): at 2.5–4.6 % EVM the float chain's implied SNR
  is 26.7–32 dB, uncoded QPSK BER < 1e-40, i.e. float BER ~ 0 — so
  **PER-to-float is closed by killing the event classes** (N4's ledger), and
  **BER-to-float is bounded by this stage budget**, which is <= 0.65 pp EVM
  internal + the B-class CFO term.

## Top contributor & runtime-register recommendation

The only consistent per-stage losses (ss +0.44 pp, cs +0.41 pp) and the
capture-level outlier (B's CFO handling) are ALL addressable through
`loop_gain_axi_overlay`'s runtime registers (0x170–0x184, LEAN images) with
**no HDL rebuild**:

| reg | offset | fi type | compiled SI |
|-----|--------|---------|-------------|
| cs_prop_gain  | 0x170 | ufix16_En16 | 98 |
| cs_integ_gain | 0x174 | ufix16_En16 | 1 |
| ss_prop_gain  | 0x178 | sfix24_En24 | -163506 |
| ss_integ_gain | 0x17C | sfix24_En24 | -2180 |
| agc_loop_gain | 0x180 | ufix32_En31 | (2e-3 double) |
| cfo_threshold | 0x184 | sfix22_En21 | +/-26214 |

Pokes to try (score by the mode-3 constellation EVM tap, both directions):

1. **B-class CFO stress (biggest lever, ~2.2 pp / ~2.4 dB on affected links):**
   halve `cfo_threshold` -> write 13107 at 0x184 so the CFC actually engages on
   +5–7 kHz offsets instead of leaving the carrier loop to absorb them; verify
   `cfc_est` (0x0E8 telemetry) moves from ~0 to ~= the float estimate on a B-type
   link. If EVM worsens on clean links, revert (0 restores compiled default).
2. **ss/cs noise bandwidth (~0.4 pp each, ceiling ~0.1 dB total):** halve the
   proportional gains — write 49 at 0x170 and -81753 (stored int, sfix24) at
   0x178 — narrowing loop noise bandwidth at the cost of acquisition speed;
   sweep {0.5x, 1x, 2x} per loop. Caveat: `cs_integ_gain` SI is already 1, the
   quantization floor — the CS integrator cannot be made finer without a
   rebuild, which caps how far the CS loop can be retuned downward.

Expected ceiling from ss/cs retuning alone is only ~0.1 dB — the honest
conclusion is that the fixed data path already meets float on healthy links,
and the remaining work item is the CFO-handling disparity on B-type captures
(poke 1), plus the event classes (N4), not stage quantization.

## Side finding: current instrument netlist fails real-IQ replay (blocker-grade)

The freshly built `obj_byte_taps_f1536` (2026-08-12 instrument netlist = LEAN
+ `loop_gain_axi_overlay` LGMux_* + FRAMESTAT, generated from the currently
dirty `commhdlQPSKTxRx*.slx`) delivers **5 packets in 78 frames** on
`chunk_270_339_r0.iq` where the Jul 25 netlist delivers 77/78 (identical
drive), and its ss/cfc/cs taps run at 2 lines/sym vs 1 (a structural
symbol-sync rate change: `Symbol_Synchronizer.v` differs by ~288 lines,
`Carrier_Synchronizer.v` ~251 — the LGMux threading). The S1B BIST gate PASSES
on this netlist (clean synthetic signal), so **S1B does not cover this
failure mode**. Either the LG-overlay zero-default path is not bit-identical
in-loop, or the dirty model changed the symbol-sync geometry. Do not trust any
image built from the current model/netlist on-air until this is resolved; add
a real-IQ replay (this harness, `win_*` windows, expect 49/50) to the gate
suite.

## Files

- `two_jup/floatgap_n3/` — `ladder_f1536.m`, `run_all_ladders.m`, `budget.py`,
  `floatref.m`, `ladder_all.csv`, per-run tap dumps `t_<cap>_o<off>_*.txt`,
  window extracts `win_*.iq` (frame offsets 0/80, 50 frames).
- `rtl_sim/obj_byte_taps_f1536_jul25/Vwrap_byte_taps` — the validated tap
  binary (Jul 25 f1536 netlist).
