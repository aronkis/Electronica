# Task 3 fix round 1 — re-review (1e82efd..51f0eba)

**Verdict: Needs fixes — one item.** All six requested checks pass; a seventh
defect surfaced that defeats both C-1 fixes at runtime.

## Blocking finding

**`two_jup/bringup_r2r3.sh:204` — the watchdog relaunch line silently reverts every
per-board knob and every T0a sink mid-leg.** `start_daemon()` (`:171-174`) now honours
`RXM_A/RXM_B`/`DAEMON_ENV_A/DAEMON_ENV_B` correctly, but 30 lines later the same script
launches `lock_watchdog.sh` with a hardcoded
`DAEMON_CMD="./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5"` — no `QPSK_FAILHDR`, no
`QPSK_TXLOG`, no `QPSK_TXLOG_USR1`, no `QPSK_RX_DRAIN_BUDGET`, no `QPSK_FRAMELOG`, no
`QPSK_RX_QUEUED`, and `-M 16` regardless of `RXM_A`. `lock_watchdog.sh:90-92`, `:155-157`
and `:181-187` relaunch `qpsk_tun` from that string on daemon death, lock loss, and DMA
wedge respectively. A single watchdog event during a T2 P1 leg therefore returns 148 to
`-M 16` and empties `failhdr.bin`/`txlog.bin` — with no signal in `meta.txt`, since
`legrun_go.sh`'s gate only reads deliver_rate. This is pre-existing (it clobbers
`QPSK_FRAMELOG` today too, and `WATCHDOG=1` is the default), but it is exactly the
durability half of the isolation property `legrun_go.sh:2-24` now asserts, and both of
this round's C-1 fixes depend on it. Fix: build `DAEMON_CMD` from `$RXM_EFF`/`$DENV_EFF`
(and `QPSK_FRAMELOG`/`RXQ`) at `:204`, or record watchdog restarts in the leg meta and
caveat the header. Not fixable in DRY; needs the owner of `bringup_r2r3.sh`.

## Requested checks — all pass

1. **Launch-line byte-identity.** Derived both strings mechanically for `$1=$A` and
   `$1=$B`, twice each (nothing set; legacy `RXM=32 DAEMON_ENV=… RXQ=0 QPSK_FRAMELOG=…
   DAEMON_EXTRA=-z`): `cmp` identical in all four. `${DENV_EFF}`≡`${DAEMON_ENV:-}` and
   `${RXM_EFF}`≡`${RXM:-16}` when no `_A`/`_B` is set; `DENV_EFF` is unconditionally
   assigned so `set -u` (`:42`) is safe. Mapping A=148/B=146 confirmed at
   `bringup_r2r3.sh:44` (`A=10.0.0.148; B=10.0.0.146`), matching `:184-185`
   (`start_daemon $B`, `start_daemon $A`). Environment reaches bringup via
   `capture_r3.sh:149` — `QPSK_FRAMELOG=/dev/shm/frames.bin "$D/bringup_r2r3.sh" r3` —
   a plain exec, no `env -i`, no `unset`; full inherited environment. Override
   isolation verified live: `RXM_A=8` alone → A gets `-M 8` + `DAEMON_ENV_A`, B gets
   `-M 16` and empty env.
2. **`legrun_go.sh`.** `:65-67` — `CAP_ENV` always carries `DAEMON_ENV_A`/`DAEMON_ENV_B`;
   `RXM_A`/`RXM_B` appended only when the corresponding `RXM_148`/`RXM_146` is non-empty.
   DRY run with `RXM_148=8` alone emits `RXM_A=8` and no `RXM_B`. `DRAIN_146=4` lands in
   `DENV_B` only (`:62`), `DRAIN_148` in `DENV_A` only (`:61`). `SINK_ENV` (`:59`) puts
   `QPSK_FAILHDR=/dev/shm/failhdr.bin QPSK_TXLOG=/dev/shm/txlog.bin QPSK_TXLOG_USR1=1`
   on both boards unconditionally — confirmed in both DRY runs. `resolve_pair` and
   `CANNOT_TARGET_PER_BOARD` are gone. Header cites check out: `capture_r3.sh:149` sets
   `QPSK_FRAMELOG`, and `qpsk_tun.c:3266`'s `signal(SIGUSR2,on_usr2)` is inside the
   `getenv("QPSK_FRAMELOG")` block opened at `:3257`; `QPSK_TXLOG_USR1` gates
   `txlog_on_usr1` (`:677`, `:3230`) which `instr_usr1_dump()` (`:771`) needs for
   `capture_r3.sh:294`'s `pkill -USR1`. `set -u` without `set -e`, so the
   `[ -n … ] && CAP_ENV+=(…)` idiom cannot abort the script.
3. **`deploy_daemon_go.sh`.** Gate scoped 148-only at `:107-113`; DRY `NAKSTAT_N` is
   per-board (`:81`: 4 for 148, 0 for 146). Live DRY: `BOARD=146` →
   `nakstat_strings=0 … informational only`, `gate_pass=1`, `DEPLOY_DAEMON_OK`;
   `BOARD=148` → `gate applies (BOARD=148)`. Precedent cite correct
   (`restore_known_good.sh:64` "(148 must be 4)", `:65` rxqstat==0). FILES cross-check
   at `:71-73` runs before anything else; all 12 entries present in `host_app_k5/`.
4. **meta.txt append.** `ddrcap_during_leg_go.sh:73` and `sel11_preflight_go.sh:144` both
   `>>`. Correct fix, not cosmetic: `ddrcap2_capture.sh:16` writes its provenance line
   with `>>` into the same `$OUT/meta.txt` and runs first. Verified by seeding a fake
   provenance line into `$OUT` and confirming it survives both wrappers.
5. **Tests.** `python3 -m pytest two_jup/tests/test_comb_rig_scripts.py -q` →
   **34 passed, 1 skipped in 10.30s** (the skip is `test_sentinel_present`, correctly
   gated on the absent operator hold). `_run()` no longer requires `SENTINEL_STOP`.
   Separately ran all five scripts in DRY myself.
6. **Zero board contact.** Ran `legrun_go.sh` (×2), `deploy_daemon_go.sh` (146 and 148),
   `ddrcap_during_leg_go.sh`, `sel11_preflight_go.sh` under a PATH shim for
   `ssh`/`scp`/`sshpass`: shim log never created. Structurally, every `anyssh.sh`/`scp`/
   `capture_r3.sh`/`ddrcap2_capture.sh` call sits in the `else` arm of a `[ "$DRY" = 1 ]`
   branch (`legrun_go.sh:84-96`, `deploy_daemon_go.sh:84-99`,
   `ddrcap_during_leg_go.sh:46-56`, `sel11_preflight_go.sh:65-75`). `bash -n` clean on
   all six touched scripts. No ssh to 10.0.0.146/148 at any point; nothing edited.

## Carried forward (not fixes)

The per-board plumbing has still only been exercised in DRY; the implementer flagged
this. The blocking finding above is the concrete reason a first live per-board leg must
be supervised, and the leg's `meta.txt` should be checked against
`/dev/shm/watchdog.log` on both boards before any T2 P1 result is believed.
