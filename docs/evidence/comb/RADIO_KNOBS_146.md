> Evidence ledger, moved verbatim from `two_jup/comb/RADIO_KNOBS_146.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# ADRV9002 radio knobs on 146 (10.0.0.146) — read-only enumeration [silicon]

SEQ-BIST Task 8a, probe P-D step 1. Unit `knobs146-8a` (same read-only script as 148:
`two_jup/comb/radio_knobs_probe.sh IP=10.0.0.146`), one ssh, 2026-09-03 23:1x.
Raw: `two_jup/comb/knobs_146/knobs.txt`. **Nothing was written.** Same exclusions as the
148 enumeration (no `*reg_access`, no trigger-shaped nodes).

146 is the **TRANSMITTING** board of the forward leg (LEG=A: 146 TX → 148 RX).

| fact | value |
|---|---|
| phy device | `/sys/bus/iio/devices/iio:device2`, `name = adrv9002-phy` (same as 148) |

## The headline: 146 has NO TX tracking calibration running [silicon]

| path | value on 146 |
|---|---|
| `out_voltage0_quadrature_tracking_en` (TX QEC) | **0** |
| `out_voltage0_lo_leakage_tracking_en` | **0** |
| `out_voltage0_close_loop_gain_tracking_en` | **0** |
| `out_voltage0_loopback_delay_tracking_en` | **0** |
| `out_voltage0_pa_correction_tracking_en` | **0** |
| `out_voltage1_*` (all five, unused channel) | **0** |
| `initial_calibrations` | **`off`** |
| `out_voltage0_hardwaregain` | `0.000000 dB` |
| `out_voltage0_atten_control_mode` | present (attenuation mode, not a tracking cal) |

**Every TX tracking calibration the driver exposes on 146 is already disabled**, exactly as on
148. There is no `*_tracking_en` on the TX side left to turn off, and no TX init cals either.
`bringup_r2r3.sh` never enables them, and the profile load leaves them off.

**Consequence for P-D as briefed:** "disable every TX tracking calibration on 146" is
**null by construction** — the probe would write `0` over `0` on five attributes and change
nothing. It cannot move the comb, cannot move PER, and would consume a 600 s leg plus a
bring-up on a rig that is next needed for the 148 flash. It is therefore **not run as a
measurement**; the finding is the enumeration itself.

*(This is the case the Task 8a brief anticipated: "If no tracking-cal control exists, say so".
Here the controls exist but are already in the OFF state the probe would put them in.)*

## What IS live on 146 — the executable P-D

146's **receive** chain is running the full set, identical to 148's:

| path | value on 146 | value on 148 |
|---|---|---|
| `in_voltage0_gain_control_mode` | `automatic` | `automatic` |
| `in_voltage0_gain_control_mode_available` | `spi pin automatic` | same |
| `in_voltage0_hardwaregain` | **`34.000000 dB`** | **`34.000000 dB`** |
| `in_voltage0_rssi` | `27.699 dB` | `27.78 dB` |
| `in_voltage0_agc_tracking_en` | **1** | 1 |
| `in_voltage0_bbdc_rejection_tracking_en` | **1** | 1 |
| `in_voltage0_rfdc_tracking_en` | **1** | 1 |
| `in_voltage0_rssi_tracking_en` | **1** | 1 |
| `in_voltage0_quadrature_fic_tracking_en` | **1** | 1 |
| `in_voltage0_hd_tracking_en` / `quadrature_w_poly_tracking_en` | 0 / 0 | 0 / 0 |

Two things follow.

1. **146's RX gain is at `34.000000 dB` too** — with `maxGainIndex 255` / `minGainIndex 187`
   (68 steps) and 34.000/68 = exactly 0.5 dB/step, that is **gain index 255, the maximum-gain
   rail**, on *both* boards [inferred, arithmetic on measured values]. Both receivers are
   pinned at maximum gain. This is a link-budget fact about the whole rig, not one board.
2. **The transmitting board still runs five periodic RX radio processes.** The campaign's own
   mechanism note (`legrun_go.sh` header, P2) is that "a board's TX silence follows that
   board's OWN RX transfer cadence" — so a periodic process in 146's *receive* chain is a
   live, never-tested candidate for imprinting a 26 ms structure on what 146 transmits.

**P-D was therefore attempted as: the P-A + P-B knob set applied to 146 instead of 148** —
same attributes, same discipline, the other end of the link.

**STATUS (updated after the legs — this paragraph is the authority for what happened):** that
RX-side attempt is **UNINFORMATIVE** and was **not re-run**. Attempt 1 (`probe-8a-D`) wedged
at 12 s; the re-run (`probe-8a-D-r2`) failed `bringup_r2r3.sh`'s arm-quality gate 6/6 and never
opened a window. The coordinator then ruled it not worth a further leg — 146 *transmits* on
LEG=A, so its RX chain is not in the forward-leg signal path. **No number is quoted from
either attempt.** The P-D result that stands is the null-by-construction TX finding above.
See `two_jup/sdd_archive/2026-09-03-seqbist/task-8a-report.md` §6.
