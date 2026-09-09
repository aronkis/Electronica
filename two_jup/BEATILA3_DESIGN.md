# BEATILA-3 — supervised on-silicon ILA: build + capture design (AUTHORIZED 2026-08-20)

Operator authorization: build + capture of the #64/#59 observability ILA. Conditions:
(1) the binary readout rule is PRE-STATED here, before any capture; (2) BUILD ONLY —
the build result is reported and the operator's explicit go is required before flashing.

## Purpose

The 5-model sim campaign (Models 1–5, `MODEL1_ENABLE_INJECT.md`, `MODEL2_CLKEN_SOURCE.md`)
eliminated every mechanism expressible in the bit-matched RTL netlist. The beat mechanism
therefore lives outside the RTL model — in the physical implementation — or in a state
the sims deemed unreachable. This capture is the sole remaining discriminator.

## Probe set (~25 bits, second ILA `u_ila_beat3`, depth 2048, clock `adc_1_clk`)

| probe | signal (RTL name; final names fixed by preflight vs build-1 routed DCP) | why |
|---|---|---|
| trig | `burst_det/trig` (existing scheduled-force trigger) | proven in-window landing |
| decis[1:0] | `u_QPSK_Demodulator/Delay12_out1[1:0]` (hard-decision pair) | is the decision correct? |
| serctr | `u_Serializer/HDL_Counter_out1` | serializer phase |
| dataOut | `u_QPSK_Demodulator/Delay8_out1` (= FEC `bitsIn`) | the corrupted stream |
| startOut / validOut | `Delay10_out1` / `Delay9_out1` | frame alignment for sequence compare |
| avgEst_hi[15:0] | `u_Average_Estimates/Unit_Delay_Enabled_Synchronous_out1_re/_im` top 8+8 | resolution-latch state |
| rails[1:0] | `inst/enb_1_2_0`, `inst/enb_1_2_0_gated` | enable-rail integrity |

Insertion method: implementation-side debug XDC against **preflight-verified names**
(no source mark_debug through the OOC IP — that flow's silent-failure mode is the reason
prior plans stalled). Preflight = `skidfix/beatila3_preflight.tcl` on build-1's routed
DCP; hard-fails the campaign before any build time if a critical net is missing.

## BINARY READOUT RULE (pre-stated; verdict decided in advance)

Capture validity gate: the scheduled force must land in a VERIFIED held window —
`cap_in` (0x13C) read at force time must be non-golden. Golden at force ⇒ Readout C.
Golden reference sequences for every probe come from a golden-gap capture in the same
session + the sim (which reproduces both hardware goldens bit-exactly), aligned on
`startOut`.

- **READOUT A — IMPLEMENTATION DIVERGENCE PROVEN.** All probed states golden-correct
  (decision pairs match the golden per-symbol sequence; `HDL_Counter` alternates with
  correct phase vs `startOut`; avgEst top-bits at golden constant; rails clean
  alternation) AND `dataOut` is WRONG (≠ golden coded sequence, consistent with the
  corrupt `cap_in`). Correct-in → wrong-out across an RTL-exonerated boundary = the
  physical implementation between probe points transforms the data. The decision-correct
  / dataOut-wrong pair brackets it inside the Delay12→Serializer→Delay8 physical cone.
  → Fix class: implementation/constraints (enable-rail extraction, KEEP/hierarchy,
  re-hosting).
- **READOUT B — STATE WRONG (sim missed a reachable state).** Any probed state deviates
  in-window. Pre-decided sub-cases: decision pair wrong → fault upstream of the demod
  output stage (avgEst probe then splits carrier-resolution vs earlier); `HDL_Counter`
  phase inverted vs `startOut` → that physical register is being disturbed (the flip sim
  called unreachable is real on silicon); avgEst wrong → per-frame re-resolution failing
  on silicon. → Fix class: harden/re-anchor the NAMED element.
- **READOUT C — VOID (not evidence).** Force landed outside a window (`cap_in` golden),
  probes read constants (nets optimized), or rail probe shows clock aliasing. No verdict;
  retry/adjust only.

## Build recipe (BUILD ONLY)

Base: `skidfix/run_beatila_build.sh` (build-1, proven) → new `run_beatila3_build.sh`:
1. Preflight gate (`BEATILA3_PREFLIGHT_OK` required).
2. Standard recipe (fresh kit, TGEN+BEATILA patches, MATLAB, Vivado) + generated
   `beatila3_debug.xdc` (implementation-only) with `create_debug_core u_ila_beat3` +
   probes on the verified names.
3. Post-impl gate: routed DCP must contain `u_ila_beat3` with all probes connected
   (`BEATILA3_ILA_OK`) — hard fail otherwise.
4. Rail census vs lean (report-only; small delta expected from the added ILA).
5. HARD STOP: image banked; flashing requires the operator's separate explicit go.

## Capture plan (after flash authorization only)

Same proven session flow as `beat_capture_win2.sh`: fresh XVC daemon, quiesce, arm BIST
ROM (arm-health gate ≥1000 f/s), scheduled forces — run1 golden gap (arm+153.10),
run2 in-window (arm+154.30) — `cap_in` logged at each force; both ILAs read over XVC;
two-pass restore + watchdog verification at the end.
