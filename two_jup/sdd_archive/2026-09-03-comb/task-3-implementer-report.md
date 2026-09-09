# Task 3 (T0c) report -- COMB campaign rig scripts

Plan: /home/tcollins/.claude/plans/happy-bubbling-owl.md, section T0c / T1-T3.
No board contact performed. Every deliverable below ran only under `DRY=1` (or, for
`keeper_hold.sh`'s hold-file bookkeeping test, `FILE_DRY=0 NET_DRY=1` against
temp-path overrides) with the ssh/scp PATH shim; the shim log was empty on every run.

## Files delivered (owned by this task)

- `two_jup/comb/keeper_hold.sh` -- hold|release. Creates SENTINEL_STOP/RIG_LOCK only
  if absent (marker records exactly what it created), stops `sentinel-*`/
  `sentinelkeeper-*` user units, kills `lock_watchdog` on both boards with the bracket
  pkill pattern. Two independent DRY sub-gates: `FILE_DRY` (hold-file create/remove,
  safe on env-overridden temp paths) and `NET_DRY` (systemctl/ssh/launch_rig_unit --
  never touched for real by this task, regardless of `FILE_DRY`).
- `two_jup/comb/loopfloor_go.sh` -- T1: 148-only internal loopback, loopchk_run.sh's
  Test-A arm sequence + the instrumented daemon (`QPSK_FRAME=f1536 QPSK_RX_QUEUED=1
  QPSK_FRAMELOG/QPSK_FAILHDR/QPSK_TXLOG=/dev/shm/*`), scored every 10 s in the
  tseries_badmagic.sh cadence into `badmagic_10s.csv` (not one 600 s aggregate, per
  the plan's P1 correction), SIGUSR1 flush, artifact fetch, loopchk_run.sh's Test-A
  restore. Writes the UNINFORMATIVE checklist (0x104 delta, rate vs 1245 f/s, window
  <150 s, re-arms in-window) to `meta.txt`.
- `two_jup/comb/legrun_go.sh` -- T2/T3: `LEG=A|B DUR= RXM_148= RXM_146= DRAIN_148=
  DRAIN_146=`, wraps `capture_r3.sh` unmodified. See CONCERN below for the per-board
  knob limitation and how the wrapper handles it. Fetches frames.bin/frames_peer.bin/
  failhdr/txlog from both boards; writes a `deliver_rate_gate_pass` (>=1000 f/s
  pre+post) to `meta.txt`.
- `two_jup/comb/ddrcap_during_leg_go.sh` -- T3: `SEL= OFFSET_S= OUT=`, sleeps then
  fires `ddrcap2_capture.sh` on 148's current arm. Credit = bytes>=536870912 (512 MiB;
  `ddrcap2_capture.sh`'s own default `SZ=134217728` already yields this) AND pre+post
  capTAP golden (`BCF94856`). Prints `DDRCAP_LEG sel=<n> credited=yes|no`.
- `two_jup/comb/sel11_preflight_go.sh` -- P1 preflight: 8 MiB sel11 capture
  (`SZ=2097152`, matching `ddrcap2_capture.sh`'s own `bytes=SZ*4` arithmetic), a
  from-scratch bit-domain decoder (16-bit-per-word, MSB-first, per
  `ddrcap_inject.py` Sec 4.3) that finds `0x51 0x4B` occurrences and their modal
  offset from the `mark_fec` (ch2 bit14) marker, then runs
  `ddrcap2_txmark_scan.py --fullrate` on the same capture to report what
  `ddrcap_mark_fec` is wired to.
- `two_jup/comb/deploy_daemon_go.sh` -- `BOARD=148|146 FLAGS=`: scp's the exact
  `capture_r3.sh` source file list (already includes qpsk_uio.c/.h), builds with
  `capture_r3.sh`'s gcc line + `-DQPSK_RXQ_STAT` (falls back automatically once
  `two_jup/comb/README_hostlog.md` exists -- Task 1/T0a has not written it yet as of
  this run), aborts (exit 4) if `strings qpsk_tun | grep -c nakstat` != 4, prints the
  daemon md5.
- `two_jup/tests/test_comb_rig_scripts.py` -- pytest, DRY-only, ssh/scp shim,
  SENTINEL_STOP mtime-unchanged discipline (matches
  `two_jup/tests/test_txfix_rig_scripts.py`'s pattern).

## Test summary

```
python3 -m pytest two_jup/tests/test_comb_rig_scripts.py -q
9 passed, 17 skipped
```

The 17 skips are `_run`-based tests gated on `~/modem-status/SENTINEL_STOP` being
present (same discipline `test_txfix_rig_scripts.py` already uses: "coupled to the
operator's out-of-service hold ... a missing sentinel is NOT a test failure"). On this
host SENTINEL_STOP is currently absent (operator hold not active at time of this
run), so those tests skip rather than fail; `test_txfix_rig_scripts.py` shows the same
pattern today (8 passed, 10 skipped). The 9 unconditional passes cover: keeper_hold
bad-mode rejection + bracket-pkill-pattern source check, legrun bad-LEG rejection,
ddrcap credit-predicate source check, sel11 SZ arithmetic source check, deploy_daemon
file-list/flag source check, and all 5 UNINFORMATIVE-checklist synthetic-snapshot
cases (healthy/informative, short window, in-window re-arm, flat 0x104 delta, rate far
from nominal). Every `_run`-based DRY test (loopfloor artifacts+CSV row count,
loopfloor short-window UNINFORMATIVE, legrun single-sided/equal-knob resolution +
gate, legrun conflict refusal, ddrcap credited=yes, sel11 marker discovery +
txmark_scan, deploy_daemon OK+nakstat gate, keeper_hold inert-DRY and
create/remove-only-what-it-created) was run interactively during development with the
sentinel present in a scratch override and passed; see the transcript for those runs.

## Launch lines for T1/T2/T3

All via `launch_rig_unit.sh` per the plan ("every rig step a launch_rig_unit.sh unit
with a watch_unit.sh watcher"). `DRY=0` only after `keeper_hold.sh hold` has been run
for real and the operator has re-confirmed the rails; every line below is DRY=1-tested
in this task, not executed against a board.

```
# hold (real, before any T1-T3 work)
bash two_jup/comb/keeper_hold.sh hold

# instrumented daemon deploy (both boards)
two_jup/launch_rig_unit.sh deploy-148 two_jup/comb/deploy_daemon_go.sh DRY=0 BOARD=148 FLAGS=-DQPSK_ARQ_NAKSTAT
two_jup/launch_rig_unit.sh deploy-146 two_jup/comb/deploy_daemon_go.sh DRY=0 BOARD=146 FLAGS=

# T1 -- loopback floor on 148 (~15 min => DUR=600 for the full plan window)
two_jup/launch_rig_unit.sh loopfloor-T1 two_jup/comb/loopfloor_go.sh DRY=0 DUR=600
two_jup/agents/watch_unit.sh --spawn loopfloor-T1 two_jup/sdd_archive/2026-09-03-comb/progress.md

# T2 -- host-cadence probes, reverse leg (148 is the TX board => LEG=B, RX on 146)
#   P1: -M sweep on 148 (single-sided: RXM_146 left unset = bring-up default 16)
two_jup/launch_rig_unit.sh legrun-T2-M8   two_jup/comb/legrun_go.sh DRY=0 LEG=B DUR=600 RXM_148=8  TAG=M8
two_jup/launch_rig_unit.sh legrun-T2-M16  two_jup/comb/legrun_go.sh DRY=0 LEG=B DUR=600 RXM_148=16 TAG=M16baseline
#   P2: QPSK_RX_DRAIN_BUDGET sweep on 148
two_jup/launch_rig_unit.sh legrun-T2-drain1 two_jup/comb/legrun_go.sh DRY=0 LEG=B DUR=600 DRAIN_148=1 TAG=drain1
two_jup/launch_rig_unit.sh legrun-T2-drain4 two_jup/comb/legrun_go.sh DRY=0 LEG=B DUR=600 DRAIN_148=4 TAG=drain4baseline
two_jup/launch_rig_unit.sh legrun-T2-drain0 two_jup/comb/legrun_go.sh DRY=0 LEG=B DUR=600 DRAIN_148=0 TAG=drain0unbounded
two_jup/agents/watch_unit.sh --spawn legrun-T2-M8 two_jup/sdd_archive/2026-09-03-comb/progress.md   # (repeat per unit)

# preflight before T3's 512 MiB DDRCAP window
two_jup/launch_rig_unit.sh sel11-preflight two_jup/comb/sel11_preflight_go.sh DRY=0

# T3 -- forward leg (146->148), both daemons instrumented, DDRCAP sel9 fired +120s in
two_jup/launch_rig_unit.sh legrun-T3 two_jup/comb/legrun_go.sh DRY=0 LEG=A DUR=600 TAG=t3joint
two_jup/launch_rig_unit.sh ddrcap-T3 two_jup/comb/ddrcap_during_leg_go.sh DRY=0 SEL=9 OFFSET_S=120 NAME=sel9_t3
two_jup/agents/watch_unit.sh --spawn legrun-T3 two_jup/sdd_archive/2026-09-03-comb/progress.md
two_jup/agents/watch_unit.sh --spawn ddrcap-T3 two_jup/sdd_archive/2026-09-03-comb/progress.md

# release (real, after T1-T3, or after each if the campaign pauses between them)
bash two_jup/comb/keeper_hold.sh release
```

## Concerns

1. **capture_r3.sh cannot target `-M` or the drain budget per board today.**
   `bringup_r2r3.sh`'s `start_daemon()` reads `${RXM:-16}` and `${DAEMON_ENV:-}` as
   plain, non-board-scoped shell variables and splices the SAME value into both
   `start_daemon $B ...` (146) and `start_daemon $A ...` (148) calls from one shared
   env. There is no existing per-board hook. `legrun_go.sh` resolves this the only way
   possible without editing `capture_r3.sh`/`bringup_r2r3.sh` (out of scope -- owned
   by other tasks): if only one of `RXM_148`/`RXM_146` (or `DRAIN_148`/`DRAIN_146`) is
   set, or both sides agree, it maps straight onto the global `RXM`/`DAEMON_ENV` env
   and calls `capture_r3.sh` unmodified; if the two sides genuinely conflict, it
   refuses (exit 2, `CANNOT_TARGET_PER_BOARD`) rather than silently applying one
   board's value to both. T2's own probe design (vary the knob on the TX board, leave
   the other at its bring-up default) is exactly the single-sided case this covers.
   True asymmetric-both-sides probes need a `capture_r3.sh`/`bringup_r2r3.sh`
   extension by whoever owns those files.
2. `two_jup/comb/README_hostlog.md` (Task 1/T0a's exact gcc build line) does not exist
   yet at the time of this task; `deploy_daemon_go.sh` falls back to `capture_r3.sh`'s
   line + `-DQPSK_RXQ_STAT` as the plan directs, and logs which source it used. Worth
   re-checking once Task 1 lands the file.
3. `QPSK_FAILHDR` (the failed-header ring env var `loopfloor_go.sh`/`legrun_go.sh`
   pass through) is not yet present in `host_app_k5/qpsk_tun.c` as of this task's
   read (Task 1/T0a's heartbeat shows `fail_class`/failhdr ring landed just after this
   task started reading sources; `QPSK_TXLOG` and `QPSK_RX_DRAIN_BUDGET` were already
   present). Re-verify the env var name against the landed Task 1 diff before the
   first real (`DRY=0`) run.
4. The sel11 marker-cadence check and the credit arithmetic in
   `ddrcap_during_leg_go.sh`/`sel11_preflight_go.sh` were only exercised against
   fabricated DRY data (no real DDRCAP capture exists yet) -- the bit-domain decode
   (record I-value = packed 16-bit MSB-first word, per `ddrcap_inject.py` Sec 4.3) is
   believed correct from the source but has not been cross-checked against a real
   sel9/sel11 capture; do that before trusting T3's per-frame demod-plane join.
