# Flash-and-bring-up cycle budget (measured 2026-08-28) and a two-tier proposal

## Measured (six flashes today, `skidfix/flash_148_rxfifo_diag.sh`, rail start → DONE)
probe-1 305 s · probe-2 304 s · probe-3 304 s · probe-4 305 s · lean 322 s · probe-4-back 313 s.
Stage split (from the start/census/DONE stamps; per-stage stamps are now being added to the rail):

| stage | what | measured / derived | fixed waits inside |
|---|---|---|---|
| [0] pre-flash health precondition | reset-aware probe, 12-s dwell | ~14 s | 12-s dwell (measurement, not padding) |
| [1] restore point | `cp` 7 MB on-board + `sync` + md5 | ~5 s | — |
| [2] stage + write | scp 7 MB + md5 + `reboot` | ~5 s | — |
| [2'] reboot → ssh back | PS reset, u-boot, kernel, ADRV9002 profile | **~150 s** (boot itself ≈120–135 s) | `sleep 45` then 15-s ssh polls → up to ~20 s granularity loss |
| [3] readback verify | md5 of /boot/BOOT.BIN (already a checksum, ~1 s) | ~1 s | — |
| [4] full bring-up (both boards) | ROM arm double-tap, gate tries, daemons | **68–76 s** (three restores today) | ≈27 s of fixed `sleep`s on the single-path (0.5/3/… s taps + gate waits) |
| [5] diag census (diag variant only) | 5 samples + 10-s delta | ~25 s | 5×2 s + 10 s |
| [5b] two-pass health gate | 2 × 12-s reset-aware dwell | ~26 s | dwell = measurement |
| [6] fixctl arm + 0x1B0 witness | 10-s delta | ~12 s | 10 s |
| **rail total** | | **≈305–320 s** | |

Around the rail (chain scripts, not the rail): rig-free/lock polling (`sleep 20/30`, 30-s "until
done" loops) and the health-precondition loop (60-s polls): **60–150 s**; post-experiment restore
bring-up: **~70 s**. So one exploratory "flash → probe → restore" ≈ 8–9 min; a diagnostic round trip
(flash X, measure, flash back) ≈ 17–20 min — that is the 20 minutes.

## What is padding vs necessary
- **Reboot (~150 s)** is the floor: BOOT.BIN only loads at boot. Runtime bitstream load via
  fpga_manager without a reboot would need DT overlays / driver re-probe for the ADRV9002 and the
  DMACs — not something to introduce on this rig now.
- `wait_back`: `sleep 45` + 15-s polls → poll ssh every 3 s from t=30 s: **−15…−30 s**, same condition.
- Chain polling (20/30/60-s sleeps) → 5-s polls on the same conditions: **−60…−120 s**.
- Bring-up fixed sleeps (≈27 s): ~half are tap settling (keep); gate waits can poll 0x104 instead of
  sleeping: **−10…−15 s**.
- Diag census (25 s) + 0x1B0 witness (12 s): only meaningful for FIFO-lineage diagnostics: **−37 s**
  when not needed.
- Two-pass gate: the second pass exists to catch the post-reboot reset storm (H-6b) that a single
  12-s window passes ~27 % of the time; needed for any number we bank; a quick probe can run one
  pass because the standing sentinel + the experiment's own counters catch a storm: **−13 s**.
- Restore-point bank: skip the 5-s copy when `/root/BOOT.BIN.<md5>.bak` already exists with a
  matching md5 (verify by md5, 1 s): **−4 s** — negligible, but free.
- Readback verify already IS a checksum (md5 of the on-board file), 1 s. Nothing to gain.

## Two tiers (safety properties stated explicitly)
**Full rails (any number we quote / bank):** unchanged: pre-flash health refusal, restore point
banked (md5-verified, on-board + repo), md5 readback, full bring-up, daemon-fingerprint equality,
census (diag lineages), TWO-pass reset-aware gate, auto-rollback, no retry. ≈305 s + chain.
**Quick (exploratory probes, results not quotable):** identical refusal conditions, identical
restore-point + readback + auto-rollback + no-retry; differences are ONLY: one gate pass instead
of two, no census/0x1B0 witness, 3-s ssh polling, 5-s chain polling, gate waits polled. Estimated
rail ≈ 215–230 s (−30 %), chain overhead ≈ 30 s (−70 %); exploratory round trip ≈ 11–12 min instead
of 17–20. The single safety property that differs: a post-reboot reset storm surviving one 12-s
gate would go unflagged by the rail (the sentinel/experiment counters still see it) — which is
exactly why quick-tier numbers are never quoted.
Honest summary: ~3–4 min per round trip is removable as waiting; the remaining ~11 min is reboot
time and real measurement dwell. No checking is removed in either tier.

## Serial console
Neither Jupiter has a console attached today: `tron:/dev/ttyUSB1` serves neither board (checked
08-28 morning), HOSTS.md's `ttyACM0` entry is stale (`RIG_NOPING_FAULT.md`). Attaching a USB
console cable from a lab host to each Jupiter's UART is a physical action (operator); once present,
a `socat`/`screen` logger unit per board captures the console to a file continuously, which is the
missing evidence for the H-7 dark-flash class (the PS hang happens before journald can write).

## MEASURED per-stage (2026-08-29, rail now stamps every stage; lean flash `flash_witlean.log`)
```
T+   0.0s start            T+  57.4s reboot->ssh back   T+ 269.3s census done
T+  13.9s precondition     T+  58.5s readback done      T+ 284.1s gate done
T+  15.8s restore banked   T+ 243.2s bring-up done      T+ 296.6s DONE
```
**Corrections to the 08-28 estimate:** the reboot is **57 s**, not ~150 s (the old `sleep 45` + 15-s polling
hid it; 3-s polling from t=30 exposes it) — and the dominant stage is the **full bring-up at 185 s**
(both boards, ROM arm double-tap, gate tries, daemons), not the reboot. Readback is 1.1 s. Census 26 s,
two-pass gate 15 s, witness 12 s. So the remaining reducible time is in the bring-up, not in waiting:
a flash that only needs 148 armed (loopback probes) does not need 146 re-armed or the daemons started.
Proposal (not implemented): a `BRINGUP_SCOPE=148only` path for loopback-only experiments — same gates,
~90 s saved per flash; full both-board bring-up stays the default for anything on air.
