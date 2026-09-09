# Campaign checkpoint — 2026-08-10

Durable state so nothing is lost across a compact. Supersedes nothing; the detailed
write-ups are `RX_CONFIG_SWEEP_RESULTS.md`, `RX_AREAS_RESULT.md`, `STAGED_CYCLIC_RX.md`,
`OVERNIGHT_FINDINGS_SCRATCH.md`.

---

## 1. THE BISECT VERDICT (the headline, and it reversed my earlier framing)

**The fabric is NOT clean. The carrier loop is the dominant fault.**

Layer A (`reverse_rom_soak.sh 120`, in-fabric ROM/BIST — DMA, byte plane and host CRC
all bypassed), 148 TX ROM -> 146 RX:

```
locked golden try 1: cap=0x4922282  dpkts/3s=3734  (1245 f/s, nominal)
then over 152 s:
  packets 75559 (630/s -- HALF nominal)     rstcs 14
  BIST bit_errors +4,424,468 over 1199 growth events
  cap_out golden in 0.4% of samples
  adc_forensic maxGap median 1 max 1   -> ADC/SSI delivery CLEAN
  cfc(0x154) median 4548 std 3925 range [-6395, 18380]
VERDICT: PHY/modem/interface;  adc clean but cfc dither -> MODEM CARRIER LOOP
```

For most of this session I argued "fabric clean, host lossy". **That is false as a
general claim** and is retracted. With the DMA and host entirely out of the path the
fabric still loses badly.

**This is not new.** `carrier_loop_sweep.sh`'s own header records an earlier sighting:
*"cap_out golden ~94%, cfc dither std~694, rstcs ~1.5/s -> the carrier loop hunts/
dithers."* Today is the same fault 5.7x worse (std 694 -> 3925).

### What still points host-side (a SECOND, smaller fault)
A carrier loop cannot explain either of these:
- the steady-state loss period tracked **-M across four values** (8->8, 16->16, 32->32,
  64->aperiodic). Nothing in the fabric knows the host's DMA batch depth.
- failed slices read back as the `carve_zero` pattern = never-written memory.

So: TWO faults. Episodic carrier-loop (large, dominates when it fires, very likely the
all-day wedge source) + steady-state M-periodic host-DMA (~0.7%).

The float oracle's **0.0000% algorithmic ceiling stands but is CONDITIONAL** — those
`bigiq` captures were health-gated, i.e. drawn from stable-carrier windows.

---

## 2. BANKED WINS (all committed)

| result | evidence | commit |
|---|---|---|
| **`RXM=16` ships** | 0.695% PER, CP95UL 0.730% PASS, vs 1.362% at M=32; 4/4 paired cycles | `d4bd49c` |
| costs nothing | goodput 14.04 vs 13.94 Mbit/s, CPU 13.5 vs 13.4% | `be0db95` |
| 4-area ring = NULL | 4xM16 0.693% vs 2xM16 0.695%; period still tracks M; my own hypothesis falsified | `be0db95` |
| capture gate fixed | gated on delivery RATE not CRC ratio; healthy=98%@1022f/s vs wedged=98%@~1f/s — the ratio is identical, only rate separates them. Both controls verified, EXIT=3 | `1373234` |
| netlist survival gate | all 4 steps PASS; `PI_GATE` clean; 27/27 ROM frames bit-exact | (run) |
| cyclic lap-guard | exercised in userspace, observed FIRING (keepup 0 / overrun 1 / boundary 1) | `2a297ff` |
| float oracle | 161/161 frames recovered, EVM med 13.82% p95 14.70%, ceiling 0.0000% | `4e10115` |
| Layer B classifier | TORN_ZERO/TORN_STALE/SCATTERED/BATCH_DROP all proven to fire + 2 negative controls | `2147460` |
| bisect verdict | Layer A fabric-not-clean; Layer B invalid | `4e10115` |

Recommendation as framed: **ship `RXM=16` now (mitigation, free, under 1%)**, with the
cyclic HDL rebuild as the permanent fix that removes re-arm — but see the caveats in
`STAGED_CYCLIC_RX.md` (benefit is predicted not observed; cyclic makes true overflow
structurally possible for the first time, guarded by never-executed code).

---

## 3. LAYER B — DEFERRED, three defects precisely identified (all mine)

Code+sim work allowed while the carrier loop has the hardware.

1. **`batch_m` never set** from `rx_multi` in `seq_run` -> `BATCH_DROP` structurally
   inert. The classifier self-test passed only because it sets `batch_m` by hand. This is
   the `engine_gaps` failure mode repeated after I had written down the lesson.
   Fix: `ss.batch_m = rx_multi;` after `qpsk_seq_reset`.
2. **`seq_run` drives its OWN legacy RX** (`rx_done()`/`rx_arm()`, manual 2-area flip),
   so `QPSK_SEQ_KEEPM=1` set `rx_multi` but the QUEUED path under test was never
   exercised — and the banner "PN traverses the batched DMA path" asserted something
   untrue, which I then quoted back as validation.
   Fix: raw-slice tap `static void (*rx_raw_tap)(const unsigned char *)` called in
   `rx_pump_queued`'s drain and eager paths (the scorer needs RAW bytes BEFORE the CRC
   gate, so it cannot consume `rx_pump_frame`'s decoded return).
   **Anchor hazard:** `rx_pump_frame` has near-identical drain/eager blocks; three patch
   attempts collided. Anchor on the `/* 1. drain a completed area ... */` comment, which
   is unique to `rx_pump_queued`. Also `seq_t0` already exists at file scope — do not
   redeclare.
3. **TX ran 467 f/s against a 1245 f/s air rate**, so most air frames carried no PN and
   everything scored junk (31456/31456, `seq_span=0`). Report TX rate per run so an
   under-fed air frame can never again be misread as link loss.

`qpsk_tun.c` is currently **clean at HEAD** — every failed patch was caught by an assert
before writing; verified `git diff` empty + compiles clean.

---

## 4. RIG STATE

- **146**: BOOT.BIN `433fd8dab393` (TMR image). Host app rebuilt several times; last
  known `50c078f2` (Layer B scorer + RXQ_STAT).
- **148**: BOOT.BIN `64bb24766032` **untouched all session**. Host app `a4dd53cf`,
  **`nakstat=4` verified before and after every change**. Its binary DID change from the
  pre-session `01499916` (the N-area ring is a runtime knob, so it cannot sit behind the
  compile flag that preserved byte-identity for everything else) — flagged, accepted.
- Both boards quiesced by Layer A's exit; watchdogs need restarting after any run that
  uses `-k` or a bespoke launcher.
- **Rig is unstable today**: ~3 wedges in 8 runs (vs 2 in 31 overnight). Now attributed
  to the carrier loop.
- **Push is blocked**: `GH_TOKEN` invalid. All commits are LOCAL ONLY.

---

## 5. NEXT: carrier loop

`carrier_loop_sweep.sh` already exists and is the right instrument — it sweeps the
loop_gain AXI regs and measures IN FABRIC (golden%, cfc-std, rstcs rate, BIST), so the
DMA plane cannot confound it.

Loop registers (LEAN-only; **0 = compiled default**, nonzero = stored integer in that
fi type):

| reg | name | type | default SI |
|---|---|---|---|
| 0x170 | cs_prop_gain | ufix16_En16 | **98** (the historical poison was 307 — NOT recurring) |
| 0x174 | cs_integ_gain | ufix16_En16 | 1 |
| 0x178 | ss_prop_gain | sfix24_En24 | -163506 |
| 0x17C | ss_integ_gain | sfix24_En24 | -2180 |
| 0x180 | agc_loop_gain | ufix32_En31 | 2e-3 (double) |
| 0x184 | cfo_threshold | sfix22_En21 | 26214 (= 0.0125 norm) |

`cfc` is the COARSE frequency compensator output, so `0x184` (its step-change detector
threshold) is the most directly relevant lever, with `0x170` (carrier loop bandwidth)
second. `LOOP_POKE="0x184=0 0x170=49"` is the syntax `capture_r3.sh` accepts.

---

## 6. CARRIER LOOP — first results (2026-08-10 evening)

### 6a. The fault is EPISODIC, not persistent
Layer A (episode): golden **0.4%**, cfc_std **3925**, rstcs 14, 630 f/s.
Baseline one hour later: golden **99.3%**, cfc_std **220**, rstcs/s **0.00**.
Same rig, same instrument. So the loop is healthy most of the time and catastrophic
occasionally — which is what makes single-window measurements untrustworthy.

### 6b. The instrument is validated
`cs_prop_gain 98 -> 300` drove golden 99.3% -> 83.3% and biterr/s 409 -> 14577 (36x).
The registers are live and the measurement resolves real effects at ~15 s per point.
This also independently reproduces the campaign's historical "307 poison" root cause and
confirms 98 is the correct default.

### 6c. *** A STABILITY CLIFF between cs_prop_gain 98 and 196 ***

| cs_prop_gain | golden | biterr/s |
|---|---|---|
| 24 | 98.0% | 281 |
| 49 | 99.3% | 330 |
| **98 (deployed default)** | 97.3% | 461 |
| **196** | **84.0%** | **14668** |
| 300 | 83.3% | 14577 |

Monotonic, and reproduced across TWO independent points (196 and 300 agree to within 1
point of golden and ~1% of biterr). That is a cliff, not an episode — an episode gives a
single non-monotonic excursion (see 6d).

**The deployed default sits only ~2x below a hard instability cliff.** If anything
transiently raises effective loop gain (temperature, LO offset, SNR, AGC state) the loop
can cross it, go unstable, and recover — a plausible mechanism for the episodes, and one
that predicts a concrete mitigation: move the operating point further from the cliff.
Both 49 and 24 measured clean. It also explains why the historical 307 poison was so
damaging: well past the cliff, not merely mistuned.

### 6d. METHOD WARNING: single-pass sweeps cannot rank settings here
`cfo_threshold` single-pass gave 0:99.3%, 13107:98.7%, 26214:100.0%, **52428:94.0%
(biterr/s 4601)**, 104857:99.3%. Non-monotonic — 2x default catastrophic but 4x clean.
A threshold effect cannot do that; an episode landing in one 15 s window can.

With an episodic fault, a 15 s window silently attributes any episode to whichever
register value happened to be live. This is the SAME trap the overnight -M sweep hit
(one cycle per point said M=8 ~ M=16 and legacy was merely mediocre; six interleaved
cycles said otherwise). Fixed there, then re-accepted here.

`carrier_loop_ab.sh` is the corrected design: round-robin the settings across passes so
an episode hits every arm equally, rank on MEDIANS, and — most important — count
EPISODIC WINDOWS (golden < 90%) per setting. With an intermittent fault the episode
count is the real question; a median hides exactly the events that matter.

### Next
Run `carrier_loop_ab.sh` (default vs csprop49 vs csinteg2 vs cfothr13107) long enough to
span episodes, and test the cliff-margin hypothesis: does a lower cs_prop_gain reduce the
EPISODE RATE, not just look fine in a quiet window?

---

## 7. *** THE ERRORS ARE MADE IN THE DEMOD PATH *** (2026-08-10 night)

Four Tap-A IQ captures with EVM in 100 ms windows aligned to the biterr timeline, one of
them TRIGGERED on the bit-error rise itself (fires at >4x baseline, floor 3000/s):

| capture | contrast across biterr onset | delta EVM |
|---|---|---|
| blind rep 1 | flat throughout, BER ~2.8e-5 | - |
| blind rep 2 | clean 14.95% vs degrading 14.87% | **-0.08 pp** |
| blind rep 3 | flat 14.94-15.33% | - |
| **TRIGGERED (5.8x excursion)** | clean 14.93% vs degrading 14.96% | **+0.03 pp** |

The >1.0 pp threshold for "signal quality" was fixed BEFORE the data. Comparisons are
WITHIN a single capture -- same gain, same LO, seconds apart -- because cross-run
comparison on this rig has been wrong repeatedly.

TWO INDEPENDENT ARGUMENTS, not one:
1. EVM does not change across the onset (0.03-0.08 pp).
2. ~15% EVM CANNOT produce 2.8e-5 BER from constellation noise at all -- QPSK at that
   EVM sits nowhere near its 45 deg decision boundaries. The observed BER is orders of
   magnitude above what the constellation implies.

Everything upstream eliminated by DIRECT measurement, not argument:
  agc_level  pinned at 12 before/during/after   -> not AGC, input power steady
  maxGap     median 1, no pre-cursor            -> SSI/ADC delivery clean
  rstcs      no pre-cursor                      -> not reset-driven
  cfc        flat until 5.3 s AFTER errors start-> carrier dither is a CONSEQUENCE

Same SHAPE as the historical demod poison (clean constellation, wrong bits, from a cut
decision margin) -- but PI_GATE passes on today's netlist, so that specific defect is not
back and the mechanism is something else in the fixed-point decision path.

### Two of my earlier claims this corrects
* "Fixed point is at float parity" -- established in FLOAT_FIXED_CAMPAIGN for **240k
  after the pi fix**, on 240k live-air captures. Never established for R3/f1536, and not
  in this regime. I over-generalised it.
* "Algorithmic ceiling 0.0000%, so the gap is host transport" -- the ceiling is real but
  was measured on HEALTH-GATED captures, structurally blind to the regime where the
  fabric errors bits on constellations the float chain decodes trivially. That blindness
  is exactly what this test removed.

### Attribution moved twice today, each time on measurement
1. "fabric clean, host lossy"  -> WRONG (Layer A: fabric loses with DMA out of path)
2. "modem carrier loop"        -> WRONG (cfc dither arrives 5.3 s AFTER the errors)
3. **demod/decision path**     -> current, 4/4 captures, two independent arguments
Loop-gain retuning is a closed avenue: a 4x range was indistinguishable once wedged,
because it was downstream of the trigger.
