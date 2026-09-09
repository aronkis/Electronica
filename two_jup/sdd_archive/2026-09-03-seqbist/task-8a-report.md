# Task 8a — radio-process probes on the forward leg (SEQ-BIST, 2026-09-03 22:0x–23:1x)

Driver: Task 8a rig driver. Ledger: `two_jup/sdd_archive/2026-09-03-seqbist/progress.md`.
Pre-registration: `two_jup/comb/RADIO_PROBES_PREREG.md`, committed **`de31d62`, before any leg ran**.
Knob enumeration: `two_jup/comb/RADIO_KNOBS_148.md`.

Every board action ran as a `launch_rig_unit.sh` unit with a `watch_unit.sh --spawn` watcher.
Every number below is **[silicon]** (measured on the rig) unless marked **[inferred]**.

## 0. Headline

**Both pre-registered probes are NULL, on both pre-registered axes.** Freezing 148's RX gain
control (P-A) and disabling all five of its RX tracking calibrations (P-B) each left the
forward-leg PER at ~8.4 % and left the ~26 ms comb fully present. **The leading hypothesis
from T3 — that a periodic RX gain-control / tracking-calibration process on the receiving
board is the 26 ms process — is FALSIFIED for every such process the ADRV9002 driver exposes
on RX0.**

**P-D closes the transmitter side without needing a leg**: every TX tracking calibration on
146 is *already* disabled (`initial_calibrations = off`, all five `out_voltage0_*_tracking_en`
= 0), so a periodic TX radio process on the transmitter cannot be the 26 ms process either
(§6). **P-C is UNINFORMATIVE** (§5).

Three findings arrived alongside the nulls that matter more than the nulls themselves:

* **The AGC never moves.** 148's RX gain sat at exactly `34.000000 dB` on all 16 live reads
  across three legs, while RSSI drifted. `maxGainIndex = 255`, `minGainIndex = 187` → 68
  steps, and 34.000 / 68 = **exactly 0.5 dB per step**, so **34.000000 dB is gain index 255 =
  the AGC's maximum-gain rail** [inferred, arithmetic on measured values]. The receiver is
  pinned at maximum gain with no headroom, on a link running 92 % CRC. That is a link-budget
  finding independent of the comb, and it is why P-A could only ever remove the AGC's
  *periodic evaluation tick*, never any gain motion — there was none to remove.
* **The two radios are configured identically.** A full diff of every non-signal ADRV9002
  phy attribute between 148 and 146 returns **nothing** (§7). The forward leg loses 8.1–8.4 %
  and the reverse 3.7 % on byte-identically configured radios, so the 2.2× directional
  asymmetry is **not** an ADRV9002 configuration difference — that explanation is now closed.
* **The period may not be crystal-stable.** Across three forward legs it measures **26.055,
  25.466 and 25.821 ms** — a ±1.2 % spread, run to run, on the same pair of boards. A process
  clocked off a 38.4 MHz crystal would repeat to ppm, not to 1 %, so this weakens the
  "1,000,000 cycles of the ADRV9002 device clock" reading that motivated these probes.
  **Caveat, stated because it bounds the claim: this is a ONE-INSTRUMENT result.** All three
  numbers come from `comb_period_ms.py`, written and calibrated tonight against a single
  reference point (a1r2). The ±1.2 % spread could be the estimator's own variance on a ~700 s
  window rather than real drift. T3's two *independent* instruments agreed to 0.25 % on the
  same night — that is the comparison that would settle it. **Worth a second instrument before
  this is treated as established.**

## 1. Legs

| leg | unit | run dir | outcome |
|---|---|---|---|
| P-A att.1 | `probe-8a-A` | `comb/runs/20260903_221742_probeA_pA` | **WEDGED at 12 s** — `MID_CAPTURE_WEDGE`, exit 3. `accept_analyze`: `UNUSABLE (live window 0s of 36s, WEDGED)`. UNINFORMATIVE. Restore **VERIFIED**. |
| P-A re-run | `probe-8a-A-r2` | `comb/runs/20260903_222141_probeA_pAr2` | ran **540 s of the 580 s** window, then a tail wedge. 883,422 records. `deliver_rate` 949 f/s ⇒ `gate_pass=0`. Scored (§3). Restore **VERIFIED**. |
| P-B | `probe-8a-B` | `comb/runs/20260903_223721_probeB_pB` | ran **516 s**, then a tail wedge. 883,391 records. `deliver_rate` 954 f/s ⇒ `gate_pass=0`. Scored (§3). Restore **VERIFIED**. |
| P-C att.1 | `probe-8a-C` | `comb/runs/20260903_225859_probeC_pC` | **aborted at the PRE-window gate** (0 f/s after 4 re-arms); poke never ran. |
| P-C r2 | `probe-8a-C-r2` | `comb/runs/20260903_230437_probeC_pCr2` | poke landed, **wedged at 12 s**. ⇒ P-C **UNINFORMATIVE** (§5). Restore **VERIFIED**. |
| P-D att.1 | `probe-8a-D` | `comb/runs/20260903_231005_probeD_pD` | poke landed on **146**, **wedged at 12 s**. Restore **VERIFIED**. |
| P-D r2 | `probe-8a-D-r2` | `comb/runs/20260903_231318_probeD_pDr2` | **bring-up failed** (arm gate 6/6). ⇒ P-D RX attempt **UNINFORMATIVE** (§6). Restore **VERIFIED**. |

### 1.1 The wedges are the rig, not the probes [silicon]

Stated plainly because it is the obvious objection to two nulls.

* **The 12 s attempt-1 wedge is this rig's base rate, with no poke of any kind.** T2's m16
  attempt 1 wedged at 12 s; T3's A1 attempt 1 wedged at 12 s (`CAPTURE_ABORTED_WEDGED`, no
  attribute touched). P-A attempt 1 did the same. P-A's re-run then sailed past 12 s with the
  gain frozen — so the pre-registered "gain-freeze not sustainable" third branch is **not**
  triggered.
* **The tail wedge hit P-A r2 (at 540 s) and P-B (at 516 s) alike** — two different pokes, one
  common failure. P-B is the control for P-A and vice versa: the tail wedge is not attributable
  to either knob.
* Neither wedge cost the analysis anything material: `accept_analyze`'s own live-window rule
  cuts the wedged tail, leaving 709 s and 706 s of scored window respectively, and
  `COMB_STATE.md` item 6 is explicit that a pre-wedge window is still scored for the comb.

### 1.2 Credit status, and why the nulls are still decidable [silicon]

Both legs armed at ~950 f/s, below the 1000 f/s `legrun_go.sh` gate, so both are
`deliver_rate_gate_pass=0` — **not credited for PER**, exactly as T3's leg A2 was at 954 f/s.
This was recorded in `RADIO_PROBES_PREREG.md §7` **while P-A's window was still running and
before any PER existed**, together with the reason it does not block a verdict: T3 established
the control that A2 at **954 f/s** gave PER **8.271 %** against a1r2's **8.121 %** at
**1909 f/s** — a 2× rate difference and a 0.15 pp PER difference. The HIT/NULL thresholds
(4–5 % vs 7.6–8.6 %) are far outside that spread, and the period measurement does not depend
on delivery rate at all.

## 2. Attributes: read, applied, restored [silicon]

Applied through the new `RX_ATTR_POKE` hook in `capture_r3.sh` §5c — same position as the
existing `LOOP_POKE`, i.e. **after the RF arm and the health gate, before the framelog rotate
that starts the scored window**. Restored by `radioprobe_go.sh`'s `trap` on EXIT/INT/TERM,
from the live before-values the hook recorded, with a read-back verify.

| probe | attribute | before | after | restored | read-back |
|---|---|---|---|---|---|
| P-A | `in_voltage0_gain_control_mode` | `automatic` | `spi` | `automatic` | ✅ |
| P-A | `in_voltage0_hardwaregain` | `34.000000 dB` | `34.000000 dB` | `34.000000 dB` | ✅ |
| P-B | `in_voltage0_agc_tracking_en` | `1` | `0` | `1` | ✅ |
| P-B | `in_voltage0_bbdc_rejection_tracking_en` | `1` | `0` | `1` | ✅ |
| P-B | `in_voltage0_rfdc_tracking_en` | `1` | `0` | `1` | ✅ |
| P-B | `in_voltage0_rssi_tracking_en` | `1` | `0` | `1` | ✅ |
| P-B | `in_voltage0_quadrature_fic_tracking_en` | `1` | `0` | `1` | ✅ |

`attr_write_fails=0` on every leg; `attr_restored=1` on every leg, **including the wedged
attempt 1** — the trap fired on the failure path, which is the case it exists for.

**Caveat, stated rather than glossed [inferred]:** a sysfs read-back of `_tracking_en` returns
the driver's cached value. It confirms the write reached the driver; it does not prove the
ADRV9002 firmware stopped that tracking calibration. P-B's null is therefore "null, with the
enable confirmed at the driver interface". No ENSM state cycle was attempted to strengthen
this — that re-arms the radio mid-leg and risks the documented no-ping board hang, and it was
pre-registered as out of scope (`PREREG §3`, fourth branch).

## 3. Per-probe results [silicon]

Baseline = T3's credited forward leg **a1r2** (`t3-run-report.md`).

| quantity | **a1r2 (baseline)** | **P-A** gain→manual | **P-B** tracking cals off |
|---|---|---|---|
| scored window | 718 s of 723 s | 709 s of 731 s | 706 s of 734 s |
| slots | 875,375 | 864,331 | 860,600 |
| **PER** (lost frames in denominator) | **8.121 %** | **8.410 %** | **8.325 %** |
| CP95UL | 8.179 % | **8.469 %** | — |
| pre-registered NULL band | — | 7.6–8.6 % → **inside** | 7.6–8.6 % → **inside** |
| pre-registered HIT target | — | 4–5 % → **not met** | 4–5 % → **not met** |
| **period (band 25–27 ms)** | **26.055 ms** (32.4497 fr) | **25.466 ms** (31.716 fr) | **25.821 ms** (32.159 fr) |
| band Rayleigh R | 0.1737 | **0.1479** (0.85×) | **0.1094** (0.63×) |
| random-event null | 0.0148 | 0.0162 | 0.0154 |
| R at exactly P = 32.000 | 0.0008 | 0.0026 | 0.0250 |
| **COMB_LINE verdict** | present | **present** | **reduced, not absent** (7× null) |
| lag-32 (ALL-LOSS) | +0.5259 | **+0.6392** | **+0.7422** |
| dominant lags | 65, 97, 32, 33 | 95, 127, 32, 63 | **32, 64, 96, 128 (slip 0)** |
| lag-16 floor | −0.0855 | −0.0863 | −0.0868 |
| run bins 1 / 2 / 3-4 / 5-20 | 35,342 / 16,140 / 632 / 146 | 35,516 / 16,402 / 634 / 214 | 34,782 / 16,426 / 597 / 196 |
| MAGIC share of failures | 71.4 % | **72.0 %** (50,210 / 69,771) | **71.7 %** (49,294 / 68,765) |
| ZEROTAIL | 0 | 0 | 0 |
| TX↔RX join `never_sent` | 0 | **0** | **0** |
| Δ0x104 vs host records | 854,729 vs 854,321 (99.95 %) | 900,035 vs 883,422 (98.2 %) | 896,734 vs 883,391 (98.5 %) |

Commands (all from the repo root):
```
two_jup/launch_rig_unit.sh probe-8a-A    <abs>/two_jup/comb/radioprobe_go.sh PROBE=A DRY=0 DUR=600 TAG=pA
two_jup/launch_rig_unit.sh probe-8a-A-r2 <abs>/two_jup/comb/radioprobe_go.sh PROBE=A DRY=0 DUR=600 TAG=pAr2
two_jup/launch_rig_unit.sh probe-8a-B    <abs>/two_jup/comb/radioprobe_go.sh PROBE=B DRY=0 DUR=600 TAG=pB
two_jup/launch_rig_unit.sh probe-8a-C    <abs>/two_jup/comb/radioprobe_go.sh PROBE=C DRY=0 DUR=600 TAG=pC
two_jup/agents/watch_unit.sh --spawn <unit> two_jup/sdd_archive/2026-09-03-seqbist/progress.md
two_jup/comb/score_probe.sh <run-dir>          # accept_analyze + comb_autocorr + comb_period_ms + comb_census
```

## 4. Verdicts against the pre-registration

### P-A — RX gain control → manual, gain frozen: **NULL** (falsifier met)
PER **8.410 %** is inside the pre-registered null band 7.6–8.6 % and nowhere near the 4–5 %
hit target. The 26 ms line **survives** at R = 0.148, 0.85× the a1r2 baseline and 9× the
random-event null; the pre-registered "absent" condition (band R < 0.05, lag-32 and lag-65
both < 0.1) is not remotely met — **lag-32 rose** to +0.6392. The k×32 family and the dead
lag-16 floor (−0.0863) are unchanged.

**What this does and does not falsify.** Because the AGC was pinned at index 255 and never
moved (§0), P-A removed the AGC loop's *periodic gain-update evaluation* and nothing else.
So it falsifies "the AGC's periodic tick (`gainUpdateCounter = 11520`) is the 26 ms process".
It says nothing about gain *excursions*, because there were none on this link to begin with.

### P-B — RX tracking calibrations off: **NULL** (falsifier met)
PER **8.325 %**, inside the null band. All five `_tracking_en` writes took and read back 0.
The comb not only survived, it **sharpened**: lag-32 **+0.7422** — the strongest of any leg in
the campaign, against a1r2's +0.5259 — with the family sitting exactly on k×32 (32/64/96/128,
slip 0) instead of the usual ±1-slipped harmonics. `band R` fell to 0.109 (0.63× baseline),
which by the pre-registered banding reads "reduced"; that is **not** a hit and must not be
reported as one, because the same leg's integer-lag comb is the strongest measured. [inferred]
The two metrics move oppositely because the Rayleigh statistic is measured over a ~700 s
window and a period that wanders (§0) smears its concentration, while integer-lag
autocorrelation does not care about slow period drift.

**So: AGC tracking, baseband DC-offset tracking, RF DC-offset tracking, RSSI tracking and
quadrature/QEC (FIC) tracking on 148's RX0 are each excluded as the 26 ms process.** Together
with `initial_calibrations = off` (already off before the campaign) and 148's five TX
`_tracking_en` already at 0, **there is no remaining periodic radio process on 148 that this
driver exposes.**

## 5. P-C — both knob sets on 148: **UNINFORMATIVE** (two attempts spent)

| attempt | unit | run dir | outcome |
|---|---|---|---|
| att.1 | `probe-8a-C` | `comb/runs/20260903_225859_probeC_pC` | **`CAPTURE_ABORTED_WEDGED` at the PRE-window health gate** — delivery 0 f/s after 4 byte double-tap re-arms. The poke **never ran** (no `attr_poke.txt`), so 148 never entered a probe state. |
| r2 | `probe-8a-C-r2` | `comb/runs/20260903_230437_probeC_pCr2` | poke landed (all 7 attributes, `write_fails=0`), then **`MID_CAPTURE_WEDGE` at 12 s**. 13,794 records ≈ 12 s — far below any scoreable window. Restore **VERIFIED**. |

Per the rails (one re-run per leg on a wedge, then UNINFORMATIVE) P-C stops here. No PER, no
period, no autocorr is quoted from either attempt, and none is implied.

**This costs the campaign little.** [inferred] P-C's prior was low to begin with: P-A and P-B
are independent knobs on the same board with no interaction mechanism, and each was
independently null with a *mechanistic* reason (§4) rather than a merely statistical one — the
AGC had no motion to remove, and every exposed tracking process was individually excluded.

### 5.1 A restore false alarm, found and fixed — defect D-8a-1 [silicon]

P-C att.1's trap ran the ORIG fallback restore (there was no live `attr_poke.txt` to read,
because the poke never ran) and logged
`!!! RESTORE MISMATCH in_voltage0_hardwaregain want='34' after='34.000000'`.

That was a **false alarm in the verifier, not a restore failure**: the fallback plan wants
`34` and sysfs reads back `34.000000 dB`, and the check was string equality. The board was at
its original value throughout. The `write=WRITE_FAIL` on the same line is likewise expected
and benign — the channel was in `automatic` mode, where the driver rejects a manual gain
write, and the mode itself restored to `automatic` correctly.

Fixed the same hour, before the next leg: the verifier now compares **numerically** when both
sides parse as numbers. Recorded because a false restore alarm is as damaging as a missed one
— it trains the reader to disbelieve the one line that exists to be believed.

## 6. P-D — the transmitting board (146)

The coordinator asked for "every TX tracking calibration the driver exposes on 146's TX
channel". The read-only enumeration was run first, as instructed
(`two_jup/comb/RADIO_KNOBS_146.md`, unit `knobs146-8a`), and settled the question **without
needing a leg at all**:

> **[silicon] Every TX tracking calibration on 146 is ALREADY disabled.**
> `out_voltage0_{quadrature, lo_leakage, close_loop_gain, loopback_delay,
> pa_correction}_tracking_en` = **0**, all five; `out_voltage1_*` likewise; and
> `initial_calibrations` = **`off`**.

**P-D as briefed is therefore NULL BY CONSTRUCTION** — the probe would write `0` over `0` and
change nothing. There is no periodic TX radio process on 146 for the driver to stop, so the
transmitter's tracking calibrations **cannot** be the 26 ms process. This is a stronger
statement than a measured null: it holds without a capture.

**The RX-side attempt (reinterpreted P-D), reported as UNINFORMATIVE.** Because 146's *receive*
chain *is* running all five tracking cals plus an AGC in `automatic`, the P-A+P-B knob set was
applied to 146 through a new `PEER_ATTR_POKE` hook (`capture_r3.sh` §5d, symmetric with §5c).

| attempt | unit | run dir | outcome |
|---|---|---|---|
| att.1 | `probe-8a-D` | `comb/runs/20260903_231005_probeD_pD` | poke landed on **146** (7 attributes, `write_fails=0`); **`MID_CAPTURE_WEDGE` at 12 s**. Restore **VERIFIED**. |
| r2 | `probe-8a-D-r2` | `comb/runs/20260903_231318_probeD_pDr2` | **`R3 BRINGUP FAILED`** — arm-quality gate failed 6/6 tries (148 rx 764–830 f/s, needs ≥ 1120). Daemons never started, no window, no poke. Restore ran the fallback plan on 146 and **VERIFIED**. |

Two attempts spent ⇒ **UNINFORMATIVE**, and on the coordinator's ruling it is **not re-run**:
146 *transmits* on LEG=A, so its RX chain is not in the forward-leg signal path, and the
reinterpreted probe is low value. No number from either attempt is quoted.

## 7. The 148 / 146 calibration comparison — they are IDENTICAL, not asymmetric [silicon]

Asked to compare 146's `initial_calibrations=off` + all-TX-cals-0 against 148's values. The
comparison is worth stating precisely, because the expected asymmetry **does not exist**:

| attribute | 148 | 146 | |
|---|---|---|---|
| `initial_calibrations` | `off` | `off` | same |
| `out_voltage0_quadrature_tracking_en` (TX QEC) | 0 | 0 | same |
| `out_voltage0_lo_leakage_tracking_en` | 0 | 0 | same |
| `out_voltage0_close_loop_gain_tracking_en` | 0 | 0 | same |
| `out_voltage0_loopback_delay_tracking_en` | 0 | 0 | same |
| `out_voltage0_pa_correction_tracking_en` | 0 | 0 | same |
| `out_voltage0_hardwaregain` / `out_voltage1_hardwaregain` | 0.000000 / −40.000000 dB | 0.000000 / −40.000000 dB | same |
| `in_voltage0_gain_control_mode` | `automatic` | `automatic` | same |
| `in_voltage0_hardwaregain` | **34.000000 dB** | **34.000000 dB** | same |
| `in_voltage0_{agc,bbdc_rejection,rfdc,rssi,quadrature_fic}_tracking_en` | 1,1,1,1,1 | 1,1,1,1,1 | same |
| `in_voltage0_{hd,quadrature_w_poly}_tracking_en` | 0, 0 | 0, 0 | same |
| `in_voltage1_gain_control_mode` | `spi` | `spi` | same |

A full diff of every non-signal phy attribute between the two enumerations returns **nothing**
(excluding the live quantities `rssi`, `decimated_power`, `in_temp0_input` and the per-die
`*_cals_internal_path_delay_ns`). **The two radios are configured identically.**

[inferred] This matters for the campaign. The forward leg loses 8.1–8.4 % and the reverse leg
3.7 %, on boards whose radio configuration is byte-identical and whose RX gain is pinned at the
same rail. Whatever makes the two directions differ by 2.2×, it is **not** an ADRV9002
configuration difference — that explanation is now closed off by measurement.

## 8. Defects and deviations

* **D-8a-1** `radioprobe_go.sh`'s restore verifier compared strings, so `want='34'` vs
  `after='34.000000 dB'` logged a false `RESTORE MISMATCH` (§5.1). Fixed to compare
  numerically when both sides parse as numbers.
* **D-8a-2** `accept_analyze.py` takes **10+ minutes** on an ~880 k-record `frames.bin` (pure
  Python per-frame loops). It completed and its PER matched `comb_period_ms.py`'s to the
  digit, but it is a poor fit for a multi-leg campaign; the fast path is
  `common.loss_slot_trains`, which both new tools use.
* **D-8a-3** `capture_r3.sh`'s `deliver_rate` gate of 1000 f/s did not admit a single leg
  tonight (949–955 f/s on every armed leg) while the same arms produced perfectly ordinary
  8.3–8.4 % PER. As written the gate does not separate "healthy" from "degraded" on tonight's
  arm class; it separates one arm lottery outcome from another.
* **D-8a-4** `pair.iq` was `DEGENERATE` (`#48` stale-DDR-replay) on every probe leg, as in T3.
  No IQ-based conclusion is drawn anywhere in this report. `frames.bin` and the host counters
  are unaffected.
* **Deviation** P-D was executed against 146's RX chain rather than its TX chain, because the
  TX chain was already in the state the probe would have set (§6). Pre-registered in
  `RADIO_PROBES_PREREG.md §8` **before** the leg ran, then closed as UNINFORMATIVE.

## 9. Rig state at the end [silicon]

* **No unit is running.** `systemctl --user list-units --state=active` shows no `probe-8a-*`,
  `knobs*` or `watch-*` unit.
* **Every attribute on both boards is at its before-value, independently verified.** Not only
  by each leg's own restore read-back (`attr_restored=1` on every leg that poked anything,
  including the wedged ones), but by a **fresh read-only enumeration of both boards after all
  rig work finished** (units `knobs148-final`, `knobs146-final`):

| attribute | 148 final | 146 final | original |
|---|---|---|---|
| `in_voltage0_gain_control_mode` | `automatic` | `automatic` | `automatic` ✅ |
| `in_voltage0_hardwaregain` | `34.000000 dB` | `34.000000 dB` | `34.000000 dB` ✅ |
| `in_voltage0_agc_tracking_en` | 1 | 1 | 1 ✅ |
| `in_voltage0_bbdc_rejection_tracking_en` | 1 | 1 | 1 ✅ |
| `in_voltage0_rfdc_tracking_en` | 1 | 1 | 1 ✅ |
| `in_voltage0_rssi_tracking_en` | 1 | 1 | 1 ✅ |
| `in_voltage0_quadrature_fic_tracking_en` | 1 | 1 | 1 ✅ |

  **Nothing is left in a probe state on either board.**
* **The hold is untouched and in place**: `~/modem-status/RIG_LOCK`, `SENTINEL_STOP` and
  `.keeper_hold_created` all still present, all still dated 17:27. The sentinel was **not**
  restarted and no keeper was relaunched.
* **Link state**: the last leg's bring-up *failed* its arm-quality gate, so it exited before
  starting daemons — the boards are armed-ROM with **no daemons, no traffic and no watchdogs**
  running. That is the quiesced, link-down-by-design state the flash expects.

### 9.1 ⚠ Rig degradation to hand over to the flash task [silicon]

The 148 arm-quality figure at `bringup_r2r3.sh`'s gate was **1242–1246 f/s on the first six
legs of the night and then collapsed to 764–830 f/s** on the last (23:13), failing 6/6 tries:

| leg | 22:17 | 22:21 | 22:37 | 22:58 | 23:04 | 23:10 | **23:13** |
|---|---|---|---|---|---|---|---|
| 148 rx f/s at the arm gate | 1244 | 1244 | 1244 | 1246 | 1242 | 1243 | **764–830 ✗** |

146 sat at 1247 f/s throughout, including on the failed attempt — **the degradation is on 148
only**. Every armed leg also delivered 949–955 f/s where T3's a1r2 delivered 1909 f/s. The
next task should expect to re-arm 148 (possibly more than once) before it gets a healthy link,
and should not read a first failed arm as a consequence of the flash.
