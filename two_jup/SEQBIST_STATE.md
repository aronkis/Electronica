# SEQBIST_STATE.md — SEQ-BIST campaign state (plan `happy-bubbling-owl`)

Ledger: `two_jup/sdd_archive/2026-09-03-seqbist/progress.md`.
This file is the **pre-registration** for Task 6/7 (rig: flash 148 + stage 1 fabric
loopback + stage 2 OTA self-reception). Sections 1–4 were written **before any run**
(2026-09-03 23:3x, PHASE A, no board writes); section 6 is filled with results as
each leg lands. Every number is labelled **[silicon]**, **[sim]** or **[inferred]**.

---

## 0. Image, addresses and control-bit map

| item | value |
|---|---|
| 148 seqbist image | `boot_known_good/BOOT.BIN.148.seqbist.a1ff3c876d91`, md5 `a1ff3c876d91f1a0330254cf10902748`, routed WNS **+0.112** |
| 148 rollback | `BOOT.BIN.148.txfixF3.f6a8c3ea119c` (the image booted now), on-board copy `/root/BOOT.BIN.f6a8c3ea119c.bak` |
| 146 seqbist image | `BOOT.BIN.146.seqbist.3378861d30bd` (WNS +0.166) — **built, not flashed; not this task** |

```
0x9D400000 tgen_ctrl   : [0] en, [15:4] fill, [31:16] skip_every|corrupt_every (N)
0x9D400008 tgen_gap    : [26:0] gap clks, [27] 0=skip_every 1=corrupt_every
0x9D410000 tgen_rx_ctrl: [3] freeze  [4] checker en (RISING EDGE = clear)  [5] tgen_mode
0x9D410008 tgen_rx_gap : [31:27] cnt_mux32 select; [26:0] gap clks (must stay < 2^27)
0x9D450008 wit ch2     : cnt_mux32.q  (slots 0-15 legacy, 16-31 = rx_seq cnt0..cnt15)
modem 0x104 packets_out   0x124 cnt_frame_start   0x114 rx_input_select (0=int loopback, 1=air)
modem 0x158 source (0=ROM, 1=external byte stream)   0x118 = 0
```

**148 aliasing rail (task-2 §"Two aliasing facts"):** the 0x9D410000 word also drives
`qpsk_traffic_gen_rx2.ctrl`, where **bits 4 and 5 alias `fill_len[1:0]`**. Harmless only
while tgen_rx (bit 0) is 0. `seqbist_run.sh` refuses (exit 5) if bit 0 is set. Every write
to 0x9D410000 is read-modify-write. `arm148_rf_self.sh` writes that word **not at all**.

---

## 1. Stage-1 pre-registration — fabric loopback on 148 (plan T2)

Arm: `0x158=1, 0x118=0, 0x114=0` (mod I/Q → demod inside the fabric), `loopchk_run.sh:31-33`
double-tap. No DMA, no daemon, no radio in the path. FILL=1516 on every leg.

| leg | unit | knobs | PREDICTION (pass) | FALSIFIER |
|---|---|---|---|---|
| A | `seqbist-s1-ctrlA` | `SKIP_EVERY=1000 GAP=0 DUR=180` | `gap_events = frames/1000 ± 2`; `gap1 = gap_events`; `lost_slots = gap_events` (skip advances seq by 2 → exactly one lost slot per event); **interval peak = 1001** (N+1, seq-delta units) | any of these off by more than ±2 → the checker's seq/gap logic does not work on silicon; **stop, report, run nothing else** |
| B | `seqbist-s1-ctrlB` | `CORRUPT_EVERY=1000 GAP=0 DUR=180` | `garbage = floor(frames/1000) ± 2` **and** `gap_events = garbage ± 2` (one gap1 per corrupted frame, its seq is unreadable); **interval peak = 1000** (M, not M+1) | as above → **stop** |
| C | `seqbist-s1-clean` | `GAP=<mission> DUR=600` | **REVISED 2026-09-04 (ruling)**: `lost_slots` ≈ 0 on the **seq axis**, `crc_fail = 0`, and `garbage` = the **filler fraction** ≈ 1 − r_tgen/r_air ± 1 pp — **not 0** | a `lost_slots`/`gap_events` rate materially above the measured background, or any `crc_fail` |
| D | `seqbist-s1-mission` | `GAP=<mission> DUR=600` | as C, at ~1245 f/s | as C |
| E | `seqbist-s1-soak` | `GAP=<mission> DUR=1800` | the `interval_last_series` shows **no 26 ms-class line**: no concentration at 32/33 emitted-frame intervals | a 32/33 line here, with no radio and no DMA in the path, moves the comb into the fabric — a campaign-level result |

**Positive controls come first and gate everything.** No null from C/D/E is quoted unless
A and B both read back exactly. This is the credit for every later null.

### 1.1 REVISED after silicon (ruling 2026-09-04): garbage is FILLER, and it is expected
The original prereg (`garbage = 0`) is **withdrawn**. Both Task-3 [sim] warnings were tested
on silicon and the picture is now settled:

1. **`garbage` = the modulator's free-run filler, not corruption.** The modulator emits an
   air frame every ~1/1245 s regardless of what TGEN supplies; slots TGEN does not fill go
   out as all-zero frames, which reach the checker with a bad magic and are counted —
   correctly — as `garbage`. So

   > **`garbage_fraction ≈ 1 − r_tgen / r_air`**

   Measured at GAP=73384 [silicon]: r_tgen 622.9 f/s, r_air (0x104) 1245.7 f/s → predicted
   50.0 %, observed **50.02 %**. At the 1,200 f/s mission point the prediction is ≈ 3.6 %.
   **Prediction for every stage-1 leg: `garbage` = filler ± 1 pp.** Filler never touches seq
   tracking (a bad-magic frame does not update `last_seq`), so it does not perturb the loss
   metric.
2. **Over-supply loss is real but is a GAP=0 artefact.** At GAP=0 TGEN emitted 330,868 while
   only 110,143 good frames arrived (3.00×), `gap2` dominant. Gone at the mission gap
   (emitted 34,391 vs good 34,348 = 1.001). `GAP=0` is therefore leg **`rail`**,
   characterisation only, never a null.

**The stage-1 loss metric is on the seq axis only**: `lost_slots`, `gap_events`, the
gap1/gap2/gap3+ histogram, the `int_last` series, and `crc_fail = 0`. `chk_frames` and
`garbage` are byte-plane quantities and are reported, not scored.

### 1.1a Measured background loss [silicon] and what it does to the controls
GAP=73384, 55.2 s: `lost_slots` 23 / 34,391 emitted = **0.0669 %**, `gap_events` 20
(gap1 17, gap2 3) ≈ 1 event per 1,720 emitted frames.

*Clustering check (ruling 2):* per-10 s gap_events = 7, 2, 4, 3, 4 — spread across the whole
window, **not** a start transient (the first interval holds 35 % of events, not ~100 %), and
not the 1.00 s class-B generator outage shape from TGEN_SWEEP.md. `int_last` = 886, 51,
3626, 844, 305, 1890 — scattered, **nowhere near 32/33**, so no comb signature at this rate.
FILL=1516 throughout, far above the fill ≤ 47 hazard.

⚠ **Consequence for the positive controls:** `seqbist_score.py` requires
`gap_events = frames/N ± 2` **absolute**, a tolerance written when the fabric was assumed
lossless. With a real background of ~1 per 1,720 emitted, a 180 s leg carries ~65 background
events, so **no N can satisfy ±2**. The controls must be scored **background-corrected**:
`observed − background` vs `emitted/N`, with background taken from the clean leg at the same
gap. Flagged to the coordinator rather than silently loosening the scorer.

### 1.2 Mission GAP — measured, and one wrong turn recorded
`r = F/(E + GAP)`. Silicon points: GAP=0 → 1870.4 f/s (backpressure-limited and 3× lossy, so
**not** a valid model point), GAP=73384 → 622.9 f/s (clean, emitted == delivered).

**Wrong turn, recorded:** I first concluded from the GAP=73384 point that "the DUT consumes
622.7 host frames/s, so 73384 *is* the mission gap." That was wrong — emitted == delivered
at that gap only means nothing was lost there, not that it is the ceiling. The air slot rate
is ~1245/s and the DUT will take a host frame per air slot; the coordinator's filler formula
makes this explicit. The mission target is **r_tgen ≈ 1,200 f/s**, reached by a smaller gap,
and is confirmed by a second clean calibration point rather than by any assumed clock F
(the two-point solve gives F = 68.5 MHz, which is not a plausible clock precisely because
the GAP=0 point is contaminated — it is not quoted as a result).

### 1.3 Interval-bin caveat (would otherwise be misread)
`int_32`/`int_33` are only meaningful at ~1245 f/s. At line rate (`GAP=0`) a 26.0 ms
process lands far outside those bins and falls into `int_other`, which is bimodal and is
**not** a flatness signal. Flatness is read from `interval_last_series` (raw `chk_int_last`,
one point per 10 s freeze), and only legs D and E test the comb.

### 1.4 Credit checklist (every leg)
`image_md5 = a1ff3c876d91f1a0330254cf10902748` · `window_s ≥ 150` · `rearms_in_window = 0` ·
no negative cumulative-counter delta · positive controls A+B green · `0x104`/`0x124`/
`chk_frames` agreement stated · sample count quoted · `[silicon]`.

---

## 2. Stage-2 pre-registration — OTA self-reception on 148 (plan T3)

148 transmits the fabric TGEN stream on its own antenna and receives it on its own RX.
No cable, no attenuator, no daemon, no watchdog, no DMA. 146's **image** is not touched.

Arm: `two_jup/seqbist/arm148_rf_self.sh` — `0x114=1, 0x118=0, 0x158=1`,
`PROF=lvds_61p44_fdd_jupiter`, `WATCHDOG` never launched, TGEN off on exit,
`0x9D410000` never written.

**LO policy (the trap `rf_loopback.sh` would walk into).** `bringup_r2r3.sh`'s CFO policy:
at R2/R3 the demod has a **dead zone at residual CFO ≈ 0**. In a two-board link the
residual is supplied by the two boards' XO offset; in *self* reception both LOs come off
the **same XO**, so a shared LO (what `rf_loopback.sh` does) gives residual **exactly 0** —
the worst point. Default here: `LO_TX = 2000000000`, `LO_RX = 2000020000` → **+20 kHz**,
inside the proven-clean ±2.4k…±20k band and the same +20k the shipped forward leg uses.

**SSI:** applied by default (`FORCE=1 apply_146_ssi_fix.sh 10.0.0.148 5 3`), because every
1242–1246 f/s 148 arm in task 8a came through `bringup_r2r3.sh` *with* `SSI148="5 3"`, and
SSI sits in the FPGA↔ADRV9002 TX path that only matters on air (`arm148_mode1.sh`'s healthy
internal-loopback fps says nothing about it). `SSI=skip` is the documented knob.
**Pre-registered: the run below is the `SSI="5 3"` variant.**

**Three-stage bring-up gate** (deliberately not one combined test — conflating them would
hide the very loss stage 2 exists to measure, and an air-only probe cannot separate a bad
arm from weak self-coupling):

* (a0) **arm-quality gate**, ROM (`0x158=0`) with **`0x114=0`** — fabric-internal loopback,
  **no radio in the RX path**. 0x104 delta over 5 s, need **≥ 1120 f/s**. This is the number
  comparable to `arm148_mode1.sh` (~1244 f/s healthy) and to task-8a §9.1's collapse to
  **764–830 f/s**. A fail here is `ARM_RF_SELF_FAIL_ARMQUALITY` — an arm problem, full stop.
* (a1) **self-coupling gate**, ROM with **`0x114=1`** — 148 must hear its **own**
  transmission over the air. Same threshold. A fail here with (a0) healthy is
  `ARM_RF_SELF_FAIL_COUPLING` → the one LO-offset alternative, then **UNINFORMATIVE**
  (cable needed). Splitting a0/a1 is what turns an ambiguous failure into a localised one.
* (b) **SEQ-BIST gate** (the brief's), `0x158=1` + TGEN on, two `seqbist_read.py` samples
  15 s apart: **0x124 ≥ 1,200 f/s** AND **|chk_frames − 0x124| / 0x124 ≤ 1 %**.

**Fallback, exactly one attempt** (brief): re-run with a different `LO_RX` offset
(`2000005000` = +5 kHz, or `1999980000` = −20 kHz). **RX gain is not a fallback knob** —
task-8a measured both receivers already pinned at the AGC max-gain rail
(34.000000 dB = index 255). If the alternative also fails: **UNINFORMATIVE** (self-coupling
too weak; the operator must rig the attenuator cable).

**Leg** `seqbist-s2-self`: `MODE=rf BOARD=148 DUR=600 FILL=1516 GAP=<mission>`.

| PREDICTION | reading |
|---|---|
| the 26 ms comb **appears** with 146 silent (`interval_last_series` concentrates at 32/33 emitted frames, or `comb_period_ms.py` finds ~26.0 ms) | the process is in **148's own radio/RX chain** (tracking cal / AGC / DC-offset update) |
| the series is **flat** | the process **needs 146** (transmitter side / air / LO / ref) — P-D's result then decides the next probe |

### 2.1 ⚠ Blocking precondition: 146 is NOT silent  [silicon, 2026-09-03 23:29]
Read-only enumeration of 146 (`two_jup/seqbist/phaseA_readonly.sh`, unit `t6-ro146`):

```
IMG=6b4744ca73f8   QPSK_TUN=(none)  WD=(none)
TX_ENSM=rf_enabled  RX_ENSM=rf_enabled
TXLO=2000000000     RXLO=1900040000     TXGAIN=0.000000 dB
R158=0x0 (ROM source)  R114=0x0 (internal loopback)  R118=0x0
RX_FPS_5S=1247
```
No daemon and no watchdog — so the brief's literal check ("daemon down, TX byte stream not
running") **passes**. But `out_voltage0_ensm_mode = rf_enabled` with `0x158 = 0` and
`hardwaregain = 0 dB` means **146 is radiating ROM at full power on 2.000 000 GHz** — the
exact carrier 148's RX (2.000 020 GHz, +20 kHz) is tuned to. Plan T3 says "146 TX disabled";
the brief softened it to a read-only check and nobody has arranged the disable. 146's ROM
frames carry no TGEN magic/CRC, so they land in `chk_garbage`/`magic_bad` and make the
stage-2 leg uninterpretable. **Ruling required with the GO**: keying 146's TX off
(`echo calibrated > .../out_voltage0_ensm_mode`, reversible, not an image change) is a
radio-state write to 146 that this task is not authorised to make.

**Recommendation if no ruling arrives:** do it — `calibrated` on 146's `voltage0` with an
explicit `rf_enabled` restore at leg end, verified by read-back: exactly the poke +
verified-restore pattern task 8a used on both boards. Radio state, not an image change.

**The coupling coin-flip, stated once so it can be decided once:** keying 146 off is
*required* for an interpretable stage 2 **and** is quite possibly what makes gate (a1) fail —
as things stand (a1) would be measuring **146's** carrier, not 148's self-coupling, so an
"it locks on air" today would be an artefact. These are the same decision. If the operator
would rather rig the Tx→Rx attenuator cable than spend a leg discovering the self-coupling
is too weak, that call is better made now than at the gate.

---

## 3. Flash pre-registration (Task 6 phase B)

`launch_rig_unit.sh flash148-seqbist <abs>/two_jup/skidfix/txfix_flash_go.sh
FLASH_MD5=a1ff3c876d91 FLASH_BAK=f6a8c3ea119c FLASH_TAG=seqbist DRY=0`, watched to UNITEXIT,
never killed mid-flash or mid-arm, **no retry loop** (the chain rolls itself back).
Post-flash: GPIO segments respond (0x9D410008 select sweep — slots 16–31 = 0 at rest after a
checker clear, slots 0–15 unchanged) and the checker reads 0 at rest.

**One re-arm attempt before the flash** is allowed for the 148 arm-quality collapse
(task-8a §9.1: 1242–1246 f/s on six legs, then 764–830 f/s failing 6/6), using the chain's
own gate stage (`arm148_mode1.sh`), not an ad-hoc arm. A first failed arm after the flash is
**not** a flash consequence.

---

## 4. What the DRY chain does and does **not** prove  [2026-09-03 23:30, unit `flash148-seqbist-dry`]

Proven: all five stages resolve and the file paths are right — `[1/5]` resolves
`boot_known_good/BOOT.BIN.148.seqbist.a1ff3c876d91` and verifies its md5; `[2/5]` stages
that exact file to `root@10.0.0.148:/root/BOOT.BIN.staged`; `[3/5]` expects `a1ff3c876d91`;
`[4/5]` runs the two-pass `arm148_mode1.sh` gate; `[5/5]` the sel-6 witness; exit
`FLASH_DDRCAP2_OK a1ff3c876d91 (sentinel untouched — external hold or DRY)`.

**Not proven, and not provable with this script:**
* `rollback()` **never executes under DRY** — every `[ "$DRY" = 1 ] ||` short-circuits the
  mismatch checks, `gate()` returns 0 unconditionally, and `poll_md5_nonempty` returns a
  non-empty `[dry]` line. The plan's "rollback path exercised in DRY" is **not achievable**;
  it is reported as a finding, not asserted as proven.
* The two-pass arm gate is likewise never exercised under DRY.
* `[1/5]`'s **on-board rollback-copy check is mis-proven under DRY**: it is
  `brd "… md5sum /root/BOOT.BIN.<bak>.bak …" | tee | grep -q "$BAK"`, and under DRY `brd`
  echoes the *command string* — which contains the literal `/root/BOOT.BIN.f6a8c3ea119c.bak`
  — so `grep -q` matches the path, not a checksum. That stage passes under DRY
  unconditionally, for the wrong reason. Substance covered instead by the real read-only
  check below (`BAKMD5=f6a8c3ea119c`, 7,203,552 B).
* `[5/5]`'s DDRCAP sel-6 witness is a **DDRCAP-v2-lineage** capture. The seqbist lineage is
  built from txfixF3, not from the ddrcap2 image, so its output may be uninterpretable.
  It is **post-gate and non-fatal** (`WITNESS_TIMEOUT` / a bad decode cannot roll back), so
  it is not read as a gate.

Read-only substitutes run instead (unit `t6-preflight-ro`) [silicon, 23:28]:
`148 IMG=f6a8c3ea119c` (= the banked restore point, so `[1/5]` will not FATAL),
`/root/BOOT.BIN.f6a8c3ea119c.bak` present, md5 `f6a8c3ea119c`, 7,203,552 B,
`/root` 20.3 GB free, `/boot` 701 MB free, both `lvds_61p44_fdd_jupiter.{bin,json}` present,
no daemons running. DRY also confirmed to set `SS_MINE=0` unconditionally and never touch
`SENTINEL_STOP` — the standing 17:27 hold (`SENTINEL_STOP`, `RIG_LOCK`,
`.keeper_hold_created`) was verified still present after the DRY run.

---

## 5. Commands (copy-paste)

```
# flash (phase B)
two_jup/launch_rig_unit.sh flash148-seqbist  <abs>/two_jup/skidfix/txfix_flash_go.sh \
    FLASH_MD5=a1ff3c876d91 FLASH_BAK=f6a8c3ea119c FLASH_TAG=seqbist DRY=0
two_jup/agents/watch_unit.sh --spawn flash148-seqbist <abs>/two_jup/sdd_archive/2026-09-03-seqbist/progress.md

# stage 1
two_jup/launch_rig_unit.sh seqbist-s1-ctrlA   <abs>/two_jup/seqbist/seqbist_run.sh DRY=0 BOARD=148 MODE=loopback FILL=1516 GAP=0 SKIP_EVERY=1000    DUR=180  TAG=ctrlA
two_jup/launch_rig_unit.sh seqbist-s1-ctrlB   <abs>/two_jup/seqbist/seqbist_run.sh DRY=0 BOARD=148 MODE=loopback FILL=1516 GAP=0 CORRUPT_EVERY=1000 DUR=180  TAG=ctrlB
two_jup/launch_rig_unit.sh seqbist-s1-clean   <abs>/two_jup/seqbist/seqbist_run.sh DRY=0 BOARD=148 MODE=loopback FILL=1516 GAP=0                    DUR=600  TAG=clean
two_jup/launch_rig_unit.sh seqbist-s1-mission <abs>/two_jup/seqbist/seqbist_run.sh DRY=0 BOARD=148 MODE=loopback FILL=1516 GAP=<mission>            DUR=600  TAG=mission
two_jup/launch_rig_unit.sh seqbist-s1-soak    <abs>/two_jup/seqbist/seqbist_run.sh DRY=0 BOARD=148 MODE=loopback FILL=1516 GAP=<mission>            DUR=1800 TAG=soak
python3 two_jup/seqbist/seqbist_score.py two_jup/comb/runs/<dir>

# stage 2
two_jup/launch_rig_unit.sh seqbist-s2-arm  <abs>/two_jup/seqbist/arm148_rf_self.sh DRY=0   # gates a0 (0x114=0) -> a1 (0x114=1) -> b
two_jup/launch_rig_unit.sh seqbist-s2-self <abs>/two_jup/seqbist/seqbist_run.sh DRY=0 BOARD=148 MODE=rf FILL=1516 GAP=<mission> DUR=600 TAG=s2self
```

---

## 6. Results  [silicon, 2026-09-04; full detail in sdd_archive/2026-09-03-seqbist/task-6-report.md]

**Image on 148:** `a1ff3c876d91f1a0330254cf10902748` (flashed 00:06, readback verified, gate
passed twice, no rollback). `tgen_mode` (0x9D410000 bit5) must be SET before any leg — nothing
in the toolchain did it, and without it every TGEN frame counts as `crc_fail`.

**Sink:** `SINK=tgenrx` is mandatory. Without a drain the seam stalls and every counter reads
0 while 0x104 runs at line rate (measured: 0x104 +179,274 with chk_frames 0).

### Stage 1 — fabric loopback, operating point GAP=60000 (622.7 f/s = every other air slot)

| leg | window | emitted | lost_slots | gap1 | gap2 | crc_fail | verdict |
|---|---|---|---|---|---|---|---|
| ctrlA-m (SKIP_EVERY=1000, GAP=73384) | 177 s | 110,208 | — | 151 | 13 | 0 | **PASS** (corrected 99.9 vs 110.2, tol 31.5) |
| ctrlB (CORRUPT_EVERY=1000) | 180 s | — | — | — | — | 0 | **PASS** (121 vs 116, tol 32, int_last 1000) |
| clean | 600 s | 377,161 | 217 (0.058 %) | 143 | 37 | **0** | **no 26 ms comb** (int_last has no 32/33) |
| soak 1800 s | — | — | — | — | — | — | **NOT RUN** (time went to stage-2 probes, per ruling) |

Saturated control GAP=45000: 1245.8 f/s, filler 0.00 %, **gap1 = 0**, gap2 17 — over-supply
family only. The gap1 family exists **only** when filler is interleaved with data.
TX pins clean on every leg (`d_tx_bit_errors = 0`) → loss is downstream of the TX byte plane.

**Verdict:** fabric loopback loss floor **0.058 %**, gap1/filler-adjacent, **no 26 ms
structure**. The on-air 8 % is not a fabric-loopback property.

### Stage 2 — OTA self-reception: **UNINFORMATIVE**
ROM self-couples at 1246 f/s (a0 and a1 both pass, at 0 dB and at −20 dB). No byte-plane
stream does: 390.8 f/s (GAP=60000), 493.4 (GAP=45000), and 209–626 f/s across six CFO/entropy
probes and three attenuation probes. CFO has no effect (P3 vs P6, the same setting, differ by
~150 f/s = the run-to-run noise floor). Low-entropy payload is **worse**, not better.
Attenuation does not recover it. In-gate rstcs 0–1: sync is stable, not storming.
The plan's prediction could not be evaluated — the bring-up gate never passed. Half-rate
detection with stable sync is the fact to carry: consistent with the sim's framing slip, but
self-reception is not the mission geometry.

### Host whitening fix-candidate: **NULL**
PER 8.170 %, lag32 +0.68, `QPSK_WHITEN=1` verified on **both** boards via `/proc/<pid>/environ`
(148 pid 35599, 146 pid 3451), 0/0 watchdog relaunches. Host payload is exonerated.

### Rig at hand-over
148 txgain 0 dB, TGEN off, sink disarmed, no daemons; 146 `rf_enabled` restored and verified,
no daemons. Both armed-ROM. Keeper hold / SENTINEL_STOP / RIG_LOCK all present, untouched.

---

## 7. Stage 3 results — fabric-only RF legs  [silicon, 2026-09-04 task 8; full detail in `sdd_archive/2026-09-03-seqbist/task-8-report.md`]

**146 image:** `3378861d30bd3d85663b31cfdd9c6296` (flashed 00:28–00:35, readback verified,
NAK rail and the 148-side health gate green first pass, **no rollback**). Rollback
`6b4744ca73f8` banked on nemo **and** as `/root/BOOT.BIN.6b4744ca73f8.bak` on 146.
⚠ `flash_146_txfix.sh`'s default `ROLLBACK_BANK` is `ec414d2df8bc`, not this restore point —
pass `ROLLBACK_BANK=boot_known_good/BOOT.BIN.146.txfixF3vendh.6b4744ca73f8` or the A0 gate
FATALs (the check is not DRY-guarded, so a DRY run does catch it).

### 7.1 The 146 instrument (SINK=cyclic, first silicon use) — CREDITED for loopback
60 s clean loopback at GAP=60000: ovf constant (`sink_witness_ok=1`), `chk_frames` tracks
0x104/0x124 to **0.0208 %**, `crc_fail` **0**, garbage **50.017 %** vs the 50.0 % filler
prediction, loss **0.0305 %** of 36,026 emitted, no 32/33 in `int_last`.
120 s `SKIP_EVERY=1000` control: **PASS** (expected 72.1, observed 110, background 40.0,
corrected 70.0, tolerance 25.5). Both carry the formal verdict UNINFORMATIVE for one reason
only — `window_s < 150` — and are quoted as instrument credit, not as scored legs.

### 7.2 The legs

| leg | geometry | gate | result |
|---|---|---|---|
| fwd GAP=60,000 | TGEN 146 → checker 148, `SINK=tgenrx` | **FAIL** 0x124 325.0 f/s, chk 279.5, dev 14.0 % | aborted, no window spent |
| **fwd GAP=45,000** | same, filler-free | **PASS** 0x124 1252.4, chk 1251.3, dev 0.084 % | **600 s leg — see below** |
| 3h (host-frame) | checker on 148 on the **real daemon stream**, `tgen_mode=0`, `SINK=none` | n/a | **400 s — see below** |
| rev GAP=45,000 ×3 | TGEN 148 → checker 146 | cyclic ×2 chk=0; daemon-sink: 0x124 halves to 531.9 | **UNINFORMATIVE** |

**fwd GAP=45,000, 600 s, no daemon / no DMA / no host:** garbage **5.894 %**, crc_fail
**0.449 %**, gap_events **5.31 %** (gap1 70.9 / gap2 21.4 / gap3+ 7.7), 0x104/0x124/chk
agreement 0.07 %, `period_est` **32.15** frames.

**3h, 400 s, real daemon traffic:** garbage **5.661 %**, crc_fail **2.118 %** (10,211), gap_events
**5.225 %** (gap1 71.9 %), agreement 0.025 %, `period_est` **32.24** frames = the 26 ms comb.

> **PREREG RESOLVED.** The loss and the comb reproduce with **no DMA and no host anywhere**
> (5.3 % gap events + 5.9 % garbage at the decoder pins vs 8.12 % at the host on a1r2, against
> a loopback floor of 0.058 % / 0.031 %). **The defect is in the fabric / RF chain; the
> host/DMA path is exonerated.**

### 7.3 Secondary findings
* **Filler frames are lethal over RF only.** GAP=60,000 (every other slot an all-zero
  unmodulated frame) collapses 148's frame sync to 325 f/s; GAP=45,000, same everything
  else, decodes at 1252 f/s. This also retires stage 2: filler-free works in the real
  geometry, so the self-reception collapse was self-reception-specific.
* **An ~8-frame (6.4 ms) structure sits under the 32-frame comb** — `int_last` clusters at
  7–9 and 23–25 with a 31–33 tail, `int_hist_lt30` is 74 % of intervals. **[inferred]**
* **D-8-1: `SINK=cyclic` drains the seam in loopback and NOT in the RF-armed state** (two
  attempts, drain-first ordering fixed and committed in between). Loopback-only credit.
* **On the receiving board, a live local daemon halves its own detection rate** (531.9 vs
  1246 f/s) — the same half-rate shape as stage 2.
* **TX-side DDRCAP sel8 on 148 credited** (512 MiB, exit 0); `ddrcap2_pc.py --sel 8` TIER2
  FAIL on `toff_range_steady` only (d0 = 489), every other gate PASS.

### 7.4 Instrument corrections made tonight
1. `lost_slots` is **VOID** on an RF leg (corrupted-seq artefact: a good-magic frame with a
   damaged seq injects a gap of up to 2^32; the counter reached 3.96e10 and wrapped 25×).
   `seqbist_score.py` now detects the signature and scores on `gap_events/emitted` + garbage
   + crc_fail. **A checker revision should reject a seq that is not `last_seq + k`, k ≤ 64.**
2. The `0x114` read-back gate in `MODE=rf` was **false** (write-only register) and refused a
   leg whose own on-air gate had just passed. Removed.
3. The drain must be armed **before any traffic exists**.
4. `arm_guard` is too wide for an in-leg reader (it refuses for the whole of `capture_r3.sh`).
5. Long multi-line remote command strings return **empty** from 146 while each fragment works
   alone; `seqbist_read.py` is unaffected (verified).

### 7.5 Hand-over
148 `a1ff3c876d91` + 146 `3378861d30bd` (**both on the seqbist images**; rollbacks
`f6a8c3ea119c` / `6b4744ca73f8` banked on nemo and on the boards). Plain daemons rebuilt and
running on both via `capture_r3.sh`'s own build line, `nakstat = 4` verified on 148,
watchdogs up, reverse LO restored to the shipped `1900040000`. Keeper hold **released**
(`KEEPER_RELEASE_OK released=[SENTINEL RIGLOCK]`); sentinel relaunched as
`sentinelkeeper-044058` and logging `ok rate=1166/s`.
