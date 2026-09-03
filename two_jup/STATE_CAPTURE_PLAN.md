# T8.7 PLAN — full-state capture + state-injected replay (the endgame)

Standing plan, to execute if the T8.6 instrumented hunt (path canary + IC/
carrier/timing shadows) fails to catch the error-causing state. Goal per the
campaign charter: **capture the data vectors AND the complete system state at
error time, so the episode reproduces in simulation and a fix can be
engineered there.**

## Why this closes the question no matter what

Deterministic logic + complete state S(T0) + exact input stream from T0 ⇒
the bit-true simulation MUST reproduce the live outputs cycle-for-cycle.
Running that experiment on captured episodes forces one of two decisive
outcomes:

- **(A) Sim reproduces the live errors** → the mechanism is functional and
  now visible in simulation with full observability → step through, name the
  defective state transition, engineer the fix, prove it in sim, gate, ship.
  (This is the outcome if the live-vs-replay gap was warm-state interaction
  we haven't understood.)
- **(B) Sim from the same state + input is clean while live erred** →
  physical (non-functional) divergence is PROVEN, and the post-episode state
  diff — sim-predicted S(T1) vs live-captured S(T1) — names the exact
  corrupted registers and the flipped bits. Fix then targets that circuit
  (hardening, retiming, clock isolation) with a named victim instead of a
  theory.

Today's replays can't do this: they start COLD (the one remaining gap in the
live-vs-sim comparison). T8.5/T8.6 shadows monitor ~15% of the loop state;
this plan captures ALL of it.

## Scope of "complete state"

The LIVE-DIRTY verdicts (11/11) place the corruption at or before the FTS
constellation output, so the state capture scopes to the synchronizer chain
— FEC/byte plane excluded (downstream of the proven corruption point):

| block | true recursive state (HDL-verified where noted) | ~words |
|---|---|---|
| AGC | loop accumulator (complex sfix33/34_En28) | 2–4 |
| Symbol sync | timing LF pipes+integrator (10, verified), IC countReg/muReg/underflowReg (verified) | 13 |
| CFC | estimator Integ/Store regs (2×complex sfix32_En24), window counter ufix13, NCO accphase+accoffsete (sfix21×2), output regs | ~10 |
| Carrier sync | LF P-hold sfix29 + integrator sfix39 + 6 pipes (verified), DDS Delay, NCO accphase+accoffsete+dither state+outsel | ~14 |
| Preamble detector / phase ambiguity / packet controller | correlator threshold state, resolver decision + lookback, frame position counters | ~10–15 |

Total ≈ **40–60 words (~2 kbit)**. Pure feed-forward pipelines (RRC, GTED
taps, matched-filter history) self-flush in <100 beats and are covered by
pre-roll, not capture.

## Mechanism: state telemetry ring ("soft ILA")

No JTAG on these boards → ILA is out. Instead, stream the state continuously
through the capture path we already own:

1. **Per-subsystem StatePacker MLFBs** round-robin their local state words
   onto a few u32 telemetry lanes (index-tagged: `{idx u8 | word[23:0]}` ×2
   lanes, or full u32 words with a frame marker). Surfaced like the T8.5/8.6
   registers (proven idiom, ~4–6 routed signals).
2. **Composite TelemetryMux**: new iq_debug_mux modes —
   - mode 4: pure state telemetry on the rx2-lpc tap channel (full state
     image every ~20 µs at rail rate: hundreds of complete snapshots per
     frame, thousands per episode);
   - mode 7 (stretch): constellation + telemetry INTERLEAVE — the held
     constellation beats repeat 7 identical samples per symbol; replace
     held-beat repeats with telemetry words (decode_con already
     run-length-parses holds; extend it to strip telemetry). One session
     then captures input + constellation + full state simultaneously.
3. **Anomaly freeze-latch** (precision trigger): a small detector on the FTS
   output cadence (validOut gap > threshold, or any shadow/canary firing)
   freezes a secondary latch bank of the state lanes at the FIRST stumble
   instant — microseconds-accurate, vs the ~ms -S event trigger. AXI-read
   after the event.

## Simulation side: state injection harness

Extend the Verilator byte-taps harness (`wrap_byte_taps.v` / `sim_byte_taps`):

1. Build with `--public-flat-rw` (or a generated `--savable` checkpoint
   path) so the C++ harness can force RTL registers directly.
2. The overlay EMITS a mapping table at assemble time: telemetry word index ↔
   RTL register hierarchical path (block names are stable across codegen —
   verified through three builds).
3. Harness: load S(T0) from the telemetry stream (choose T0 ≈ 2 frames before
   the trigger, at a telemetry frame boundary), force registers, feed the
   rx-lpc input ring from T0, free-run.
4. Verdicts, automated per event:
   - output compare: sim constellation vs live tap (mode 7 session) or vs
     live byte errors (-S event map);
   - state compare: sim S(T1) vs captured S(T1) after the episode → bit-level
     diff report per register.

## Phasing, cost, decision gates

- **P0 (free, immediate):** T8.6 hunt analysis. If any canary/shadow steps
  with episodes → skip to targeted fix; this plan becomes the verification
  harness for it.
- **P1 (~1 day):** state inventory finalization from the netlist (recon
  pattern, mostly done for SS/CS/CFC) + StatePacker/TelemetryMux overlay +
  freeze-latch. One gate run + build + deploy (pipeline is scripted).
- **P2 (~1 day):** Verilator state-injection harness + mapping table + the
  automated verdict tooling (extends hunt_verdict_k5).
- **P3 (hours):** instrumented hunts until ≥10 episodes captured with full
  state; run the protocol; verdict A → sim-debug the transition and fix;
  verdict B → named-register physical fix (targeted hardening like T8.4, or
  clock isolation scoped to the victim circuit).
- **Fallback if mode-7 interleave proves fragile:** two-session capture
  (mode 3 constellation session + mode 4 telemetry session) — episodes are
  periodic and plentiful; cross-session statistics still decide A vs B, only
  per-event output-compare granularity is lost.

## P2 STATUS: FOUNDATION PROVEN (2026-07-12)

The injection completeness self-test passed on a real captured episode window
(hunt ev2): run A (continuous replay) dumped all 41,176 registers at sample
2.0M; run C cold-started on only the input tail with that state injected at
its first sample. Result: **49,556 consecutive constellation samples match
bit-exactly, and the entire synchronizer chain's state matches after 200k
samples of free-running** (zero non-FEC diffs). State + input provably
determine the system in simulation; the injection machinery works end-to-end.
Iterations that the self-test caught before hardware depended on them:
composite-level state outside the first map scope, un-inlined FIR subfilter
classes (fixed with --inline-mult), and a line-alignment artifact in the
naive output compare. Known residual: 60 FEC-internal combinational/multirate
members don't stick under forcing -- downstream of the constellation verdict
point, documented as out of scope.

## Risks / notes

- Register forcing requires the netlist register names ↔ model mapping to be
  regenerated per build — the overlay writes the table; never hand-maintain.
- The NCO/dither state inside library blocks may not be packer-tappable (same
  limitation as T8.6); the injection harness CAN still force those registers
  by RTL path — capture-side gap only, and the dither is a deterministic
  PRBS reproducible from its (forceable) seed state.
- tmpfs budget: telemetry ring replaces the tap ring in mode 4 — no growth.
- All additions remain read-only taps: gates must stay bit-identical; every
  new compare structure ships with an alignment/zero proof like
  tb_shadow_align.
