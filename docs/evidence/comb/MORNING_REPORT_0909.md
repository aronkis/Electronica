> Evidence ledger, moved verbatim from `two_jup/comb/MORNING_REPORT_0909.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# Morning report — 2026-09-08 day + overnight → 2026-09-09 07:00

**Instruction I worked to (20:0x):** "continue working through improvements. I'm away until 7am EST. Use
hardware as needed without approval. push forward with testing without approval." Flashes pre-authorised
("yes flash", 15:1x; "DO NOT GATE ON APPROVALS FOR HARDWARE FLASHES", 11:5x).

## Headline

The forward leg's residual is solved to its root and the fix is shipped as a host default. Three defects
were found and fixed today, in series:

| defect | what it was | fix | forward PER (lost frames in denominator) |
|---|---|---|---|
| 148's RX antenna (physical, degrading, frequency-selective) | the 09-06/07 collapse to 58–61 % CRC-ok | antenna swapped by the operator (replace it) | 56.7 % → 0.070 % |
| FIFO/DMAC deadlock amplifier (fabric) | one short frame misaligned the DMAC transfer; SYNC_TRANSFER_START wait + FIFO drop-oldest cost 3 frames per event | **F4 / RXFIX_PAD**: ByteSerializer pads truncated frames to 191 words; image `bf2a7305bbe0` on 148 | 0.061 % → 0.045 % (window) |
| **Un-whitened idle payload → false preamble peak → early frame start → k × 1536-bit truncation** (the root) | 97 % of the remaining loss, ~0.22 events/s, 2–3 CRC-fail frames each | **`WHITEN=1` default in `bringup_r2r3.sh`** (both ends; carried into the watchdog relaunch) | **0.045 % → 0.005 % (27 / 585,772, CP95UL 0.007 %)** |

Full record: `two_jup/comb/FWD_CRC_REGRESSION_0907.md` §46 (morning: reboot, watchdog timeline, antenna
swap, no-ping hang) and §47 (afternoon/evening: census leg, sim reproduction, F4, root cause, whitening).

## Numbers, with the qualifications the rig rules require

- Forward, whitening ON, census window 469 s: PER **0.005 %** (27 lost / 585,772 transmitted, CP95UL 0.007 %),
  `bs_trunc` 2 (was 104), `bs_drop` 0. Command: `w1leg_go.sh DRY=0 MODE=air LEG=A BOARD=148 DUR=600 PERIOD=10
  BS=1 R4B=1 RSSI=1 EXP=bf2a7305bbe0 FIXCTL_BASE=0x0 WHITEN=1 WHITEN_DENV=QPSK_WHITEN=1`, run
  `runs/20260908_203759_w1_whiten1`, scored by `bs_pair_score.py` (host_seq span denominator). Whole-leg
  `accept_analyze`: 0.031 % (231/733,891) — includes one 191-frame run at t = 602.5 s, after the 600 s
  traffic end (teardown artefact, present on every leg today); the window number is the comparable one.
- Reverse, whitening ON, on the DEGRADED antenna (now on 146's RX): loss in runs ≤ 20 frames **0.170 %**
  (455/267,858) vs 0.367 % this afternoon — NOT credited: the leg was cut at 228 s by a class-E wedge.
  The 09-06 baseline (good antenna, no whitening) was 0.191 %; expect < 0.1 % after the antenna is replaced.
- **≤ 1 % target: met on both legs** (forward 0.005 % window / 0.031 % whole leg; reverse 0.170 % small-run
  loss on a wedge-cut leg). The reverse number needs a full 600 s leg to be credited — the overnight runner
  is producing them (below).

## Overnight runner result (21:21–23:28, ledger §47.24)

Eight 600 s legs, whitening at the shipped default, PER over the 15–598 s window (lost frames in the
denominator; the end-of-traffic run at t ≈ 602 s excluded):

| | forward (146 → 148) | reverse (148 → 146, degraded antenna) |
|---|---|---|
| per-leg PER | 0.0067 / 0.0076 / 0.0059 / 0.0113 % | 0.070 / 0.080 / 0.022 / 0.043 % |
| **pooled** | **0.0079 % (229 / 2,904,364)** | 0.055 % (1,447 / 2,619,378), two legs wedge-cut |
| class-E wedges | 0 of 4 | 2 of 4 (at 574 s and 418 s), **no peer TX gap within ±19 s of either** |

Forward is ten times better than the 09-05 best and stable. Class E tracks the degraded receive path
(4 of the last 5 reverse legs; 0 of 5 forward legs since the antenna swap), not transmitter gaps.
After the runner: the sentinel logs `crc=`/`rev=`/`rcrc=` every 5 min until 07:00.

## 07:49–08:57: re-baseline on the replaced antenna (ledger §48.3)

| | forward | reverse (new antenna) |
|---|---|---|
| window PER, 2 legs each | 0.0103 / 0.0063 % (pooled 0.0083 %) | 0.091 / 0.058 % (pooled 0.075 %) |
| class-E wedges | 0 | **0** (was 4 of the last 5) |
| receiver level | 148: 27.2 dBFS (was 22.9 yesterday) | 146: 30.2 dBFS (was 28.3 on the bad antenna, 24.6 on 09-05) |

Both receive levels are WEAKER than before the replacement (148 −4.3 dB, 146 −1.9 dB); the reverse leg is
5.6 dB below its 09-05 level and its loss is level-limited. Check antenna placement/orientation on both
boards before treating the reverse number as final.

## Open items, ranked

1. **Class-E receiver storm** — 4 of the last 5 reverse legs (degraded antenna, 28 dBFS) died in it, 0 of 5
   forward legs since the swap; no peer TX gap precedes it (§47.24). It is the carrier loop's marginal-signal
   failure mode: ~20 s flatline, then a reset storm until a re-arm (the in-service watchdog does that in
   ~15 s; the re-arm's TX gap can storm the peer — §46.2). Fix candidates: the antenna replacement first;
   then receiver storm-exit robustness / watchdog soft-rearm-first (NEXT_STEPS 3).
2. **Replace the bad antenna / cable** (on 146's RX since the swap); re-baseline the reverse leg.
3. Content-independent hardware fix for the root defect (preamble peak position flywheel, or TX scrambler
   + RX descrambler) — desirable, not urgent now that whitening is the default.
4. `capture_r3.sh`'s pair.iq "REBOOT-ONLY" verdict misfires on every class-E wedge and leaves both daemons
   down; an `r3` bring-up cleared it 4/4 today. Fix the verdict or make its restore run the bring-up.
5. Housekeeping from the day: watchdog cross-coupling (§46.2), the 148 no-ping hang I caused (§46.6, rule
   restated in BRINGUP §0.3), sentinel high-mode artefact (§46.4).

## Rig state at hand-back (see overnight.log for the final line)

148 = `BOOT.BIN.148.rxfixpad.bf2a7305bbe0` (rollback `dec007ae70dd` on-board), 146 = `9acbe2ebe1db`,
whitening ON both daemons, DP cable out of 146, shipped LOs. Antennas are SWAPPED (the bad one is on
146's RX). Everything committed and pushed on `per-under-1pct-2026-07`.
