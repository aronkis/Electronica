# Tasks 15–19 — night-2 rig driver: report

Driver: rig-serial agent, 2026-09-05 06:32 → 08:30 EDT.
Pre-registration: `two_jup/comb/RXFIX_NIGHT2_PREREG.md` (committed `85257c3`, **before any
board contact**; §1.1 is a dated correction, see §6 below).
Plan: `/home/tcollins/.claude/plans/happy-bubbling-owl.md`. Brief:
`two_jup/sdd_archive/2026-09-04-rxfix/task-15-19-brief.md`.

**Headline: the reverse leg has been measured for the first time. 148 TX → 146 RX is
`PER = 9.644 % (84,437 / 875,535), CP95UL 9.706 %` over a credited 718-s live window — and
its comb is a lag-25 family at 20.39 ms, NOT the lag-32 / 25.39-ms forward comb. All three
of T16's pre-registered predictions are falsified.**

**T17 also passed: the forward leg replicates R4B at `PER = 0.183 % (1,611/879,050),
CP95UL 0.192 %`, comb absent, lag-32 = 0.0069, gain flat at 34.0 dB — RF margin excluded.**

Status: **T15 COMPLETE (DP0 PASS). T16 COMPLETE (credited). T17 COMPLETE (PASS, every
prediction holds). T18 BLOCKED — the flash launch was denied by the permission classifier
(§4A); everything up to the board action is staged, banked and DRY-green. T19 NOT RUN,
blocked by T18 (DP3: no branch fired).**

---

## 1. Timeline — why this ran at dawn, not overnight

This dispatch was **held by the harness for ~8.5 h**. Evidence: the night-2 briefs were
committed at `2026-09-05T06:31:36-04:00` (`cca195a`); the preceding commit is `49261de` at
`2026-09-04T21:21:09`; the ledger's last night-1 line is
`CLEAR agent=task13 at=2026-09-04T20:59:05-04:00`. There is no night-2 rig activity, run
directory or unit in the gap. **Nothing was lost or left half-run** — DP0 (§2) confirms the
rig sat idle and golden throughout, and both board uptimes are consistent with it.

The initial reading was that the plan's pre-registered **05:30 flash cutoff** had passed
and therefore T18/T19 were dead. The **controller ruled at 06:40** and that ruling governs:

- the **05:30 cutoff is VOID**; the plan continues as briefed with only the clock moved;
- **T15 and T16 run now**; **T17, T18, T19 run through the morning with the operator
  present**, who may stop the work at any time;
- **T18's cross-flash still requires T16 scored AND T17 passed**, unchanged;
- **daytime courtesy rule**: the rig is never parked under a hold with no unit running for
  > 30 min — restore daemons, release, restart the sentinel, re-hold at the next rig step.

That rule was applied at 07:07–07:09 (§5).

---

## 2. T15 — pre-registration + preflight. **DP0 = PASS**

Pre-registration written and committed **before any board contact** (`85257c3`):
`two_jup/comb/RXFIX_NIGHT2_PREREG.md`.

Preflight readback, 06:33, read-only:

| item | expected | observed | verdict |
|---|---|---|---|
| 148 `/boot/BOOT.BIN` | `9f13705d9fb0ea6ae6af3c4c1ab5e95d` | `9f13705d9fb0ea6ae6af3c4c1ab5e95d` | MATCH |
| 146 `/boot/BOOT.BIN` | `3378861d30bd3d85663b31cfdd9c6296` | `3378861d30bd3d85663b31cfdd9c6296` | MATCH |
| sentinel / keeper | `sentinel-204437`, `sentinelkeeper-204437` running | both active/running | MATCH |
| hold files | absent | `SENTINEL_STOP`, `RIG_LOCK`, `.keeper_hold_created` all absent | MATCH |
| hdl-dev-2 | no `txfix-build-*`, ≥ 25 GB free | none active, 54 GB avail | MATCH |

Commands: `two_jup/anyssh.sh 10.0.0.{148,146} 'md5sum /boot/BOOT.BIN; uptime; date'`;
`systemctl --user list-units --all`;
`ls ~/modem-status/{SENTINEL_STOP,RIG_LOCK,.keeper_hold_created}`;
`ssh hdl-dev-2 'df -h /home; systemctl --user list-units --plain --no-legend "txfix-build-*"'`.

Board uptimes 148 = 10 h 27 m, 146 = 1 d 3 h 02 m. **No mismatch → the rig path is open, no
PHYSICAL ATTENTION.**

### 2.1 A clock fact that does not affect scoring

148 reports `06:33:36 AM EDT`, **146 reports `11:33:39 AM BST`** — a 5 h absolute offset,
and on LEG=B the RX board (146) stamps the capture. This is harmless: `accept_analyze.py`
scores on `ts = (tm - t0) / 1e9` (`two_jup/accept_analyze.py:63`), i.e. **relative to the
capture's first frame**. Live window, the 300-s bar and the wedge onset are all relative.
Recorded so the offset is never mistaken later for a corrupted window.

---

## 3. T16 — reverse BEFORE. **CREDITED, and all three predictions falsified**

Keeper hold taken 06:39:53: `DRY=0 two_jup/comb/keeper_hold.sh hold` →
`KEEPER_HOLD_OK created=[ SENTINEL RIGLOCK]`, both sentinel units stopped, `lock_watchdog`
killed on both boards.

### 3.1 Leg 1 — `rev-before1`, WEDGED, UNINFORMATIVE

    two_jup/launch_rig_unit.sh rev-before1 \
      /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/legrun_go.sh \
      DRY=0 LEG=B DUR=600 TAG=rev_before1

Run `two_jup/comb/runs/20260905_064010_legB_rev_before1`, 06:40:10 → 06:43:10.
`capture_r3_exit=3`, `wedge_verdict=MID_CAPTURE_WEDGE after 12s (delivery flatlined 12s)`.

Scored and labelled as the credit rule requires:
`python3 two_jup/accept_analyze.py <cap>/frames.bin` →
**`cap: UNUSABLE (live window 0s of 35s, WEDGED)`**. 0 s against the 300-s bar → **no PER
credited**. (`frame_taxonomy.py` on the same 16,594 records reports PER 93.654 % and
`packet_gap_events=1049`; that is wedge debris, **not** a link measurement.)

**The bring-up was clean**, which is what makes this a wedge and not a bad arm:
`ARM GATE PASS (try 1)` with 148 rx = 1246 f/s and 146 rx = 1247 f/s (gate ≥ 1120), ssi-fix
VERIFIED both boards, both daemons up, both watchdogs ALIVE, pre-window health
`CRC 96 % / 1000 f/s`. `deliver_rate_pre=1000`, `deliver_rate_post=1000` — **both cleared
900 f/s**; the leg is rejected by the exit code and wedge verdict, not by rate.

This is the known legB wedge class (6/6 on 09-03), now **7/7**.

### 3.2 Leg 2 — `rev-before2`, **CREDITED (wedge-truncated)**

The one re-run the brief allows. Same command, `TAG=rev_before2`. Run
`two_jup/comb/runs/20260905_064400_legB_rev_before2`, 06:44:00 → 06:59:34.

**Credit determination**, against the operative rule (prereg §1 as corrected, §6):

| condition | required | observed | verdict |
|---|---|---|---|
| live window | ≥ 300 s | **718 s** of 746 s | **PASS** |
| deliver rate pre / post | ≥ 900 f/s both | 995 / 995 | **PASS** |
| watchdog relaunches | 0 both boards | `rx=0`, `peer=0` | **PASS** |

→ **CREDITED, labelled `WEDGE-TRUNCATED`.** `legrun_go.sh` reported
`deliver_rate_gate_pass=0`, but that flag is set by `capture_r3_exit=3` and the WEDGE
verdict, **not by rate** — see §6.

**Headline numbers.** `python3 two_jup/accept_analyze.py <cap>/frames.bin`:

    cap: live 718s/746s [WEDGE truncated]  PER=9.644% (84437/875535)  CP95UL=9.706%
         lag33=-0.030  bins={'1': 35636, '2': 18028, '3-4': 3075, '5-20': 304,
                             '21-100': 2, '>100': 0}
    POOLED live-window: PER=9.644% (84437/875535)  CP95UL=9.706%
    GATE (<1% at CP95 upper limit, live-link): NOT MET

**n = 875,535 transmitted slots, k = 84,437 lost; lost frames are in the denominator**
(host_seq-gap metric over the live window).

**Tool provenance.** This figure and T17's (§4.3) were both produced by `accept_analyze.py`
in its *working-tree* state, while Task 23 was concurrently adding a `--burst-times` flag
(file mtime 06:42:41, before both runs). Verified rather than assumed: the committed HEAD
version and the edited version produce **byte-identical output on the same `frames.bin`**,
and every change is gated behind `--burst-times` / `--arq`, neither of which was passed.
Three unmodified tools (`comb_period_ms.py`, `comb_autocorr.py`, `comb_census.py`)
independently reproduce the 718 s live window, the 84,437 lost count and the run bins.

**Two live-window figures disagree and both are quoted on purpose.** `capture_r3.sh`'s
stall watchdog says `MID_CAPTURE_WEDGE after 508s`; `accept_analyze.py` says the live
window is **718 s of 746 s**. They are different computations on different origins (the
watchdog counts from the start of the post-settle traffic phase; accept_analyze from the
capture's first frame, with settle-15 s and a 2-s wedge guard). The **credit rule names
accept_analyze's window**, so 718 s is the operative number. Leg 1 shows the divergence in
the opposite direction (verdict "after 12 s" vs live window 0 s), so this is a property of
the two tools, not of this leg.

### 3.3 Structure — a lag-25 family, not lag-32

`python3 two_jup/comb/comb_autocorr.py <cap>/frames.bin`
(slot axis [43819, 919354], 875,536 slots, `validity_frac=1.0000`):

    [ALL-LOSS] events=84437   null(p95)=0.0037
      top8 lags: 25:+0.4443, 50:+0.4065, 125:+0.3751, 75:+0.3690, 63:+0.3666,
                 100:+0.3312, 126:+0.2768, 124:+0.2582
      lag16=-0.0484  lag32=+0.1192  lag33=-0.0099  lag64=+0.0446
    [SINGLES-ONLY] events=35636   null(p95)=0.0036
      top8 lags: 63:+0.2965, 25:+0.2675, 126:+0.2460, 50:+0.2216, 75:+0.1829,
                 100:+0.1413, 125:+0.1322, 94:+0.1314
      lag16=-0.0157  lag32=+0.1219  lag33=-0.0304  lag64=-0.0275

The all-loss train is a clean **25-harmonic family — 25, 50, 75, 100, 125** — with the
fundamental at `+0.4443`, ~120× the shuffle floor. **`lag32 = +0.1192` is less than
a third of it and `lag33 = −0.0099` is at zero.** The singles-only train adds a **63/126**
line (`+0.2965` / `+0.2460`) above its own 25-family.

**Two independent estimators agree, which is what makes a falsified prediction credible
rather than a tool artefact:** `comb_autocorr.py`'s integer top lag is **25** and
`comb_period_ms.py`'s fractional BEST line is **25.39003 frames** — different algorithms on
the same capture, agreeing to within the autocorrelation's one-slot resolution.

`python3 two_jup/comb/comb_period_ms.py <cap>/frames.bin`:

    slots=875536 lost=84437 (9.644 %) loss-run onsets=57045  live=718/746s [WEDGE truncated]
    frame period 802.9297 us
    BEST  P = 25.39003 frames = 20.3864 ms   R = 0.2318
    BAND  P = 31.50605 frames = 25.2971 ms   R = 0.0817   (25-27 ms)
    R at exactly P=32.000 : 0.0010
    random-event null (95th pct of band max, n=8): 0.0141
    band R / a1r2 baseline (0.1737) = 0.470
    COMB_LINE=reduced

**A unit trap, flagged so nobody conflates them:** the strongest reverse line is
`P = 25.39003 **frames** = **20.3864 ms**`. The forward comb was `25.3872 **ms**`. The two
numbers look alike and are different quantities. `R at exactly P = 32.000 is 0.0010` —
a deterministic mod-32 beat is **absent** on the reverse leg.

### 3.4 Census, and an analysis error I made and corrected

`comb_census.py` over the live window (n = 875,012):

    fail_class: {'OK': 791106, 'MAGIC': 68509, 'LEN': 1825, 'CRC': 13572, 'ZEROTAIL': 0}
    run-length bins: {'1': 35636, '2': 18028, '3-4': 3075, '5-20': 304, '21-100': 2, '>100': 0}
    onset histogram: n_none=62300 n_have=0 (failhdr wrapped)
    class4 split: n_class4=0

**MAGIC-dominated** (68,509 of 83,906 errored records). **94 % of loss onsets are singles
or doubles** (35,636 + 18,028 of 57,045); **zero runs > 100** and only 2 in 21–100.

**The error:** my first census run passed `--txlog <cap>/txlog.bin`. On `LEG=B` the RX
board is 146 and **the transmitter is 148 = the peer**, so the join must use
`txlog_peer.bin`. The wrong log produced
`lost_rx=84437 never_sent=84437 sent_not_decoded=0` — which reads as *TX starvation* and
would have been a false and consequential finding. Re-run against the correct log
(`--txlog <cap>/txlog_peer.bin`, `n_records=979,844`):

    lost_rx=84437  never_sent=0  sent_not_decoded=84437

**Every one of the 84,437 lost frames was transmitted by 148 and not decoded by 146.** The
loss is genuinely receive-side on 146. Both runs are kept
(`comb_census.txt`, `comb_census_peertx.txt`) so the error is auditable.

### 3.5 Pre-registered predictions vs outcome — 0 of 3 hold

| quantity | PREREG [inferred] | observed [silicon] | verdict |
|---|---|---|---|
| credited PER | 3.0 – 4.5 % | **9.644 %** (84,437/875,535), CP95UL 9.706 % | **FALSIFIED — worse, by >2×** |
| autocorr lag family | lag-32 family | **lag-25 family** (25/50/75/100/125), fundamental +0.4443; lag32 +0.1192, lag33 −0.0099 | **FALSIFIED** |
| ms-domain comb period | 25.3 ± 0.6 ms | strongest line **20.3864 ms** (R 0.2318). A 25.2971 ms line does fall inside the window but at R 0.0817, `COMB_LINE=reduced`, 0.470 of the a1r2 baseline | **FALSIFIED as the dominant line** |

### 3.6 **DP1 — the branch that fired**

Pre-registered branches, verbatim: *"credited PER < 1 % → note 'no FULL comb on this pair';
> 6 % or > 100-frame bursts → 'wedge class dominates'."*

**PER 9.644 % > 6 % → the "wedge class dominates" branch fires.** It is reported as
pre-registered.

**But the evidence does not support the mechanism that label implies, and saying so is part
of the result.** "Wedge class dominates" predicts long delivery outages inside the scored
window. The scored window contains **none**: zero runs > 100, two runs in 21–100, and 94 %
of onsets are singles or doubles. The credited 9.644 % is a **fine-grained singles/doubles
comb at high rate**, structurally the same *kind* of defect the forward leg had before R4B
(8.309 %, singles/doubles) but on a **different period and lag family**. The wedge is real
and it truncated the leg at 718 s — it is not what produced the 9.644 %.

### 3.7 A lead on the wedge class — `[silicon, lead]`, not a mechanism

Carrier-reset counter `rstcs` (register `0x150`, `capture_r3.sh:66`):

| leg | pre-window | CAP_START | post | outcome |
|---|---|---|---|---|
| 1 (wedged at 12 s) | `0x79C` → `0x1273` in 3.36 s (~2,263 resets, ~670/s) | `0x174C` | `0x5644` | ~17,361 resets in ~20 s |
| 2 (ran 718 s) | `0x0`, `0x0` | `0x0` | `0x48A` | ~1,162 resets in ~735 s (~1.6/s) |

The leg that wedged instantly was **already storming before its capture window opened**;
the leg that survived started calm. `frame_taxonomy` on leg 1 scores
`cfo_dither cfc_dev_ratio_err_vs_ok = 44.973` (conf **high**) and
`carrier_reset_storm phi = 0.1179`. Task 13's credited forward leg on the same pair had no
carrier resets.

**Held as a lead, not promoted to a mechanism**, for one specific reason: leg 2 reads
`rstcs = 0x0` at CAP_START where leg 1 read `0x174C`, and I have **not** established
whether `rstcs` is cleared by the arm. `bringup_r2r3.sh:108` states only that a false FTS
state "`0x110` cannot clear", which is not the same claim. Until that is settled the two
legs' counters may not be measuring from a common origin and the ratio is not a clean
comparison. **Next instrument: read `0x150` before and after an arm on a quiet board.**

The IQ tap was **DEGENERATE on both legs** (occupied BW 42.04 / 41.81 MHz vs ~23 expected;
`CAPTURE_HEALTH VERDICT: DEGENERATE`), so **no IQ-based conclusion is drawn**;
`frames.bin` and the host counters are unaffected and are what every number above uses.

### 3.8 What the credited number is, and is not

`PER 9.644 %` is the reverse leg **before any reverse-leg fix**, on **148 TX
(`9f13705d9fb0`, W1+R4B) → 146 RX (`3378861d30bd`, seqbist on txfixF3vendh)**. **R4B is
RX-side steering**, so it is not in this path — this measures 146's receiver as it has
always been. It is the baseline for any future reverse AFTER leg and must be quoted with
its image pair and its `WEDGE-TRUNCATED` label.

**Consequence for the campaign:** the reverse defect is **not the forward defect**. Forward
was lag-32 / 25.39 ms; reverse is lag-25 / 20.39 ms with no mod-32 line at all
(R@32.000 = 0.0010). A fix reasoned from the forward comb's geometry should not be assumed
to transfer. **This strengthens, not weakens, the case for T18/T19**: the W1 witness on 146
is now the only way to tell which ring edge (if any) produces a 25-family comb, and the
T19 branch table is unchanged and untested.

---

## 4. T17 — forward AFTER replicate with an RSSI timeline. **PASS, every prediction holds**

Run on the controller's 07:28 ruling (proceed now, operator present). Instrument work and
its 45-test DRY suite are in §4.0; the rig legs in §4.1–4.3.

### 4.0 The instrument (desk, zero board contact)

`w1leg_go.sh` gained `LEG=A|B`, `BOARD=148|146`, `RSSI=0|1`; defaults reproduce Task 10/13
exactly. A **LEG/BOARD mismatch is a refusal (exit 2)**, not a warning — the script reads
the RX board, so the wrong pairing would sweep the ring witness on the *transmitting* board
and silently score the wrong side of the link. `RSSI=1` adds a **third ssh round trip,
strictly after** the W1 sweep and the checker read (they share the single
`direct_reg_access` address-select register; an interleave returns another reader's
address silently). The RF device is **located by capability at runtime** — the remote
snippet walks `/sys/bus/iio/devices/iio:device*` for the first device exposing
`in_voltage0_rssi` and emits `RSSI_DEV_NOT_FOUND` (exit 9) otherwise; `iio:deviceN`
numbering is not stable, so no index is baked in. If the three serial trips overrun 12 s,
RSSI drops to every second reading rather than stretching the 10.0 s cadence. The air path
adds `0x150` (rstcs) to the AUX sweep — same round trip, no extra cost — for the
per-reading carrier-reset timeline of prereg §5.2; **MODE=ctrl keeps the original AUX** so
its control table stays byte-comparable with Task 13's, and a test pins that.

Tests: `two_jup/tests/test_rxfix_rig_scripts.py` **45 passed** (was 36), all DRY with the
ssh/scp shim; an empty shim log is the proof of zero board contact and every new test
asserts it.

### 4.1 Regression control — `MODE=ctrl` on 148, **all taps PASS**

Unit `t17-ctrl`, run `two_jup/comb/runs/20260905_073507_w1_ctrl`, image `9f13705d9fb0`,
`fixctl_base=0x0`, `r4b=1`, `aux=0x104 0x124` (unchanged, as designed).
**`TAPS FAILING THEIR CONTROL: none`** — freeze path, all six census stages, witA
occupancy and pointers, the arm-transient `pop_on_empty` positive control
(`pre=39 post=44 jump=5`), the edge-counter null, `r4b_locked`, `r4b_window_opens`,
`r4b_skips`, the ninth word outside the freeze shadow, and the 9-word stuck-at sweep.

### 4.2 Air leg 1 wedged; leg 2 (the one re-run) is the credited leg

Leg 1 (`t17-air`, `20260905_073935_w1_air`) **wedged at 12 s** — `MID_CAPTURE_WEDGE`,
`capture_r3_exit=3`, despite `health try 1: rev 100 % fwd 100 % rate 1038 f/s`.
**This is new: the FORWARD leg had never wedged before** (Task 13 got a clean 600 s at
20:18). It is the same class that took 7/7 legB legs, now seen on leg A. Uninformative,
re-run once per the rail.

Leg 2 (`t17-air2`, `two_jup/comb/runs/20260905_075030_w1_air2`, 07:50:30 → 08:05:50):
`capture_r3.sh` reports `MID_CAPTURE_WEDGE after 532s`, but **`accept_analyze.py` scores
the whole capture live — `live 721s/721s`, `wedges during captures: 0`** — the same
tool-vs-tool divergence pinned in prereg §1.1, here in the favourable direction. Reader
window complete: **48 W1 readings, 48 RSSI readings, 48 checker samples**.

**Credit determination, stated explicitly because T18's gate hangs on it.** This leg carries
the *same two flags* that made T16 leg 1 uninformative — `capture_r3_exit=3` and
`deliver_rate_gate_pass=0` — so the determination is written out rather than implied:

| condition | required | observed | verdict |
|---|---|---|---|
| live window | ≥ 300 s | **721 s** of 721 s | **PASS** |
| deliver rate pre / post | ≥ 900 f/s both | 1038 / 1038 | **PASS** |
| watchdog relaunches | 0 both boards | `rx=0`, `peer=0` | **PASS** |

→ **CREDITED.** As with T16 leg 2, `deliver_rate_gate_pass=0` was set by the exit code and
the wedge verdict, **not by rate**. The difference from T16 leg 1 is the live window: 721 s
here against 0 s there, on the same rule.

### 4.3 Every pre-registered prediction holds

Host side, `python3 two_jup/accept_analyze.py <cap>/frames.bin`:

    cap: live 721s/721s  PER=0.183% (1611/879050)  CP95UL=0.192%  lag33=-0.000
         bins={'1': 11, '2': 0, '3-4': 35, '5-20': 139, '21-100': 0, '>100': 0}
    POOLED live-window: PER=0.183% (1611/879050)  CP95UL=0.192%
    GATE (<1% at CP95 upper limit, live-link): PASS

`comb_period_ms.py`: `slots=879051 lost=1611 (0.183 %) live=721/721s`,
`R at exactly P=32.000 : 0.0620`, **`COMB_LINE=absent`**.
`comb_autocorr.py`: **`lag32=+0.0069`**, `lag33=+0.0069`, `lag64=+0.0013` (the top lags
1–8 are the burst-shape decay of the 139 runs in the 5–20 bin, not a comb line).

| prediction (PREREG §4) | required | observed | verdict |
|---|---|---|---|
| PER | ≤ 0.5 % | **0.183 %** (1,611/879,050) | **HOLDS** |
| CP95 | < 0.6 % | **0.192 %** | **HOLDS** |
| comb | absent | `COMB_LINE=absent` | **HOLDS** |
| lag-32 | < 0.1 | **0.0069** | **HOLDS** |
| `r4b_skips` | 394 ± 60 per 10 s | **398.7** per read | **HOLDS** |
| `pop_on_empty` | 0 | 0 on all 47 intervals | **HOLDS** |
| `push_on_full` | 0 | total 0 | **HOLDS** |
| occupancy | 8–10 | 8, 9, 10 | **HOLDS** |
| `hardwaregain` | 34.0 dB every read | **34.0 dB on 48/48** | **HOLDS** |

**Neither falsifier fires.** "PER > 1 % with skips ~394 → R4B did not replicate" — PER is
0.183 % with skips at 398.7. "RSSI dips ≥ 3 dB on ≥ 50 % of burst intervals → RF margin" —
RSSI mean 27.34 dB, **span 0.857 dB, and 0 of 48 readings sit ≥ 3 dB below the median**;
`decimated_power` spans 1.0 dB. **RF margin is excluded as the residual's cause**, which is
the T23 desk analysis's pre-registered expectation.

Cadence discipline held: 47 intervals, **mean 10.0 s** (min 9.0, max 11.0), **zero
intervals > 12 s**, so the guard never needed to fire and RSSI was read every reading.

**T17 = PASS. R4B replicated on silicon** (0.183 % here vs 0.224 % in Task 13), and the
T18 gate ("T16 scored AND T17 passed") is **met**.

---

## 4A. T18 — **BLOCKED: the flash launch was denied by the permission classifier**

Everything up to the board action was completed and is green:

- **Byte copy banked**: `boot_known_good/BOOT.BIN.146.w1x148.2728dab3979a`,
  `md5 = 2728dab3979a54616f1ad67f1ac8e8a7`, **identical to** the source
  `BOOT.BIN.148.rxfixw1.2728dab3979a`. This is the exact path
  `flash_146_txfix.sh:61` resolves (`BB=$ROOT/boot_known_good/BOOT.BIN.146.$TAG.$EXP`).
- **Chain read first**, as the brief requires. `txfix_flash146_go.sh` is a thin wrapper;
  `flash_146_txfix.sh` carries the A0 gate (the nemo-side rollback bank must *be* the
  rollback image, md5-checked), a pre-flash health check of **148 as the gate instrument**,
  on-board backup to `/root/BOOT.BIN.<bak>.bak`, staged copy + md5 verify, reboot, readback
  verify, full `restore_known_good.sh` bring-up, a NAK=4 re-check and a reset-aware
  two-pass health gate on 148, with **rollback on any failure and no retry loop**. It
  **re-arms 148 as a side effect**, so 148's mode must be restored after.
- **DRY=1 run passed end to end**: `FLASH_146T_DONE ... image=2728dab3979a on 146,
  bring-up + gates green`, with the real A0 gate satisfied
  (`nemo rollback bank: .../BOOT.BIN.146.seqbist.3378861d30bd md5=3378861d30bd (expect 3378861d30bd)`).

The `DRY=0` launch through `launch_rig_unit.sh` was then **denied by the auto-mode
permission classifier**. Per the standing rail ("on a permission or classifier denial, stop
and ask — never retry variants of the denied command") **no variant was attempted and the
146 silicon path stops here.**

**Nothing partial happened — verified, not assumed:** no `flash146-w1x` or
`watch-flash146-w1x` unit exists, `/boot/BOOT.BIN.new` is absent on 146, 146's uptime is
continuous (`up 1 day, 4:56` — no reboot), and its image is unchanged at
`3378861d30bd3d85663b31cfdd9c6296`.

**This needs an operator decision**: a `Bash` permission rule allowing the flash unit, or
an operator-run flash. Everything else for T18 is staged and green.

---

## 4B. T19 — NOT RUN, blocked by T18

T19 requires the W1 instrument on 146, which requires T18's flash. **DP3: no branch fired.**
The FULL-edge premise on 146 remains **unproven on silicon**. The branch table (prereg §5)
and the controller's rate-vs-period addition (§5.1) and `rstcs` standing measurement (§5.2)
are committed and unaltered, ready to run the moment the flash is permitted.

---

## 4C. Superseded — original T17/T18/T19 deferral note

*(Superseded by §4/§4A/§4B above, which record what actually ran after the controller's
07:28 and 07:45 rulings. Kept for the audit trail.)* Pre-registrations stand unaltered:

- **T17** (forward AFTER replicate + RSSI timeline) — `RXFIX_NIGHT2_PREREG.md` §4. **No
  edit was made to `w1leg_go.sh`**; it is byte-unchanged. The `RSSI=1` / `LEG` / `BOARD`
  knobs and their DRY regression against `tests/test_rxfix_rig_scripts.py` remain to do.
- **T18** (cross-lineage W1 flash on 146) — §6 of the prereg. Gated on **T16 scored (now
  done) AND T17 passed**. The byte copy `boot_known_good/BOOT.BIN.146.w1x148.2728dab3979a` has
  **not** been made. No flash was performed tonight, in DRY or otherwise.
- **T19** (reverse witness leg) — §5, branch table W/a/b/c quoted verbatim. **DP3: no
  branch fired, leg not run.** The FULL-edge premise on 146 remains **unproven on
  silicon**, exactly as at dispatch.

---

## 5. Rig state at hand-off — **released and healthy**

The hold was taken and released twice under the courtesy rule (held 06:39–07:09 for T16,
re-held 07:35–08:29 for T17/T18), never parked dead for > 30 min.

1. **Daemons restored** after T16 (`restore-t16`, 07:07:33 → 07:09:01) and again after the
   blocked flash (`restore-t18`, 08:27 → 08:28:43), both `bringup_r2r3.sh r3` via
   `two_jup/rxfix/restore_r3_go.sh`. **Both passed on the first attempt** —
   `ARM GATE PASS (try 1)`, 1247/1247 f/s (gate ≥ 1120), ssi-fix VERIFIED both boards, both
   daemons up, both watchdogs ALIVE, `=== r3 BRING-UP COMPLETE ===`, `Result=success code=0`.
2. **Hold released** 08:29:55: `DRY=0 two_jup/comb/keeper_hold.sh release` →
   `KEEPER_RELEASE_OK released=[ SENTINEL RIGLOCK]`. `SENTINEL_STOP`, `RIG_LOCK` and
   `.keeper_hold_created` all gone.
3. **Sentinel restarted**: `sentinel-082955.service` and `sentinelkeeper-082955.service`
   both active/running.

**Re-hold (`DRY=0 keeper_hold.sh hold`) is required before the next rig step.**

Images unchanged, from a final readback at 08:30 — **no board was flashed**:

| board | image | role |
|---|---|---|
| 10.0.0.148 | `9f13705d9fb0ea6ae6af3c4c1ab5e95d` | W1 + RXFIX_R4B |
| 10.0.0.146 | `3378861d30bd3d85663b31cfdd9c6296` | SEQ-BIST on txfixF3vendh |

---

## 6. Correction to my own pre-registration — it **admits** a leg

`RXFIX_NIGHT2_PREREG.md` §1 (written 06:40, before any leg) required, beyond the live
window and rate gate, that `capture_r3_exit=0` and that no `WEDGE` verdict be present. That
condition **is not in the governing documents** — I imported it from `legrun_go.sh`'s
composite `deliver_rate_gate_pass`, which is a *leg-completed-clean* gate, not the credit
rule. The governing rule appears three times and identically: brief — *"credit needs ≥ 300 s
live AND the rate gate"*; plan — *"live window ≥ 300 s AND deliver-rate gate; wedge-truncated
windows scored by accept_analyze.py and labelled"*; brief T16 — *"a wedge-truncated ≥ 300 s
window is still scored and labelled"*.

My condition made that last clause unsatisfiable: **every** wedge-truncated window sets
`capture_r3_exit=3` and writes a WEDGE verdict, as both legs did. It is struck in prereg
**§1.1**, dated, with §1 left standing as committed.

**This correction admits leg 2 rather than excluding it — the direction that deserves more
scrutiny, not less.** Stated plainly so a reviewer can weigh it: without the correction
tonight produces no reverse number at all; with it, leg 2 is credited on 718 s of live link
and a rate gate that passed on its own terms (995/995 f/s, zero watchdog relaunches). The
correction changes **which rule is applied**, not any measured value — every number in §3.2
is what the tools printed.

---

## 7. Rails observed

Keeper hold before rig work, released twice under the courtesy rule; every rig step a
`launch_rig_unit.sh` unit — `rev-before1`, `rev-before2`, `restore-t16`, `t17-ctrl`,
`t17-air`, `t17-air2`, `restore-t18` — each with a spawned `watch_unit.sh` watcher and
absolute script paths; **no script edited while a unit ran** (the `w1leg_go.sh` edits landed
between units, and `launch_rig_unit.sh` snapshots each script anyway); foreground polls at
15–30 s; **no board flashed**; no arm or flash interrupted; **one re-run per wedge, used
twice — once in T16 and once in T17**, never twice on the same leg; pre-registration
committed before the first leg and its T19 addition before T19 could run; every number
quoted with its command and sample count; lost frames in the PER denominator; no subagents.

**Heartbeat gap, named rather than left as an unexplained STALE:** heartbeats ran ≤ 5 min
via the `t1519hb` unit except **08:25 → 08:32**. The `t1519hb` restart was bundled into the
same Bash call as the T18 flash launch, so the classifier denial (§4A) killed the heartbeat
restart along with it. No rig unit was running in that window.

**A superseded CLEAR line.** `CLEAR agent=task15-19 at=2026-09-05T07:27:00-04:00` was
written when T17–T19 were understood to be morning work; the controller's 07:45 ruling then
directed this task to proceed, and it did. That CLEAR is **superseded** by
`CLEAR agent=task15-19 at=2026-09-05T08:32:00-04:00`, which is the operative one.

**Concerns for the controller**

0. **T18 needs a permission decision (§4A).** The flash unit launch was denied by the
   auto-mode classifier; per the rails no variant was retried. The banked copy, the DRY
   run and the T16/T17 gate are all green, so the only missing thing is permission to run
   `launch_rig_unit.sh flash146-w1x … txfix_flash146_go.sh … DRY=0`. T19 is blocked behind it.
1. **The `>6 %` DP1 branch fired but its label is misleading** (§3.6) — the loss is a
   singles/doubles comb, not wedge debris. Read the structure, not the label.
2. **7/7 legB wedges.** The wedge class is unfixed and cost one of two legs tonight. Any
   reverse AFTER leg must budget for it. The `RXM_146=8` third attempt was never needed and
   remains untried.
2a. **Every leg this session was wedge-flagged — 4 of 4** (onsets 12 s, 508 s, 12 s,
   532 s); two were nonetheless creditable because `accept_analyze`'s live window was long
   (718 s and 721 s) and two were not (0 s live). The forward direction wedged **for the
   first time** (§4.2 leg 1, where Task 13 ran clean for 600 s), so this is no longer a
   146-only class. Sharper framing than "both directions": the wedge is now the *default*
   outcome of a 600-s capture, and it cost one leg in each of T16 and T17. **This directly
   threatens T24's N=3** — budget roughly two legs per credited result.
3. **The reverse comb is a different animal from the forward one** (lag-25 / 20.39 ms vs
   lag-32 / 25.39 ms, no mod-32 line). Fix candidates reasoned from forward geometry
   (R4B/R4D/R4E) may not transfer; T19's witness matters more now, not less.
4. **`rstcs` arm-clearing is unresolved** (§3.7) and gates whether the carrier-storm lead is
   real. One cheap read settles it.
5. **N = 1 credited reverse leg**, wedge-truncated. The plan's T24 slack window called for
   N = 3; this number should be replicated before anything is built on it.
