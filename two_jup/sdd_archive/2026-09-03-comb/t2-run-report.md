# T2 — host-cadence probes on the reverse leg (148 TX → 146 RX)

Campaign COMB (happy-bubbling-owl), 2026-09-03. Rig driver report.
Pre-registration: `two_jup/COMB_STATE.md` §T2 and its "P1b addendum" (commit `2b49e97`).
Every number below is **[silicon]** unless explicitly marked otherwise.

**Headline: both pre-registered predictions are FALSIFIED.** The loss comb on the reverse
leg is locked to a period of **32 transmitted-frame slots (25.72 ms at 1,244 f/s)** that is
indifferent to the host RX queue depth `-M` on *either* board. P2 (drain budget) was dropped
by controller ruling before its legs ran.

---

## 1. What was run

Six legs, all `LEG=B` (148 transmits, 146 receives), all `DRY=0 DUR=600`, each launched as a
systemd user unit via `two_jup/launch_rig_unit.sh` and watched by
`two_jup/agents/watch_unit.sh --spawn`. No leg was killed; no bring-up was interrupted.

| # | leg | exact command (after `two_jup/launch_rig_unit.sh <unit> /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/legrun_go.sh`) | unit | run dir |
|---|---|---|---|---|
| 1 | m16 | `DRY=0 LEG=B DUR=600 RXM_148=16 TAG=m16` | `legrun-T2-m16` | `two_jup/comb/runs/20260903_174902_legB_m16` |
| 2 | m16 re-run | `DRY=0 LEG=B DUR=600 RXM_148=16 TAG=m16r2` | `legrun-T2-m16-r2` | `two_jup/comb/runs/20260903_175236_legB_m16r2` |
| 3 | m8 | `DRY=0 LEG=B DUR=600 RXM_148=8 TAG=m8` | `legrun-T2-m8` | `two_jup/comb/runs/20260903_180810_legB_m8` |
| 4 | m8 re-run | `DRY=0 LEG=B DUR=600 RXM_148=8 TAG=m8r2` | `legrun-T2-m8-r2` | `two_jup/comb/runs/20260903_182006_legB_m8r2` |
| 5 | m8rx (P1b) | `DRY=0 LEG=B DUR=600 RXM_146=8 TAG=m8rx` | `legrun-T2-m8rx` | `two_jup/comb/runs/20260903_183520_legB_m8rx` |
| 6 | m8rx re-run | `DRY=0 LEG=B DUR=600 RXM_146=8 TAG=m8rxr2` | `legrun-T2-m8rx-r2` | `two_jup/comb/runs/20260903_184803_legB_m8rxr2` |

**`TAG=` is not a pre-registered knob** — it only names the run directory, and does not reach
the boards. All other arguments are exactly as pre-registered.

**Not run: d1 (`DRAIN_148=1`) and d0 (`DRAIN_148=0`).** Dropped by controller ruling after P1b,
recorded in `COMB_STATE.md` §"T2 verdicts". **P2 is therefore untested** — neither confirmed
nor falsified — and no claim about the drain budget is made anywhere in this report.

### Knob witness (that the `-M` override actually landed)

`bringup_r2r3.sh:172` applies `RXM_A`/`RXM_B` per board with `RXM_EFF=${RXM:-16}` as the default.
`legrun_go.sh` maps `RXM_148 → RXM_A` and `RXM_146 → RXM_B`. Each run's `meta.txt` `resolved:`
line was checked before scoring:

* legs 1–4: `RXM_A=<16|8>` present, no `RXM_B` → 146 at the default 16.
* legs 5–6: `RXM_B=8` present, **no `RXM_A` at all** → 148 falls through to the default 16.
  This asymmetry (receiver 8, transmitter 16) is what P1b requires, and it is witnessed in
  `run.log`/`meta.txt` on both legs.

**Caveat on the witness [inferred, not silicon].** The `resolved:` line proves the value was
passed into `bringup_r2r3.sh`; there is no fetched artifact that echoes the daemon's actual
`-M` argument on 148. `lock_watchdog`'s `DAEMON_CMD` string would carry it, but the fetched
`watchdog_peer.log` contains only the two startup lines, not the command. See defect D5.

---

## 2. Per-leg results

Machine-readable copy: `two_jup/sdd_archive/2026-09-03-comb/t2-legs.csv`.

### 2.1 Credit gate and health

| leg | `capture_r3` exit | wedge onset | rate pre/post (f/s) | `gate_pass` | wd relaunch rx/peer | capTAP | Δ0x104 | frames.bin records |
|---|---|---|---|---|---|---|---|---|
| m16    | 3 | 12 s  | 1003/1003 | **1** (see D1) | 0/0 | 38.51 MHz FAIL | 12,534  | 53,393  |
| m16r2  | 3 | 544 s | 1000/1000 | 0 | 0/0 | 38.29 MHz FAIL | 915,047 | 896,985 |
| m8     | 3 | 396 s | 1002/1002 | 0 | 0/0 | 22.34 MHz OK   | 645,127 | 651,535 |
| m8r2   | 3 | 548 s | 998/998   | 0 | 0/0 | 22.34 MHz OK   | 921,611 | 897,433 |
| m8rx   | 3 | 420 s | 1001/1001 | 0 | 0/0 | 41.81 MHz FAIL | 690,871 | 712,436 |
| m8rxr2 | 3 | 548 s | 997/997   | 0 | 0/0 | 38.31 MHz FAIL | 921,117 | 899,452 |

**Every leg failed the credit gate**, all six for `MID_CAPTURE_WEDGE`; m8r2 and m8rxr2 also
fell just under the ≥1000 f/s floor. Watchdog relaunches were **0 on every board on every leg**
(`capture_r3.sh` stops both watchdogs before traffic), so no leg is disqualified on that axis.

### 2.2 Pre-registered UNINFORMATIVE checklist

| leg | Δ0x104 ≈ 0? | window < 150 s? | re-arm in window? | capTAP not golden? | wd relaunch? | verdict |
|---|---|---|---|---|---|---|
| m16    | no (12,534) | **YES (~43 s)** | no | **YES** | no | **UNINFORMATIVE — not scored** |
| m16r2  | no | no (718 s) | no | **YES** | no | UNINFORMATIVE by capTAP only |
| m8     | no | no (519 s) | no | no | no | UNINFORMATIVE by wedge/gate only |
| m8r2   | no | no (719 s) | no | no | no | UNINFORMATIVE by wedge/gate only |
| m8rx   | no | no (546 s) | no | **YES** | no | UNINFORMATIVE by capTAP only |
| m8rxr2 | no | no (719 s) | no | **YES** | no | UNINFORMATIVE by capTAP only |

Leg m16 is the only one with no scoreable window and it is excluded entirely. The other five
each yielded a live window of 519–719 s, far above the 150 s floor.

**On the capTAP item.** `check_capture_health.py` failed on 4 of 6 legs and passed on 2, on an
otherwise identical rig and with the occupied-bandwidth figure jumping between 22.34, 38.29,
38.31, 38.51 and 41.81 MHz. It gates **`pair.iq` only**; `capture_r3.sh` itself says
"frames.bin / host-side counters are unaffected". **No quantity in this report is derived from
`pair.iq`.** The checklist is honoured as written — the four legs are flagged — but the flag is
recorded as a *tension*, not as grounds to discard the frame-log evidence, exactly as
pre-registration discipline requires. A checklist item that fires on two thirds of legs while
being causally disconnected from every scored quantity should be re-scoped before T3.

### 2.3 PER (`two_jup/accept_analyze.py`, lost frames in the denominator)

| leg | knob | live window | **PER** | lost/denom | CP95 UL | `<1 %` gate |
|---|---|---|---|---|---|---|
| m16r2  | 148 `-M` 16 | 718 s/740 s | **3.742 %** | 32,763/875,542 | 3.782 % | NOT MET |
| m8     | 148 `-M` 8  | 519 s/548 s | **3.713 %** | 23,309/627,710 | 3.760 % | NOT MET |
| m8r2   | 148 `-M` 8  | 719 s/745 s | **3.785 %** | 33,184/876,787 | 3.825 % | NOT MET |
| m8rx   | 146 `-M` 8  | 546 s/580 s | **3.672 %** | 24,281/661,326 | 3.717 % | NOT MET |
| m8rxr2 | 146 `-M` 8  | 719 s/751 s | **3.695 %** | 32,396/876,787 | 3.735 % | NOT MET |

Five windows, 145,933 lost frames over 3,918,152 slots. **PER is flat at 3.67–3.79 % across
every knob setting**; the spread is smaller than the difference between the two re-runs of the
same setting (m8 3.713 vs m8r2 3.785). Neither board's `-M` moves PER.

> **These are not the shipped-configuration PER.** All five windows are wedge-truncated, and
> 3.7 % is ~2.7× the 1.39 % reverse-leg figure in the shipped defaults. The wedge (§4) is
> present in every window and inflates these numbers by an unknown amount. **Do not quote
> 3.7 % as the reverse-leg PER.**

### 2.4 Comb autocorrelation (`comb_autocorr.py`, ALL-LOSS; lag units = transmitted-frame slots)

| leg | knob | top-5 lags (value) | **lag16** | lag32 | lag33 | lag64 | family |
|---|---|---|---|---|---|---|---|
| m16r2  | 148 `-M` 16 | 65 (+0.6731), 98 (+0.5123), 33 (+0.4589), 32 (+0.3875), 97 (+0.3322) | **−0.0276** | +0.3875 | +0.4589 | +0.1385 | k×32, **+1 slip dominant** |
| m8     | 148 `-M` 8  | 32 (+0.6236), 64 (+0.4733), 97 (+0.4211), 96 (+0.4046), 65 (+0.3973) | **−0.0336** | +0.6236 | +0.2490 | +0.4733 | k×32, slip 0 dominant |
| m8r2   | 148 `-M` 8  | 32 (+0.6583), 127 (+0.5542), 64 (+0.5231), 95 (+0.4689), 96 (+0.3981) | **−0.0340** | +0.6583 | +0.1260 | +0.5231 | k×32, slip 0 dominant |
| m8rx   | 146 `-M` 8  | 32 (+0.7504), 64 (+0.7091), 96 (+0.6697), 128 (+0.6268), 127 (+0.2452) | **−0.0362** | +0.7504 | +0.1378 | +0.7091 | k×32, **clean ladder** |
| m8rxr2 | 146 `-M` 8  | 32 (+0.6180), 97 (+0.5926), 64 (+0.4370), 65 (+0.4251), 96 (+0.2788) | **−0.0312** | +0.6180 | +0.2537 | +0.4370 | k×32, mixed slip |

Null floors (p95 sampling floor, lags 1–128) were 0.0037–0.0045 on every leg, so every value
above ±0.1 is far outside noise. SINGLES-ONLY reproduces the ALL-LOSS shape on all five legs.

**The discriminator lags.** P1's prediction turns on the odd multiples of 16 (16, 48, 80),
because k×32 is a subset of k×16 and "peaks at 32" alone is not evidence either way:

* **lag16 = −0.028, −0.034, −0.034, −0.036, −0.031** on the five legs — negative, flat, and
  indistinguishable across all three knob settings.
* **48 and 80 never appear in any leg's top-8.**

**What does vary** is which harmonic of 32 dominates and the ±1 sidebands: m16r2 peaks at 65
(2×32+1) while the four `-M 8` legs peak at 32 itself, and sidebands at 95/97/127 (slip ∓1)
come and go between two runs of the *same* setting (m8 vs m8r2, m8rx vs m8rxr2). Because the
slip is unstable across re-runs of an identical configuration, **the slip is not a function of
`-M`**; an earlier working note of mine claiming "`-M` moved the phase slip" is withdrawn.

### 2.5 Fail-class census (`comb_census.py`, RX = 146)

| leg | n | OK | MAGIC | LEN | CRC | ZEROTAIL | **MAGIC share of failures** | class-4 split (n / hole / alignloss) |
|---|---|---|---|---|---|---|---|---|
| m16r2  | 874,846 | 842,789 | 26,855 | 280 | 4,922 | 0 | **83.77 %** | 0 / 0 / 0 |
| m8     | 627,278 | 604,403 | 19,104 | 209 | 3,561 | 1 | **83.52 %** | 1 / 1 / 0 |
| m8r2   | 876,223 | 843,606 | 27,377 | 311 | 4,929 | 0 | **83.94 %** | 0 / 0 / 0 |
| m8rx   | 661,020 | 637,051 | 20,047 | 210 | 3,712 | 0 | **83.64 %** | 0 / 0 / 0 |
| m8rxr2 | 876,256 | 844,396 | 26,736 | 287 | 4,837 | 0 | **83.92 %** | 0 / 0 / 0 |

**~84 % of every leg's failures are already garbage at the header** (MAGIC), with CRC failures
a distant 15 % and LEN under 1 %. The share is stable to ±0.2 pp across all five legs and all
three knob settings — a strong invariant, and consistent with a mechanism that destroys frame
alignment rather than corrupting payload bits.

**The class-4 split is empty and therefore decides nothing here.** ZEROTAIL totals 1 record
across 3.9 M frames, and the failhdr onset histogram is `n_have=0` on four legs (one record in
`[0,64)` on m8) — no `first_zero_off` data exists to split. The pre-registered delivery-hole
vs ALIGNLOSS discriminator **could not be exercised on this leg type**; T3 must not assume it
will be available. (This also resolves the direction of the T1 §6.3 blocker: on RF legs the
in-window failhdr count equals the `fail_class>0` count exactly — 32,057 on m16r2, 23,969 on
m8rx — i.e. one record per failed frame, which is the correct behaviour.)

### 2.6 TX↔RX join and hand control

The join is only meaningful against the **transmitter's** log. For `LEG=B` that is 148's
`cap/txlog_peer.bin`; `cap/txlog.bin` is 146's own log and holds just **5 unique seq values
(4–8)** on every leg, because 146 transmits essentially nothing on the reverse leg.

| leg | lost_rx | never_sent | sent_not_decoded | hand control (lost seqs present in 148's txlog) | decoded-seq control |
|---|---|---|---|---|---|
| m16r2  | 32,763 | 0 | **32,763** | 32,763/32,763 = 100.00 % | 20,067/20,067 |
| m8     | 23,309 | 0 | **23,309** | 23,309/23,309 = 100.00 % | 20,147/20,147 |
| m8r2   | 33,184 | 0 | **33,184** | 33,184/33,184 = 100.00 % | 20,086/20,086 |
| m8rx   | 24,281 | 0 | **24,281** | 24,281/24,281 = 100.00 % | 20,551/20,551 |
| m8rxr2 | 32,396 | 0 | **32,396** | 32,396/32,396 = 100.00 % | 20,105/20,105 |

**Every lost frame was submitted by the transmitter.** `never_sent = 0` on all five legs; there
is no TX-side delivery hole on the reverse leg. `unjoinable_time` reads 100 % on every leg and
carries **no** information here (cross-board `CLOCK_MONOTONIC`); it is reported, not interpreted.

A tooling defect had to be fixed to obtain this (D3): the original `comb_census.py` applied the
cross-board `t_submit` span gate *before* testing seq membership. Fixed in `aa7aa99`
(seq-membership first, span demoted to the `unjoinable_time` annotation); the fixed tool
reproduces the hand control exactly on m16r2. The hand control was run independently on all
five scored legs and agrees with the tool on all five.

### 2.7 148-side signature (from `txlog_peer.bin`; 148 has no fetched daemon log — see D5)

| leg | 148 TX rate, its final 10 s | frames submitted **beyond** 146's last observed slot | = continued TX after 146 went deaf |
|---|---|---|---|
| m16r2  | 1245.5 f/s | 46,099 | 37.1 s |
| m8     | 1245.5 f/s | 47,311 | 38.0 s |
| m8r2   | 1245.5 f/s | 51,126 | 41.1 s |
| m8rx   | 1245.5 f/s | 53,426 | 42.9 s |
| m8rxr2 | 1245.5 f/s | 50,834 | 40.9 s |

**148's TX plane never falters, on any leg.** It submits at a flat ~1,244 f/s straight through
the flatline and continues for a further 37–43 s until capture teardown.

---

## 3. Verdicts against the pre-registration

### P1 — transmitting board's RX cadence — **FALSIFIED**

> Pre-registered: *"P1 prediction: the ALL-LOSS autocorrelation's dominant comb family follows
> 148's own -M: m8 → k×16 (± the +1 slip), m16 → k×32. Falsifier: m8 still peaks at k×32 → the
> comb is not locked to the transmitting board's RX cadence."*

m8 and m8r2 (148 at `-M 8`) both peak at **32**, with family 32/64/96, `lag16 = −0.034` on both,
and no 48 or 80 anywhere in the top-8. The falsifier condition is met exactly as written.
**The comb is not locked to the transmitting board's RX cadence.** Two independent ~500–700 s
windows agree, so the verdict does not rest on a single truncated capture.

### P1b — receiving board's RX cadence — **FALSIFIED**

> Pre-registered (addendum, `2b49e97`): *"Prediction if the comb is the RECEIVING board's host
> back-pressure cadence: family moves to k×16 (lags 16/48/80 rise above the −0.03 floor).
> Falsifier: family stays k×32 → the comb is not host-queue-locked on either board → an
> air/RX-DSP mechanism with a ~32-frame (25.7 ms) period."*

m8rx and m8rxr2 (146 at `-M 8`, 148 at the default 16) both peak at **32**; m8rx gives the
cleanest ladder of the campaign (32/64/96/128 at +0.75/+0.71/+0.67/+0.63). `lag16 = −0.036` and
−0.031; 48 and 80 absent. The family does not move. The falsifier condition is met exactly as
written. **The comb is not host-queue-locked on either board.**

Per the addendum's own falsifier branch, this leaves an **air/RX-DSP process with a ~32-frame
period = 25.72 ms at 1,244 f/s**. T3/T4 should hunt a 25.7 ms cadence in the receiver
(timing-loop / AGC / carrier-tracking); DMA S2MM transfer boundaries are already excluded by
the RXQ evidence. The ~84 % MAGIC share (§2.5) and `never_sent = 0` (§2.6) both point the same
way: frames are transmitted intact and lose *alignment* at the receiver.

### P2 — drain budget — **NOT TESTED**

Legs d1 and d0 were dropped by controller ruling before running. No evidence for or against.

---

## 4. The wedge, as a finding in its own right

**Six legs, six `MID_CAPTURE_WEDGE` aborts** — a 100 % rate, where the pre-registered risk
table anticipated occasional wedges handled by a single re-run.

* **Onsets: 12, 544, 396, 548, 420, 548 s.** Five of six between 396 and 548 s; three at
  544–548 s. This clusters far too tightly for an arm-lottery outcome and looks like a
  time-dependent process reached a few hundred seconds into a saturated run.
* **Signature at the flatline** (146's `qpsk_tun.log`, m16r2): `dma_rx_ok`, `seq_gap` and
  `tunB_tx` all freeze together at 887,649 / 27,176 / 887,649 while `dma_tx` keeps incrementing;
  `crc_drop` runs on for ~4 more stat windows (46,720 → 47,202) then freezes too; `idle_rx`
  ramps 23,353 → 76,236. So 146 goes from decoding-with-errors → receiving frame-shaped
  garbage that fails CRC → receiving only idle slices.
* **Not the transmitter** (§2.7): 148 keeps submitting at full rate for 37–43 s past the point
  146 stops seeing anything.
* **Not a host delivery stall**: `never_sent = 0` and `tunB_tx` freezing *with* `dma_rx_ok`
  place the failure upstream of the tun handoff.
* **Both directions wedge, forward first [one leg only]**: on m16r2, 148's own forward-direction
  RX log wedged at 392 s while the reverse leg wedged at 544 s. This cross-check exists only on
  m16r2 — `frames_peer.bin` was empty on m8/m8r2 (D6) and yielded `usable=False` on m8rx/m8rxr2 —
  so it is suggestive of a shared RF/board cause rather than a direction-specific host bug, and
  is **not** established across legs.

The wedge is the dominant threat to every number in §2.3; it truncates all five windows and is
the reason PER reads ~2.7× the shipped reverse-leg figure. It does **not** threaten §2.4–2.7:
the comb, the MAGIC share, and the join are all measured *inside* the live window, and the two
`-M` settings' combs are compared across windows of comparable length.

---

## 5. Defects found

| id | where | defect | status |
|---|---|---|---|
| **D1** | `legrun_go.sh` | `WD_RELAUNCH_*=$(grep -c … \|\| echo 0)` — `grep -c` prints `0` *and* exits 1 on a present file with no match, so `\|\| echo 0` appended a second `0`, giving `"0\n0" != 0` and failing the credit gate on **every clean leg**. Found in preflight before any leg ran. | fixed `fb8f71e` |
| **D2** | `legrun_go.sh` | The credit gate keyed only on rate and watchdog relaunches, so a `capture_r3.sh` wedge/abort could still report `gate_pass=1` — leg m16 is the live demonstration (`exit=3`, 12 s wedge, `gate_pass=1`). | fixed `aaf560a` (controller) |
| **D3** | `comb_census.py` | `tx_rx_join` applied the cross-board `t_submit` span gate *before* seq membership, so on any RF leg `never_sent`/`sent_not_decoded` were 0 by construction and everything fell to `unjoinable`. | fixed `aa7aa99` (controller); hand-verified |
| **D4** | `comb_census.py` usage | Joining `LEG=B` RX frames against `cap/txlog.bin` (146's own log, 5 unique seqs) silently yields `never_sent == lost_rx` — a plausible-looking but entirely spurious "nothing was sent" result. The transmitter's log is `cap/txlog_peer.bin`. | usage rule; documented here and in the ledger |
| **D5** | `capture_r3.sh:309` | Fetches `qpsk_tun.log` from `RX_IP` only, while the header at `:31` advertises `qpsk_tun.log(+peer)`. **There is no 148 daemon log in any run dir**, so the transmitting board's stats/txgap lines are unavailable; the 148-side signature had to be reconstructed from `txlog_peer.bin`. Also means `lock_watchdog`'s `DAEMON_CMD` (the only echo of the actual `-M`) is never captured. | **open** |
| **D6** | `capture_r3.sh` / leg artifacts | `frames_peer.bin` came back **0 bytes** and `failhdr_peer.bin` header-only (32 B) on m8 and m8r2, and `usable=False` on m8rx/m8rxr2, while m16r2 got 4.2 MB/2.1 MB. The 148-side census is lost on 4 of 6 legs, non-deterministically. | **open** |
| **D7** | `check_capture_health.py` gating | Fired FAIL on 4 of 6 legs with occupied BW ranging 22.3–41.8 MHz on an unchanged rig, while gating only `pair.iq`. As a pre-registered UNINFORMATIVE trigger it would disqualify most legs for a reason causally unrelated to any scored quantity. | **open — recommend re-scoping before T3** |

---

## 6. Rig state left behind

**No board contact was made after leg 6 finished** (19:03:04). Everything since is desk-side.

* `capture_r3.sh` quiesces both boards at the end of every leg (it is not invoked with `-k`):
  `lock_watchdog` and `qpsk_tun` killed, `tun0` deleted, `0x9D000000` and `0x9D000114` zeroed on
  both boards. Leg 6 ran that path to completion, so **the RF link is DOWN by design, not wedged**.
* **The hold is NOT released**: `~/modem-status/SENTINEL_STOP` and `~/modem-status/RIG_LOCK`
  remain in place, untouched by this task. **The sentinel was not restarted.**
* No `legrun-T2-*` unit remains loaded (all reset after exit). The heartbeat writer
  `t2-heartbeat.service` is a host-side file-append loop with no board contact.
* Daemon binaries: every leg rebuilds both boards from `host_app_k5` via `capture_r3.sh`. The
  148 `nakstat` check passed on every leg (`10.0.0.148: NAK-stat counter VERIFIED present after
  rebuild`). **No `rxqstat` line appears for 146 on any leg** — `legrun_go.sh` passes no
  `HOST_CFLAGS_B`, and `capture_r3.sh:140` gates that verification on `BCF` matching
  `*QPSK_RXQ_STAT*`, so the check is skipped by construction. The flag was deliberately **not**
  added mid-campaign, since doing so would change 146's binary away from the pre-registered
  launch line. 148's T1 instrumented daemon (md5 `f2c33f9b…`, `rxqstat=1`) was replaced by the
  first leg's rebuild, as README §5 says it should be on a `capture_r3.sh` leg.

## 7. Artefacts committed

Report, `t2-legs.csv`, and per-run `meta.txt` / `run.log` / `capture_r3.log` /
`autocorr_146.{json,txt}` / `census_146_peertx.{json,txt}` / `per_146.txt` plus the small
`cap/*.txt` and `cap/*.log` witnesses. **No `.bin` and no `pair.iq`** (multi-GB in total).
The stale `census_146.json` from the mis-keyed join (D4) was deleted rather than committed.
