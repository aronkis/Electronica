# 119.75 s Beat — Bisection Plan (2026-08-19)

## Constraint set (all measured; any explanation must satisfy every line)
- Strictly periodic error bursts, canonical link: start-to-start 119.75 s, duration 6–8 s,
  first burst at **arm+153 s** (arm-phase-locked).
- Two alternating deterministic species: ~293,18x / ~215,0xx bit errors, sizes reproduced
  **byte-identically** across: FPGA-internal digital loopback, ADRV9002 SSI near-end
  loopback (RF excluded), and board 146. (LAYERA_BER.md)
- Period changes with link state: (1245 f/s → 119.75 s), (341 f/s degraded → 6.7 s),
  (34 f/s degraded fine-poll 2026-08-19 → 37 s bursts / 67 s start-to-start). NOT a fixed
  wall-clock timer, and not a simple 1/rate law either — see Axis A.
- RX tracking-cal toggle invariant. No PL timebase found (DUT + BD IP scans). No DUT
  counter pair predicts the period. Both idealized-clock sims (RTL netlist, Simulink)
  are clean. Post-Viterbi comparator (0x108) is where we see it; corruption content
  never yet observed directly.
- Sole surviving suspect family: **SSI-derived clock chain / a periodic event in the
  clock-common domain** (both loopback paths share the SSI-derived fabric clock).

## Axis A — rate/period law (no build, rig, cheap)
Collect (fsync rate, burst period, burst duration, species sizes) at every reachable
link state: canonical 1245, half-rate 586 (degraded bring-up mode — now easy to reach),
341, 34. Fit candidate laws: period = N_frames/rate (frame-count-locked),
period = N_samples/sample-rate per domain, period = f(two beating counters).
The three existing points already reject a single fixed counter; a fourth (586) and
species sizes vs rate will discriminate count-locked vs beat-of-two-counters.
**Deliverable: the counting domain named by its scaling law.**

## Axis B — driver/chip event coincidence (no build, rig, highest info/minute)
The chip cannot corrupt deterministically without state change; if the event originates
chip-side or driver-side there is almost certainly an SPI transaction at burst time.
On 148: enable kernel SPI tracing (tracefs `events/spi/`) — or, if absent, poll
adrv9002 debugfs/API telemetry (PLL status, SSI status, temperature reads) at 10 Hz —
across a window covering arm+140 s..arm+170 s in digital loopback. A SPI burst
coincident with error onset = smoking gun (then bisect WHICH register by content);
silence = fabric-side clock handling, chip exonerated.
**Deliverable: chip/driver-side vs fabric-side split.**

## Axis C — spatial bisection inside the fabric (ILA image, this build)
Schedulable ILA capture at burst onset (see BEAT_ILA_DESIGN.md):
- Fast ILA (SSI clk, 4k deep, ~66 µs): comparator error strobe, framesync, timing-loop
  state, carrier-loop state, demod input samples, MMCM/PLL locked flags.
- Slow ILA (same core, capture-qualified on framesync, ~3.3 s span): frame counter,
  per-frame error counts, lock flags — the context lane.
- Trigger: burst-onset detector overlay (errors-per-1ms window > threshold, immune to
  the 62 err/s quiet floor), arm gated by software at t+140 s ("schedulable").
First probe group that shows disturbance at onset names the stage; clean demod inputs
with dirty outputs = DSP-internal; disturbed MMCM/locked or input samples = clock chain
upstream.
**Deliverable: the failing stage named by waveform.**

## Axis D — species anatomy (offline, no rig)
293,18x/12,224 bits-per-frame ≈ 23.99 frames; 215,0xx/12,224 ≈ 17.59 frames.
Fine-structure 0.1 s poll (queued) resolves the burst envelope: contiguous full-loss
frames vs partial-rate span. Combined with Axis A species-vs-rate scaling this
constrains the corruption mechanism (full-frame kills vs distributed bit flips).

## Sequencing
1. Axis B SPI trace — NOW (rig free, ~10 min/run).
2. Axis A half-rate point — next rig session (deliberately accept a 586 bring-up).
3. Axis C build — kick off now (2–3.5 h); flash on operator authorization; capture same day.
4. Axis D — after fine poll on canonical link.
Decision tree: B positive → chip/driver register bisect, C confirms effect;
B negative → C is primary; A's law narrows which counter/domain in either branch.
