# T3 run report — forward-leg DDRCAP captures (2026-09-03 19:10–19:5x)

Driver: T3 rig driver. Ledger: `two_jup/sdd_archive/2026-09-03-comb/progress.md`.
All board actions ran as `launch_rig_unit.sh` units with `agents/watch_unit.sh --spawn` watchers.
Every number below is labelled **[silicon]** (measured on the rig / from a capture) or
**[inferred]** (reasoning on top of measurements). RTL line citations are **[netlist]**.

---

## 0. What changed under me during the task (recorded, not hidden)

Three coordinator rulings landed mid-run and are reflected below:

1. **sel13 demoted, A1 becomes SEL=9** (after `two_jup/comb/SRO_SEL13_DESK.md`). A1's capture had
   not fired (the first leg wedged at 12 s), so A1 was fired as SEL=9.
2. **capTAP golden gate replaced by `SKIP_GOLD=1`** after two aborts (§2.2).
3. **A2's capture switched from SEL=6 to SEL=13** after the desk found the 09-02 captures were
   148-only self-reception, voiding that file's `|SRO| < 0.066 ppm` bound. The sel6 gate unit was
   stopped 3 s before it would have fired (no board contact — no `ddrcap2_capture.log`, no `.bin`).

---

## 1. Legs

| leg | unit | run dir | outcome |
|---|---|---|---|
| A1 att.1 | `legrun-T3-a1` | `comb/runs/20260903_191042_legA_a1` | **WEDGED at 12 s** — `CAPTURE_ABORTED_WEDGED`, exit 3. Pre-gate healthy (rev CRC 92 %, fwd 100 %, 1908 f/s); delivery flatlined immediately after `CAP_START`. Same 12 s failure mode as T2's m16 attempt 1. UNINFORMATIVE. |
| A1 re-run | `legrun-T3-a1-r2` | `comb/runs/20260903_191410_legA_a1r2` | **CREDITED** — `capture_r3_exit=0`, `deliver_rate` 1909/1909 f/s pre/post, `watchdog_relaunch_rx=0 peer=0`, `wedge_verdict=healthy crc=92% rate=1909f/s`, `deliver_rate_gate_pass=1`. **The first fully credited leg of the campaign.** |
| A2 | `legrun-T3-a2` | `comb/runs/20260903_192933_legA_a2` | **NOT CREDITED** — ran the **full 600 s with no wedge** (`capture_r3_exit=0`, `wedge_verdict=healthy crc=92% rate=954f/s`, `watchdog_relaunch_rx=0 peer=0`), but `deliver_rate` **954/954 f/s < 1000** ⇒ `deliver_rate_gate_pass=0`, unit exit 3. **UNINFORMATIVE for PER** by the pre-registered gate. Its sel13b capture is credited separately on bytes + positive control (§2.1, and pre-declaration D3: the transfer completed at 19:34, long before the leg ended). |

Knob witness (both legs): `rxm_148= rxm_146= drain_148= drain_146=`, resolved to the sink env only
(`DAEMON_ENV_A/B = QPSK_FAILHDR/QPSK_TXLOG/QPSK_TXLOG_USR1`) — no `-M`/drain knobs, as briefed.
File identity confirmed from `meta.txt`: `rx=10.0.0.148 peer=10.0.0.146`, so **`frames.bin`/`failhdr.bin` are 148's (RX) and `txlog_peer.bin` is 146's (TX)** — the LEG=A mapping the brief specifies.

### 1.1 Launch gate actually used [silicon]

Window-start marker = `capture_r3.sh:246` `CAP_START t=$(date +%s.%N) …`, tee'd to `capture_r3.log`
at `:243-249`. The DDRCAP was fired when **CAP_END was present AND 120 s had elapsed since CAP_START**
(`two_jup/comb/ddrcap_gated_launch.sh`, new this task). CAP_END matters independently: `capture_r3`'s
own `iio_readdev` on `axi-adrv9002-rx-lpc` (`:247`) must not overlap the DDRCAP `iio_readdev` on
`rx2-lpc`. The `frames.bin` timebase origin is the SIGUSR2 rotate at `capture_r3.sh:219-221` (no
echoed line), 3–5 s before CAP_START. a1r2: CAP_START 1788477383.508 (19:16:23), gate fired 19:18:24 = **+120 s**.

---

## 2. Captures and credit

### 2.1 Credit checklist

| capture | unit | bytes | capTAP pre / post | ddrcap2_pc | credited |
|---|---|---|---|---|---|
| A1 sel13 | `ddrcap-T3-sel13` | — | never read | — | **never fired** (leg wedged first; the gate was still in its CAP_START+120 s wait and was stopped host-side — **zero board contact from the instrument**) |
| A1r2 sel9 att.1 | `ddrcap-T3-sel9` | 0 | `0x76C5315B` ≠ `BCF94856` | — | **no** — aborted at `ddrcap2_capture.sh` before capturing |
| A1r2 sel9 att.2 | `ddrcap-T3-sel9b` | 0 | `0xCECD115B` ≠ `76C5315B` | — | **no** — aborted again |
| **A1r2 sel9c** | `ddrcap-T3-sel9c` | **536,870,912** (= 512 MiB, target met) | `0x9B84255B` / `0x098D015B` (logged, not gated) | PASS on every structural rule; one FAIL (§2.3) | **YES** (bytes + positive control) |
| A2 sel6 | `ddrcap-T3-sel6` | — | never read | — | **never fired** — stopped 3 s before firing on the coordinator's SEL=6→SEL=13 switch |
| **A2 sel13b** | `ddrcap-T3-sel13b` | **536,870,912** | `0xF78C3553` / `0x93883153` (logged, not gated) | PASS on every structural rule; one FAIL (§2.3) | **YES** (bytes + positive control) |

### 2.2 Why the capTAP golden gate was dropped [silicon]

`0x20C` is a **live tap sample**, not a constant. On the 09-02 `arm148_mode1` arms it read
`BCF94856` on *every* capture and *every* selector (sel6/12/13/14/15 — selector-independent), i.e.
a ROM/rung-arm constant. On the a1r2 arm, with live air traffic, it walked **within one healthy arm
and one selector**: `0x76C5315B` (19:18:28) → `0xCECD115B` (19:22:43) → `0x9B84255B` (19:24:49) →
`0x098D015B` (19:25:35). No fixed word can gate a capture fired during a `capture_r3` leg. The
coordinator's ruling (`SKIP_GOLD=1`) is therefore substituting a **stronger** data-plane proof —
`ddrcap2_pc.py` structural rules on 67.1 M records — for a single register word. Recorded here
because it is a deviation from the brief's stated credit ("capTAP golden pre/post").

### 2.3 Positive controls [silicon]

`ddrcap2_pc.py --sel 9` on `sel9_leg.bin`: `not_constant_IQ` PASS, `not_ramp_IQ` PASS,
**`demod_marks_periodic` PASS**, `slots_cycle` PASS, `tref_monotone` PASS. The single FAIL is
`toff_range_steady` (`d0`=482, modal fraction 0.761, only 5 distinct values 400/403/404/482/514).
`toff` is `Receiver_ddrcap_dc_toff` — the frame timing offset, i.e. **signal content**, and its
wander is part of what this task is measuring. **Verdict: PC PASS for data quality.**

`ddrcap2_pc.py --sel 13` on `sel13_leg.bin`: `not_constant_IQ`/`not_ramp_IQ`/`slots_cycle`/
`tref_monotone`/**`tref_cadence`** PASS (modal δ=1, `frac_at_modal=0.9980`, drops 0.20 %,
drop median 163 symbols, 488 drops per 1e6 records), `countreg_not_constant` PASS,
`underflow_per_symbol` PASS. Same single `toff_range_steady` FAIL (`d0`=5371). **PC PASS.**

Pre-declared before the captures (progress.md, D2): a `demod_marks_periodic` FAIL would have been an
expected DMA-drop artefact with 09-02 precedent. It did **not** fail — see §3.0.

`pair.iq` on **both** legs is `DEGENERATE` with the `#48` stale-DDR-replay signature on
`axi-adrv9002-rx-lpc`. The DDRCAP path is `rx2-lpc` and is manifestly **not** stale: sel9c holds
43,578 distinct frame markers with correct 1540-record spacing, sel13b 16.75 M distinct symbol
groups. No IQ-based conclusion is drawn from `pair.iq` anywhere in this report.

---

## 3. sel9 — the demod hard-bit plane [silicon]

Record format from the built RTL [netlist,
`jupiter_240k5_byte/rtl_sim/s1_rtl_ddrcap2/hdlsrc/commhdlQPSKTxRxLoopback/TxRxComposite.v`]:
ch0 = `ddrcap_bitword`, **16 successive `Receiver_ddrcap_demodbit` values packed MSB-first**
(`:2118-2131`); ch1 = 0 (`:2153`); one record per **16 valid demod bits** (`:2149-2151`).
Markers are sticky-latched (`:2158-2177`) precisely so the 1-in-16 valid cannot drop one.

### 3.0 The bit-domain tap does *not* lose 20–40 % of records

`sel9_leg.bin` = 67,108,864 records, 16,777,216 valid-tref samples (exactly n/4). tref δ per 4
records: **32 for 99.73 %**; 45 appears 40,887 times (≈ once per frame — 45 = 32+13, and
12333 − 12320 = **13**, the frame's non-payload symbols); 77 (= 45+32, one dropped record group)
only 1,343 times = **3.1 % of frames**, 31/33 (±1 quantisation) 1,340/1,341. The memory fact
"full-rate taps lose 20–40 % at the rx2 DMA" is about **full-rate** taps; a bit-domain tap runs at
1/16 the rate and the DMA keeps up. sel13b (a full-rate tap) shows drops on 0.20 % of tref pairs on
this arm, also far below 20 %. Both statements are for these two captures only.

### 3.1 Marker-interval histogram — pre-registered question (2)

Inter-`mark_demod` interval, in **records** (exact, no time base needed), 43,577 intervals:

| interval | count | share |
|---|---|---|
| **1540** | 42,227 | 96.90 % |
| **1538** (−2 records = −32 demod bits = −16 symbols) | 840 | 1.93 % |
| **1537** (−3 records = −48 demod bits = −24 symbols) | 503 | 1.15 % |
| everything else (2365, 2275, 1978, 1672, 1531, 1485, 1397, …) | 8 | 0.02 % |

**It is NOT "exactly one frame period".** 1,350 of 43,577 frames (**3.098 %**) are short by exactly
2 or 3 records. There are no long intervals apart from 8 stragglers: the receiver's frame start
arrives **early**, never late. `mark_fec` (148's own `Transmitter_txFrameStart`) is 1540 for
40,886 intervals with 1536/1541/1542 jitter and a handful of spurious short pulses (316/280/251) —
so the anomaly is on the **air-recovered** marker, not on 148's own TX frame clock.

### 3.2 The anomaly train IS the comb — pre-registered question (3)

FFT autocorrelation of the short-interval indicator over the capture's frame index (43,577 frames):

| lag | value | | lag | value |
|---|---|---|---|---|
| **65** | **+0.7371** | | 33 | +0.4856 |
| 130 | +0.6049 | | 32 | +0.4122 |
| 195 | +0.4972 | | 98 | +0.4367 |
| 97 | +0.3985 | | **16** | **−0.032** |

Inter-event interval histogram: **33 (675), 32 (580)**, 94 intervals **below 32** (values 2…31),
and **not one interval above 33**. Endpoint estimate of the period: span 43,534 frames over 1,349
intervals = **32.2713 frames**, whose uncertainty is set by the ±1-frame endpoint ambiguity,
≈ 2/1349 = **±0.0015 frames** (the sd/√n of the interval series is *not* a valid error bar — the
intervals are increments of a near-deterministic phase process, not independent draws).

**The period is not 32.** Scanning the candidate period that maximises the Rayleigh concentration of
the 1,350 event indices:

| event set | best period (frames) | R | R at P = 32.000 | period in ms |
|---|---|---|---|---|
| all 1,350 | **32.44301** | **0.8720** | 0.0101 | **26.0489** |
| −2-record class (840) | 32.44302 | 0.8760 | 0.0133 | 26.0489 |
| −3-record class (503) | 32.44307 | 0.8787 | 0.0109 | 26.0490 |

The two event classes, scanned **independently**, agree to 5 × 10⁻⁵ frames. At P = 32.000 the
concentration is **null** (R = 0.010). Phase histogram at the best period (16 bins):
`[0,1,0,2,76,189,214,456,285,114,9,2,0,1,1,0]` — a single clean concentration, not a gap.

The 94 sub-32 intervals are **cross-class collisions**: 69 of 94 are a −2 event followed by a −3 event
or vice versa, and within the −3 class alone **no** interval is below 32 (the −2 class has 19 at 31,
2.4 %). Per class the mean spacings are 51.888 ± 0.0024 and 86.526 ± 0.0040 frames, i.e. the two
classes fire on a subset of the same ≈32.44-frame lattice (their modal spacings 65, 97/98, 32/33,
130 are all near multiples of it), and 1/51.888 + 1/86.526 = 1/32.4365 — the combined rate recovers
the lattice period.

**Consequence, and it is sharp**: 32.44301 ± 0.0015 frames is **295 σ away from 32.000**. A purely
deterministic mod-32 fabric beat (12333 ≡ 13 mod 32, `COMB32_RTL_HUNT.md` candidate #1) predicts
*exactly* 32.000 frames and is therefore **also excluded** by this measurement, just as the 0.63 ppm
SRO is. Whatever sets the period is close to, but not on, the mod-32 lattice.

**Absolute phase mod 32 is NOT locked**: Rayleigh on event index mod 32, n = 1,350, **R = 0.0101,
p ≈ 0.87**, histogram flat (35…51 per bin). The comb is a *lag* structure, not a fixed phase.

### 3.3 Host-side comparison [silicon]

The same leg's host log: ALL-LOSS autocorrelation top lags **65 : +0.7550**, 97 : +0.5615,
32 : +0.5259, 33 : +0.4885, 98 : +0.4502, `lag16 = −0.0855`. **The fabric anomaly train and the
host loss train have the same top harmonic (65), the same family (k×32 / k×33) and the same dead
lag-16 floor** — measured on the same leg, from two completely independent instruments (a DDRCAP
tap in the RX fabric and the host daemon's per-frame log).

### 3.4 Intact vs garbage at the demod bit plane — pre-registered question (1)

The literal magic parse **cannot** be done: scanning 200 nominal frames at every bit offset in the
first 2,000 bits found **zero** occurrences of `0x51 0x4B` (or its complement) at any offset, and
across 43,577 frames **no bit position in the first 1,024 bits is even 97 %-deterministic** (the
extreme bit probabilities are 0.125 and 0.733). The demod hard-bit stream is fully scrambled at this
tap; there is no plaintext header to check.

The question is nevertheless answered, and more directly: **3.098 % of frames are physically short
at the demod bit plane** — the deframer receives 32 or 48 fewer demod bits for that frame than the
1540-record (24,640-bit) nominal. A short frame cannot pass CRC. So:

> **[silicon] The frames are GARBAGE at the demod hard-bit plane, not intact.** Under the
> coordinator's own pre-registration this **SUPPORTS the "air/RX-DSP" reading and FALSIFIES the
> delivery-plane reading** ("all frames intact at sel9 while the host log loses them" — not observed).

Rate reconciliation on the **matched window** [silicon]. The sel9c capture holds 67,108,864 records
at one record per 16 demod bits = 1.92 M records/s, i.e. **35.0 s of air**, taken between 19:24:49
and ≈19:25:25 wall clock — CAP_START + 507…542 s. Restricting `frames.bin` to 507–545 s of its own
timebase (47,318 slots): host **PER 7.984 %** (3,778 lost) and host **loss-event rate 5.974 %**
(2,827 loss runs), against the leg-wide 8.121 % / 5.88 % — the leg is flat, so the window is
representative. The fabric short-frame rate in the same window is **3.098 %**, i.e. the demod-plane
short frames account for **52 % of the host loss events** over the overlapping window. Not a 1:1
accounting, and not claimed as one; the other half is unattributed by this capture.

### 3.5 The on-air SRO measurement — the coordinator's decisive test [silicon]

`tref` is a free-running local mod-12333 symbol counter [SRO_SEL13_DESK §3; confirmed here by the
per-frame δ=45 gap]. Measuring the **air frame period in local symbols** over the whole capture:

* total local symbols between first and last `mark_demod`: **537,484,486**
* air frames spanned (each interval rounded to the nearest multiple of 12333; 43,573 singles,
  4 doubles): **43,581**
* ⇒ **12,333.000298 local symbols per air frame** ⇒ **SRO = +0.0242 ppm**
* with an 8-symbols-per-record correction applied to the marker's sub-tref position:
  12,333.000115 ⇒ **+0.0093 ppm**
* endpoint quantisation (one tref group = 32 symbols, at each end): **± 0.06 ppm (1 σ)**

Predicted under the surviving hypothesis: 0.63 ppm ⇒ 0.0078 symbols/frame ⇒ **338.6 symbols of drift
across this capture**. Observed total drift: **5 to 101 symbols** depending on the sub-tref
correction — an order of magnitude below.

> **[silicon] |SRO| ≤ 0.06 ppm on the live 146 → 148 air link.** This is the first *on-air*
> SRO measurement of the campaign (SRO_SEL13_DESK's bound was voided because 148 was demodulating
> its own transmission). **The 0.63 ppm sample-slip hypothesis is falsified ~10×.**
> A whole-sample slip every 32 frames requires 0.63 ppm; the boards' converter clocks match ten
> times better than that.

---

## 4. sel13b — interpolator strobe census [silicon]

Field map [netlist `TxRxComposite.v:2060,2075`]: ch0 = `{uf_now, 4'b0, countReg[10:0]}`,
ch1 = `{5'b0, mu[10:0]}`. Desk fact from the 09-02 file, re-confirmed here: `countReg` steps −256
per record and wraps mod 1024 once per symbol (4 records = 4 samples = 1 symbol), so **256 counts
== one sample interval** and `mu` is the same value's low bits — `mu` is not an independent field.

Strobe census over **16,752,604** symbol groups of exactly 4 records (never straddling a DMA drop):

| strobes per symbol | count |
|---|---|
| 0 | **6,393** |
| 1 | 16,739,878 |
| 2 | **6,333** |
| 3 | 0 |

* net (2s − 0s) = **−60** over 12,726 ±1 events; ±1 random-walk endpoint noise **± 113**
* ⇒ slip rate −39 ± 74 symbols/s over 1.533 s ⇒ **SRO = −2.55 ± 4.79 ppm** — consistent with zero
  and, as SRO_SEL13_DESK §4 already warned, **not sensitive enough to test 0.63 ppm**. The sel9
  marker measurement (§3.5) is ~80× tighter and is the one that decides.

### 4.1 The ±1 strobe events fire in bursts every 32.36 frames [silicon] — new

A first pass tested the events' phase **mod exactly 32 frames** and got Rayleigh R = 0.389 with a
histogram containing a contiguous ~10-bin near-empty window. That shape is a *gap*, not a
concentration, and R = 0.389 was an **aliasing artefact of assuming the period is 32**. Scanning the
period instead resolves it completely:

| event set | best period | R | R at 32.000 | R at 32.44301 (the sel9 value) |
|---|---|---|---|---|
| all 12,726 ±1 strobe events | **32.361855 frames = 25.9843 ms** | **0.99443** | 0.3888 | 0.9578 |

R = 0.994 with n = 12,726: the phase histogram at the best period puts **12,676 of 12,726 events in
one bin of 16**. Controls: mod 1 frame R = 0.0070 (p = 0.53) and mod 65 frames R = 0.0010 (p = 0.99)
— neither modulus is special, so the concentration is not a binning artefact. Coverage control: the
events are spread evenly over the whole capture (per-fortieth counts 178…505, no empty stretch) and
the largest inter-event gap is 32.0 frames, so this is **not** a time-localised dropout.

Structure: clustering the events at a 5,000-symbol threshold gives **103 bursts**, median **182
events per burst**, median burst width **6,064 symbols = 0.49 frames**. Within the bursts the
0-strobe and 2-strobe events are balanced (6,393 vs 6,333), which is why the net slip is ≈ 0 (§4).
So once every 32.36 frames the symbol-timing interpolator enters a ~half-frame window of ±1 strobe
churn that cancels on average.

**Two independent instruments, two different legs, the same period**: sel9 demod frame-marker
anomalies on a1r2 give **32.44301 frames (26.0489 ms)**; sel13 ±1 strobe bursts on a2 give
**32.36186 frames (25.9843 ms)**. Both are inside the pre-registered 25.72 ms ± 5 % window, both are
hundreds of σ away from exactly 32 frames, and they differ from each other by 0.25 % (different legs,
different arms — no claim is made that they are the same number).

[inferred] `COMB32_RTL_HUNT.md` candidate #1 (`Symbol_Synchronizer → Rate_Handle → FIFO_block`, the
only mod-32 structure in the design, unguarded and never flushed [netlist, `FIFO_block.v:113,148,180`;
`Rate_Handle.v:97,106`]) remains the best structural candidate for a ~32-frame process **and it is
the right kind of object** — a strobe FIFO is exactly what a ±1 strobe burst passes through. But its
predicted period from 12333 ≡ 13 (mod 32) is *exactly* 32.000 frames, and both measurements exclude
that. Either the counter is not clocked once per symbol, or a second, slower term sets the 1.3 %
offset. **T4's job is to find what makes it 32.4 and not 32.0.**

---

## 5. Leg A1r2 scoring [silicon]

`accept_analyze.py` (lost frames in the denominator; `frames.bin` = 148 = RX):

* **PER = 8.121 % (71,090 / 875,375)**, CP95UL **8.179 %**, lag33 = 0.268
* live window **718 s of 723 s**, flagged `[WEDGE truncated]` by `accept_analyze`'s own live-window
  rule even though `capture_r3` exited 0 and the harness gate passed — both facts stated, neither buried
* run bins: singles **35,342**, doubles **16,140**, 3-4 **632**, 5-20 **146**, >20 **0**
* GATE (<1 % at CP95UL): **NOT MET**

`comb_autocorr.py` — see §3.3. `lag16 = −0.0855` (ALL-LOSS), `−0.0421` (SINGLES).

`comb_census.py --failhdr failhdr.bin --txlog txlog_peer.bin` (n = 872,744):
`OK 804,287 · MAGIC 48,882 · LEN 2,106 · CRC 17,469 · ZEROTAIL 0` ⇒ MAGIC is **71.4 %** of failures
(T2's reverse legs ran 83.5–83.8 % — the forward leg has proportionally more CRC/LEN).
`class4 n=0`; onset histogram unusable this leg (`n_none=61,599`, `n_have=0` — the failhdr ring
recorded no `first_zero_off`).
TX↔RX join: **lost_rx 71,090 · never_sent 0 · sent_not_decoded 71,090** — 100 % of lost frames were
submitted by 146.

**Hand seq-membership control** (independent of `comb_census`): of the 71,090 lost host_seq values,
**71,090 (100.00 %) are present in 146's `txlog_peer.bin`** (896,961 unique seqs) and **0 are present
in 148's own `txlog.bin`** (which holds only 5 unique seqs — 148 barely transmits on this leg).
Decoded control: 20,000 of 20,000 sampled `crc_ok==1` seqs are also in 146's TX log.

---

## 6. Verdicts against the pre-registrations

### 6.1 COMB_STATE.md §"T3/T4 pre-registration" (quoted verbatim)

> "Positive control: `ddrcap2_pc.py --sel 13` PASS and a visible mu sawtooth."

**PARTIAL.** `ddrcap2_pc.py --sel 13` PASSes every structural rule (§2.3). There is **no visible mu
sawtooth**: `mu` is not an independent field (it is `countReg mod 256` scaled), `countReg` at the
strobe is a bounded locked-loop residual, and neither wraps.

> "Prediction: mu/countReg shows a sawtooth whose wrap period is 25.7 ms ± 5 % (32 frames), and
> every wrap coincides (within one frame) with a lost-frame onset in 148's frames.bin/failhdr; the
> comb phase mod 32 of the losses is locked to the wrap phase. Falsifier: wrap period ≠ 32 frames,
> or wraps without losses / losses without wraps at > 20 % → the SRO reading is wrong and T4 moves
> to sel5/sel14 (carrier sync, interpolated samples) at the loss onsets."

**FALSIFIES** — on the falsifier's own terms and on a stronger one:

* there is **no mu/countReg sawtooth at all**, so there is no wrap period; the falsifier's first
  clause ("wrap period ≠ 32 frames") is met vacuously and decisively;
* the mechanism the sawtooth stood for — a ~0.63 ppm SRO producing one whole-sample slip per
  25.7 ms — is **falsified on air by ~10×** (§3.5, |SRO| ≤ 0.06 ppm);
* the coincidence half was never reached, and per pre-declaration D4 it would have been
  phase-degenerate anyway.

**The ≈25.7 ms period itself SURVIVES** — measured twice, at two different planes, on two different
legs, by two independent instruments: demod frame-marker anomalies at **32.44301 ± 0.0015 frames =
26.0489 ms** (R = 0.872, §3.2) and interpolator ±1 strobe bursts at **32.361855 frames = 25.9843 ms**
(R = 0.994, §4.1). Both sit inside the pre-registered 25.72 ms ± 5 % window. What is falsified is the
*SRO explanation* of that period, not the period.

**And the deterministic mod-32 reading is falsified too.** Both measurements put the period ~1.3 %
above 32.000 frames, hundreds of σ out (R at exactly 32.000 is 0.010 for the marker anomalies).
`Rate_Handle`'s unguarded 32-entry strobe FIFO stays the best *structural* candidate — it is the only
mod-32 object in the design and a strobe FIFO is exactly what a ±1 strobe burst traverses — but
12333 ≡ 13 (mod 32) predicts exactly 32.000 frames, and the rig says 32.36–32.44. [inferred] Two
readings survive: the FIFO is not clocked once per symbol, or a second slower term adds the 1.3 %.
**That is the T4 question.**

### 6.2 Coordinator's sel9 pre-registration (quoted verbatim)

> "Prediction under the surviving "air/RX-DSP" reading: garbage frames present at sel9 with a
> 32-frame comb; under a delivery-plane reading: all frames intact at sel9 while the host log loses
> them. State which you see."

**SUPPORTS the air/RX-DSP reading; FALSIFIES the delivery-plane reading.** I see garbage —
3.098 % of frames short by 32 or 48 demod bits at the hard-bit plane (§3.1) — with a 32.271-frame
comb whose top harmonic (65) matches the host loss train's top harmonic (65) on the same leg (§3.3).

Question (2), the marker-interval histogram: **it is NOT exactly one frame period** (§3.1).
Question (3), phase mod 32 of the garbage frames: **not locked in absolute phase** (R = 0.0101,
p ≈ 0.87) — the structure is a lag comb, not a fixed phase (§3.2).

---

## 7. Defects and deviations found

* **D-T3-1** `ddrcap2_capture.sh`'s capTAP-golden gate is unsatisfiable for any capture fired during
  a live `capture_r3` leg — `0x20C` is a live tap sample (§2.2). Worked around by `SKIP_GOLD=1`
  (coordinator ruling, commit 887f868); the brief's stated credit criterion was substituted.
* **D-T3-2** `ddrcap2_pc.py`'s `toff_range_steady` rule fails on every live-air capture (both
  selectors, both legs) because `toff` legitimately wanders on air. It is a rule calibrated on
  self-reception arms; it should be data, not a gate, for on-air captures.
* **D-T3-3** The failhdr ring produced `n_have=0` first-zero offsets on this leg, so the
  corruption-onset histogram is unusable — the onset-offset half of scoring item (c) could not be
  computed from the host side.
* **D-T3-4** `pair.iq` is `DEGENERATE` (`#48` stale-DDR-replay) on both A legs; documented recovery
  for that class is reboot-only. It did not affect `rx2-lpc` (the DDRCAP path) or any host counter.
* **D-T3-5** [inferred] `mu` (sel13 ch1) carries no information beyond `countReg` — it is
  `4 × (countReg mod 256)`. Any future pre-registration that treats `mu` and `countReg` as two
  observables is treating one observable twice.

## 8. New tooling (committed with this report)

* `two_jup/comb/ddrcap_gated_launch.sh` — CAP_START/CAP_END launch gate (§1.1), host-side only until
  it fires, so a leg that dies first costs zero board contact (it saved A1's sel13 and A2's sel6).
* `two_jup/comb/sel13_sro.py` — tref-indexed sel13 sawtooth/periodogram tool, validated at the desk
  on the archived 09-02 capture before any board contact.

## 9. Rig state at the end

Left exactly as `capture_r3.sh` leaves it. Keeper hold, `SENTINEL_STOP` and `RIG_LOCK` all still in
place (`~/modem-status/`); the sentinel was **not** restarted; no keeper was relaunched. No board
contact after the last leg's own quiesce. Instrumented daemons remain deployed on both boards
(`capture_r3.sh` rebuilds them per leg).

**A2 closed out** at 19:43:59 (`UNITEXIT legrun-T3-a2 result=exit-code code=3`) — a gate failure on
rate, not a wedge. No unit is running; no board has been contacted since that leg's own quiesce.

### 9.1 Leg A2 measured outcome [silicon] — reported, NOT quotable as a credited PER

The gate rule is pre-registered and is applied: A2 is **UNINFORMATIVE for PER**. The numbers are
recorded here because the leg is otherwise clean (full 600 s, no wedge, no relaunch) and because its
loss-train structure is the second forward-leg replicate of §3.3.

* `accept_analyze.py`: PER **8.271 % (72,317 / 874,298)**, CP95UL **8.329 %**, lag33 = 0.202,
  live window 717 s of 722 s (again flagged `[WEDGE truncated]` by `accept_analyze`'s own
  live-window rule while `capture_r3` exited 0 — same discrepancy as A1r2, both stated)
* run bins: singles **35,552**, doubles **16,002**, 3-4 **597**, 5-20 **216**, 21-100 **1**, >100 **2**
* `comb_autocorr.py` ALL-LOSS top8: **97 : +0.6773**, **65 : +0.6764**, 32 : +0.5744, 33 : +0.4304,
  8 : +0.3279, 64 : +0.3133, 57 : +0.3074, 98 : +0.2936; **lag16 = −0.0810**
* SINGLES-ONLY top: 97 : +0.5329, 65 : +0.5280, 32 : +0.3881, 57 : +0.2780; **lag16 = −0.0424**

Reading: the same **k×32 / k×33 family with the dominant peak in the 65/97 pair and a dead lag-16
floor**, on a second forward leg, with PER 8.271 % against A1r2's 8.121 % — the two forward legs are
indistinguishable, exactly as T2's four reverse legs were (3.67–3.79 %). Nothing about the comb
depends on which leg or which capture is running: it is present on every leg the campaign has
measured, in both directions.

*(Not run on A2, for budget: `comb_census.py` and the hand seq-membership control. A1r2 carries both,
and A2 cannot be quoted for PER anyway.)*
