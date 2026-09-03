# RX1A HMC8414 LNA experiment — the LNA is already ON (and mandatory)

**Question (task premise):** the link's ~20 % EVM is an additive RF/SNR floor
(docs/EVM_BUDGET.md, C2). The Jupiter HW doc says RX1A/RX2A have a bypassable
HMC8414 LNA on ADRV9002 AGPIO (RX1A→agpio4, RX2A→agpio6; HIGH=on, LOW=bypass).
If the link ran LNA-bypassed, ~17–19 dB of low-NF gain would be on the table.

**Answer:** the premise is **false**. The LNA is **already enabled** in every
armed baseline, it delivers ~17–18 dB, and the link **cannot close without it**.
The ~20 % floor is measured *with* the LNA on; there is no LNA headroom to bank.

## Why the LNA is already on
Both arm paths — `link_test.sh` (`arm_ber` / `coldstart_tun`) and
`capture_evm.sh` (`arm`) — contain, verbatim:

```
for g in 4 5 6 7; do echo 1 > $DB/agpio${g}_direction; echo 1 > $DB/agpio${g}_value; done
#   $DB = /sys/kernel/debug/iio/iio:device2   (adrv9002-phy)
```

so **agpio4 (RX1A LNA) and agpio6 (RX2A LNA) are driven HIGH at every arm.**
Idle readback on both 148 and 146 confirmed `agpio4=agpio5=agpio6=agpio7=1`
(state persists between arms). The modem RX runs at 1.90/2.00 GHz on the single
RX1 channel (`iio:device2 in_voltage0`), which is physically **RX1A** (RX1B is
the sub-1 GHz low band and cannot tune 2 GHz) → its LNA control is **agpio4**.

## Control surface (the real driver mechanism on these images)
debugfs, per ADRV9002 IIO driver:
`/sys/kernel/debug/iio/iio:device2/agpio{0..11}_{direction,value}` (+ `dgpio{0..15}`).
Manual GPIO: write `1`→direction (output) then `1`/`0`→value. No raw SPI needed.
`in_voltage0_port_select` is **empty** (RX port is fixed by profile/DT, not
runtime-selectable), so the RX1A binding is inferred from the 2 GHz tune, and
then **proven empirically** by the toggle below.

## Toggle proof (reverse link, receiver = 146, agpio4 ONLY, no re-arm)
Only agpio4 was touched (5/6/7 left as the arm set them — they are the
known-good T/R-switch / PA block, not a second LNA). No re-arm between states.

| state | agpio4 | RSSI (dB↓FS) | decimated_power (dB↓FS) | hwgain | BER (60 s, rev, scored by 146) |
|---|---|---|---|---|---|
| **lna1** (baseline, arm default) | 1 | 30.4 | 27.75 | 34 dB (AGC max) | **1.72e-6**, CLEAN 98.0 % |
| **lna0** (LNA bypassed) | 0 | **48.1** | **45.0** | 34 dB (pinned) | — CLEAN 0 %, **PHASE 100 %** |

RSSI/decimated_power are reported as **dB below full-scale**, so turning the LNA
OFF **dropped the received level by ~17.7 dB / ~17.25 dB** — exactly the HMC8414
gain. hwgain did *not* rise to compensate because the AGC was already at its
**34 dB ceiling**; the 18 dB loss therefore fell straight onto post-AGC SNR and
the link **collapsed** (all frames → PHASE bucket, no clean decode; `rstcs`
began incrementing). This simultaneously proves: (1) agpio4 is the live RX1A LNA
control, (2) the modem RX is on RX1A, (3) the LNA is ~18 dB and (4) it is
**required** for the link to close on the quiet pair.

## Mode-3 EVM (rx2-lpc tap), reverse
- **lna1 (LNA on):** RMS EVM **20.18 %** (mag 14.17 / phase 14.57, excised 20.10 %, nFrames=271) — matches the C2 reverse floor (~20.0 %). ideal_ref raw.iq = 19.79 %. *This is the shipping floor, LNA already applied.*
- **lna0 (LNA off):** RMS EVM **161 %** at **nFrames=0** (tap collapsed to 0.33×Rsym, conf=low) — broken link, not a floor number; ideal_ref raw.iq = 39.7 % (phase-dominated 39.4 %). Recorded only to show the link is gone without the LNA.

CSV rows: `evm/evm_results.csv`, session dirs
`two_jup/evmcap/20260723_185312_rev_lna1` / `..._rev_lna0`.

## Conclusion / final state
- **No EVM gain available from the LNA — it is already enabled.** The RF/SNR
  floor of EVM_BUDGET.md is the *LNA-on* floor. The lever for the floor is
  elsewhere (front-end NF beyond this LNA, antenna/cabling, quiet-pair freq),
  not this switch.
- **Better state = LNA ON = the arm default.** No change needed. Both boards
  left **idle with agpio4=1** (verified: 148 agpio4=1, 146 agpio4=1, RSSI 30.6 dB,
  no qpsk_tun/watchdog).

### How to flip the RX1A LNA (reference)
```
DB=/sys/kernel/debug/iio/iio:device2
echo 1 > $DB/agpio4_direction          # output
echo 1 > $DB/agpio4_value              # LNA ON  (bypass off)   <-- keep this
echo 0 > $DB/agpio4_value              # LNA bypassed (link fails on quiet pair)
```
The standard arm already sets agpio4=1; a re-arm restores it. Do **not** run the
link with agpio4=0 — it does not close.

_Experiment: `two_jup/lna_experiment.sh` (reverse; agpio4 only; restores 1 +
quiesces on exit). Image md5 dcf5c5fb29e6509723b35f476a0a1bfa (lean/rxfix)._
