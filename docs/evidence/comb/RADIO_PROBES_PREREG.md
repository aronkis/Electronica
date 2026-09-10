> Evidence ledger, moved verbatim from `two_jup/comb/RADIO_PROBES_PREREG.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# Radio-process probes — PRE-REGISTRATION (SEQ-BIST Task 8a)

Written **before any leg was run**, 2026-09-03 ~22:2x, after the read-only knob
enumeration (`two_jup/comb/RADIO_KNOBS_148.md`) and after the scoring instrument was
built and calibrated at the desk (§4). Nothing below is edited after a leg runs;
outcomes go in `two_jup/sdd_archive/2026-09-03-seqbist/task-8a-report.md`.

## 0. What is being tested

T3 [silicon, `two_jup/sdd_archive/2026-09-03-comb/t3-run-report.md`]: the residual
forward-leg loss (8.121 % on leg a1r2) is a comb whose period is **26.0489 ms
(32.44301 frames)** — measured in TIME, at the demod bit plane, hundreds of σ away from
exactly 32 frames, and independent of every host knob tested. `26.042 ms = 1,000,000
cycles of the ADRV9002 38.4 MHz device clock` [inferred] ⇒ a **periodic radio process on
the receiving board** (RX AGC / tracking calibration / DC-offset / QEC) is the lead.

These probes turn those processes off, one axis at a time, on the RECEIVING board of the
forward leg (148), and ask whether the 26 ms line survives.

## 1. Baseline to compare against — leg a1r2 [silicon]

| quantity | a1r2 value |
|---|---|
| PER (lost frames in the denominator, `accept_analyze.py`) | **8.121 %** (71,090 / 875,375), CP95UL 8.179 % |
| comb autocorr ALL-LOSS | lag 65 **+0.7550**, 97 +0.5615, 32 +0.5259, 33 +0.4885; **lag16 −0.0855** |
| period-in-ms, host log (`comb_period_ms.py`, this task) | **32.4497 frames = 26.0548 ms, R = 0.1737**; R at P=32.000 = 0.0008; random null 0.0148 |
| period-in-ms, DDRCAP sel9 (independent instrument, same leg) | 32.44301 frames = 26.0489 ms, R = 0.872 |
| MAGIC share of failures (`comb_census.py`) | 71.4 % (MAGIC 48,882 of 68,457) |
| 0x104 vs host records | Δ0x104 854,729 vs 854,321 records (within 0.05 %) |
| run bins | singles 35,342 · doubles 16,140 · 3-4 632 · 5-20 146 · >20 0 |

## 2. The probes

Each probe = **one `capture_r3.sh` LEG=A forward leg, 600 s**, 146 TX → 148 RX, the same
instrumented daemons and the same `legrun_go.sh` gate as T2/T3, via the wrapper
`two_jup/comb/radioprobe_go.sh` (`PROBE=A|B|C|D`, `DRY=1` default). The attribute is
applied on 148 **after the RF arm and the health gate, before the 600 s scored window**,
through the new `RX_ATTR_POKE` hook in `capture_r3.sh` (same position as the existing
`LOOP_POKE`), and restored afterwards by a wrapper `trap` on EXIT/INT/TERM.

All paths are under `/sys/bus/iio/devices/iio:device2/` (`adrv9002-phy`, discovered by
name at run time, never hardcoded).

### P-A — RX gain control → manual, gain frozen where the AGC sat
```
in_voltage0_gain_control_mode : automatic -> spi        (manual; `spi` is the string in
                                                         _available: "spi pin automatic")
in_voltage0_hardwaregain      : @keep  (re-assert the value the AGC had settled on with
                                        live traffic, read on the board at poke time)
```
Restore: `in_voltage0_hardwaregain` to its recorded before-value, then
`in_voltage0_gain_control_mode` back to `automatic` (mode last, so the AGC resumes control
only after the gain is back).

### P-B — RX tracking calibrations off
```
in_voltage0_agc_tracking_en              : 1 -> 0
in_voltage0_bbdc_rejection_tracking_en   : 1 -> 0
in_voltage0_rfdc_tracking_en             : 1 -> 0
in_voltage0_rssi_tracking_en             : 1 -> 0
in_voltage0_quadrature_fic_tracking_en   : 1 -> 0
```
(`hd_tracking_en` and `quadrature_w_poly_tracking_en` are already 0; `initial_calibrations`
is already `off`.) Restore: all five back to 1.

### P-C — both (ONLY if A and B are both null)
P-A's two writes plus P-B's five, applied in that order, restored in reverse.

### P-D — the same knobs on **146**, the TRANSMITTING board (only if A, B, C are all null)
Pre-registered now so it is not invented after the fact. Rationale: 26.042 ms is 1e6 cycles
of a 38.4 MHz device clock and **both** boards have one; a periodic TX-side process on 146
(TX QEC / LO-leakage / close-loop-gain / PA-correction tracking, or 146's own RX AGC, whose
tick is what silences its TX between frames) would imprint a 26 ms disturbance on the air
that 148's demod sees as short frames, and would explain the forward/reverse symmetry as
well as an RX-side process does. On 148 all five TX `_tracking_en` are already 0; **146's
are unmeasured** — P-D begins with the same read-only enumeration on 146.

## 3. Predictions and falsifiers (identical form for every probe)

**HIT** — the 26 ms process is that knob:
* `comb_period_ms.py` finds **no line in the 25–27 ms band**: band `R < 0.05`, i.e. a >3×
  reduction from a1r2's 0.174 and within ~3× of the random-event null (~0.015); **and**
* `comb_autocorr.py` ALL-LOSS **lag-32 family collapses**: lag32 and lag65 both < 0.1
  (a1r2: +0.5259 and +0.7550); **and**
* PER falls materially. **The success target is ~4–5 %, not 0.25 %.** T3 attributes ~52 %
  of host loss events to the 26 ms demod short-frame train, and T1 withdrew the old
  "0.22–0.31 % floor" (it belonged to the now-fixed beat defect; the real loopback floor is
  ≲0.0006 %). So removing this one process predicts roughly halving the loss, not clearing
  it. A PER of 4–5 % with the 26 ms line gone is a **full HIT**, not a partial.

**NULL (falsifier)** — period and PER unchanged: band R within ±30 % of 0.174 **and**
PER 8.1 % ± 0.5 (i.e. 7.6–8.6 %). Then that knob is not the 26 ms process.

**PARTIAL** — anything between (line reduced but present, or PER moved outside 7.6–8.6 %
without the line clearing). Reported as PARTIAL, not spun either way.

**Third branch, pre-registered for P-A specifically:** freezing the gain may push the link
under the delivery gate or wedge it mid-window. Bring-up and the health gate run with the
AGC still on, so a **mid-capture** wedge or a post-window rate < 1000 f/s under frozen gain
is *informative* — it says the AGC was doing necessary work on this link — and is reported
as `P-A: gain-freeze not sustainable` rather than merely UNINFORMATIVE. A wedge that
occurs **before** the poke is an ordinary UNINFORMATIVE wedge.

**Fourth branch, pre-registered for P-B:** the adrv9002 driver may refuse `_tracking_en`
writes while the channel is `rf_enabled`. If the write returns an error (the hook reports
`write=WRITE_FAIL` and an unchanged `after=`), P-B is reported **NOT EXECUTABLE** with the
driver's error, and **no ENSM state cycle is attempted** — that would re-arm the radio
mid-leg and risks the documented no-ping board hang. The correct follow-up is then a
bring-up-time change, which is a different task.

## 4. The scoring instrument, built and calibrated at the desk before any board contact

The probes run **no DDRCAP capture**, and no committed tool could measure a *fractional*
period from a host log: `comb_autocorr.py` gives integer lags, `comb_phase.py` needs the
period handed to it, `loss_period.py` scans a fixed integer candidate list. Distinguishing
32.44 from 32.00 is the entire point, so the probes would have had no discriminating
metric. `two_jup/comb/comb_period_ms.py` (new, this task) closes that: Rayleigh
concentration of **loss-run onsets** on the reconstructed TX-slot axis, scanned over a
continuous period band by zero-padded FFT then refined, with a random-event null, converted
to ms by the exact frame period (12333 sym / 15.36 Msym/s = 802.9297 µs).

**Calibration [silicon]:** run on a1r2's `frames.bin` it recovers **32.4497 frames =
26.0548 ms, R = 0.1737** against the wholly independent DDRCAP sel9 marker value
**32.44301 frames = 26.0489 ms** — 0.02 % agreement between two instruments on the same
leg — with R at exactly P = 32.000 equal to **0.0008**, at the null. R = 0.174 (not 0.87)
is the correct "line fully present" baseline for a host-only leg because the host loss
train mixes this process with everything else that loses a frame.

## 5. Scoring, per probe (all [silicon])

1. `accept_analyze.py` on 148's `frames.bin` — PER with lost frames in the denominator, CP95UL, run bins, live window.
2. `comb_autocorr.py` — ALL-LOSS top lags and the lag-16 floor; lag-32 family amplitude.
3. `comb_period_ms.py` — best period in frames and ms, band R, R at 32.000, null.
4. `comb_census.py --failhdr --txlog` — fail-class census, MAGIC share, TX↔RX join (never_sent).
5. 148 daemon-log Δ0x104 vs host record count (detections vs deliveries).
6. `meta.txt`: the legrun keys plus `probe=`, `attr_before=`, `attr_after=`, `attr_restored=`.

## 6. Gates and rails

`legrun_go.sh`'s gate is kept verbatim: `deliver_rate ≥ 1000 f/s` pre AND post, zero
watchdog relaunches, `capture_r3` exit 0, no `WEDGE`/`NOT usable` verdict. **One re-run per
probe on a wedge, then UNINFORMATIVE.** Every board action is a `launch_rig_unit.sh` unit
with a `watch_unit.sh --spawn` watcher. Keeper hold, `SENTINEL_STOP` and `RIG_LOCK` stay in
place. Every attribute written is read first, logged, and restored under a `trap` inside
the run script itself, with a read-back after restore; a restore mismatch is made LOUD in
`meta.txt` and in the report.

---

## 7. ADDENDUM, 2026-09-03 22:2x — written DURING P-A's window, before any PER exists

What I know at the moment of writing: P-A's attribute poke landed cleanly
(`gain_control_mode automatic -> spi`, `hardwaregain` frozen at `34.000000 dB`,
both read back), and `capture_r3`'s pre-window health gate reported
**`rev 92% fwd 100% rate 959 f/s`**. What I do NOT know: the PER, the comb autocorr,
or the period — the 600 s window is still running and no `frames.bin` has been pulled.

**959 f/s is below the 1000 f/s credit gate**, so `legrun_go.sh`'s rule (kept verbatim in
`radioprobe_go.sh`) will mark this leg `deliver_rate_gate_pass=0` ⇒ **not credited for PER**.
This is the same condition T3's leg A2 hit (954 f/s, `UNINFORMATIVE for PER` by the gate)
and it is an arm-lottery property of the rig, not of the probe: a1r2 armed at 1909 f/s, A2
and this leg at ~955.

**Pre-registered handling, decided before the numbers exist:**

1. The gate verdict is **not weakened**. Any leg with `deliver_rate < 1000 f/s` is reported
   `deliver_rate_gate_pass=0`, exactly as A2 was.
2. The **PER is still reported**, labelled precisely as T3 labelled A2's — measured, not
   quotable as a credited PER — because T3 established the relevant control: A2 at
   **954 f/s** gave PER **8.271 %** against a1r2's **8.121 %** at **1909 f/s**. Two forward
   legs, a 2× delivery-rate difference, PER indistinguishable. So a PER measured at ~955 f/s
   is comparable to the a1r2 baseline, and the HIT/NULL thresholds in §3 (4–5 % vs
   7.6–8.6 %) are far outside that 0.15 pp spread.
3. The **primary discriminator is unaffected by the rate gate**. `comb_period_ms.py` measures
   a period on the reconstructed TX-slot axis; it does not depend on the delivery rate. The
   26 ms line was present on a1r2 (R = 0.174) and the k×32/k×65 family was present on A2 at
   955 f/s. If a probe's line vanishes at 955 f/s, that is a real result.
4. A rate-gate failure is **not** a wedge, so it does **not** consume the one pre-registered
   re-run. Re-runs remain reserved for `MID_CAPTURE_WEDGE` / `CAPTURE_ABORTED_WEDGED`.
5. Because ~955 f/s appears to be tonight's arm, **all** probes will most likely be scored
   this way. They are therefore compared **against each other** as well as against a1r2,
   which is the stronger comparison anyway: same night, same arm class, one knob different.

---

## 8. P-D — pre-registered 2026-09-03 23:1x, BEFORE the leg, after the 146 enumeration

The coordinator asked for P-D on the transmitting board: "disable every TX tracking
calibration the driver exposes on 146's TX channel". The read-only enumeration
(`RADIO_KNOBS_146.md`, unit `knobs146-8a`) was run first, as instructed, and found:

**every TX `_tracking_en` on 146 is ALREADY 0** — `out_voltage0_{quadrature, lo_leakage,
close_loop_gain, loopback_delay, pa_correction}_tracking_en` = 0, `initial_calibrations` =
`off`. So the probe as literally specified writes 0 over 0 and is **null by construction**.
It is not run as a measurement; the enumeration is the finding, and it is reported as such.

**Executed instead (same question, executable knobs):** the P-A + P-B knob set applied to
**146**, the transmitting board, whose RX chain *is* running all five tracking cals and an
AGC in `automatic` — and which, by the campaign's own P2 mechanism note ("a board's TX
silence follows that board's OWN RX transfer cadence"), is the untested axis.

```
146: in_voltage0_gain_control_mode      automatic -> spi
     in_voltage0_hardwaregain           @keep (freeze at the AGC's live value)
     in_voltage0_agc_tracking_en            1 -> 0
     in_voltage0_bbdc_rejection_tracking_en 1 -> 0
     in_voltage0_rfdc_tracking_en           1 -> 0
     in_voltage0_rssi_tracking_en           1 -> 0
     in_voltage0_quadrature_fic_tracking_en 1 -> 0
```
Applied through a new `PEER_ATTR_POKE` hook in `capture_r3.sh` §5d — byte-identical in
position and rules to `RX_ATTR_POKE`, differing only in the board it lands on — and restored
by the same wrapper trap, from the live before-values, with read-back.

**Prediction (HIT):** if the 26 ms process is the transmitter's radio, the comb vanishes
(band R < 0.05, lag-32 < 0.1) and PER falls toward 4–5 %.
**Falsifier (NULL):** PER 7.6–8.6 % and the 26 ms line survives.
Same wedge rules: one re-run, then UNINFORMATIVE.
