> Evidence ledger, moved verbatim from `two_jup/comb/MORNING_REPORT_0908.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# Morning report — overnight 2026-09-07 21:24 → 2026-09-08

**Instruction I worked to:** "I'll be away until 7am EST. Run and use hardware as needed
without approval. Solve outstanding issues."

**Headline: I did not solve it. I localised it, and I killed three of my own hypotheses
doing so.** The forward leg is still broken at the shipped carrier. What changed overnight
is that the defect now has a measured profile, a calibrated instrument pointed at it, and
a much shorter list of things it can be.

**One-line status:** forward leg (146 TX → 148 RX) at the shipped 2000 MHz carrier decodes
**27.5 % of every frame's first 120 bits wrong**, while delivering **every frame** and
holding carrier lock perfectly. Measured **seven times** across four independent sweeps:
0.2755, 0.2645, 0.2782, 0.2814, 0.2778, 0.2740, 0.2915, 0.2823 — mean 0.276, spread ±5 %,
**~175,000 frames**, full delivery on every one.

**Rig state: restored, verified, and handed back.** Both boards on their banked images, no
flash performed at any point tonight, keeper hold released. Details in §9.

---

## 1. The defect, as measured

The impairment is **frequency-selective and follows the band, not the board** — established
09-07 by exchanging the transmitting and receiving boards at each carrier. Tonight's sweeps
resolved the structure on a 10-20 MHz grid, 25 s per point, ~31,200 frames per point.

**Three separate failing regions between 1845 and 2265 MHz:**

| region | extent | signature | frames delivered |
|---|---|---|---|
| **~1965-2005 MHz** | ~40 MHz, floor at 1980 | carrier loop thrashing (rstcs 40-59,000) | 25-93 % |
| **~2110-2125 MHz** | 15-40 MHz | mixed; loop quiet at 2110/2115 | 35-100 % |
| **1920 MHz** | ≤ 20 MHz | loop resets (rstcs 2,586), **normal CFO** | 93 % |

Everything else measured is spotless: **1845, 1860, 1880, 1900, 1940, 1950, 1960, 2010,
2020, 2040, 2060, 2080, 2100, 2140, 2170, 2200, 2235, 2250** — eighteen points, zero bit
errors, full frame delivery, at 8 s or 25 s dwell.

**The shipped 2000 MHz carrier sits inside the first region**, 20-25 MHz up its recovering
flank. That is why the link is degraded rather than dead: carrier lock holds, every frame
arrives, and the first 120 bits of each are ~28 % wrong.

## 2. The strongest single result: this is not RF

At 2110 MHz, changing the receiver's LO offset from +20 kHz to +40 kHz — **9.5 ppm** —
changed frame delivery from **11,018 of 31,176 (65 % missing)** to **31,109 of 31,176
(0.2 % missing)**, with carrier resets going 1 → 0 and received level unchanged (28.265 →
27.977 dBFS, 0.29 dB).

**No RF mechanism — multipath, reflection, antenna pattern, spur, roll-off, level — varies
measurably over 9.5 ppm.** This came out of a control I ran for an unrelated purpose, and
it is the cleanest evidence of the night that the band structure is not a propagation
problem. Please weight it accordingly, because it contradicts the direction I was heading
in for most of the night.

Supporting this, RF level was excluded four independent ways:
1. 2000 MHz fails at rssi 30.0 while 1960 is clean at 30.3 — **equal-or-weaker level,
   opposite outcome**, measured twice on each side.
2. The muted-transmitter noise floor (Task 64) leaves 27.5 dB of margin at the failing
   carrier — *more* margin than at the working one.
3. BER sits flat at ~0.26 across an 8.5 dB level recovery from 1980 → 1990 → 2000.
4. Board 146 decodes **0 errors in ~10,000 frames per point at rssi ~37.8 dBFS**, weaker
   than any level at which 148 fails.

## 3. The new instrument: CFC is a calibrated frequency meter

Register 0x154 (`cfc`) turns out to be linear in residual carrier frequency offset at
**~150 counts/kHz**, established two ways that agree:

- **147 counts/kHz** — doubling the receive offset at two known-clean frequencies 240 MHz
  apart (2010 and 2250) roughly doubled CFC, and both stayed clean.
- **153 counts/kHz** — Task 60's independent sweep of the *transmit* LO across ±80 kHz,
  run four hours earlier, in the opposite sense as it must be.

With that calibration, the failing frequencies say something new:

| where | commanded offset | implied residual | **error** | arm-to-arm spread |
|---|---|---|---|---|
| 18 clean points | +20 kHz | -19 to -29 kHz | ~0 | **9.5 kHz** |
| 2010, 2250 | +40 kHz | -41 to -44 kHz | ~0 | 3 kHz |
| **2000 MHz** (×7) | +20 kHz | -5 to +39 kHz | **+20 to +35 kHz** | **44 kHz** |
| **2110 MHz** | +40 kHz | **~-121 kHz** | **-81 kHz** | — |

**The carrier arrives at the wrong frequency by a frequency-selective amount, and the
error is largest where the damage is worst.** At 2110 the receiver tracks an 80 kHz error
with the loop perfectly quiet and every frame delivered, and still decodes wrong.

**This is a co-symptom, not the cause.** Task 60 already established that deliberately
correcting the carrier by up to ±80 kHz at 2000 MHz leaves BER flat at 0.27-0.38 with no
minimum. Something upstream is both mistuning the carrier and corrupting the bits;
correcting the frequency alone repairs neither.

## 4. Three hypotheses of mine that died overnight

I am listing these because the surviving picture is only as good as what was cleared out
of the way, and because two of them appear in earlier drafts you may have seen.

**(a) The two-ray multipath comb — REFUTED, and the 2.22 m figure is WITHDRAWN.**
Having found failures at ~1980 and ~2110, I inferred a null spacing of ~135 MHz, an excess
path length of **Δd ≈ 2.22 m**, and predicted further nulls near **1845** and **2250**. I
pre-registered the prediction, then tested it at four frequencies. **1845, 2235 and 2250
all came back with zero errors and full delivery** — 2235 and 2250 are among the cleanest
points of the night. The model is wrong and the number is retracted. **Do not go looking
for a 2.2 m reflector.** If an earlier draft reached you suggesting a physical inspection
target, that was this, and it is withdrawn.

**(b) The CFO dead zone — REFUTED as the cause.** The demod is documented to fail at
residual CFO ≈ 0, and at the shipped carrier CFC reads near zero while every clean point
reads ≈ −3450. That looked like the whole answer and it implied a one-line fix. Doubling
the LO offset moved CFC squarely back into the clean band and **did not recover a single
bit** (0.3099 vs the 0.2915 control, level unmoved). There is no one-line LO fix.

**(c) The 38.4 MHz device-clock spur reading — unresolved, weakened.** 1920 MHz is exactly
50 × 38.4 and ~2112 is 55 × 38.4, which is suggestive. But the ~2110 feature turned out to
be **15-40 MHz wide** (2115 and 2125 both fail), which is far too broad for a single CW
spur, and 1845 — 1.8 MHz from 48 × 38.4 — is clean. Still live for **1920** specifically,
which is the one failing point with a completely normal CFO reading and therefore probably
a different defect from the other two regions.

## 5. Two process failures on my side, stated plainly

**I re-ran a settled experiment.** The project memory note on this defect already recorded
that Task 60 swept ±80 kHz of LO offset and found BER flat with no minimum. I wrote up the
dead-zone hypothesis and spent a rig leg testing it without re-reading the note that
contained the answer. The leg produced two genuinely new results (§2, §3), so it was not
wasted — but the central question was answerable from the archive at zero cost.

**I quoted six numbers I was not entitled to quote.** The same note records that CFC is
not a valid measurement wherever `rstcs` is non-zero. My first write-up of the CFC finding
built its table partly on readings taken from an unlocked carrier loop. Corrected in the
ledger (§43.4); the conclusion survives on the valid rows and is cleaner without the
invalid ones.

## 6. A monitoring gap worth fixing regardless

**The health sentinel is blind to this defect.** It gates on delivery rate (≥ 1120 f/s),
and this defect does not reduce delivery rate — every frame arrives, with wrong bits. The
sentinel logged 348 samples at ~1245 f/s across 09-06/09-07 and passed a full r3 arm gate
at 09-07 18:21, hours after the collapse was already present. **Recommend adding a CRC or
0x108 bit-error check to the sentinel**, independent of everything else here.

## 7. Numbers, with the qualifications the rig rules require

- **Shipped-carrier BER:** `ber_120b` = 0.2755 / 0.2645 / 0.2782 / 0.2814 / 0.2778 /
  0.2740 / 0.2915 / 0.2823. Command: `two_jup/comb/band_ber_sweep.sh` (unmodified) via
  `two_jup/launch_rig_unit.sh`, `DRY=0 DWELL=25 WINBITS=120`. **~175,000 frames.**
  **Denominator note: full delivery on every one of these** — 31,176-31,177 of 31,177
  frames detected, so no frames are missing from the denominator.
- **Every BER quoted at 1980, 2110 (at +20 kHz), 2125 or 2265 understates the damage**,
  because register 0x104 counts *detected* frames and 25-65 % of frames were never
  detected at those points. Those frames are in neither numerator nor denominator.
- **`ber_120b` scores only the first 120 of 2240 bits per frame** (register 0x108). Every
  bit-error figure here is frame-**start** damage and says nothing about the rest of the
  frame.
- **`fps` in the sweep tables is unreliable** — the dwell timer has 1-second granularity.
  Score `frames`, not `fps`.
- **This is a diagnostic measurement configuration, not a shipped one.** Nothing was
  adopted; `bringup_r2r3.sh` is unedited.
- **Not confirmed:** no PER/BER target is claimed as met anywhere in this report. The
  forward leg is **out of specification** and remains so at hand-back.

## 8. Suggested next steps — yours to decide

In the order I would take them:

1. **Correct the carrier at 2110 FULLY and see if the bits follow.** Be precise about
   what has already been tried: T69 corrected 2110 by **20 kHz against an ~80 kHz error** —
   **delivery recovered completely** (35 % → 99.8 %) and **the bits did not** (0.3567). A
   partial correction moved detection and left the bit errors, which is the same pattern as
   2000 MHz. A **full** correction has never been tried: one sweep at
   `OFF=120000 FREQS="2110"`, five minutes, settles whether the residual frequency error is
   what breaks the bits. This is the highest-value open experiment.
2. **Ask why the carrier lands 20-80 kHz off at three specific frequencies.** This is now
   the sharpest question in the investigation and it is a synthesiser/LO-planning question,
   not a DSP one. Worth an hour with the ADRV9002 PLL configuration and the frequency plan.
3. **Move an antenna and re-measure the band map.** Cheap, and it settles the last
   RF-versus-radio ambiguity. Under the (now refuted) multipath model the features move;
   if they stay put, propagation is finally out of the picture entirely.
4. **Add the CRC/0x108 check to the sentinel** (§6) — independent of the diagnosis.
5. **1920 MHz is probably a separate defect** — normal CFO, carrier resets, exactly on
   50 × 38.4 MHz. Worth separating from the other two regions rather than folding in.

## 9. Rig state at hand-back

- **No flash was performed tonight, on either board, at any point.** Both boards are on the
  images they started on: **148 = `BOOT.BIN.148.rxfixr4b.9f13705d9fb0`**,
  **146 = `9acbe2ebe1db`**.
- Four rig legs ran (Tasks 67, 68, 69, 70), each as a `launch_rig_unit.sh` unit with a
  watcher. **Every one completed with `SWEEP_OK` and `restore: BRING-UP OK`**, and every
  one restored the shipped LOs and re-armed via `bringup_r2r3.sh r3`.
- Final readback after the last leg (03:20:37):
  `148 txlo=1900000000 rxlo=2000020000 txensm=rf_enabled rxensm=rf_enabled txatt=0 rxgain=34.0`
  `146 txlo=2000000000 rxlo=1900040000 txensm=rf_enabled rxensm=rf_enabled txatt=0 rxgain=34.0`
  — the shipped configuration on both boards.
- **No board wedged, no permission or classifier denial occurred, and no command failed**
  across the whole window.
- Keeper hold released and hand-back verified by effect — see the verification block
  appended below.

**Full record:** `two_jup/comb/FWD_CRC_REGRESSION_0907.md`, §36-§43 for tonight
(§38 the comb refutation, §39/§41 the CFO work, §43 the calibration and the corrections).
Pre-registrations are §37, §40 and §42, each committed before its leg was launched.

---

## Hand-back verification (the block §9 promised) — 2026-09-08 03:41–03:47

The keeper hold is released and the rig is back in service. Verified by effect, not by the
tool's own success message.

**Release command** (note the trap: `keeper_hold.sh` defaults `DRY=1`, whose tell is a unit
named `sentinel-000000`; this ran with `DRY=0` and named a real unit):

```
DRY=0 bash two_jup/comb/keeper_hold.sh release
  03:41:46 removed SENTINEL_STOP
  03:41:46 removed RIG_LOCK
  03:41:46 relaunched keeper as sentinelkeeper-034146
  KEEPER_RELEASE_OK released=[ SENTINEL RIGLOCK]
```

The marker file read `SENTINEL RIGLOCK`, so both files were ones this campaign created and
both were ours to remove.

**Verified by effect:**

| check | result |
|---|---|
| `~/modem-status/SENTINEL_STOP` | absent |
| `~/modem-status/RIG_LOCK` | absent |
| `~/modem-status/.keeper_hold_created` | absent |
| `sentinelkeeper-034146.service` | loaded **active running** |
| `sentinel-034146.service` | loaded **active running** (the keeper started it) |
| `sentinel.log` ticking | yes — `03:41:58 ok rate=851/s`, `03:46:59 ok rate=865/s` |
| 148 image `md5sum /boot/BOOT.BIN` | `9f13705d9fb0` — matches banked rxfixr4b |
| 146 image `md5sum /boot/BOOT.BIN` | `9acbe2ebe1db` — matches banked |
| 148 RF (03:20 readback) | `txlo=1900000000 rxlo=2000020000 tx/rx ensm=rf_enabled txatt=0.0 rxgain=34.0` |
| 146 RF (03:20 readback) | `txlo=2000000000 rxlo=1900040000 tx/rx ensm=rf_enabled txatt=0.0 rxgain=34.0` |

Nothing was flashed tonight, on either board, in any window. Both boards are on their banked
images and the shipped LO configuration.

**One snag worth knowing about:** the release was blocked twice by the auto-mode classifier —
both times with messages self-identifying as transient infrastructure errors ("not a judgment
that the action is unsafe... wait briefly and try this action again as-is"). I waited two
minutes and re-ran the **identical** command, which succeeded. I did not rewrite the command
to get around the block, and no other action was attempted during the denials.

---

## 10. Late finding: the delivery sentinel may be a free monitor for this defect

> **SUPERSEDED IN PART, 07:30 — read `two_jup/RESUME_20260908_0730.md` §3 first.** This
> section was written at 03:50 from four samples spanning sixteen minutes and describes a
> "~30 % deficit". Three and a half more hours of unattended, rig-idle sampling show the
> deficit is **episodic, not steady**: recovery to ~1180 by 04:27, drift to ~1020, a
> **collapse to 163–358 f/s for the full hour 06:27–07:23** (the most severe excursion in
> the record), then 1237 at 07:28. Do not quote "30 % deficit". The 15-minute test proposed
> at the end of this section is also too short to span an episode — see the resume file.

Found at 03:50 while verifying the hand-back, from `~/modem-status/sentinel.log` — read-only,
no rig action. **Read §45 in the ledger, not §44: §44 is what I first wrote and §45 is where
I retract most of it forty minutes later after reading two log files I should have read
first.** The retraction is in the ledger in full; here is what survives.

**A clean healthy baseline exists.** The sentinel's low mode read **exactly 1245 f/s** — not
1245 ± noise, exactly 1245 — for **34 consecutive hours**, twelve samples an hour, ending
with the sample at `2026-09-07 18:00`. That is the best "known good" reference this campaign
has.

**Tonight it reads 828–881.** Post-release samples: `03:41:58 → 851`, `03:46:59 → 865`,
`03:52:01 → 881`, `03:57:03 → 828` — sixteen minutes, no upward trend, so not a settling
transient. (Correction to an earlier draft of this section: these are **not** the lowest
readings in the record. 74 of 2136 samples are below 900 f/s and the record low is 389. What
is unusual about tonight's is not their rank but that the rig is *verified idle* — see
below.)

**And that number is clean — tested against a control, not asserted.** The release also
*relaunched* the sentinel, so "nothing running" needed ruling out against "still starting up."
The record settles it: across the **18 keeper relaunches since the 1245 baseline began**, the
first sample after the relaunch was 1245, within 1 % of it, or in the high mode — in 17 of 18
cases. Tonight's 851 is the sole exception. A restart does not depress the sentinel. Unit list
at 03:58 confirms only `sentinel-034146` and `sentinelkeeper-034146` are running and no hold
file is present. So unlike the evening's readings (contaminated by my own experiments, and
retracted as evidence by §45), this is a real ~30 % deficit against baseline with the rig
idle. Ledger §45.7 has the per-relaunch numbers.

**Why it might matter:** 30 % is about the size the forward collapse predicts. The forward
leg runs at 58–61 % crc_ok; 1245 × 0.6 ≈ 747, and a mixed forward/reverse measure would land
between that and 1245. 865 is in that band. If the sentinel number and the CRC number are the
same defect seen twice, then **there is a continuous, zero-cost monitor for this bug already
running and already logging**, and its history goes back to 08-25.

**One thing I cannot account for:** the sentinel's bimodal high mode (1750–1868) appears
throughout the record and then stops dead after `2026-09-07 20:21`. It has not appeared in
any sample since. Rig activity does not explain that, and I have no story for it.

**The 15-minute test that settles it, needing no flash:** run the sentinel idle for one
window and score a `rom_air_ber.sh` leg on the same boards beside it. If the sentinel deficit
tracks the ROM air BER, it is the same defect and you have a monitor. If it does not, it is a
second defect and it has been hiding in plain sight in a log file since 08-25.

**What I retracted, so you do not chase it:** I initially read a five-minute onset window
(18:00→18:05 on 09-07) and a coincident 148 flash as a causal lead. Both are dead. The flash
log records `fps=1248 errps=0` twice with `GATE_PASS x2` and a clean Tier-2 witness four
minutes after that flash — the board was healthy. And `SENTINEL_STOP` was already present at
18:09:44, so the rig was being held during the interval I called the onset, which
contaminates the sample. **Do not go looking for what happened at 18:05.**
