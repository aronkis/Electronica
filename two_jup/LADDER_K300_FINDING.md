# k=300 localisation — 2026-08-11 (off-hardware, overnight)

**Answer: a static carrier-phase step of ~11.7°, present in the RECEIVED SIGNAL.
Not a fixed-point stage divergence, and not a sample splice. Do not run the ladder
on this frame.**

Five measurements. Two of my own hypotheses died along the way; both retractions are
kept in place below rather than edited out.

---

## 1. The ladder is blocked at R3 (tooling gap — reported, not worked around)

`hybrid_ladder_k5.m` needs per-stage fixed-point taps (`wrap_byte_taps.v` exposes
`agc/rrc/ss/cfc/cs/pd/pa/con/dem/fec`).

| requirement | state at R3 |
|---|---|
| tap netlist | only `obj_byte_taps` — **240k geometry** |
| f1536 netlist | compiled archive only; wrapper exposes `byte_rx_*` + counters, **no taps** |
| f1536 HDL source | **absent** — generated HDL is k5 (`2240` bits / `1120` sym; f1536 is `24640`/`12333`) |

Running the 240k ladder on an R3 frame would repeat the `replay_capture.sh` geometry trap.
**The build turned out to be unnecessary** — see §4.

---

## 2. The float front end: k=300 is not the damaged frame

```
k=299   4.60%      k=329   5.23%
k=300   3.39%   <- netlist CRC FAIL, EVM BELOW baseline
k=301  21.19%   <- +16 pp                 k=331  21.64%
k=302   4.90%      k=332   4.96%
```

Wide scan k=270..700 (431 frames, baseline 4.19%, threshold 9.19%): **exactly two interior
spikes** (k=301, k=331; k=270 is the acquisition edge) and **exactly two genuine netlist
CRC failures** (k=300, k=330). Perfect 1:1 adjacency, nothing else in 431 frames.

**Not periodic.** The two events are 30 frames apart, but a 30-frame cadence would have
produced ~14 in this window. n=2 is not a period.

## 3. RETRACTED: it is not a sample-domain splice

I initially read the spike-after-failure shape as an insertion/deletion at the frame
boundary — the 240k device-tick mechanism. **Direct measurement refutes that:**

```
k=300 -> 301   diff = 12333 symbols   deviation +0 samples
k=330 -> 331   diff = 12333 symbols   deviation +0 samples
```

Frame cadence is *exactly* nominal at both boundaries. No insertion, no deletion. (The
lone deviation in the window, at 290→291, is the front end's acquisition edge.) The 240k
tick mechanism is **ruled out** for these frames.

## 4. What it actually is: a static ~11.7° phase rotation

Sub-block structure inside the 21% frames (12 blocks of 1026 symbols):

```
k=301  EVM%:   23.63 21.25 20.95 20.89 20.99 20.91 20.96 20.87 20.99 20.92 20.90 21.05
       phase:  -12.1 -11.7 -11.7 -11.7 -11.7 -11.7 -11.7 -11.7 -11.7 -11.7 -11.7 -11.8
       -> ratio max/min 1.1x, phase swing 0.5 deg

k=331  EVM%:   24.77 21.85 21.24 ... 21.25 21.39      ratio 1.2x, swing 0.5 deg
       phase:  -12.4 -11.9 -11.9 ... -11.9 -12.0
```

**Flat EVM, constant phase.** Not a corruption burst (which would concentrate in one or
two blocks) and not a carrier transient (which would ramp or swing). It is a *static
rotation of the whole frame*.

**It accounts for the magnitude exactly.** A static rotation θ gives EVM = 2·sin(θ/2):

```
theta = 11.7 deg  ->  2*sin(5.85 deg)          = 20.39%
combined with the 4.9% noise floor in quadrature:
sqrt(20.39^2 + 4.9^2)                          = 20.97%
measured                                        = 21.0%
```

Nothing else is happening in those frames. They are cleanly received and simply rotated.

**k=300 has the complementary shape** — EVM concentrated at the frame *edges*
(8.02 start / 4.87 end) with an unusually clean middle (**1.67%**, well below the 4.9%
baseline), phase flat. That is the event landing inside k=300's window: its preamble-based
derotation is thrown by a phase step partway through, while k=301 sits wholly after the
step at a uniform offset.

### The key attribution

This is measured by the **float** front end. The rotation is therefore **in the received
signal**, not manufactured by fixed-point arithmetic. A fixed-point stage cannot be
"where it diverges" for something the float model sees too.

**RETRACTED: the "5-bit phase quantum" lead is dead.** I noted that 11.7 deg is near
`360/32 = 11.25` deg. The multi-capture scan in §5 refutes it — the magnitudes are not a
single quantum.

---

## 5. Recurrence and direction (multi-capture scan)

Four banked captures, 400 frames each, same detector:

| capture | dir | frames | baseline | events | phase of each (deg) |
|---|---|---|---|---|---|
| `hunt_auto_20260731_211829` | fwd | 400 | 4.16% | 2 | −11.9, −12.1 |
| `cfo0_M32` | fwd | 399 | 6.02% | 2 | **+17.2**, −13.5 |
| `rxq_M32` | fwd | 400 | 6.63% | **0** | — |
| `revlong` | **REVERSE** | 399 | 5.77% | **24** | 0, −30.1, 0, −30.4, 1, −29.4, 0, −30.9, … |

1. **It happens in BOTH directions** — so it is not one board's RX path. It is
   common-mode to the link.
2. **It is NOT a fixed quantum.** Magnitudes span −11.9, −12.1, −13.5, **+17.2**, −30:
   different signs, no common divisor. The `360/32` idea is dead.
3. **The pair structure is confirmed.** Reverse alternates `~0 deg` and `~−30 deg`: one
   frame with elevated EVM but *no* net rotation (the frame the step lands in — the
   k=300-shaped member) followed by one uniformly rotated (the k=301-shaped member). In
   forward only the rotated member cleared the threshold, because k=300's EVM sits
   *below* baseline; in reverse both members clear it.

**Rate differs 6x by direction:** forward ~2/400 = 0.5%, reverse ~12 events/399 = 3%. And
one forward capture (`rxq_M32`) shows **zero** events in 400 frames, so it is not present
in every capture.

## Consequences

1. **Do not run the hybrid ladder on k=300**, even after an f1536 tap netlist is built.
   There is no arithmetic divergence to bracket.
2. **`SLICER_REPLAY_FINDINGS.md` fault #2 is renamed again** — from "demod/decision path"
   (original) → "sample-domain splice" (my first correction, wrong) →
   **"static carrier-phase step in the received signal"**. The two-fault separation itself
   is unchanged and still rests on the burst evidence.
3. **Scale check:** 2 failures in 431 frames = 0.46%. Real, but not the dominant PER term,
   and the <1% goal is already met by the shipped `RXM=16`.

## Next step (analysis, off-hardware)

The direction question is **answered** (§5): it occurs in both, so it is common-mode, not
one board's RX. The open questions now are:

1. **Why is reverse 6x more affected than forward**, and why does one forward capture show
   zero events? A per-capture correlate (LO offset, gain, profile, time-of-day) would say
   whether this tracks a configuration or is sporadic.
2. **What sets the magnitude?** −11.9 / −12.1 / −13.5 / +17.2 / −30 deg, mixed signs, no
   common divisor. Both signs occurring rules out a one-way accumulator.
3. **Does it cost frames in production?** The netlist fails the frame the step lands in.
   At forward's 0.5% that is small against the shipped 0.695% PER; at reverse's 3% it
   would be the dominant term — but reverse PER has historically measured *better* than
   forward, which does not fit and needs reconciling before this is called a PER driver.

Item 3 is the one worth doing first: it decides whether this matters at all.

## Artifacts

- `two_jup/k300_float_probe.m` — per-frame EVM/preCorr (verdict direction corrected once:
  the first version tested `|dEVM|` and read k=300's *below*-baseline EVM as "disturbed")
- `two_jup/r3cap/k300_float.csv`, `two_jup/r3cap/evm_scan_270_700.csv`
- `tick_repro_r3/burst_study/bs_front_end.m` — now additionally returns `symC` (additive;
  all pre-existing fields unchanged) so callers can examine within-frame structure
