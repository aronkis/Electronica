# T1 — loopback floor on board 148 (happy-bubbling-owl §T1)

Rig driver run, 2026-09-03. **148 only for deploy and measurement** (10.0.0.148); 146 received
only the authorised `lock_watchdog` kill issued by `keeper_hold.sh hold` (sequence step 2) and
nothing else — no deploy, no arm, no register access.
All measured numbers below are **[silicon]** unless marked [inferred].

## 1. Exact commands

Pre-check (read-only, no board contact):
```
systemctl --user list-units --type=service --state=running | grep -E 'sentinel|keeper'
tail -12 ~/modem-status/sentinel.log
```
Result: `sentinel-153110.service` + `sentinelkeeper-152910.service` running; sentinel log
`ok rate=...` through `2026-09-03_17:22:00` with no restore/arm in flight. No hold files present.

Hold (positional arg — `keeper_hold.sh` takes `mode=$1` and cannot be wrapped by
`launch_rig_unit.sh`, which passes `K=V` env only; sequence step 2 authorises running it directly):
```
DRY=0 two_jup/comb/keeper_hold.sh hold
```
Result: `KEEPER_HOLD_OK created=[ SENTINEL RIGLOCK]`; stopped `sentinel-153110.service` and
`sentinelkeeper-152910.service`; `lock_watchdog` kill sent to 10.0.0.148 and 10.0.0.146.
Verified: both `~/modem-status/SENTINEL_STOP` and `~/modem-status/RIG_LOCK` exist; no
sentinel/keeper unit running.

Deploy (148 only):
```
two_jup/launch_rig_unit.sh deploy148-T1r \
  /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/deploy_daemon_go.sh DRY=0 BOARD=148
two_jup/agents/watch_unit.sh --spawn deploy148-T1r \
  /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/sdd_archive/2026-09-03-comb/progress.md
```

T1 run:
```
two_jup/launch_rig_unit.sh loopfloor-T1 \
  /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/comb/loopfloor_go.sh DRY=0 DUR=600
two_jup/agents/watch_unit.sh --spawn loopfloor-T1 \
  /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/sdd_archive/2026-09-03-comb/progress.md
```

## 2. Unit names

| unit | result |
|---|---|
| `deploy148-T1` | `UNITEXIT ... result=exit-code code=127` — **not a board action**: `systemd-run --user` runs with cwd `$HOME`, so the *relative* script path never resolved (`/bin/bash: two_jup/comb/deploy_daemon_go.sh: No such file or directory`). Zero ssh/scp, zero board contact. Re-launched with an absolute path; this is a launcher-invocation error, not a rig wedge, so it does not consume the one-re-run allowance. |
| `deploy148-T1r` | `UNITEXIT ... result=success code=0 at=2026-09-03T17:28:51-04:00` |
| `loopfloor-T1` | see §6 |
| `watch-deploy148-T1`, `watch-deploy148-T1r`, `watch-loopfloor-T1` | watchers, ledger = `progress.md` |

## 3. Deploy credit

`two_jup/comb/runs/20260903_172821_deploy_148/meta.txt`:
```
board=148 ip=10.0.0.148 flags=[] dry=0
gcc_line_source=README_hostlog.md
build_ok=1
nakstat_strings=4 (need 4; gate applies (BOARD=148))
nakstat_gate_pass=1
daemon_md5=f2c33f9b1b784d3c91a85c2d9383030d
```
- **nakstat gate: PASS, count 4** [silicon]. Deployed daemon md5 `f2c33f9b1b784d3c91a85c2d9383030d` [silicon].
- The `rxqstat == 0` rail in `restore_known_good.sh:65` is **tripped by design** (instrumented
  build carries `-DQPSK_RXQ_STAT`). **Ledgered.** Note: `deploy_daemon_go.sh` records **no**
  rxqstat count at all — README_hostlog.md §5.1's manual `strings | grep -c rxqstat` is the only
  path for 148, and this script does not run it. The rxqstat attestation therefore comes from
  `loopfloor_go.sh`'s post-run `RXQSTAT_N` (§6).
- The on-board `gcc -o qpsk_tun` rebuilt a **running** binary without ETXTBSY (GNU ld unlinks the
  output path before creating it). The running daemon kept the old inode until `loopfloor_go.sh`'s
  `pre_cleanup` `pkill`ed it and `start_daemon` relaunched from the new path — so T1 ran the
  instrumented build by construction.

## 4. Output directory

`two_jup/comb/runs/20260903_172902_loopfloor/`
(deploy: `two_jup/comb/runs/20260903_172821_deploy_148/`)

## 5. Results — all [silicon]

Output dir `two_jup/comb/runs/20260903_172902_loopfloor/`. Window 600 s, 60 x 10 s windows,
`DUR=600`, `UNITEXIT loopfloor-T1 result=success code=0 at=2026-09-03T17:40:33-04:00`.

### 5.1 magic_bad 10 s time series (denominator = fabric `frames` counter, same window)

| stat | value |
|---|---|
| windows | 60 / 60 |
| frames (sum of per-window deltas) | **816,963** |
| magic_bad (sum) | **1** |
| per-window pct — min | 0.0000 % |
| per-window pct — median | 0.0000 % |
| per-window pct — max | **0.0074 %** (the t=10 s window, the single event) |
| windows with any event | 1 of 60 |
| **windows >= 3 % (falsifier)** | **0** |
| aggregate | 1 / 816,963 = **0.000122 %** |

Counts first, per the campaign metrics rule: **1 magic_bad event in 816,963 frames over 600 s.**
For scale, the historical loopback floor of 0.22-0.31 % (SINGLES_CAMPAIGN.md:3455-3479) would have
produced ~1,800-2,500 events in this same sample. With a single event the Poisson 95 % upper bound
is ~5 events, i.e. the floor is **<= ~0.0006 %** on this path — not a five-figure point estimate.

### 5.2 txgap (three periodic dumps recovered by `grep "qpsk_tun txgap" | tail -3`)

```
n=6228 empty=0 gt20us=0 gt50us=0 gt200us=0 max_us=0   p99_us=0    mean_us=0.0 idle_batch=0
n=3567 empty=0 gt20us=0 gt50us=0 gt200us=0 max_us=0   p99_us=0    mean_us=0.0 idle_batch=0
n=2661 empty=1 gt20us=1 gt50us=1 gt200us=1 max_us=962 p99_us=1023 mean_us=962.0 idle_batch=0
```
Totals over the three dumps: **gt20us = 1, gt50us = 1, gt200us = 1** (the same single 962 us gap,
in the last dump, i.e. at the close). The two steady-state dumps show **gt20us = 0 and max_us = 0
across 9,795 transfers** — literally zero inter-transfer silence. The PREREG's `gt20us ~ 0` clause
is **met**, with this coverage caveat: the three dumps total 12,456 transfers against 819,211 frames
in the window, i.e. **~1.5 % of window transfers**, because `loopfloor_go.sh` fetches the histogram
with `grep "qpsk_tun txgap" | tail -3` and discards every earlier periodic dump (defect D4).
Note the third dump's `empty=1` alongside `gt20us=1` places that one gap at the SIGUSR1/close
boundary, outside the steady-state measurement, not inside the window.

### 5.3 Registers

`regs_pre.txt` / `regs_post.txt` (hex, as `snap()` emits them):
```
pre : t=1788470960.826 pkts=0x2034   biterr=0x5D0BC   rstcs=0x0 cfc=0xFFFFFFF3 fx=0x0
post: t=1788471618.601 pkts=0xCA03F  biterr=0x276D2E3 rstcs=0x0 cfc=0xFFFFFFF6 fx=0x0
```
- **0x104 delta = 0xCA03F - 0x2034 = 819,211** (hand-computed base-16, 32-bit masked; the script's
  `d104=0` is defect D2, not the measurement). Rate 1,365.4 f/s.
  **Cross-check:** the `p104` column of `badmagic_10s.csv` sums to 816,964 (1,361.6 f/s), and the
  fabric `frames` column sums to 816,963. The three agree to within 0.3 % (the 2,247-frame gap is
  the pre-snapshot-to-first-window and last-window-to-post-snapshot edges). **No disagreement.**
- 0x108 BIST delta = 0x276D2E3 - 0x5D0BC = 40,960,551 over the window. Reported as a **delta**; the
  large pre-value (381,116) is history from before the window. Per the standing BIST caveat this
  counter sees only the first 120 of 2,240 bits, so it is not a frame-error rate and is not scored here.
- 0x150 `rstcs` (carrier reset) = 0x0 -> 0x0, **delta 0** — no carrier resets in-window.
- 0x154 `cfc` 0xFFFFFFF3 -> 0xFFFFFFF6 — a 3-LSB CFO wander, negligible.
- 0x15C `fx` = 0 -> 0.

### 5.4 Delivered rate

**There is no host delivered-rate number for this run, and the fabric rate is not a substitute.**
The sentinel was stopped for the hold (correctly), and this is a 148-internal loopback with no peer.
What is measured is the **fabric frames rate: 1,361.6 f/s**, inside `loopfloor_go.sh`'s own
1,245 +/- 400 gate. `meta.txt` reports the same number as `rate_fps=1361.6`.

### 5.5 Re-arm in window

**No re-arm occurred in-window.** Basis (see defect D1): `arm_loop` is called exactly once, before
`SNAP_PRE`, and there is no second call inside the sampling loop; the sentinel and keeper were
stopped and both hold files were in place for the whole window, and `lock_watchdog` was killed on
148 before the run. `rearms_in_window=0` in `meta.txt` is consistent but, on its own, is not
evidence — the counter cannot detect a genuine in-window re-arm.

### 5.6 Artifact completeness

| file | size | check |
|---|---|---|
| `frames.bin` | 75,648 B | `% 48 == 0` **PASS**, 1,576 records |
| `failhdr.bin` | 50,464 B | `== 32 + 32n` **PASS**, 1,576 records |
| `txlog.bin` | **MISSING** | see defect D3 |
| `badmagic_10s.csv` | 60 windows | complete |

## 6. Verdicts

### 6.1 Credit — UNINFORMATIVE checklist (plan T1)

| item | result |
|---|---|
| 0x104 delta ~= 0 | **PASS** (delta = 819,211, not ~0). The artifact `uninformative.txt` says otherwise **only** because of defect D2. |
| rate far from ~1250 f/s | **PASS** — 1,361.6 f/s, inside the script's own 1,245 +/- 400 gate |
| window < 150 s | **PASS** — 600 s, 60/60 windows |
| any re-arm in-window | **PASS** — none (§5.5) |
| capTAP not golden | **N/A** — no DDRCAP tap in T1 |

`uninformative.txt` verbatim, as the artifact of record:
```
UNINFORMATIVE window_s=600 rate_fps=1361.6 d104=0 rearms_in_window=0
  - 0x104 delta ~= 0 (0)
```
**Corrected verdict: INFORMATIVE — the run is credited.** The file's sole flag is the false
`d104 ~= 0` produced by defect D2 (hex parsed as decimal); the true delta is 819,211, independently
corroborated by the `p104` and `frames` columns. Every other checklist item passes on the artifact's
own numbers.

Additional positive evidence the byte-in path genuinely ran (i.e. this is not a silent-path null):
`frames` and `p104` track one another window-by-window across all 60 windows (13560/13561,
13609/13608, 13597/13599, ...), and `txgap` recorded 9,795+ real transfers with max_us=0.

### 6.2 PREREG verdict

- Prediction: **0.2-0.35 % magic_bad in every 10 s window.** Observed: 0.0000 % median,
  0.0074 % max, aggregate 0.000122 %. **Prediction NOT met — missed LOW, by roughly 300x.**
- No burst window: **CONFIRMED** — max window 0.0074 %, no burst class of any kind.
- `txgap gt20us ~= 0`: **CONFIRMED** — 1 event, at the close boundary, 0 in steady state.
- **Falsifier (>= 3 % in any window): NOT tripped.** 0 of 60 windows >= 3 %.
  The beat fix **holds** on this path; T1 does not re-open the beat, and the campaign proceeds to T2.

**Consequence for the plan.** P2 bounded the TX byte-in plane at <= ~0.25 % of the 8.06 % forward /
3.87 % reverse residual. T1 tightens that bound by more than an order of magnitude: at f1536,
`-M 16`, RXQ=1 the loopback floor is **<= ~0.0006 % [silicon]**. Carrying that to the on-air
residual is **[inferred]**, via P2's argument that an ALIGNLOSS corrupts the air frame identically in
loopback and on air; on that inference the TX byte-in plane accounts for well under 0.01 % of the
8.06 % / 3.87 % residual. The ByteWordBuffer depth fix and the T5b TX-side witness are **more firmly
pre-disqualified**, not less. Direction of the miss is favourable.

## 6.3 Rig state left behind (T2 handoff — read before the next task)

- Hold **NOT released** (controller ruling: held across T1-T3). `~/modem-status/SENTINEL_STOP` and
  `~/modem-status/RIG_LOCK` both present; `.keeper_hold_created` records that this invocation
  created both. Sentinel and keeper units **stopped, not restarted**.
- **Instrumented daemon left on 148** as directed: md5 `f2c33f9b1b784d3c91a85c2d9383030d`,
  `nakstat=4`, `rxqstat=1`. Image md5 `f6a8c3ea119cd55459a9b30c576e5d91` (txfixF3), unchanged.
- **148 has no daemon process running**: `loopfloor_go.sh`'s close does `pkill -x qpsk_tun`.
- The **byte-source injector written by `arm_loop` is left armed** — the close step does not clear
  0x9D400000 / 0x9D410000 (only `pre_cleanup` does, at start of the next run).
- 146's daemon is still up but its `lock_watchdog` was killed by the hold.
- Net: **the RF link is down after T1, by design, not a wedge.** T2's `capture_r3.sh` bringup
  re-arms from this state.

**T3 BLOCKER (does not affect any T1 number or the T1 credit).** `failhdr.bin` holds **1,576**
records against **1** fabric `magic_bad` event, and `frames.bin` holds exactly 1,576 records too.
Either the failed-header ring is recording something other than header failures, or the host RX path
saw ~1,576 bad frames the fabric checker did not count. T3's decision table keys entirely on
fail-class and on the TX<->RX join's `NEVER_SENT` / `SENT_NOT_DECODED` classification, so this
ambiguity would corrupt exactly the output T3 is most sensitive to. **Resolve with the T0b tools
before any T3 leg is scored.** T1's scored quantity is the fabric `magic_bad` counter (148 loopback
has no peer and the checker is in fabric), so nothing in §5 or §6.1-6.2 depends on it.


## 7. Script defects found (both in `loopfloor_go.sh`; concerns for T2/T3)

**D1 — `REARM_COUNT` off-by-one (FIXED before the run, DRY-verified).** `arm_loop` is called once
*before* `SNAP_PRE`, incrementing `REARM_COUNT` to 1 under `DRY=0`; the UNINFORMATIVE checklist
flags `rearms > 0` as "re-arm in-window", so `uninformative.txt` (and the `meta.txt` line it feeds)
would have read `UNINFORMATIVE ... 1 re-arm(s) in-window` on **every** real run regardless of the
data. Fixed by resetting `REARM_COUNT=0` immediately after the pre-window `arm_loop`; confirmed
with one `DRY=1` run printing `INFORMATIVE window_s=600 rate_fps=1245.0 rearms_in_window=0`.
Residual: there is no second `arm_loop` call inside the sampling loop, so the counter cannot
detect a *genuine* in-window re-arm either — the "no re-arm in-window" claim in §6 rests on the
script's structure plus the hold (sentinel and keeper stopped, `lock_watchdog` killed), not on
that counter.

**D2 — hex snapshot parsed as decimal (NOT fixed; found mid-run, script not editable while
running).** `snap()` emits register values in hex from `cat $DRA` (e.g. `pkts=0x2034`), but
`uninformative.py` parses with `re.findall(r'(\w+)=(\d+)')`, which matches only the leading `0`.
Every register therefore parses as 0, `d104` computes as `0 - 0 = 0`, and the checklist raises a
**false** `0x104 delta ~= 0` flag, forcing `UNINFORMATIVE` on any `DRY=0` run. `loopfloor_go.sh`
was not edited mid-run (bash re-reads a running script by byte offset). The true 0x104 delta in
§5 is computed by hand from `regs_pre.txt`/`regs_post.txt` with base-16 parsing and a 32-bit mask,
cross-checked against the `p104` column of `badmagic_10s.csv`.
Scope: the `(\w+)=(\d+)` regex is a shared lineage (`loopchk_run.sh`, `loopA_cadence.sh`,
`loopchk_b.sh`, `txq_session.sh`, `rxchk_run.sh`, `rxchk16_run.sh`), but in those it parses the
*decimal* `CNT ...` line. The hex defect is **unique to `loopfloor_go.sh`'s `uninformative.py`**,
the only place `snap()`'s hex output is fed to that regex.

**D3 — `txlog.bin` is never fetched by `loopfloor_go.sh` (NOT fixed).** `scp_err.txt` reads
`scp: /dev/shm/txlog.bin: No such file or directory`. Per README_hostlog.md §5.4.2 the TX log on the
loopback floor is deliberately **atexit-only** (`QPSK_TXLOG_USR1=1` is correctly *not* set, because a
32 MiB write per 10 s poll would manufacture the very starvation T1 measures). But the script's order
is: SIGUSR1 -> scp all three files -> `pkill -x qpsk_tun`. The atexit dump therefore happens *after*
the fetch, so `txlog.bin` can never exist at scp time. T1 did not need it (the `txgap` histogram in
the daemon log is the PREREG's discriminator and was recovered), but **T3's TX<->RX join depends on
this file**. Fix before T3: move the `pkill` ahead of the `txlog.bin` fetch, or fetch `txlog.bin` in
a second pass after the restore step. `legrun_go.sh` goes through `capture_r3.sh` (which sends
SIGUSR1 with `QPSK_TXLOG_USR1=1`) and is not affected by this ordering.

**Observation, not scored — host-side rings are small and equal.** `frames.bin` holds 1,576 records
and `failhdr.bin` holds exactly 1,576 records, against 816,963 fabric frames. On the T1 loopback the
scored quantity is the fabric `magic_bad` counter (the host has no peer and the checker is in
fabric), so this does not affect any number above, but the 1:1 ratio should be explained by the T0b
tools before `frames.bin`/`failhdr.bin` are trusted on a T3 leg.

**D4 — `txgap` histogram truncated to the last three dumps (NOT fixed).** `loopfloor_go.sh`'s close
fetches the histogram with `grep "qpsk_tun txgap" /dev/shm/loopfloor.log | tail -3`, keeping only the
last three periodic dumps: 12,456 transfers against 819,211 frames, ~1.5 % coverage. For T1 that is
enough (two full steady-state dumps at max_us = 0), but T2/T3 want the whole histogram — drop the
`tail -3`, or fetch `loopfloor.log` itself.
