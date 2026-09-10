# 146 TX Byte-Plane Fix + Full-Sweep Acceptance — Design

**Date:** 2026-08-25
**Goal:** Deliver PER < 1% (CP95 upper limit) both directions, ARQ OFF, by fixing the
localized forward defect (146 TX byte-plane, ~10.6%) and restoring the validated reverse
fix (BEATFIX), then closing with a both-direction acceptance soak and a BER-residual
tap-ladder.

**Operator decisions embedded in this spec (2026-08-25):**
- The "146 never flashed" freeze is LIFTED — aggressive path chosen.
- First 146 image: **fresh TMR rebuild** (new placement of the same RTL) — the flash is
  simultaneously the board-vs-implementation discriminator and the likely fix.
- Scope: **full sweep** — 146 fix, DCP census, watchdog delivery criterion, BEATFIX v3
  back on 148, both-direction re-baseline, BER tap-ladder on the residual.

## Established facts this design builds on (do not re-derive)

- Forward loss 10.62% (8,332/78,461 live-window frames, CP95UL 10.837%), saturated tun;
  idle-only byte-DMA 9.33%; **ROM bypass 0 events / 28,213 frames** → defect is in 146's
  TX byte-plane datapath (byte-DMA → ByteWordBuffer → encoder feed), content- and
  load-independent. (SINGLES_CAMPAIGN.md)
- TX byte-plane RTL is bit-identical across TMR and 148 lineages (headers only) → defect
  is implementation-level (cf. ebbf4eb rail-re-hosting forensic) or board-level.
- Float receiver on real air: 0 errors / 995,652 bits, Es/N0 ~29 dB; hardware same
  window 8.2e-5 BER → all residual loss is implementation, not channel.
- Reverse last measured pooled 1.72% (228,659 frames, CP95UL 1.78%); BEATFIX validated
  on-air earlier but v3 not currently deployed (148 runs e49c011b for its working tap).
- #48 delivery wedge: 7 occurrences, watchdog-blind, intervals ≲40 min; nemo-side
  sentinel (`~/modem-status/delivery_sentinel.sh`) auto-recovers as a stopgap.
- **No banked copy of 146's running image (433fd8dab393) exists on nemo** — every
  `BOOT.BIN.*.bak` on disk is 148's 64bb2476. Banking it off the board is a hard
  precondition to any 146 flash.
- `jupiter_byte_tmr146_build/` was rebuilt 08-18 → BOOT.BIN `4be9286ca111` (candidate
  fresh rebuild, provenance unverified). `jupiter_byte_tmr146_gates/asrun_433fd8da/`
  exists (asrun .slx + workspace) as the rebuild-from-source fallback.

## Global constraints

- Rig is a hard mutex. Stop the sentinel (`touch ~/modem-status/SENTINEL_STOP`, verify
  process exit) before any measurement leg or flash; restart it (remove stop-file,
  relaunch detached) after, until Lane C retires it.
- **One flash event per board maximum** in this campaign, each behind its own gate.
- Flash rails (both boards, no exceptions): md5 precondition on the exact image file,
  readback verify, full bring-up, two-pass health gate (fsync ≥ 1100 AND wcnt ≥ 1100),
  auto-rollback to the banked image on failure, **no retry** after a failed attempt.
- Metrics discipline: every PER/BER claim carries the exact command, sample count, and
  confirmation that dropped/lost frames are in the denominator. Verdict rules are
  pre-stated and never revised after data.
- Long builds detached (`setsid nohup … & disown`) with one watcher; no foreground
  polling. Commits `git commit -s`; commit implies push.
- All results appended to `two_jup/SINGLES_CAMPAIGN.md`.

## Lane A — 146 TX byte-plane fix (centerpiece)

**A0 — Bank the rollback image (hard gate for A3).**
Copy 146's live BOOT.BIN off its boot partition to
`jupiter_byte_tmr146_gates/boot/BOOT.BIN.146.433fd8da.bak`, md5 it, and require the
md5 to be `433fd8dab393` (12-char prefix convention). If the on-board file does not
match the expected md5, STOP Lane A and surface to operator (identity of the running
image would be in question).

**A1 — Candidate image provenance.**
Verify the 08-18 rebuild (`jupiter_byte_tmr146_build`, BOOT.BIN `4be9286ca111`) was
generated from the same RTL as the asrun lineage: bit-compare generated HDL under the
build dir vs `asrun_433fd8da` sources (TxRxComposite.v and the byte-plane module set at
minimum). PASS → `4be9286ca111` is the flash candidate (saves ~3 h). FAIL → rebuild
from `asrun_433fd8da` detached (~3 h), same recipe, and the new BOOT.BIN becomes the
candidate.

**A2 — Pre-flash rail census (kill gate).**
Run the ebbf4eb-style rail/enable census on the candidate's DCP: does the byte-plane
enable network get re-hosted into the AXI addr decoder (the named implementation
divergence)? If the candidate shows the same defect signature as the witness builds,
flashing it cannot test the hypothesis — divert to a reseeded or rail-guarded rebuild
and re-run A2. Only a census-clean (or census-different) candidate proceeds to A3.

**A3 — Flash 146 (first time this campaign).**
Full rails per global constraints; rollback target is the A0 banked image. Gate to
proceed past A3: bring-up completes and two-pass health gate passes on the new image.

**A4 — Verdict by byte-source ladder (pre-stated rule).**
Same instruments and thresholds as the localization campaign:
1. ROM leg (60 s census, `rom_air_comb_census.sh` + `analyze_comb_census.py`):
   must remain ABSENT (<1e4 events/s). If ROM is now dirty, the flash regressed the
   datapath → immediate rollback and record.
2. Idle-only byte-DMA leg (60 s stats delta) and saturated-tun leg
   (`capture_r3.sh`, wedge-aware scoring, ≥75 k live-window frames).
Verdict rule, stated before data:
- **FIXED**: saturated-tun live-window PER CP95UL < 1% → implementation defect
  confirmed and fixed; proceed to Lane D.
- **UNCHANGED**: PER in 9–12% → board-level (or design-level invisible to rebuild).
  Close the discriminator by A/B: flash back the banked original (uses the rollback
  path, not a new flash budget) and confirm the rate reproduces; then the follow-on
  (148-lineage image on 146, or fabric-side comparators) is a new operator decision.
- **CHANGED-BUT-NOT-FIXED** (e.g. 3%): implementation-sensitivity proven; iterate
  placement/rail-guard rebuilds (each further 146 flash is a new operator gate).

## Lane B — 148 BEATFIX v3 + reverse re-baseline

B1: locate/verify a banked BEATFIX v3 BOOT.BIN + md5 (beatfix2 build dir first);
rebuild detached if absent. B2 (ORDERING GATE): before flashing 148, complete every
capture-tap-dependent leg (Lane D BER captures, any A4 IQ capture) OR verify v3's tap
health with `check_capture_health.py` post-flash — e49c011b's working tap is currently
the only known-good capture path. B3: flash 148 under full rails (rollback = e49c011b,
already banked). B4: reverse re-baseline: 3 runs, ≥75 k frames each, wedge-aware,
drops in denominator; target CP95UL < 1%; poke fixctl=3 per the validated recipe and
verify by effect.

## Lane C — lock_watchdog delivery criterion (retires the sentinel)

C1: add to `/root/lock_watchdog.sh` (both boards): sample `idle_rx` from the stats
line; if delta over its poll interval < 100/s while lock is asserted, restart the
daemons (existing recovery action). C2: positive control — with the link healthy, kill
delivery deliberately once (the documented TGEN fill≤16 trigger or daemon SIGSTOP) and
verify the watchdog recovers within 2 poll intervals; a watchdog that has not caught a
planted fault is not trusted. C3: after 2 h of wedge-free (or wedge-auto-recovered)
operation, stop and remove the nemo sentinel; keep `sentinel.log` as the wedge-interval
dataset.

## Lane D — Acceptance + BER residual

D1: with A4=FIXED and B4 done, simultaneous both-direction soak: ≥200 k frames per
direction, ARQ OFF, wedge-aware scoring, drops in denominator. **Campaign goal met**
iff both directions CP95UL < 1%, reported with commands and counts.
D2: BER tap-ladder on the residual (float 0 vs hardware 8.2e-5): re-run
`float_baseline_f1536` and the fixed-point tap ladder on a fresh health-gated capture,
name the first stage where hardware diverges from float. D2 runs on whichever board
still has a working tap (see B2 ordering).

## Sequencing

```
now      A0 (bank 146 image)  ─┐
         A1 (provenance)       ├─ parallel, no build needed
         C1/C2 (watchdog fix)  ─┘
then     A2 (rail census on candidate)   [rebuild in background if A1 FAILED]
         B1 (locate/verify BEATFIX v3)
flash1   A3 (146) → A4 ladder verdict
         D2 BER captures while 148 tap still known-good
flash2   B3 (148 BEATFIX v3) → B4 reverse re-baseline
close    D1 acceptance soak → goal verdict; C3 retire sentinel
```

## Risks / honest limits

- A4=UNCHANGED is a real possibility (board-level cause); the campaign then ends with
  the discriminator closed, not the goal met — that is still the decisive result.
- The 08-18 rebuild may fail provenance (A1) → +3 h build before flash1.
- Vivado rebuild could accidentally reproduce the same placement pathology; A2 exists
  precisely to catch that before spending the flash.
- BEATFIX v3 tap status unknown; B2's ordering gate protects capture capability but may
  serialize D2 before flash2, lengthening the day.
- 146 flash is inherently the campaign's riskiest act; A0 banking + rails + rollback
  bound the damage to one recovered flash cycle.
