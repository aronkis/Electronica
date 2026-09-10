> Evidence ledger, moved verbatim from `two_jup/comb/RXFIX_NIGHT2_PREREG.md` on 2026-09-09. Relative paths inside refer to the tree at tag `archive/pre-cleanup-2026-09-09`.

# RXFIX NIGHT-2 PRE-REGISTRATION — Tasks 15–19 (rig driver)

Written and committed **before any night-2 leg**. Plan: `/home/tcollins/.claude/plans/happy-bubbling-owl.md`
(Context, rails, T15–T19, DP0–DP3). Brief: `two_jup/sdd_archive/2026-09-04-rxfix/task-15-19-brief.md`.

Authored 2026-09-05 06:40 EDT, revised 06:43 on the controller ruling below.
**Read section 0 first: it sets what runs now and what runs with the operator present.**

---

## 0. TIMELINE — dispatch was held ~8.5 h; controller ruling at 06:40

The night-2 plan window is 2026-09-04 21:50 → 09-05 08:00, with a pre-registered **146
flash cutoff at 05:30** and a hand-back window 06:30–08:00.

The briefs for Tasks 15/20/21/23 were committed at **2026-09-05 06:31:36 -0400** (commit
`cca195a`, `git log --pretty='%h %ad %s' --date=iso`) and this rig-driver task started at
**06:32**. The preceding commit is `49261de` at 2026-09-04 21:21:09; the ledger's last
night-1 entry is `CLEAR agent=task13 at=2026-09-04T20:59:05-04:00`. There is no night-2
rig activity in the ledger, no night-2 run directory and no night-2 unit. **Cause: the
dispatch was held by the harness for ~8.5 h** (controller, 06:40). Nothing was lost or
left half-run; the rig sat idle and golden throughout, which the preflight confirms (§9).

**Controller ruling, 2026-09-05 06:40 — this supersedes the cutoff:**

- The **05:30 flash cutoff is VOID.** The plan continues exactly as briefed; only the
  clock moved.
- **T15 and T16 run now.** **T17, T18 and T19 run through the morning with the operator
  present** (they return at 08:00). They may stop this work at any point; **if a message
  from the operator arrives via the controller it is obeyed immediately**, including
  mid-task.
- **T18's cross-lineage flash still requires T16 scored and T17 passed first**, exactly as
  briefed. It is not unlocked by the cutoff being void.
- **Rig courtesy rule (daytime).** If the rig would otherwise sit under hold with no unit
  running for **> 30 min** (e.g. while waiting on a build), then: restore daemons, release
  the hold, restart the sentinel — as Task 10's hand-back did — and **re-hold when the
  next rig step starts**. The rig is not to be parked under a dead hold during the
  operator's day.
- Heartbeat to `two_jup/sdd_archive/2026-09-04-rxfix/progress.md` every **≤ 5 min** from
  06:40 onward, including while parked on a unit.

### 0.1 Ordering consequence

Exactly one rig leg runs before 08:00: **T16 leg 1 (reverse BEFORE, LEG=B, DUR=600)**. It
is the only unblocked, never-measured number on the rig and it needs no script change.
T17 needs a script change to `w1leg_go.sh` (the `RSSI=1` / `LEG` / `BOARD` knobs) plus a
DRY regression against `tests/test_rxfix_rig_scripts.py` before any board contact; that
work is desk work and may proceed while T16 runs, but the T17 **leg** waits for T16 to be
scored.

**The brief's "one re-run per wedge" rail is IN FORCE** — the clock no longer forbids it.
A wedge-truncated leg (live window < 300 s) is scored, labelled `WEDGE-TRUNCATED`, and re-run
**once**; if the second attempt also truncates, a third leg with `RXM_146=8` (the m8rx
configuration) is the pre-registered next attempt, and after that the result is
UNINFORMATIVE and the wedge class itself is the reported finding.

### 0.2 A board-clock fact that does NOT affect scoring

Preflight readback shows **148 at `06:33:36 AM EDT`** and **146 at `11:33:39 AM BST`** —
a 5 h absolute offset. On LEG=B the RX board is 146, so 146's clock stamps the capture.
This is harmless for credit: `accept_analyze.py` computes `ts = (tm - t0) / 1e9`
(`two_jup/accept_analyze.py:63`), i.e. **time relative to the first frame of the capture**.
The live-window length, the 300-s credit bar and the wedge onset are all relative
quantities and are unaffected by an absolute offset. No rescoring workaround is needed.
Recorded so the offset is not later mistaken for a corrupted window.

---

## 1. Reverse-leg credit rule (binding on T16)

A reverse leg is **CREDITED** only if all of:

1. **Live window ≥ 300 s** as measured by `accept_analyze.py` (settle 15 s, wedge-guard 2 s).
2. **Deliver-rate gate passes**: `deliver_rate_pre` and `deliver_rate_post` both
   ≥ 900 f/s (`RATE_GATE=900`, `legrun_go.sh:119`).
3. **Zero watchdog relaunches** in-window on either board
   (`watchdog_relaunch_rx=0` and `watchdog_relaunch_peer=0`).
4. `capture_r3_exit=0` and no `*WEDGE*` / `NOT usable` in `wedge_verdict`.

Conditions 2–4 are exactly `legrun_go.sh`'s `deliver_rate_gate_pass=1` / `LEGRUN_DONE`.

### 1.1 CORRECTION, 2026-09-05 07:12 — conditions 4 were mis-transcribed

**This amendment ADMITS a leg that the text above would have excluded. That is the
direction that deserves more scrutiny, not less, so it is recorded in full rather than
folded silently into the rule.**

Section 1 was written at 06:40, **before any leg ran**, and it is left standing above
exactly as committed. Condition 4 (`capture_r3_exit=0` **and** no `*WEDGE*` / `NOT usable`
verdict) does not come from the governing documents — it came from my adopting
`legrun_go.sh`'s composite `deliver_rate_gate_pass`, which is a **leg-completed-clean**
gate, not the credit rule.

The governing rule is stated three times and identically:

- task brief (rig driver): *"credit needs ≥ 300 s live AND the rate gate."*
- plan, standing rails: *"Reverse-leg credit rule: live window ≥ 300 s AND deliver-rate
  gate; wedge-truncated windows scored by accept_analyze.py and labelled."*
- brief T16: *"One re-run per wedge (**a wedge-truncated ≥ 300 s window is still scored
  and labelled**)."*

Condition 4 makes that last clause **unsatisfiable**: every wedge-truncated window sets
`capture_r3_exit=3` and writes a `WEDGE` verdict — both of tonight's legs did. A reading
that turns an explicit clause in all three governing documents into dead text is the wrong
reading, so the governing rule wins and condition 4 is struck.

**Operative credit rule, from here on:**

1. **Live window ≥ 300 s**, as measured by **`accept_analyze.py`'s live window** (settle
   15 s, wedge-guard 2 s), or by a tool that copies that rule (`comb_census.py`,
   `comb_autocorr.py`, `comb_period_ms.py` all do, and all report the same window).
   **Not** `capture_r3.sh`'s `wedge_verdict` onset — that is the stall watchdog's own
   arithmetic on a different origin and the two genuinely disagree (leg 1: verdict "after
   12 s" vs live window 0 s; leg 2: verdict "after 508 s" vs live window 718 s).
2. **Rate gate**: `deliver_rate_pre` and `deliver_rate_post` both ≥ 900 f/s, and zero
   watchdog relaunches on either board.

A credited leg that was wedge-truncated is **always labelled `WEDGE-TRUNCATED`** and
always quoted with both its live window and its total span. Conditions struck: none other
than 4. Lost frames stay in the PER denominator.

**Wedge-truncated windows are still scored and labelled.** A window < 300 s is reported
with its PER and its onset and carries the label `WEDGE-TRUNCATED / UNINFORMATIVE`; it is
never quoted as the reverse before-number. **Lost frames are in the PER denominator**
(host_seq-gap metric), and every number is quoted with its command and its sample count.

Known class being measured against: **6/6 legB captures on 09-03 ended MID_CAPTURE_WEDGE**
(delivery flatline, onsets 12–548 s); watchdogs are killed during captures by design.

---

## 2. T16 — reverse BEFORE, predictions and falsifiers

Command (leg 1; leg 2 is the same with `TAG=rev_before2`):

    DRY=0 two_jup/comb/keeper_hold.sh hold
    two_jup/launch_rig_unit.sh rev-before1 \
      /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/legrun_go.sh \
      DRY=0 LEG=B DUR=600 TAG=rev_before1

Shipped rig defaults (RXQ=1, shipped LOs) and the `SINK_ENV` failhdr/txlog daemon env on
both ends, i.e. the `DAEMON_ENV_A`/`DAEMON_ENV_B` defaults `legrun_go.sh` resolves. No
`RXM_*` / `DRAIN_*` override on leg 1.

Scoring, four ways, each with its sample count:

- `two_jup/accept_analyze.py <cap>/frames.bin` — PER, burst decomposition, CP95, live window.
- `two_jup/comb/comb_autocorr.py` — the lag family.
- `two_jup/comb/comb_period_ms.py` — **the first reverse ms-domain comb period ever measured.**
- `two_jup/comb/comb_census.py` — fail classes.

**PREREG [inferred]** (from the sign cross-check and the provisional 09-03 figures; not
[silicon] — nothing here has been measured on this pair since the SEQ-BIST/W1/R4B flashes):

| quantity | pre-registered prediction |
|---|---|
| credited PER | **3.0 – 4.5 %** |
| autocorrelation lag family | **lag-32 family** |
| ms-domain comb period | **25.3 ± 0.6 ms** |

**Falsifiers / DP1:**

- credited PER **< 1 %** → *"no FULL comb on this pair"*; the 146 fix flash would then
  need the T19 witness to show an edge before it is justified.
- credited PER **> 6 %**, or bursts **> 100 frames** → *"wedge class dominates"*.
- Either way the task continues; DP1 is a note, not a stop.
- Live window **< 300 s** → `WEDGE-TRUNCATED`: scored and labelled, **not** quoted as the
  reverse before-number, and **re-run once** per §0.1 (then the `RXM_146=8` third attempt,
  then UNINFORMATIVE).

---

## 3. What a credited T16 number is and is not

It is the reverse-leg PER **BEFORE any reverse-leg fix**, on 148 TX (image
`9f13705d9fb0`, W1+R4B) → 146 RX (image `3378861d30bd`, seqbist on txfixF3vendh).
**R4B is an RX-side guard-band skip steering**, so on LEG=B it is not in the signal path;
this leg measures 146's receiver as it has always been. It is the baseline any future
reverse AFTER leg is compared against, and it must be quoted with its image pair.

---

## 4. T17 — forward AFTER replicate with an RSSI/gain timeline (runs after T16 is scored)

Command:

    two_jup/launch_rig_unit.sh fwd-after2 <abs>/two_jup/rxfix/w1leg_go.sh \
      MODE=air LEG=A DUR=600 R4B=1 RSSI=1 EXP=9f13705d9fb0 FIXCTL_BASE=0x0 DRY=0

**PREREG [silicon, Task 13]:** PER ≤ 0.5 %, CP95 < 0.6 %, comb absent, lag-32 < 0.1,
`r4b_skips` 394 ± 60 per 10 s, `pop_on_empty` 0, `push_on_full` 0, occupancy 8–10,
`hardwaregain` 34.0 dB on every read.
**Falsifiers:** PER > 1 % with skips still ~394 → R4B did not replicate → ledger, freeze
T18/T19, stop. RSSI dips ≥ 3 dB on ≥ 50 % of burst intervals → "RF margin" note for T23.

Preconditions, in order: T16 leg scored; the `RSSI=1` / `LEG=A|B` / `BOARD=148|146` knobs
added to `w1leg_go.sh` and DRY-tested with the ssh shim in `tests/test_rxfix_rig_scripts.py`;
`DRY=0 MODE=ctrl` on 148 byte-identical to Task 13's control table except the new columns
(regression control). The RSSI knob is a **third sequential** ssh read per 10-s reading on
the RX board — `in_voltage0_rssi`, `in_voltage0_hardwaregain` (and `decimated_power` if
present) under `/sys/bus/iio/devices/iio:device*/`, the device found **by name at runtime,
failing loudly if absent** — appended as columns. Never concurrent with `w1_read.sh` or
`seqbist_read.py` on the shared DRA address-select register. The reading period must stay
**10.0 s**; if it exceeds 12 s, poll RSSI every second reading.

Status: **runs in the morning with the operator present** (§0). `w1leg_go.sh` is unchanged
as of this leg.

---

## 5. T19 witness branch table — pre-registered verbatim, runs after T18

Quoted **verbatim** from the brief, committed before the leg that tests it. T19 requires
the W1 instrument on 146, i.e. T18's cross-lineage flash, which in turn requires T16
scored and T17 passed (§0). Command:

    two_jup/launch_rig_unit.sh w1air-146 <abs>/two_jup/rxfix/w1leg_go.sh \
      MODE=air LEG=B BOARD=146 DUR=600 RSSI=1 EXP=2728dab3979a FIXCTL_BASE=0x0 DRY=0

> (W) occupancy 30–32 on every in-window read, push_on_full 394 ± 60 per 10 s with mean
> interval within 1 % of the PER comb period, pop_on_empty 0, Rate_Handle-out and
> downstream census SHORT by the push_on_full count vs the strobe; (a) occupancy 31/32 and
> push_on_full 0 → counter dead/unexercised; (b) occupancy 0–1 and pop_on_empty ~394 →
> sign model wrong, 146 is EMPTY-trending; (c) neither edge.

### 5.1 ADDITION, controller 2026-09-05 07:28 — the rate-vs-period comparison

**Written before the T19 leg, as the rails require.** T16 changed what T19 has to answer:
the reverse comb is a **lag-25 family at 20.3864 ms**, not the forward leg's lag-32 /
25.39 ms, so "an edge counter advanced" is no longer enough — the edge has to advance *at
the comb's own rate* to be the event behind it.

**Procedure.** On the T19 leg, from the 10-s W1 readings on 146, compute the **ring
edge-event mean interval**: take whichever of `push_on_full` or `pop_on_empty` (word
`0x218`) actually advances, form wrap-aware deltas between consecutive readings, and
convert to a mean interval (reading period / events per reading). Compare it against **the
same leg's own PER comb period** from `comb_period_ms.py` on that leg's `frames.bin` — not
against T16's number, and not against the forward leg's.

**Pre-registered decision:**

| outcome | reading | branch |
|---|---|---|
| intervals **equal within 2 %** | the ring edge **is** the event behind the 20.39 ms comb | then **W** or **b** applies, by which counter advanced |
| intervals **differ by > 2 %** | **two distinct processes** — the ring is not what is deleting the frames | **(c)**, reported with both raw numbers |

Worked example of the (c) case, stated in advance so it cannot be reinterpreted after the
fact: **the ring edge at ~25.3 ms while the losses sit at ~20.4 ms means two processes**,
and T19 reports branch (c) with both figures rather than crediting the ring.

Both intervals are quoted with their sample counts (number of 10-s readings, number of
edge events) and with the wrap-aware delta method named. If neither counter advances, that
is branch **(a)** and no interval is computed.

**The 2 % figure is a threshold, not an error bar — pre-registered now so it is not argued
after the leg.** `comb_period_ms.py` reports **no confidence interval** on its period
estimate, and the Task 10 review already logged this as an Important against exactly this
tool ("the '0.031 % agreement' is quoted beyond the comb-period estimator's precision
(R=0.131, no CI)"). T16's BEST line carries R=0.2318 from the same estimator, still with no
CI. So: 2 % is the controller's stated decision threshold, and it is **not** a claim that
the estimator resolves 2 %. Consequently, if the ring interval and the comb period land
within a few percent of each other — close enough that the estimator's unquantified
precision could decide the comparison either way — **the branch call is reported as
INDETERMINATE with both raw numbers**, not resolved to W/b or to (c). A clean call requires
a separation large enough that no plausible estimator error changes it, of which the worked
example above (25.3 ms vs 20.4 ms, ~24 % apart) is one.

### 5.2 ADDITION, same ruling — `rstcs` on 146 for every leg

The carrier-reset-storm lead from T16 §3.7 is promoted to a **standing measurement**:
record the carrier-reset counter **`rstcs` (register `0x150`) before, at, and after the
window on 146 for every leg from here on**, and report the three values with the elapsed
time between them. `capture_r3.sh` already emits this in `regs_pre.txt` / `regs_cap.txt` /
`regs_post.txt`, so on a `legrun_go.sh` leg it is a reporting duty, not new instrumentation;
on a `w1leg_go.sh` leg the reader must capture it explicitly.

This also settles the open question in T16 §3.7: with `rstcs` read on both sides of a known
arm, whether the counter is **arm-cleared** becomes directly observable, which is what
currently blocks the storm lead from being promoted to a mechanism.

DP3 is the branch that fires, ledgered with its raw numbers. As of this leg **no branch has
fired**: the FULL-edge premise on 146 is **unproven on silicon**, exactly as at dispatch.

Optional T19b (runtime enSlack A/B, `LOOP_POKE=0x208=0x8`, `FIXCTL_BASE=0x8`, PREREG null
[netlist]) was gated on "only if before 00:30" and is **not run**.

---

## 6. Flash cutoff and the T18 gate

The pre-registered **146 flash cutoff of 05:30 is VOID** by the controller ruling in §0;
the flash may run in the morning with the operator present. It remains gated, unchanged
from the brief, on **T16 scored AND T17 passed**, plus: the byte copy banked as
`boot_known_good/BOOT.BIN.146.w1x148.2728dab3979a`, a DRY=1 chain run first, rollback bank
`BOOT.BIN.146.seqbist.3378861d30bd` named on the command line, and the chain's own health
gate and auto-rollback. The chain **brings up BOTH boards and re-arms 148**, so 148's mode
is restored after it. Never killed mid-flash or mid-arm; no retry loop.

**No board is flashed by the T16 leg.** Both boards end this leg on the image they started
on — **148 = `9f13705d9fb0`, 146 = `3378861d30bd`** — confirmed by readback.

---

## 7. Hold, courtesy rule, and hand-back

This task takes the hold with `DRY=0 two_jup/comb/keeper_hold.sh hold` (creates
`~/modem-status/SENTINEL_STOP` + `RIG_LOCK`, records which of the two it created in
`.keeper_hold_created`, stops the sentinel/keeper units, kills `lock_watchdog` on both
boards) and holds it **only while a rig unit is running or the next one is imminent**.

**Courtesy rule (controller, 06:40):** the rig must not sit under hold with no unit running
for **> 30 min** during the operator's day. If that is about to happen — waiting on a
build, waiting on a decision, or ending a turn with no successor step queued — then
restore daemons, `DRY=0 two_jup/comb/keeper_hold.sh release`, restart the sentinel (as Task
10's hand-back did), and **re-hold when the next rig step starts**.

The final hand-back (T25) stays the controller's: `bringup_r2r3.sh r3` restore (one re-run
allowed; Task 10 saw a first restore fail its arm gate 6/6), watchdogs up, hold released,
sentinel restarted, both images re-read back and checked against this file, `CURRENT.txt`
updated. Standing rail: **never leave the rig held or a board on an unbanked image**, and
if any readback mismatches or a board is unreachable, the hold stays and PHYSICAL
ATTENTION goes at the top of the report.

---

## 8. Rails in force (unchanged)

Keeper hold before rig work; every rig step a `launch_rig_unit.sh` unit with
`watch_unit.sh` and absolute script paths; scripts are snapshotted — never edit a script a
live unit runs; polls ≥ 1 s; minimal register reads; write-only registers verified by
effect; `FIXCTL_BASE` stated on every W1 read (`FIXCTL_BASE=0x0` throughout — the freeze
foot-gun); one re-run per wedge then UNINFORMATIVE (**deviated, §0.1**); positive controls
before nulls; never kill a flash or an arm mid-way; no retry loops; labels
`[silicon]`/`[sim]`/`[netlist]`/`[inferred]`; every number with its command and sample
count; lost frames in the PER denominator; heartbeats ≤ 5 min.

---

## 9. Preflight readback — DP0

Taken 2026-09-05 06:33, read-only, before any hold or leg.

| item | expected | observed | verdict |
|---|---|---|---|
| 148 `/boot/BOOT.BIN` | `9f13705d9fb0ea6ae6af3c4c1ab5e95d` | `9f13705d9fb0ea6ae6af3c4c1ab5e95d` | MATCH |
| 146 `/boot/BOOT.BIN` | `3378861d30bd3d85663b31cfdd9c6296` | `3378861d30bd3d85663b31cfdd9c6296` | MATCH |
| sentinel unit | `sentinel-204437` running | active/running | MATCH |
| keeper unit | `sentinelkeeper-204437` running | active/running | MATCH |
| hold files | absent | `SENTINEL_STOP`, `RIG_LOCK`, `.keeper_hold_created` all absent from `~/modem-status/` | MATCH |
| hdl-dev-2 `txfix-build-*` | none active | none | MATCH |
| hdl-dev-2 free space | ≥ 25 GB | 54 GB avail on `/` (492 G, 89 % used) | MATCH |

Commands: `two_jup/anyssh.sh 10.0.0.148 'md5sum /boot/BOOT.BIN; uptime; date'` (and
`10.0.0.146`); `systemctl --user list-units --all`; `ls ~/modem-status/{SENTINEL_STOP,RIG_LOCK,.keeper_hold_created}`;
`ssh hdl-dev-2 'df -h /home; systemctl --user list-units --plain --no-legend "txfix-build-*"; uptime'`.

**DP0 = PASS.** No mismatch; the rig path is open. Board uptimes: 148 up 10 h 27 m, 146 up
1 d 3 h 02 m — consistent with an idle rig since the night-1 hand-back, no unlogged activity.
