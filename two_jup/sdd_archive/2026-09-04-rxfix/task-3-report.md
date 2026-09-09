# Task 3 (T0c) report — rig scripts, DRY only

**Fix round 1 applied** (review: `two_jup/sdd_archive/2026-09-04-rxfix/task-3-review.md`, commit d34e530, CONDITIONAL PASS). C-1 (restore() must kill+wait the backgrounded 146 peer-write watcher before writing restores) and I-1 (the 146 poke timing must be derived from capture_r3.sh's own sequence, not asserted from a wrong radioprobe_go.sh citation) are both fixed below, with a new test for C-1 and updated docs/meta.txt for I-1.

Deliverables (all new files, no edits to any existing script):
- `two_jup/rxfix/slackleg_go.sh`
- `two_jup/rxfix/witness_read.sh`
- `two_jup/tests/test_rxfix_rig_scripts.py` (18 tests, all green, zero ssh/scp shim hits)

## Insertion-point finding (required by the brief)

Read `two_jup/capture_r3.sh` sections 5b–5d before writing anything:
- **148 (RX board on a LEG=A forward leg): a clean hook already exists** — `capture_r3.sh:209-217`, the 5b `LOOP_POKE` generic `direct_reg_access` k=v poke, applied AFTER the wedge re-arms/health gate and BEFORE the framelog rotate that starts the scored window. `slackleg_go.sh` reuses it verbatim: it exports `LOOP_POKE="0x208=<val>"` and calls `legrun_go.sh LEG=A`, which execs `capture_r3.sh` via `env "${CAP_ENV[@]}" ...` without clearing the caller's environment, so `LOOP_POKE` reaches `capture_r3.sh` unchanged. **No edit to `legrun_go.sh` or `capture_r3.sh` was made** (test `test_slackleg_no_edits_to_capture_r3_or_legrun` guards this).
- **146 (peer/TX board): no clean hook exists.** `capture_r3.sh` has `PEER_ATTR_POKE` (5d) but that's the ADRV9002 sysfs-attribute path, not `direct_reg_access` — there is no `PEER_LOOP_POKE`. Implemented as a **timed action** (background watcher on `capture_r3.log`), not a script edit.

  **Fix round 1 (I-1):** the original version cited "radioprobe_go.sh's model" for a fixed `WAIT_146=20s` settle. That citation was wrong — `radioprobe_go.sh` has no sleep/wait/timed-poke anywhere; its peer probe lands via `capture_r3.sh`'s own in-script `PEER_ATTR_POKE` hook, not an external timer, and the 20 s figure was asserted, not derived — walking `capture_r3.sh`'s own sequence (health gate at :198 → 5b `LOOP_POKE` :211 → framelog rotate :273 → `CAP_SETTLE` → Tap-A capture :296 → `"traffic remaining"` watchdog :316) shows the whole gap could plausibly be under 15 s, so a blind 20 s settle could land the 146 write *after* the window opened. Fixed by deriving the trigger from `capture_r3.sh`'s own timeline instead of guessing a delay: the peer watcher now fires on the **same `"wedge verdict:"` marker** that fires 148's `LOOP_POKE` (capture_r3.sh:198, immediately before :211) — no settle at all. This satisfies both options the review offered (same marker as 148's window-opening hook; and, trivially, ≥5 s before `"traffic remaining"` since it fires strictly earlier than 148's own poke completes). `meta.txt` now carries `peer_poke_trigger=wedge_verdict_marker` instead of `wait_146_s=`.

Restore: trap on EXIT/INT/TERM, idempotent, reverse order of the poke (146 then 148), writes `0x208=0x0`. Because fixctl is write-only (no `read_fixctl` port anywhere in `TxRxCompo_ip_addr_decoder.v`, confirmed by grep across the seqbist/txfixF3 builds), restore cannot be read back — `meta.txt`'s `fixctl_restored=` means "write issued, exit 0 on both boards," stated as such, not a verified value. `stage3h_reader.sh` is run in the background on 148 (`LEGLOG=<leg's capture_r3.log>`, `BOARD=148`) for the duration of the window.

**Fix round 1 (C-1), the SIGTERM race:** the original `restore()` never stopped the backgrounded 146 peer-write watcher (`$PEER_PID`) before writing the restores. On a mid-window `systemd stop` (SIGTERM), the trap fired immediately and could race a peer write already dispatched or still asleep in its wait loop, which could land *after* the restore wrote `fixctl=0x0` to 146 — silently re-arming the probe state even though `meta.txt` reported `fixctl_restored=1`. Fixed: `restore()` now unconditionally `kill`s and `wait`s `$PEER_PID` **first**, before either restore write, in both the trap path and the normal-completion path (a harmless no-op there, since the watcher already exited via the earlier explicit `wait`). Verified by manual repro (`DRY=0` + PATH-shimmed ssh + a fake-sleep peer watcher, SIGTERM sent mid-sleep: the watcher was killed cleanly, never reaching its own write, and the two restore ssh calls fired in order 146-then-148) and by the new automated test below.

## 0x20C/0x210 and beatobs ownership (required by the brief before witness_read.sh could report anything but a guess)

Traced directly in the generated netlist for both `jupiter_byte_seqbist_build` and `jupiter_byte_txfixF3_build` (byte-identical at these lines — seqbist does derive from txfixF3 as the brief said):
- **0x20C/0x210 (nominally the FIFO witA/witB)**: `TxRxCompo_ip_src_QPSK_Rx.v:816,818` wires `beatfix_viol_count`/`beatfix_viol_latch` (the registers that land on 0x20C/0x210 per the addr decoder) to `fixctl[13] ? mdcapl : dcapl` / `... : dcmm` — the 2026-08-30 DBGCAP per-stage capture registers, **not** witA/witB. The Preamble_Detector FIFO's own `pdWitA`/`pdWitB` nets (`QPSK_Rx.v:190-191,386-387`) are declared and driven but connected to **nothing else** — dead nets. `witness_read.sh` reports `NOT_AVAILABLE` for both, with the reason inline in each JSON line.
- **Rate_Handle beatobs pointers**: `beatobsRhCtr/Push/Pop` route through `debugI1/debugQ1` straight to `dut_data_out_0_rx`/`dut_data_out_1_rx` (`TxRxCompo_ip.v:355,357`) — the RX I/Q **sample stream to the DMA**, not an AXI-lite register. No `direct_reg_access` address exists for it on this image; only a DDRCAP-style stream capture could see it. `witness_read.sh` reports `NOT_AVAILABLE` here too.

`witness_read.sh` (K=V `BOARD=148|146 N=<readings> PERIOD=10(floor) DRY=1(default)`) emits one JSON line per reading at ≥10 s spacing (PERIOD below 10 is clamped with a logged warning), always `NOT_AVAILABLE` for `fifo_witA`/`fifo_witB`/`beatobs` with the reasons above. DRY emits all N lines immediately (no real sleeps); real mode adds one benign reachability probe (`devmem 0x9D410000`, the same register `stage3h_reader.sh` reads) so an unreachable board is reported honestly.

## Tests

`two_jup/tests/test_rxfix_rig_scripts.py`, 18 tests, PATH-shimmed `ssh`/`scp` (fake binaries that log+exit 1). 17 run under DRY=1 only: required-env rejection, zero-network proof, meta.txt key presence, 148-then-146 poke ordering, 146-then-148 restore-plan ordering (a DRY-mode trap-fires-on-normal-exit check — see caveat below), stage3h background-plan presence, no-capture_r3.sh-edit guard, witness NOT_AVAILABLE content + reasons on both boards, DRY speed (no real sleeps), PERIOD floor clamp, and DRY reachability-probe skip.

**Fix round 1 (C-1) test — `test_slackleg_restore_kills_peer_watcher_before_restoring_146_then_148`**: the prior TERM-signal test only proved the trap prints a restore verdict when nothing was racing it (DRY=1 never launches the peer watcher at all, so the race was structurally untested). This new test runs `DRY=0` with PATH-shimmed `ssh`/`scp` (zero real network — the shim logs and exits 1) plus a new `PEER_POKE_TEST_SLEEP` test seam that replaces the peer watcher's real "watch `capture_r3.log`" loop with a plain long sleep — a "fake peer watcher (a sleep)" per the review's ask. It waits for the watcher to actually start, sends SIGTERM to the process group, and asserts: the watcher never reached its own write (`"finished WITHOUT being killed"` absent from `peer_poke.log`), `run.log` shows kill-watcher → `RESTORE 1/2: 146` → `RESTORE 2/2: 148` in that order, and the shim log shows exactly two `0x208 0x0` writes, to 146 then 148.

```
$ python3 -m pytest two_jup/tests/test_rxfix_rig_scripts.py -q
18 passed in 3.01s
```

## Launch lines for T1 (rig, not run by this task — no board contact here)

Control leg (enSlack OFF):
```
launch_rig_unit.sh rxfix-t1-control two_jup/rxfix/slackleg_go.sh SLACK=0 DUR=600 DRY=0 TAG=t1-control
```
Treatment leg (enSlack ON, fixctl 0x8):
```
launch_rig_unit.sh rxfix-t1-slackon two_jup/rxfix/slackleg_go.sh SLACK=1 DUR=600 DRY=0 TAG=t1-slackon
```
Witness poll (either leg, run alongside, e.g. from a second unit or a plain background job outside the rig-hold discipline since it makes no board-state change — read-only when DRY=0, though on this image it always reports NOT_AVAILABLE regardless of board contact):
```
BOARD=148 N=60 PERIOD=10 DRY=0 two_jup/rxfix/witness_read.sh
```
T1 must run `keeper_hold.sh hold` first and `keeper_hold.sh release` after, per the standing rails; `slackleg_go.sh`'s own restore trap only handles fixctl, not the hold.

## Not done in this task (by design)
- No board contact, no ssh/scp beyond the PATH-shimmed tests, no subagents launched, nothing pushed.
- Did not edit `capture_r3.sh`, `legrun_go.sh`, or any RTL — DRY-only rig-script task.
