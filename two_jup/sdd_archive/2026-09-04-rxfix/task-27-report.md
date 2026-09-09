# Task 27 — deploy the host resync fix (Task 26) to 148 and judge it on the forward leg

Driver: rig-serial agent, 2026-09-05 08:38 → 09:36 EDT.
Pre-registration: `two_jup/comb/RXFIX_HOSTFIX_PREREG.md` (P1–P13, F1–F5), written before any deploy.
Brief: `two_jup/sdd_archive/2026-09-04-rxfix/task-27-brief.md`.

**Headline: the fix works and clears its registered bound — a same-binary A/B on
back-to-back legs gives `PER 0.196 % → 0.079 %` (−60 %, a 0.117 pp difference against the
0.10 pp requirement), and the 5–20 run bin drains from 150 runs to zero. But the
pre-registered *mechanism* is wrong: `resync_568` fired ZERO times. Every recovery came
through `resync_other`. Falsifier F5 fires — the 568-byte phase is not the displacement on
this leg, and the class must be re-opened before the mechanism is credited.**

Verdict: **P1 PASS on outcome; F5 fires on mechanism.** Per brief step 6 (leg A passes P1
and the link is healthy) **the fixed daemon is left running on 148**.

---

## 1. What was actually under test — two facts that shape everything below

**(a) `capture_r3.sh` rebuilds 148's daemon at the start of every leg.** It scps
`host_app_k5/` from the repo and compiles on-board
(`capture_r3.sh:106`, `:128` — `gcc -O2 -Wall -DQPSK_CARVE_2MB $NAKKEEP ${HOST_CFLAGS:-} $BCF`),
with `$BCF = $HOST_CFLAGS_B` scoped to **board B/146 only** by design ("board A (148) must
rebuild to a functionally untouched binary"). So `deploy_daemon_go.sh`'s binary is
superseded at leg time unless the leg's flags are made to match.

They were made to match: both legs ran with **`HOST_CFLAGS=-DQPSK_RXQ_STAT`**, the same
flag `deploy_daemon_go.sh` adds. **The result is exact: the on-board binary after both legs
is `md5 0ee566203a9752ddde036371c583774e` — byte-identical to the deployed one.** So the
judge legs tested precisely the deployed build, and A and B are a true same-binary pair.

**(b) The counters split across the `#ifdef` line.** `rxresync_dump()`
(`qpsk_tun.c:1088`, called at `:279`) is **unconditional**, so P4/P5/P6/P12 read from any
build. `rxq_stats_dump()` is behind `#ifdef QPSK_RXQ_STAT` (`:275`), so **P11 would have
been unmeasurable** on a default leg — the `HOST_CFLAGS` above is what made it readable.

---

## 2. Deploy and rollback

**Banked first** (brief step 1): the pre-existing 148 daemon copied to
`boot_known_good/daemon/qpsk_tun.148.1f834433`, **md5
`1f834433f7dac41e774e88f9a833f041`** — matching Task 10's recorded `app 1f834433`, verified
identical to the board copy. Its fingerprint: `nakstat=4, rxqstat=0, rxresync=0`, i.e. a
plain build with **no resync code**. Rollback = redeploy that file.

**Deployed** (`deploy148-resync`, run `two_jup/comb/runs/20260905_084351_deploy_148`,
DRY=1 first, then DRY=0):

    DEPLOY_DAEMON_OK board=148 daemon_md5=0ee566203a9752ddde036371c583774e
    build_ok=1   nakstat_strings=4 (need 4; gate applies (BOARD=148))   nakstat_gate_pass=1

On-board fingerprint after deploy: **`nakstat=4, rxqstat=1, rxresync=1`** — the NAK gate
passes, the queued-RX instrumentation is in, and the re-anchor is compiled in. Daemon
restarted through `bringup_r2r3.sh r3` (`restore-t27a`, `Result=success`), then verified
live: `pid=547458`, `QPSK_RX_QUEUED=1`, `QPSK_RX_RESYNC` unset (default ON),
**`QPSK_RXQ_ZEROHDR` unset (off, as the pre-registration requires)**, and the counter line
present: `qpsk_tun rxresync: on=1 phase=0 ...`.

---

## 3. The two legs

Both: `w1leg_go.sh MODE=air LEG=A BOARD=148 DUR=600 R4B=1 RSSI=1 EXP=9f13705d9fb0
FIXCTL_BASE=0x0 HOST_CFLAGS=-DQPSK_RXQ_STAT DRY=0`, back-to-back on an unchanged rig,
bitstream `9f13705d9fb0` (W1 + R4B) untouched throughout.

**Leg A — fix ON** (`hostfix-on`, `runs/20260905_084623_w1_hostfix_on`, 08:46 → 09:01).
`capture_r3` flagged `MID_CAPTURE_WEDGE after 560s`, but `accept_analyze` scores
**live 721 s / 721 s, `wedges during captures: 0`**; rate gate 1037/1037 f/s, zero watchdog
relaunches → **credited** (same rule as the Task 16/17 legs).

**Leg B — control, fix OFF, same binary.** `QPSK_RX_RESYNC=0` delivered through
`legrun_go.sh`'s `WHITEN_DENV` hook (`legrun_go.sh:68`), which appends to `DENV_A`/`DENV_B`
and — the reason it is the right vehicle despite its name — **is carried into
`bringup_r2r3.sh`'s `lock_watchdog` relaunch string**, so the control cannot silently revert
mid-leg. No script was edited. Confirmed in the leg's own meta:
`DAEMON_ENV_A=… QPSK_RX_RESYNC=0`.

Attempt 1 (`hostfix-off`) **wedged at 12 s** (28,156 records) → uninformative, re-run once
per the brief. Attempt 2 (`hostfix-off2`, `runs/20260905_091549_w1_hostfix_off2`,
09:15 → 09:30) is **the session's only completely clean capture**:
`capture_r3_exit=0`, `wedge_verdict=healthy crc=100% rate=1038f/s`,
**`deliver_rate_gate_pass=1`**, 898,283 records.

**The control is verified by effect, not assumed:**
`qpsk_tun rxresync: on=0 phase=0 resync_568=0 resync_other=0 resync_fail=0 recovered=0 tail_lost=0`
— every counter exactly zero, which is what the pre-registration's §4 claims the OFF path
must do.

---

## 4. The A/B

| | **A — fix ON** | **B — control, fix OFF** |
|---|---|---|
| PER (live window) | **0.079 %** (692 / 879,018) | **0.196 %** (1,724 / 879,794) |
| CP95 upper limit | 0.085 % | 0.205 % |
| live window | 721 / 721 s | 722 / 721 s |
| loss runs | 383 | 188 |
| **slots per event** | **1.81** | 9.17 |
| run-length bins | {1:179, 2:112, 3:79, 4:13} | {1:13, 2:0, 3–4:25, **5–20:150**} |
| **max run length** | **4** | 20 |
| `failhdr` records | 482 | 1,524 |
| fail_class MAGIC | 274 | 1,349 |

**A/B difference = 0.196 − 0.079 = 0.117 pp**, against the brief's **≥ 0.10 pp**
requirement → **passes**.

The control reproduces the historical baseline independently: its 5–20 bin holds 150 runs
against T17's 139 on the same rig with the *pre-fix* daemon, and its PER (0.196 %) sits
beside T17's 0.183 %. That is the pre-registration's §4 claim ("the OFF path reproduces the
historical accounting exactly") confirmed on silicon.

---

## 5. Predictions, scored

| # | prediction | observed | verdict |
|---|---|---|---|
| P1 | PER ≤ 0.08 % | **0.079 %**, CP95UL 0.085 % | **PASS** |
| P2 | events unchanged, ~0.30 /s | 0.531 /s (383) vs control 0.261 /s (188) | **fails as written** — see below |
| P3 | slots per event 8.59 → ~3 | **9.17 → 1.81** | **HOLDS, exceeded** |
| P4 | `resync_568` ≈ event count (~140) | **0** | **FAILS** |
| P5 | `recovered` ≈ 5.5 × `resync_568` | `recovered=1,237`, `resync_568=0` | **not evaluable as written** (ratio undefined); `recovered / resync_other` = 7.2 |
| P6 | `resync_other` ≪ `resync_568` | **171 vs 0 — inverted** | **FAILS → F5** |
| P7 | checker gap events ~3 per 10 s | **3.19** (150 over 47 intervals) | **HOLDS** |
| P8 | checker lost slots ~0.054 % | 0.0355 % (A) vs 0.0460 % (B) | moved; see caveat |
| P9 | r4b `d_skips`/`d_frames` unchanged | **399.2 vs 398.7** per read; occupancy 8–10 both | **HOLDS** |
| P10 | run-length ceiling 17 → ~3 | **max run 4; the 5–20 bin goes 150 → 0** | **HOLDS** |
| P11 | `rx_q_resets` = 0 | **1** — *and 1 in the control too* | **fails as written, not fix-attributable** |
| P12 | `resync_fail` : `resync_568` ~2:1 or ~0:1 | 9,757 : 0 | **moot** — the row exists to separate two burst-head models, and neither applies when the 568 re-anchor never fires |
| P13 | failure records drop faster than lost slots | records/event **8.11 → 1.26** (−84 %) vs slots/event 9.17 → 1.81 (−80 %) | **HOLDS** |

**P2, honestly.** The event *count* nearly doubles (188 → 383) while total loss falls 60 %.
This is the run-splitting artefact P13 registered in advance: recovering frames *inside*
what used to be one 5–20-slot run turns it into several 1–3-slot runs, so "events" is not a
conserved quantity across the two builds. The physically meaningful pair is
**slots/event 9.17 → 1.81** and **total lost 1,724 → 692**.

**P8, honestly.** The checker sits at the decoder pins, **upstream of a host-side fix**, so
it cannot be moved by the change; 0.046 % → 0.036 % is run-to-run variation. With N = 1 per
arm there is no spread estimate, so F4's "changes by more than its run-to-run spread"
**cannot be evaluated rigorously** — it is called not-fired on the strength of P9 instead,
which is a far tighter invariant (0.13 % apart).

**P11, honestly.** `rx_q_resets = 1` in leg A would trip F3's letter. It is **1 in the
control arm as well**, on the same binary with the re-anchor disabled, so it is not caused
by the fix — it is an arm-time artefact common to both. F3 is therefore not fired.

---

## 6. Falsifiers

- **F1 (counts at event rate but no recovery)** — does **not** fire: PER fell 60 % and
  `recovered = 1,237`.
- **F2 (PARTIAL, PER 0.08–0.10 %)** — does **not** fire: 0.079 % is below the bound.
- **F3 (worse / `rx_q_resets` > 0 / `crc_drop` up without resync)** — does **not** fire:
  PER improved, and the reset appears identically in the control (§5).
- **F4 (a fabric witness moves)** — does **not** fire: P9 unchanged to 0.13 %, P7 at ~3 per
  10 s, bitstream untouched.
- **F5 (`resync_other` ≳ `resync_568`) — FIRES.** `resync_other = 171`,
  `resync_568 = 0`. The pre-registration's instruction is explicit: *"The 568 phase is not
  the dominant displacement on this leg, contradicting the 1,259-of-1,305 measurement.
  **Re-open the class before crediting the fix.**"*

### What F5 means here, stated carefully

The **outcome** is not in doubt: a same-binary A/B, back-to-back, on an unchanged fabric,
with the control verified by effect, halves-and-better the forward residual and drains the
5–20 bin to nothing. That is as clean as this rig produces.

What is refuted is the **phase**. Task 23/26 measured the displacement at 568 bytes in
1,259 of 1,305 cases and the fix was built to re-anchor there; on silicon that path fired
**zero** times in 721 s while 171 re-anchors landed at other offsets and recovered 1,237
frames (7.2 frames per re-anchor — the same *shape* P5 predicted, at the wrong offset).
Either the displacement distribution differs on this leg from the banked capture the 568
figure came from, or the scan reaches a valid frame at another offset first. **The fix's
value does not depend on which**, but the class description does, and no fabric-side
conclusion should be drawn from "568" until it is re-measured.

---

## 7. Rig state at hand-off — released and healthy

Keeper hold 08:43:41 → 09:35:21, `KEEPER_HOLD_OK` / `KEEPER_RELEASE_OK released=[ SENTINEL RIGLOCK]`.
Final `bringup_r2r3.sh r3` (`restore-t27b`, `Result=success`) run **without** the control
env, so the daemon is back on the default.

**Verified after the restore:** `pid=595597`, daemon
**`md5 0ee566203a9752ddde036371c583774e`** (the fixed build),
`QPSK_RX_RESYNC` unset → **re-anchor ON**, `QPSK_RXQ_ZEROHDR` unset → off.
Sentinel restarted: `sentinel-093521` + `sentinelkeeper-093521` active/running; no hold files.

**The fixed daemon is left on 148**, per brief step 6 (leg A passes P1, link healthy).
Rollback if ever needed: redeploy `boot_known_good/daemon/qpsk_tun.148.1f834433`.

Bitstreams unchanged and not touched by this task: **148 = `9f13705d9fb0`,
146 = `3378861d30bd`**.

---

## 8. Concerns

1. **F5 is the real finding and it should gate any fabric work.** The 568-byte phase — the
   number the whole displacement story rests on — never fired. Re-measure the displacement
   distribution before anyone builds on "568".
2. **`resync_fail = 9,757` against 171 successes** (98 % of scans find nothing). The fix
   still nets a large win, but the scan is mostly missing. That is headroom, and it is also
   a hint about where the real phase is.
3. **P1 passed by 0.001 pp** (0.079 % against ≤ 0.08 %). The pre-registration itself warned
   the bound had ~5 % headroom. Do not treat this as a comfortable pass — treat P3/P10/P13
   and the 0.117 pp A/B difference as the load-bearing evidence.
4. **The wedge class cost a leg again** (control attempt 1, 12 s). Session total: 6 of 8
   captures wedge-flagged. Budget two attempts per credited leg.
5. **N = 1 per arm.** The A/B is single-shot. A replicate of both arms would firm up P8's
   spread and the 0.117 pp difference.
