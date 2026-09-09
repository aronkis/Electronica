# Task 10 — W1 on silicon: flash, controls, one witnessed forward air leg

Branch `per-under-1pct-2026-07`. Ledger `Task 10:` lines in `progress.md`.
Commits: `cc344e6` (Step 0), `695cf42` (Steps 1–2), this report.
Labels: **[silicon]** unless marked otherwise. Evidence banked under
`two_jup/sdd_archive/2026-09-04-rxfix/t10_evidence/`.

---

## 0. Headline

**The AXI decode works, every tap passed its control, and the leg answered the
question in the sim's favour.** On the forward air leg the Rate_Handle ring sits
pinned at its EMPTY edge and suppresses a pop 394 times per 10 s — and **not one
valid is lost anywhere in the receiver chain as a result**. P1, P2 and P3 all
hold; P2-alt (the deletion reading) is refuted at every stage; **F2 fires**.

The single most decisive number is a coincidence the campaign had never been able
to test directly:

| quantity | value | source |
|---|---|---|
| `pop_on_empty` mean inter-event interval | **25.3793 ms** | W1 register, 18,519 events / 470 s |
| PER comb period, measured independently host-side | **25.3872 ms** | `comb_period_ms.py` on `frames.bin` |
| agreement | **0.031 %** | — |
| implied SRO | **2.565 ppm** | vs campaign's 2.575 / 2.59 ppm |

The ring's empty-edge event and the PER comb are the **same event**, identified on
silicon, from two instruments that share no code path. And the census proves that
event **deletes nothing**. So the frames die for a reason that is not a missing
symbol — which is exactly F2.

**Image on the board at the end, from a readback:** `2728dab3979a` (W1) on 148;
146 untouched on `3378861d30bd`. Rig back in service, hold released, sentinel
running.

---

## 1. Step 1 — flash under the full rails

Keeper hold taken first (`DRY=0 keeper_hold.sh hold`): `SENTINEL_STOP` and
`RIG_LOCK` both **created by this task** (marker `SENTINEL RIGLOCK`),
`sentinel-100708` + `sentinelkeeper-100708` stopped, `lock_watchdog` killed on
both boards. Unit `flash148-w1` via `launch_rig_unit.sh`, watched with
`watch_unit.sh`; never interrupted.

```
16:40:37  148 current image: a1ff3c876d91 (expect a1ff3c876d91)
16:40:41  FLASHED 2728dab3979a
16:41:50  booted image: 2728dab3979a (expect 2728dab3979a)
          gate 1: ARM_OK profile=lvds_61p44_fdd_jupiter fps=1248 capTAP=0xBCF94856
          gate 2: ARM_OK profile=lvds_61p44_fdd_jupiter fps=1248 capTAP=0xBCF94856
16:44:50  GATE_PASS x2
16:44:53  FLASH_DDRCAP2_OK 2728dab3979a
```

Tier-2 witness decoded: 524,288 records, 43 demod marks, `toff` mode 12314,
distinct 1. `postflash_check.sh`: **POSTFLASH_OK**, `mux_select=distinct` — the
SEQ-BIST checker, `cnt_mux32` and the 0x9D4x GPIOs all survived the W1 build.

**Correction to the brief's precondition, stated because a reader should not
believe more than happened.** The brief says the on-board
`/root/BOOT.BIN.a1ff3c876d91.bak` "must be verified by the chain before it
flashes". That file **did not exist**. The chain's own line is
`[ -f /root/BOOT.BIN.$BAK.bak ] || cp -f /boot/BOOT.BIN /root/BOOT.BIN.$BAK.bak`,
so it **created** the rollback point from the running `/boot/BOOT.BIN` (which was
`a1ff3c876d91`) and then verified its own copy. Same bytes, and safe — but no
independent pre-existing backup was verified.

**Provenance (coordinator item 3):** the flashed image's injector source is
**`2c661e6`**, not the `b5c39a10` printed in the Task 9 report.

---

## 2. The first board read — the AXI decode gate  [silicon]

Task 9 concern 3 said the first real proof that `0x214` returns `witA` would be
the first board read. It does.

```
witA=0x6D5  -> occ=1 pushPtr=22 popPtr=21
witA=0x5CD  -> occ=1 pushPtr=14 popPtr=13
witA=0x4A4  -> occ=1 pushPtr=5  popPtr=4
witB=0x2C   -> pop_on_empty=44  push_on_full=0
```

Not `const_0`, not stuck, not all-identical. Structural decode checks pass on
every reading of every set in this task: **`witA[31:16] == 0`** (documented zero)
and **`occTrue <= 32`**. `freeze_effective` true on every sweep taken.

`FIXCTL_BASE=0x0` was used for every read and is recorded in every run meta. It
is justified by evidence, not assertion: `arm148_mode1.sh` writes `0x208 0x0` in
every arm, and **`bringup_r2r3.sh` and `capture_r3.sh` contain no `0x208` write
at all** (grepped) — so the air leg inherits fixctl from the arm/FPGA reset, both
0. `w1_read.sh` also rewrites `FIXCTL_BASE` after each reading, so from the first
reading onward it holds by construction. Consequence, stated: `enSlack`(3)=0 and
the TXCAP/DEMODCAP mux bits (12/13)=0 throughout — which is what keeps `0x20C` on
the DBGCAP source that the golden `capTAP=0xBCF94856` expects.

---

## 3. Step 2 — control table, one row per tap  [silicon]

Run `two_jup/comb/runs/20260904_164756_w1_ctrl`. 148 in mode-1 digital loopback
(`arm148_mode1.sh`), `SINK=tgenrx` armed for the run and disarmed on exit, three
reads 10 s apart → one 10 s freeze-hold read → **exactly one** re-arm → three more
reads.

| tap | verdict | control and evidence |
|---|---|---|
| freeze path (0x208 bit 4) | **PASS** | freeze **held 10 s**; all eight words identical across two sweeps 10 s apart (`aux_lag_s=10.049` proves the hold was real). Every counter's delta exactly 0. |
| `cSS` | **PASS** | advances ~1.68e8 / 10 s; equals the other pre-discard stages |
| `cRH` | **PASS** | as above |
| `cCFC` | **PASS** | as above |
| `cCS` | **PASS** | as above (within the measured ±1 phase jitter, §3.2) |
| `cPD` | **PASS** | as above |
| `cPC` | **PASS** | advances, and matches **12,320/frame** not 12,333: at-rest intervals gave exp 167,908,736 / got 167,908,735 (−1) and exp 167,709,009 / got 167,709,019 (+10) |
| `witA` occupancy | **PASS** | nonzero, constant at 1 in steady loopback (matches sel15's 09-02 pinning at 1) |
| `witA` pointers | **PASS** | 6 distinct (push,pop) pairs, advancing mod 32 |
| `pop_on_empty` | **PASS (LIVE)** | **arm-transient control**: 10 → 44 across the one re-arm, i.e. **+34** — sim predicted **34** in the first three frames of acquisition |
| `push_on_full` | **NOT EXERCISED** | stayed 0. Not a failure (Task 9 concern 2); the FULL edge is unreachable on a forward leg |
| edge counters NULL | **PASS** | `pop_on_empty` and `push_on_full` deltas both **0** on every steady-loopback interval, occupancy constant |
| stuck-at sweep | **PASS** | every word differs between at least two reads |

**TAPS FAILING THEIR CONTROL: none. No tap is excluded and the air leg is NOT
labelled PARTIAL.**

### 3.1 `pop_on_empty` clears on every arm — an instrument fact

At rest it read 44; after arm #1, 10; after arm #2, 44 again. The arm's `0x000`
soft reset zeroes it and it then accumulates **that acquisition's own transient**
(10 and 44 on two arms; sim 34). So a cumulative value is **never** comparable
across an arm and only per-interval deltas are meaningful. The scorer uses
per-interval deltas throughout.

### 3.2 Inter-stage equality needs a measured tolerance — and why that matters

In any frozen snapshot the stages sit at **fixed pipeline offsets**: `cRH=cSS−1`,
`cCFC=cSS−9`, `cPD=cSS−12352` constant across all nine loopback snapshots, while
`cCS` alternates `cSS−11`/`cSS−12` — one beat of sampling phase. A constant offset
cancels in a delta; the one-beat jitter does not, so **a stage delta can differ
from `cSS`'s by ±1 with zero loss** (proven here: zero SRO, `pop_on_empty` delta
0). `EQ_TOL` set to **±4** from this measurement.

This is load-bearing. Testing P2 as *exact* equality would have failed it
spuriously on almost every air-leg reading. P2-alt predicts a shortfall of ~395
per 10 s — about **100×** this band — so the two readings are never confusable.
Measured `cPD` offset 12,352 vs the sim's ≈12,340.

---

## 4. Step 3 — the forward air leg  [silicon]

Run `two_jup/comb/runs/20260904_165420_w1_air`. `legrun_go.sh LEG=A DUR=600`,
`RATE_GATE=900`, `bringup_r2r3.sh` defaults, keeper hold kept, no watchdog
relaunch. **Leg gate PASSED**: `capture_r3_exit=0`,
`deliver_rate_pre=1900 deliver_rate_post=1900 deliver_rate_gate_pass=1`,
`watchdog_relaunch_rx=0 watchdog_relaunch_peer=0`,
`wedge_verdict=healthy crc=92% rate=1900f/s`. Reader window **480 s, 48 readings,
47 intervals, spacing min=max=10.0 s**. No re-run was needed.

### 4.1 The table (cumulative AND delta, per read)

Full 48-row CSV: `t10_evidence/air_w1_reads.csv`. Extract:

| # | t | occ | poe cum | poe Δ | pof cum/Δ | 0x104 Δ | cSS cum | cSS Δ | cRH Δ | cCFC Δ | cCS Δ | cPD Δ | cPC Δ |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 16:56:49 | 1 | 3321 | 401 | 0/0 | 12682 | 833,124,864 | 156,770,613 | 156,770,612 | 156,770,612 | 156,770,613 | 156,770,613 | 156,228,150 |
| 2 | 16:56:59 | 1 | 3723 | 402 | 0/0 | 12707 | 990,127,236 | 157,002,372 | 157,002,372 | 157,002,372 | 157,002,371 | 157,002,372 | 156,508,911 |
| 3 | 16:57:09 | 1 | 4123 | 400 | 0/0 | 12635 | 1,146,305,756 | 156,178,520 | 156,178,520 | 156,178,520 | 156,178,520 | 156,178,521 | 155,636,689 |
| 4 | 16:57:19 | 0 | 4484 | 361 | 0/0 | 11433 | 1,287,554,929 | 141,249,173 | 141,249,174 | 141,249,174 | 141,249,174 | 141,249,173 | 140,830,244 |
| 5 | 16:57:29 | 1 | 4884 | 400 | 0/0 | 12631 | 1,443,604,526 | 156,049,597 | 156,049,596 | 156,049,596 | 156,049,596 | 156,049,595 | 155,406,354 |
| 6 | 16:57:39 | 0 | 5285 | 401 | 0/0 | 12670 | 1,600,435,327 | 156,830,801 | 156,830,802 | 156,830,802 | 156,830,802 | 156,830,802 | 156,240,563 |
| 24 | 17:00:39 | 1 | 12386 | 400 | 0/0 | 12614 | 72,448,785 | 155,958,362 | 155,958,362 | 155,958,362 | 155,958,362 | 155,958,362 | 155,379,913 |
| 45 | 17:04:09 | 1 | 20640 | 400 | 0/0 | 12638 | 3,292,538,816 | 156,165,640 | 156,165,639 | 156,165,639 | 156,165,639 | 156,165,639 | 155,680,844 |
| 46 | 17:04:19 | 0 | 21039 | 399 | 0/0 | 12622 | 3,448,633,982 | 156,095,166 | 156,095,167 | 156,095,167 | 156,095,167 | 156,095,167 | 155,513,490 |
| 47 | 17:04:29 | 1 | 21439 | 400 | 0/0 | 12626 | 3,604,798,811 | 156,164,829 | 156,164,828 | 156,164,828 | 156,164,828 | 156,164,828 | 155,542,111 |

Over 47 intervals: **occ ∈ {0,1} only**; `pop_on_empty` Δ mean **394.0**, min 361,
max 403; `push_on_full` Δ **0 on every single interval**. (The 361–363 rows are
intervals where the board delivered ~11,4xx rather than ~12,6xx frames;
`pop_on_empty` scales with them, so the *rate* is unchanged.)

Per-stage deviation from `cSS`, across all 47 intervals:

| | min | max | mean | P2-alt would need |
|---|---|---|---|---|
| `cRH − cSS` | −1 | +1 | −0.021 | −394 |
| `cCFC − cSS` | −1 | +1 | −0.021 | −394 |
| `cCS − cSS` | −1 | +1 | −0.021 | −394 |
| `cPD − cSS` | −2 | +1 | +0.000 | −394 |

### 4.2 Counter wrap accounting (coordinator item 2)

Read spacing min 10.0 s, max 10.0 s over 47 intervals. Census wrap horizon
**279 s**, edge wrap horizon **1,659 s** — **no interval reaches either, so every
delta is unambiguous.** Wraps traversed over the window: each census counter
**1.68 × 2³²** (`cSS` total 7,223,411,856; `cPC` 7,196,602,064),
`pop_on_empty` **0.28 × 2¹⁶** (18,519), `push_on_full` 0. Every figure is
accumulated from consecutive ≤10 s reads; **no quantity anywhere in this report is
a raw leg-end-minus-leg-start subtraction**, which would have aliased 1.68 wraps
into nonsense.

### 4.3 Checker and PER

Checker read sequentially in the same loop, host-frame mode, 48 samples / 470 s:
`chk_frames` +584,054 (12,419/10 s), `chk_good` +507,289, `chk_garbage` +33,960,
`chk_crc_fail` +11,887, **`chk_gap_events` +30,861 = 656.2 per 10 s**,
gap1 22,391 / gap2 6,200 / gap3plus 2,270.

**`chk_lost_slots` is NOT a counter on this image and is excluded.** Across the
48 samples it is **non-monotone**, taking 48 distinct values scattered over the
whole 32-bit range (1,024,244,510 → 2,061,170,479 → 2,637,452,364 →
2,225,552,276 → 490,619,383 → …), which would imply ~6e7 "lost slots" per 10 s
against 12,419 frames. It is uninitialised or undriven, not a measurement. No
verdict in this report uses it — P3 uses `chk_gap_events`, which **is** monotone
across all 48 samples (120 → 30,981), as are `chk_frames` and `chk_good`. The
raw field is nevertheless present in the banked `t10_evidence/air_checker.jsonl`,
so it is flagged here: **do not quote `chk_lost_slots` from this run.**

Two legacy `cnt_mux32` slots are likewise not usable loss measurements on this
lineage and were not used: `max_len` read all-ones (`0xFFFFFFFF`, the
"segment not driven" signature) in the at-rest `postflash_check.sh` sweep and a
single constant (2,367,506,757) for the whole leg, and `starve_clk` is a
free-running clock counter, not a loss count. Pre-existing, not introduced by W1;
noted so the banked postflash log is not misread.

PER (`accept_analyze.py`, lost frames in the denominator):
**8.309 % (72,738 / 875,375)**, CP95UL 8.367 %, live 718/723 s, bins
{1: 37,288, 2: 15,731, 3-4: 500, 5-20: 220, 21-100: 1}.
`comb_autocorr.py --live-window`: **lag32 = +0.6130** (null p95 = 0.0039),
lag33 = +0.0557, lag64 = +0.4014.
`comb_period_ms.py`: **P = 31.61819 frames = 25.3872 ms**, R = 0.1310,
R at exactly P=32.000 = 0.0017, `COMB_LINE=present`.

---

## 5. Verdicts — each prediction quoted verbatim

> **P1:** "witA occupancy pinned at the EMPTY edge (0–1) on every in-window read;
> pop_on_empty delta ≈ 395 ± 60 per 10 s; push_on_full delta 0."

**HOLDS.** occ ∈ {0,1} on all 48 readings; `pop_on_empty` delta mean **394.0**
per 10 s (predicted 395); `push_on_full` delta **0** on every interval.

> **P2 (corrected 14:45):** "per 10 s, symbol-sync strobe delta = Rate_Handle-out
> delta EXACTLY, every downstream stage delta equal to it (the fixed pipeline
> offsets cPD ≈ −12,340 and cPC ≈ −40,400 seen in sim are constants, not per-event
> losses), and strobe delta = 12,333 × (TX frames in the window) ± 1 frame. I.e.
> the sim's prediction is that NO stage is short in valid count while pop_on_empty
> runs at ≈ 395 per 10 s."

**HOLDS.** `cSS == cRH` on every reading; all five pre-discard stages equal within
the measured ±4 band (max deviation observed **2**). The fixed offsets are
confirmed as constants (`cPD` −12,352 measured vs −12,340 sim). **No stage is
short in valid count while `pop_on_empty` runs at 394 per 10 s.**

Two qualifications, both stated rather than buried:

1. **"± 1 frame" against 0x104 is not achievable**, and not because of noise:
   0x104 is not behind the W1 freeze, so it is sampled `aux_lag_s` (46 ms) after
   the frozen census. The pairing bound is therefore ±~60 frames, computed per
   reading from board-side timestamps rather than assumed. Against that bound the
   measurement is well inside: `cSS/12333` vs the 0x104 delta differ by **+0.96
   and −0.26 frames**. The exact, unbounded test is the inter-stage one above,
   which uses one coherent frozen snapshot and needs no pairing at all.
2. **`cPC` is excluded from "every downstream stage delta equal to it" by
   design**, and this was pre-registered before the window. `sample_discard_
   controller` drops the 13-slot inter-frame guard, so `cPC` delta = 12,320 ×
   frames while everything above it is 12,333 × frames (W1_REGMAP §3). P2's
   wording conflicts with the register map here; the register map is right.

> **P2-alt:** "some stage's delta is short by the pop_on_empty delta."

**DOES NOT HOLD.** Zero stage-readings short by the `pop_on_empty` delta, out of
47 intervals × 4 stages. The largest deviation anywhere is 2 counts against a
required 394.

> **P3:** "checker gap events per 10 s ≈ 1–2 × pop_on_empty delta; capture_r3 PER
> within 8 ± 1 % with a lag-32 comb; comb_period_ms ≈ 25–26 ms."

**HOLDS, all three clauses.** Gap events **656.2** per 10 s against
`pop_on_empty` **394.0** = **1.67×** (predicted 1–2×). PER **8.309 %** (predicted
8 ± 1 %) with **lag32 = +0.6130** against a 0.0039 null. `comb_period_ms`
**25.3872 ms** (predicted 25–26).

### Falsifiers

> **F1:** "pop_on_empty delta ≈ 0 while occupancy is NOT pinned at 0 and frames
> still die at the comb rate → the hole is not at the ring; report the first stage
> whose census goes short."

**Does not fire.** `pop_on_empty` delta is 394, not ≈0.

> **F2:** "occupancy pinned at 0 AND pop_on_empty delta ≈ 395 AND every census
> delta equal → the suppressed pop removes nothing from the valid stream; if
> frames still die at the comb rate the death is a TIME-domain effect (a consumer
> that counts enb ticks rather than valids — the Preamble_Detector tick-delayed
> pop, or an epoch/timing path), not a symbol deletion. Report this as the
> localisation, with the checker's gap-event rate against the pop_on_empty rate."

**FIRES. This is the localisation.** All three conjuncts are met and frames do
still die at the comb rate (8.309 % PER, lag-32 +0.613, period 25.3872 ms).
Checker gap-event rate 656.2 per 10 s against `pop_on_empty` 394.0 per 10 s =
1.67 gap events per suppressed pop.

> **F3:** "all census deltas exact and pop_on_empty ≈ 0 with frames dying at the
> comb → the entire symbol-rate path is exonerated on silicon; the comb's origin
> is elsewhere."

**Does not fire.** Census deltas are exact, but `pop_on_empty` is 394, not ≈0 —
so the symbol-rate path is *not* exonerated. It is implicated in **time**, and
cleared of **deleting data**.

> **Third branch** (pre-registered before the window, outside the brief's P/F
> set): occupancy pinned near 32 with `push_on_full` incrementing on a forward leg
> would be a sign error in the campaign model, not "the FULL-edge counter finally
> worked."

**Does not fire.** Occupancy is pinned at the EMPTY edge as the model predicts, so
the sign question flagged in RXFIX_STATE §2(a) is **not** resolved by this leg and
remains open.

---

## 6. The one stage that is short, and by how much

`cPC` runs **0.266 % of frames** below even its designed 12,320/frame guard drop
(mean −33.2 frames per 10 s interval). That is real but it is **neither** of the
two candidate explanations:

* ratio to `pop_on_empty` = **0.084** — P2-alt would need 1.000;
* it is **0.266 %**, not the host's **8.309 %** PER.

So the Packet_Controller emits slightly fewer symbols than the guard arithmetic
predicts, at a rate that tracks neither the ring events nor the frame loss. Most
likely re-acquisition behaviour of `sample_discard_controller` on a live air leg
(the loopback control, with no re-acquisition, matched to −1/+10). Flagged as an
observation, not a claim — the guard-drop model itself is only pinned to
±10 counts by the loopback control.

---

## 7. Step 4 — hand back

* Plain daemons restored with `bringup_r2r3.sh r3`. **The first restore failed its
  arm gate 6/6** (148 rx 373–777 f/s, 146 steady at 1247, gate ≥1120). Per the
  rails, **exactly one** re-run: `restore-t10b` **passed** — `BRING-UP COMPLETE`,
  148 **1245 f/s**, 146 **1247 f/s**, daemons and watchdogs up on both.
  **Outcome (a) of the controller's three: arm lottery, not an image effect. W1
  stays on the board; no rollback was performed.**
* 148 daemon **`nakstat=4`** as required (app `1f834433`). 146 `nakstat=0`, app
  `3349df8f` — its normal state, untouched.
* Hold released (`keeper_hold.sh release` removed only the two files this task
  created); sentinel restarted: `sentinel-172940` + `sentinelkeeper-172940` active.
* **Image on the board at the end, from a readback:** 148 = **`2728dab3979a`**
  (W1); 146 = **`3378861d30bd`** (never touched). Rollback `a1ff3c876d91` remains
  banked in-repo and on-board.

---

## 8. What this means for the campaign

The receiver's symbol-rate path is now **split cleanly in two** on silicon:

* **Cleared of deleting data.** Every stage from the symbol-sync strobe through
  the Preamble_Detector carries exactly the same number of valids, to ±2 counts
  in 156 million, while the ring suppresses 394 pops per 10 s. A suppressed pop
  is a **skipped time slot, not a lost symbol** — the sim's corrected reading
  (Task 9 gate, `cSS = cRH = 2,614,900` with 21 `pop_on_empty`) is confirmed on
  hardware.
* **Implicated in time.** The suppressed-pop rate and the PER comb period agree to
  0.031 %. Whatever kills the frames is downstream of, and triggered by, that
  skipped slot — a consumer counting `enb` ticks rather than valids.

Every edge-directed fix that works by *changing the number of symbols* is aimed at
something that is already conserved. Task 11's R3S is a **steering** fix (move the
skip into the guard band) and is therefore still on target; its sim result — the
hole moving into the guard band and the ring lifting off the EMPTY edge — is the
right shape for this finding.

---

## 9. Concerns

1. **`push_on_full` is still unexercised — now on silicon as well as in sim.** It
   read 0 on every reading of every set. Task 9 concern 2 stands: a zero is
   consistent with both "no FULL-edge event" and "the counter does not work". The
   forward leg cannot exercise it by construction. **It is not usable as evidence
   until 146 gets W1 and a reverse leg is run**, and the reverse leg is where the
   campaign's unresolved sign question (RXFIX_STATE §2(a) — forward loses *more*
   than reverse) actually lives.
2. **The brief's "±1 frame" census tolerance was unachievable as written** and I
   replaced it with a measured bound rather than silently relaxing it (§5, P2
   qualification 1). If a future brief wants a ±1-frame frame count, 0x104 has to
   go behind the same freeze level as the eight W1 words — a small RTL change.
3. **`EQ_TOL = ±4` is my calibration, from one loopback session.** It is 100×
   below the effect it has to discriminate, and the observed air-leg maximum was
   2, so there is a lot of headroom — but it is a number I chose, and a future
   variant with deeper pipelining should re-derive it rather than inherit it.
4. **The first restore's 6/6 arm-gate failure was diagnosed as arm lottery on the
   strength of one successful re-run.** That is the rails' one-re-run rule
   correctly applied, but it is a single trial: if 148's post-W1 arms fail their
   gate again in later sessions, revisit the image-effect hypothesis (controller
   outcome (b)) rather than assuming lottery.
5. **`cPC`'s 0.266 % shortfall is unexplained** (§6). It is too small to be the
   comb and too large to be nothing, and the guard-drop model it is measured
   against is only pinned to ±10 counts.
6. **This leg's 8.309 % is not a like-for-like comparison against the shipped
   8.06 % forward baseline, and must not be read as a regression.**
   `accept_analyze` reported one wedge with the live window truncated
   (live 718/723 s), the leg logged three `delivery stalled 4s (+0 frames in 4s)`
   events inside the window, and `wedge_verdict` recorded `crc=92 %`. The
   *method* is the same one that produced the 8.06 % figure — PER over the
   tool's live-link window with lost frames in the denominator — so the numbers
   are methodologically comparable; but this leg was not a pristine link, the
   +0.25 pp difference has **not** been shown to exceed leg-to-leg spread, and
   nothing in this task was designed to test it. The 8.309 % is used here only
   to confirm P3's "8 ± 1 % with a lag-32 comb", which it does.
   (`GATE (<1 % at CP95 upper limit): NOT MET` is expected — this leg measures
   the defect, it does not fix it.)
7. **The DRA address-select race I fixed in Step 0 is still latent in
   `slackleg_go.sh`**, which backgrounds `stage3h_reader.sh` alongside a leg. It
   is safe there today only because nothing else touches `direct_reg_access` in
   that window. Any future script that adds a second concurrent DRA reader to an
   existing leg wrapper will corrupt both readers silently.
