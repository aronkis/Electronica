# Task 3 (T0c) review — COMB campaign rig scripts

Reviewed against: `/home/tcollins/.claude/plans/happy-bubbling-owl.md` (T0c, T1-T3,
Corrections P1/P2, Risks). Read-only review, no board contact, no subagents.
Pinned at commit `010dd9ba370e10390f8cf83bb081ef141cdef5a5`
(scripts land in `c8da5d7`, ledger update `6b0561b`); the six reviewed files are
git-clean at that commit (md5s below). **Note:** `deploy_daemon_go.sh` and
`host_app_k5/` mutated on disk mid-review (a concurrent T0a/T0c edit added
`qpsk_join.h` to both the source tree and the `FILES` list) — findings below are
against the state as of this pin; re-verify `deploy_daemon_go.sh` if it changes again.
The implementer's own delivery report was moved to
`task-3-implementer-report.md` (this review needed the mandated report path).

```
8f4e341be069a5b7d0a95709400de58d  ddrcap_during_leg_go.sh
9b9cdd53aaac17ac133f604d8136ee19  deploy_daemon_go.sh
11e79e75ec39a2cbbffa644fac0cebf5  keeper_hold.sh
a8f2f2b6978d296cd175bcf11e8ab7b6  legrun_go.sh
8a8011ce7c0339a0bedffa00bb5baf45  loopfloor_go.sh
9e38181119673a89c3c65c8ca0a24084  sel11_preflight_go.sh
```

`python3 -m pytest two_jup/tests/test_comb_rig_scripts.py -q` → **9 passed, 17 skipped**
(SENTINEL_STOP absent on this host at run time — see Issues, Important #1).

## ### Spec Compliance
- ⚠️ **T0c deliverables present, DRY-safe, mostly faithful to their named sources —
  but the campaign's central T2 probe (per-board `-M`) cannot be run as the plan and
  the script's own launch lines describe.** One false safety claim in `legrun_go.sh`'s
  header, one board-scoping gap in `deploy_daemon_go.sh`, real but currently-untested
  coverage gaps. Items 1, 5, 6 check out; item 3 (loopfloor fidelity) verified
  byte-for-byte against `loopchk_run.sh`; item 2 (deploy_daemon flags) is right for
  `-DQPSK_RXQ_STAT` but wrong for the nakstat abort scope; item 4 is the critical
  finding.

## ### Strengths
- `keeper_hold.sh` (item 1): creates SENTINEL_STOP/RIG_LOCK only if absent, marks
  exactly what it created (`HOLD_MARK`), removes only that on release, uses the
  bracket pkill pattern (`pkill -9 -f "[l]ock_watchdog"`, verified by
  `test_keeper_hold_uses_bracket_pkill_pattern`), and relaunches the keeper via
  `launch_rig_unit.sh` (not a bare `systemd-run`) on release. The "never kill a
  bring-up mid-arm" claim holds: `bringup_r2r3.sh`'s `arm_rom()` already pkills
  `lock_watchdog` itself before every arm (confirmed at `bringup_r2r3.sh:61-66`), so
  `keeper_hold.sh`'s own watchdog kill is idempotent with bring-up and touches nothing
  arm-related. Verified live against the running rig (read-only `systemctl --user
  list-units`, no state change): `sentinel-153110.service` and
  `sentinelkeeper-152910.service` are both currently running and match the
  `sentinel-*`/`sentinelkeeper-*` glob `keeper_hold.sh` stops.
- `loopfloor_go.sh` (item 3): `arm_loop_real` and `rdc_real` are byte-for-byte copies
  of `loopchk_run.sh`'s `arm_loop()`/`rdc()` (same double-tap register sequence,
  same TXD discovery, same delays); the restore step (`pkill -x qpsk_tun; sleep 1`)
  matches Test A's close in `loopchk_run.sh`. Scoring in 10 s windows (not one 600 s
  aggregate) correctly implements the P1 correction. SIGUSR1 flush precedes artifact
  fetch. The UNINFORMATIVE checklist (0x104 delta, rate vs 1245 f/s, window <150 s,
  re-arms in-window) is present and its short-window branch is exercised by
  `test_loopfloor_short_window_is_uninformative`.
- `ddrcap_during_leg_go.sh` / `sel11_preflight_go.sh` (items 5, 6): credit predicate
  (`bytes>=536870912` AND pre+post capTAP golden `BCF94856`) matches
  `ddrcap2_capture.sh`'s own default arithmetic (`SZ=134217728` samples × 4 B =
  536870912 B) and abort behavior exactly; neither script arms anything. sel11's 8 MiB
  `SZ=2097152` arithmetic is correct, and the bit-domain reconstruction (I = packed
  16-bit MSB-first word per record, Q=0 for sel≥9) matches the RTL patch in
  `two_jup/skidfix/ddrcap_inject.py` (`ddrcap_bitword <= {ddrcap_bitpack[14:0],
  ddrcap_bitsel_bit}`, `assign ddrcap_i = ... : ddrcap_bitword`, `assign ddrcap_q = ...
  : 16'sd0`) and the record layout / `mark_fec` = ch2 bit14 matches the canonical
  decoder `two_jup/ddrcap2_decode.py:11-15`.
- Test harness design (item 7, partially — see Issues): the PATH-shim design is sound.
  `anyssh.sh` and every script's `SCPPUT`/`$W` call `ssh`/`scp` unqualified (never an
  absolute path), so the shim genuinely intercepts every path that could reach the
  network; the harness checks the shim log (not the script's own `[dry]` print) as the
  proof, which is the right adversarial posture.
- `keeper_hold.sh`'s two-axis DRY design (`FILE_DRY` vs `NET_DRY`) lets the test suite
  exercise real hold-file create/remove/leave-alone logic on temp paths while
  `NET_DRY` stays permanently pinned to 1 in every test — no test can accidentally
  flip a real systemctl/ssh action.

## ### Issues

### Critical
1. **`legrun_go.sh` cannot run the plan's T2 P1 probe as designed, and its own header
   asserts a false safety property.** `bringup_r2r3.sh:167,177-178` reads `-M
   ${RXM:-16}` and `${DAEMON_ENV:-}` from ONE shared shell env and splices the SAME
   value into `start_daemon $B` (146) and `start_daemon $A` (148) — there is no board
   scoping for either knob (contrast `CYC`/`RXCYC_A`, which the same function DOES
   board-scope two lines above, at `bringup_r2r3.sh:156-158` — a working in-pattern
   precedent this script did not use). `legrun_go.sh`'s `resolve_pair()`
   (`legrun_go.sh:52-63`) maps a single-sided knob (e.g. `RXM_148=8`, `RXM_146` unset)
   straight onto the one global `RXM`, and the header comment claims this is "correct,
   because the unset side just gets the bring-up default (RXM 16 ...), which is what
   it already gets today" (`legrun_go.sh:14-17`). That is false and self-contradicts
   the CONCERN paragraph three lines above it (`legrun_go.sh:6-11`, which correctly
   diagnoses the shared-env problem): `RXM_148=8` sets **both** boards to `-M 8`, not
   148 only. The report's own T2 launch lines
   (`two_jup/launch_rig_unit.sh legrun-T2-M8 ... RXM_148=8 TAG=M8`) will run exactly
   this confounded case. Concretely, what T2 **can** test with this script: whether
   the comb is `-M`-locked at all (both boards moved together; if the lag doesn't
   move, nothing here is `-M`-locked — the plan's stated falsifier survives). What it
   **cannot** test: which board's cadence drives the lag, because the TX board's own
   RX-drain cadence and the RX (peer) board's queue depth change simultaneously. The
   plan's P1 as literally written ("148 `-M 8` vs `-M 16`" with 146 implied to stay at
   its bring-up default) cannot be run with this script without a
   `bringup_r2r3.sh`/`capture_r3.sh` change (out of scope here, but the fix is cheap
   and in-pattern: add `RXM_A`/`RXM_B` and a board-scoped `DAEMON_ENV_A/_B`, following
   the existing `RXCYC`/`RXCYC_A` split). Same defect applies to the P2 drain-budget
   probe (`DRAIN_148`/`DRAIN_146`) via the same `DAEMON_ENV` path. Before any T2 run,
   either fix the header claim to state the true (joint) semantics and re-scope the
   report's launch lines to match, or extend `bringup_r2r3.sh` for real per-board
   control.

### Important
2. **`deploy_daemon_go.sh`'s nakstat abort gate is not scoped to 148, contrary to the
   plan and to precedent.** The plan says "aborts unless nakstat==4 **on 148**", and
   `restore_known_good.sh:64` annotates the same check "(148 must be 4)" — every other
   precedent in the repo (`soak_run.sh:19`, `restore_known_good.sh:64`) treats
   `nakstat==4` as a 148-specific fingerprint; 146 is not expected to carry it.
   `deploy_daemon_go.sh`'s abort gate (`NAKSTAT_OK`, applied unconditionally at the
   end of the script) fires for BOTH boards regardless of `$BOARD`. Whether this
   actually blocks a real `BOARD=146` deploy depends on what 146's currently-deployed
   binary carries (unverifiable without board contact), so impact is not certain — but
   the DRY path hardcodes `NAKSTAT_N=4` for every board (`deploy_daemon_go.sh`, DRY
   branch), so no test can catch a false abort on 146, and the report's own launch
   line (`deploy-146 ... BOARD=146 FLAGS=`) is untested against this gate. Fix:
   `[ "$BOARD" = 148 ] && { [ "$NAKSTAT_N" = 4 ] || abort; }`; log-only (no abort) on
   146.
3. **Test coverage is gated on an unrelated operator marker.** Every `_run`-based test
   (i.e. every test that actually executes a script and inspects the network-shim log)
   requires `SENTINEL_STOP` to exist first (`test_comb_rig_scripts.py:56-64`,
   `_require_sentinel()`), a convention borrowed from `test_txfix_rig_scripts.py`. On
   this host right now, that gate skips 17 of 26 tests, including the ones that would
   most directly test today's findings:
   `test_legrun_single_sided_knob_resolves_and_gates`,
   `test_keeper_hold_creates_only_absent_files_and_release_removes_only_those`,
   `test_deploy_daemon_dry_ok_and_nakstat_gate`. `python3 -m pytest ... -q` →
   **9 passed, 17 skipped** at review time. Item 7 ("do the tests prove zero network
   calls and the hold-file logic") is only true when SENTINEL_STOP happens to be
   present; as configured, a routine CI/local run without an active operator hold
   proves the network-hygiene claim for barely a third of the suite. Note also that
   `test_legrun_single_sided_knob_resolves_and_gates` only asserts `resolved: RXM=8`
   in `meta.txt` — even when it runs, it does not (and cannot, from meta.txt alone)
   catch Critical #1, since the resolved-value string is identical whether the value
   reaches one board or both.
4. **`ddrcap_during_leg_go.sh` and `sel11_preflight_go.sh` destroy
   `ddrcap2_capture.sh`'s own provenance line in `meta.txt`.** `ddrcap2_capture.sh`
   appends (`>>`) its `<name> sel=<n> bytes=<b> pre=<p> post=<q>` line to
   `$OUT/meta.txt`; both wrappers then write their own summary block with `>
   "$OUT/meta.txt"` (truncating), so the underlying capture's own logged line is gone
   by the time the run finishes. The wrapper's own meta.txt recomputes the same
   fields, so no information is actually lost today, but a campaign whose rails
   explicitly want "meta with image md5, daemon md5, string counts" per run should not
   be silently clobbering a sibling tool's own provenance record — append, don't
   truncate, or write to a separate file.

### Minor
5. `sel11_preflight_go.sh`'s `DRY=0` branch does `cp "$OUT/sel11_preflight.bin"
   "$CAPFILE"` where `CAPFILE` is already `"$OUT/sel11_preflight.bin"` — a no-op
   self-copy, silently discarded by `2>/dev/null`. Harmless (the file is already at
   the right path because `ddrcap2_capture.sh` was invoked with matching `OUT`/`NAME`
   env), but it is dead code and, per the implementer's own report, evidence the
   `DRY=0` path was never traced end to end (no real capture exists yet to test it
   against).
6. `deploy_daemon_go.sh` applies `-DQPSK_RXQ_STAT` to both boards unconditionally,
   whereas `capture_r3.sh:~123` deliberately scopes that flag to board B (146) only,
   with an explicit comment that "board A (148) must rebuild to a functionally
   untouched binary." The plan does bless this ("compile -DQPSK_RXQ_STAT" for the
   T0a-instrumented build, and separately "deployed instrumented builds fail
   `restore_known_good.sh:65`'s rxqstat==0 rail by design"), so this is very likely
   intentional for this campaign rather than a bug — but it is a real deviation from
   the existing safe-build pattern and is worth an explicit operator confirmation
   before the first real 148 deploy, alongside the nakstat point above (#2).
7. `deploy_daemon_go.sh`'s `FILES` list changed on disk mid-review (a `qpsk_join.h`
   entry was added, matching a same-time addition to `host_app_k5/`). At the moment
   of this review both are in sync, but the DRY path only *logs* `scp` lines — it
   never stats a local source file — so a future desync (an entry added to `FILES`
   before the corresponding source lands, or vice versa) would pass every DRY test and
   only fail for real at `DRY=0` (`scp` exits nonzero, script exits 1 — not silent,
   but only caught on the real board). Not a fix, just a note that this file list has
   no DRY-time cross-check against `host_app_k5/`'s actual contents.

## ### Assessment
**Task quality: Needs fixes.**

**Reasoning.** Five of the six scripts (`keeper_hold.sh`, `loopfloor_go.sh`,
`ddrcap_during_leg_go.sh`, `sel11_preflight_go.sh`, and `deploy_daemon_go.sh`'s
`-DQPSK_RXQ_STAT`/file-list handling) hold up well under source-level verification —
faithful reproduction of `loopchk_run.sh`'s arm/measure/restore sequence, correct
DDRCAP credit and bit-packing arithmetic cross-checked against the RTL patch and
canonical decoder, sound hold-file bookkeeping, and a genuinely adversarial DRY/shim
test design. But `legrun_go.sh` — the script that runs the campaign's central T2
host-cadence probe, on both boards, for up to 60 rig-minutes — asserts a false
per-board isolation property in its own header and cannot run the plan's stated P1
experiment ("148 `-M 8` vs `-M 16`") as designed: `RXM`/`DAEMON_ENV` are single global
variables read once by `bringup_r2r3.sh` and applied identically to both
`start_daemon` calls, so a "148-only" knob change actually changes both boards. This
would not surface from the DRY-only development path used here (DRY never invokes
`bringup_r2r3.sh`, and the one test that exercises single-sided resolution only checks
the resolved string, not which board it reaches) — it only surfaces from reading
`bringup_r2r3.sh:145-178` directly, which is exactly the kind of thing a rig-facing
review needs to catch before real time is spent on a confounded T2 leg. Fix the header
claim (or the underlying knob plumbing) and re-scope `deploy_daemon_go.sh`'s nakstat
abort to 148 before either script is run with `DRY=0`; the remaining Important/Minor
items are worth fixing but do not block a first supervised T1 (loopback-only, no
per-board knobs, 148-only) run.
