# Task 3 fix round 1 — comb rig scripts: implementer report

Fixed against `two_jup/sdd_archive/2026-09-03-comb/task-3-fix1-brief.md`, applying
the controller's rulings from `task-3-report.md`. DRY=1 only, zero board contact
throughout (no ssh to 10.0.0.146/148); no subagents dispatched; `host_app_k5/` not
touched (read-only, to verify FILES entries and qpsk_tun.c line references).

## Changes

### C-1 (critical): per-board `-M` / drain knobs
`two_jup/bringup_r2r3.sh`'s `start_daemon()` now accepts `RXM_A`/`RXM_B` and
`DAEMON_ENV_A`/`DAEMON_ENV_B` (A=148, B=146), resolved per-board immediately before
the launch line, exactly as specified in the brief. With none of the new vars set,
the launch line is byte-identical to before (verified by diff: only the resolution
block is new; the `$W $1 "..."` line itself is unchanged except for
`${DENV_EFF}`/`${RXM_EFF}` replacing `${DAEMON_ENV:-}`/`${RXM:-16}`, which are equal
to the old values when unset).

Confirmed `capture_r3.sh:149` (`QPSK_FRAMELOG=/dev/shm/frames.bin
"$D/bringup_r2r3.sh" r3`) is a plain exec of `bringup_r2r3.sh`, not a `source` — it
inherits the calling process's full environment, so `RXM_A`/`RXM_B`/
`DAEMON_ENV_A`/`DAEMON_ENV_B` set via `env "${CAP_ENV[@]}" "$TJ/capture_r3.sh" ...`
in `legrun_go.sh` reach `bringup_r2r3.sh` unchanged through both levels.

`legrun_go.sh` rewritten: `resolve_pair()` and the `CANNOT_TARGET_PER_BOARD` refusal
are gone. `RXM_148`→`RXM_A`, `RXM_146`→`RXM_B`; `DRAIN_148`/`DRAIN_146`→
`QPSK_RX_DRAIN_BUDGET=` inside `DAEMON_ENV_A`/`DAEMON_ENV_B` respectively. The header
comment's false single-sided-isolation claim is replaced with the true per-board
semantics and the confirmed capture_r3.sh/bringup_r2r3.sh pass-through chain.

### C-1 from Task 1 review: daemon sinks never enabled on legs
`legrun_go.sh` now always includes `QPSK_FAILHDR=/dev/shm/failhdr.bin
QPSK_TXLOG=/dev/shm/txlog.bin QPSK_TXLOG_USR1=1` in both `DAEMON_ENV_A` and
`DAEMON_ENV_B`, regardless of whether drain knobs are requested. Confirmed
`capture_r3.sh` sets `QPSK_FRAMELOG` (capture_r3.sh:149) and that the SIGUSR2
rotate handler is installed only inside the `QPSK_FRAMELOG` block
(`qpsk_tun.c:3266`); confirmed `capture_r3.sh`'s post-window SIGUSR1
(`capture_r3.sh:293`, "pull artifacts (flush the loggers first: SIGUSR1)") is what
dumps the TX log via `instr_usr1_dump()` (`qpsk_tun.c:771`), gated on
`QPSK_TXLOG_USR1` (`qpsk_tun.c:677,3230`) — hence that var, not just
`QPSK_FAILHDR`/`QPSK_TXLOG`, is mandatory in the sink set. Cited in the new header
comment.

### I-1: nakstat abort gate scoped to 148 only
`deploy_daemon_go.sh`'s abort gate now applies only when `BOARD=148`; `BOARD=146`
records `nakstat_strings=<n> (need 4; informational only (BOARD=146, gate is
148-only))` in meta.txt and always passes the gate. The DRY branch fabricates
`NAKSTAT_N=4` for 148 and `NAKSTAT_N=0` for 146 (no longer a shared hardcoded 4),
so a future regression that scopes the gate back to "both boards" is caught by
`test_deploy_daemon_nakstat_gate_is_148_only`.

### I-2: 17 of 26 tests skipped without SENTINEL_STOP
`_run()` in `test_comb_rig_scripts.py` no longer requires `SENTINEL_STOP` to run a
test — every test here forces `DRY=1` and makes zero board contact by construction,
so the operator's out-of-service marker was never a real precondition for these.
When the sentinel does exist, `_run()` still asserts its mtime is unchanged
pre/post (a genuine no-side-effects check). Only `test_sentinel_present` — a
rig-state assertion with no other subject — still skips when the hold is lifted.
Added `test_legrun_rxm_148_alone_yields_rxm_a_only_true_per_board_isolation`
(asserts `RXM_A=8` present and `RXM_B=` absent — the isolation Critical #1 was
about) and `test_legrun_launches_both_boards_with_sink_vars`.

Result: `python3 -m pytest two_jup/tests/test_comb_rig_scripts.py -q` →
**34 passed, 1 skipped** (up from 9 passed, 17 skipped).

### I-3: meta.txt truncation
`ddrcap_during_leg_go.sh` and `sel11_preflight_go.sh` now `>>` (append) their own
summary block instead of `>` (truncate), preserving `ddrcap2_capture.sh`'s own
provenance line. Covered by `test_ddrcap_during_leg_appends_not_truncates_meta` and
`test_sel11_preflight_preserves_preexisting_meta_line`, which pre-seed a fake
provenance line and assert it survives the wrapper's run.

### Minors
- `sel11_preflight_go.sh`'s no-op self-copy (`cp "$OUT/sel11_preflight.bin"
  "$CAPFILE"` where both paths were already identical) removed.
- `deploy_daemon_go.sh` now cross-checks every `FILES` entry exists under
  `host_app_k5/` before doing anything else (DRY or not), failing loudly
  (`DEPLOY_DAEMON_FAIL missing_source <f>`) instead of only at a real `scp`.
  Verified all 12 current entries exist.
- `deploy_daemon_go.sh`'s header now states `-DQPSK_RXQ_STAT` on both boards is
  intentional (plan T0a) and that a deployed instrumented build trips
  `restore_known_good.sh:65`'s `rxqstat==0` rail by design.

## Verification
- `python3 -m pytest two_jup/tests/test_comb_rig_scripts.py -q` → 34 passed, 1
  skipped (the skip is `test_sentinel_present`, correctly gated on the operator
  hold, which is not currently in place on this host).
- `bash -n` syntax check on all five touched scripts.
- Manual DRY=1 runs (PATH-shimmed `ssh`/`scp`, shim log inspected after) of
  `legrun_go.sh` (LEG=A, RXM_148=8, RXM_146=32, DRAIN_148=1 — confirms both boards
  now get distinct values, sink vars appear for both `DAEMON_ENV_A`/`DAEMON_ENV_B`),
  `deploy_daemon_go.sh` (BOARD=146 and BOARD=148, confirms the nakstat gate scoping),
  `ddrcap_during_leg_go.sh` (SEL=9), and `sel11_preflight_go.sh` — shim log was
  empty/absent in every case, confirming zero board contact.
- `bringup_r2r3.sh` has no DRY gate of its own (out of scope to exercise live); only
  syntax-checked, plus a manual diff review confirming the launch line is
  unchanged when no `_A`/`_B` override is set.

## Concerns
- `bringup_r2r3.sh` and `capture_r3.sh` remain owned by other tasks; this fix
  round only added the additive, backward-compatible override hooks the brief
  specified. A live T2 P1 run should still be supervised the first time, per the
  original review's "not blocked but needs an explicit confirmation" tone around
  `-DQPSK_RXQ_STAT` and the nakstat gate.
- The T2 P1/P2 per-board plumbing is now exercised only in DRY mode; the first
  real leg with `RXM_148`≠`RXM_146` (or a drain-budget split) has not been run
  against real boards under this fix round, per the hard rails (zero board
  contact). Confirm on the rig before trusting a real per-board comb result.
- SENTINEL_STOP was absent throughout this session (rig out-of-hold as of
  2026-09-03), so the sentinel-mtime-unchanged assertion in `_run()` was never
  actually exercised against a live sentinel file during this fix round's test
  runs — it only ran the `pre is None` branch. The assertion logic itself is
  simple enough (`stat` before/after) that this is low risk, but it is untested
  against a real sentinel in this session.

Claude-Session: https://claude.ai/code/session_019NZLGbxoaPRkDnKFMPiBrq
