# Task 3 fix round 1 — comb rig scripts (two_jup/comb/*.sh, two_jup/tests/test_comb_rig_scripts.py)
Review verdict: Needs fixes (two_jup/sdd_archive/2026-09-03-comb/task-3-report.md). Findings and the controller's rulings:

## C-1 (critical): per-board -M / drain knobs are impossible through the shared env
`bringup_r2r3.sh:167` reads `RXM` and `DAEMON_ENV` from ONE shared env for both `start_daemon` calls, so `RXM_148=8` sets both boards. The plan's T2 P1 needs 148 at -M 8 with 146 at baseline.
RULING: extend `two_jup/bringup_r2r3.sh` `start_daemon()` with backward-compatible per-board overrides. A = 148 (`$A`), B = 146 (`$B`). Inside start_daemon, before the launch line:
```
  RXM_EFF=${RXM:-16}; DENV_EFF=${DAEMON_ENV:-}
  if [ "$1" = "$A" ]; then RXM_EFF=${RXM_A:-$RXM_EFF}; DENV_EFF=${DAEMON_ENV_A:-$DENV_EFF}; fi
  if [ "$1" = "$B" ]; then RXM_EFF=${RXM_B:-$RXM_EFF}; DENV_EFF=${DAEMON_ENV_B:-$DENV_EFF}; fi
```
and use `$DENV_EFF` / `-M $RXM_EFF` in the launch line (nothing else on that line changes; with none of the new vars set the line is byte-identical to today). Verify capture_r3.sh passes the environment through to bringup_r2r3.sh unchanged (it execs/sources it; confirm by grep and state the line). Then rewrite legrun_go.sh: drop `resolve_pair` and the CANNOT_TARGET_PER_BOARD refusal; map RXM_148→RXM_A, RXM_146→RXM_B, DRAIN_148→`QPSK_RX_DRAIN_BUDGET=` inside DAEMON_ENV_A, DRAIN_146→ inside DAEMON_ENV_B. Fix the header comment (the single-sided claim becomes true only via these overrides).

## C-1 from the Task 1 review (daemon sinks never enabled on legs)
legrun_go.sh:77 builds DAEMON_ENV with only the drain knob, so the T0a sinks (`QPSK_FAILHDR`, `QPSK_TXLOG`) are never set and capture_r3.sh's fetch of failhdr.bin/txlog.bin gets nothing. Every leg MUST launch both boards with `QPSK_FAILHDR=/dev/shm/failhdr.bin QPSK_TXLOG=/dev/shm/txlog.bin QPSK_TXLOG_USR1=1` in DAEMON_ENV_A and DAEMON_ENV_B (plus the per-board drain knob when requested). Confirm capture_r3.sh sets QPSK_FRAMELOG on legs (the SIGUSR2 handler is installed only inside the QPSK_FRAMELOG block, qpsk_tun.c ~:3266) and that its post-window SIGUSR1 (~:294) is what dumps the TX log — cite the lines in the header comment. Add a DRY assertion/test that the launch env contains both sink vars for both boards.

## I-1: nakstat abort gate is 148-only
deploy_daemon_go.sh:78-96 applies the `strings | grep -c nakstat == 4` gate to both boards. RULING: 148 only (precedent restore_known_good.sh:64). For 146 record the count in the meta as informational. In DRY mode do not hardcode NAKSTAT_N=4 for both; make the DRY value per-board so a test can catch a 146 abort regression.

## I-2: 17 of 26 tests skip without SENTINEL_STOP
The tests must exercise the DRY paths without the operator hold; only tests that genuinely touch the rig may skip. Restructure so DRY runs never need SENTINEL_STOP (DRY makes zero board contact by contract). Target: `python3 -m pytest two_jup/tests/test_comb_rig_scripts.py -q` runs ≥ 24 tests with 0 skips on this host, including a test that `RXM_148=8` alone yields RXM_A=8 and no RXM_B, and one for the sink vars.

## I-3: meta.txt truncation
ddrcap_during_leg_go.sh:73 and sel11_preflight_go.sh:142 use `>` and destroy ddrcap2_capture.sh's own provenance line. Use `>>` (append your block) and keep the original.

## Minors
Remove the no-op self-copy in sel11_preflight_go.sh; add a DRY-time cross-check that every entry in deploy_daemon_go.sh FILES exists in host_app_k5/ (fail loudly if not); note in deploy_daemon_go.sh header that -DQPSK_RXQ_STAT on both boards is intentional (plan T0a) and that the instrumented build trips restore_known_good.sh:65's rxqstat==0 rail by design.

Rails: DRY=1 only; ZERO board contact (no ssh to 10.0.0.146/148); the rig is live with the sentinel keeper running. Commit each logical fix with `git commit -s -- <paths>` and the trailer `Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq`. Do not push. Write the report to two_jup/sdd_archive/2026-09-03-comb/task-3-fix1-report.md and return only: commits, pytest one-line summary, concerns.
