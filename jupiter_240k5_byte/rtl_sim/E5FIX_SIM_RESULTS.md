# E5-class patch (peak-anchored search window) — netlist A/B against the burst signature (2026-08-28, off-rig)

## 1. Mechanism in the flashed RTL (`s1_rtl_beatfix3`, Preamble_Detector → Peak_Search / Timing_Adjust)

- **Peak_Search** keeps a free-running mod-12333 symbol counter `timing_Reference` (counts every valid symbol,
  reset only by the modem reset). Its search WINDOW is tied to that counter: at `timing_Reference == 12332`
  (`done`) the running maximum of the preamble correlation is cleared and `success` is cleared. Inside the
  window, every valid symbol whose correlation exceeds the running max AND the threshold latches
  `timingOffset <= timing_Reference` (the counter value at the peak). So the reported offset is the
  counter phase of the best peak seen *within the current counter-defined window*.
- **Timing_Adjust** keeps an identical free-running mod-12333 counter, latches `timingOffset` when
  `timingOffsetValid` (= `done && success`, one delay later), arms, and emits `SyncPulse` when its own
  counter equals the latched value — i.e. the frame start is re-derived once per window, one frame late.
- Consequence 1 (why a forced +32 on ONE counter persists): the two counters are lock-stepped on hardware
  (same `validIn`, same enable) and nothing ever re-synchronises them to each other; forcing only one of
  them in the model creates a permanent 32-symbol disagreement (SyncPulse 32 symbols late every frame →
  48/68 BIST errors per frame forever). That state is NOT reachable on hardware — it is an artefact of the
  single-counter force, so `ps`/`ta` are not the hardware mechanism by themselves.
- Consequence 2 (the real E5 failure): on hardware a strobe deletion/insertion moves BOTH counters together,
  i.e. the preamble peak moves by ±1 symbol *relative to the window*. If the peak sits near the window edge
  (offset ≈ 0 or ≈ 12332), the moved peak lands on the `done` slot or straddles two windows: the correct
  peak is cleared by `done` before it is latched (done has priority over the latch), a lower secondary
  correlation lobe (the +32 sidelobe seen in the reverse-leg E5 study) wins the next window, and
  Timing_Adjust pulses on the wrong phase. Because the window is anchored to the free-running counter and
  not to the detected peak, this condition is stable: every subsequent frame's peak lands on the same bad
  slot, so the error persists until the counters happen to drift again — a long episode, no carrier reset,
  framesync intact (the ~3-s hardware burst signature).
- The timing-loop kick (`ss`) produces the same signature by a different route: the loop's slow
  re-convergence delivers a train of strobe insertions/deletions (each one a joint counter move), so the
  peak keeps moving relative to the window for tens of frames.

## 2. Patch (`s1_rtl_e5fix`, ONE file: `Peak_Search.v`, 27 added lines, see `e5fix_runs/Peak_Search.diff`)

Anchor the search window to the last detected peak instead of to the free-running counter: a new 14-bit
window counter `win` restarts at 1 on every new-peak latch (`Logical_Operator4`), counts valid symbols mod
12333 otherwise, and the running-max reset / `done` / `success`-reset now fire at `win == 12300`, i.e.
33 symbols BEFORE the next expected peak. A peak that moved by up to ±32 symbols is therefore always
captured inside the right window; the reported `timingOffset` is still the free-running counter value at
the peak, so Timing_Adjust's semantics, latency and the downstream frame alignment are unchanged.
Everything else in the netlist is byte-identical (`diff -rq`: 1 file).

## 3. A/B (Verilator, `obj_burst` vs `obj_burst_e5fix`, ROM/BIST loopback as the hardware ROM run, force at packet 80, 180 frames)

Stimuli: `none` (control), `ss` (timing-loop kick), `ps`/`ta` (single-counter +32 — model artefact, kept
for comparison), and the hardware-realistic JOINT slips (both counters moved together): `slip1` (+1),
`slipm1` (−1), `slip32` (+32), `edge` (shift chosen at run time so the peak lands exactly on the window's
`done` slot — the E5 boundary case).

RESULTS_TABLE

## 4. Risks / side effects to check on silicon
- Acquisition from cold: before the first peak, `win` free-runs mod 12333 (as the original counter did), so
  the first window behaves as before; after the first latch the window is anchored. If a frame's peak is
  missed entirely (deep fade), the window keeps free-running from the last anchor — same as the original.
- A spurious threshold crossing (noise) re-anchors the window to the wrong place for one frame; the next
  true peak (higher correlation) re-anchors it back. Original design has the same exposure via `timingOffset`.
- Timing_Adjust is untouched; `timingOffset` values and the 1-frame latency are unchanged.

## 5. Hardware witness before any build
- Zero-build: the 120-s burst's Peak_Search telemetry (`p1c_tref`, `p1c_heldts`, `p1c_runmax`, p1c_newpk
  count) sampled through a burst on the probe-4 image — a jump of the latched offset at burst onset and a
  return at the end confirms the window/peak mechanism; the `ss_integ_gain` (0x17C) sweep (running) shows
  whether the drift feeding the slips is timing-loop-driven.
- After a build (NOT started): the same loopback ROM series must show the 120-s bursts shrink from ~3 s to
  ≤ 2 frames (BIST error step ≤ ~150 per event instead of ~200 k per 10 s).
