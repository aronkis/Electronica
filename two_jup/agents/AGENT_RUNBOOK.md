# Worker agent runbook

You are a ONE-SHOT worker. Run your cycle once, report, exit. Do not iterate;
a second attempt is a fresh agent dispatched by the governor.

## Absolute rules
1. Board 148 only. **146 is never flashed or touched.**
2. **No retry loop.** A flash that fails after touching the board: roll back,
   `rig_halt_set "<agent>: flash failed"`, release, report, exit.
3. **Positive control before any null.** If your witness has not been shown to
   produce a non-null, you may not report a null. Report WITNESS-DEAD instead.
4. Never steal a stale rig lock. Report it and exit.
5. Source-only resynth. No BD changes, no MATLAB regeneration.

## Cycle
```bash
. two_jup/agents/rigmutex.sh
. two_jup/agents/agentstate.sh
agent_state_init "<AGENT>" "<host>" "<blocks>"; agent_state_flush
```
1. **Design** the instrument: bounded capture, armed by a frame marker, scored
   by golden-constancy. No rolling signatures. No on-chip reference latch --
   the frame-8 reference latches during acquisition and is a bad baseline.
2. **Sim-gate**: Verilator, clean loopback, every witness frame-invariant.
   Fail => `agent_state_step 2 fail`, report, exit. No flash.
3. **Positive control in sim**: force a non-null. Fail => report, exit. No rig.
4. **Acquire**: `rig_acquire "<AGENT>" 5400` -- 0 ok, 2 halted, 3 timeout,
   4 stale (report, exit). Set `rig_held true`, heartbeat every 60 s.
5. **Flash** via `two_jup/skidfix/flash_148_stagesig.sh` with an **absolute**
   `BB` path and `BAK_MD5` = the image currently on 148. Full rails.
6. **Positive control on silicon** before the real measurement.
7. **Measure**, then restore: `RXM=16 RXQ=1 GATE_TRIES=12 two_jup/bringup_r2r3.sh r3`,
   restart both watchdogs, then `rig_release`.
8. **Report**: for each block -- status (UNTESTED / INSTRUMENTED / WITNESS-DEAD /
   MEASURED-CLEAN / MEASURED-DEVIATES), provenance ([SILICON] / [SIM] / [INFERRED]),
   run directory, whether the positive control passed, and the numbers.

## Report format (return this verbatim as your final message)
```
AGENT: <name>
BLOCKS: <comma-separated>
POSITIVE_CONTROL_SIM: pass|fail  <evidence>
POSITIVE_CONTROL_SILICON: pass|fail|n/a  <evidence>
FLASH: none|md5 <md5>  RAILS: green|rolled-back
RESULTS:
  <block>: <status> <provenance> quiet=<x>% burst=<y>% run=<dir>
RIG: released|halted
NOTES: <anything the governor must know>
```

## Operational hazards (learned the expensive way -- read before touching the rig)

These four are not optional and are not covered above; each one has already
cost a run today.

1. **Never let off-rig test/probe output land in `/home/tcollins/modem-status/agents/`
   (the default `RIG_DIR`'s `agents/` dir used by `agentstate.sh`).** A stray
   fragment there does **not** halt the rig -- `sweep.sh`'s halt decision is
   structural and reads `$RIG_DIR/RIG_MUTEX.d` directly, never a fragment.
   What a stray fragment actually does: it can produce false
   `SWEEP_ALERT stale-no-rig` / `unreadable-fragment` alerts, which can make
   the governor believe an agent died and requeue its work.
   Remedy, scoped narrowly: for **off-rig work only** -- unit tests, harness
   development, anything that never touches board 148 -- point it at a temp
   `RIG_DIR` instead: `export RIG_DIR=$(mktemp -d)` **before** sourcing
   `rigmutex.sh` or `agentstate.sh` (both read `RIG_DIR` at source time via
   `${RIG_DIR:-/home/tcollins/modem-status}`, so setting it after sourcing is
   too late).
   **Never export a temp `RIG_DIR` in the shell that runs the real
   Acquire/Flash/Measure cycle (steps 4-7).** That cycle must use the default
   `RIG_DIR`. If you set a temp `RIG_DIR` for off-rig work earlier in this
   session, start a fresh shell before step 4. Violating this is silent and
   dangerous: `rig_acquire` will `mkdir` a mutex inside your private temp
   directory and always return 0, so you will believe you hold the real rig
   while `sweep.sh` -- which only inspects the real `RIG_DIR` -- sees nothing.
   A second agent in this state can flash board 148 concurrently with zero
   mutual exclusion.
2. **Write `iq_debug_mux` (0x10C) and every other AXI write register *after*
   the `0x000` soft reset, never before.** The soft reset clears the write
   registers, so a pre-reset write is silently wiped. One earlier run
   believed it was measuring tap 3 while it was actually sitting on tap 0 for
   its entire duration.
3. **Never rely on `flash_148_stagesig.sh`'s default `BAK_MD5`.** The script
   defaults to `BAK_MD5=786dce9fafc8`, which goes stale as soon as 148's
   image changes -- an agent trusting the default hits the script's
   `CUR = BAK_MD5` precondition and gets refused (safe, but a wasted rig
   hold). Before step 5, query the live value on-board and pass it
   explicitly:
   `two_jup/anyssh.sh 10.0.0.148 'md5sum /boot/BOOT.BIN | cut -c1-12'`
   then invoke the flash script with `BAK_MD5=<that value>`. Also pass `BB`
   as an **absolute** path -- a relative one has already caused a
   precondition refusal.
4. **Run the cycle under bash, not sh or another shell.** `agentstate.sh`
   uses bash arrays; sourcing it from a non-bash shell silently yields empty
   values with no error.
5. **Rig ownership is a random session token (`RIG_TOKEN`), not a PID.**
   `rig_acquire` exports `RIG_TOKEN`; `rig_release` returns 1 on token
   mismatch. Acquire and release must happen in the same shell process (or
   its children) -- do not hand off a held rig across shells. `sweep.sh` runs
   every 10 minutes and halts the rig if the holder's heartbeat goes stale,
   so call `rig_heartbeat` at least every 60 s for the entire time you hold
   the rig (step 4 onward).

## Positive-control gating (which field the governor trusts)

`POSITIVE_CONTROL_SIM` and `POSITIVE_CONTROL_SILICON` are both `pass|fail|n/a`
strings, but only one of them may gate a `MEASURED-*` status, and it is not
the sim one:

- **`POSITIVE_CONTROL_SILICON` is the field that gates any `MEASURED-*`
  status.** A sim-only pass is never sufficient on its own -- it clears you
  to touch the board (steps 4-5), nothing more.
- If the silicon positive control did not run, or ran and did not pass, the
  correct status for that block is **`WITNESS-DEAD`**, never a `MEASURED-*`
  status, regardless of what `POSITIVE_CONTROL_SIM` says.
- The governor (`chainctl.set_block`) converts `POSITIVE_CONTROL_SILICON`
  literally: `pass` -> `True`, anything else (`fail`, `n/a`) -> `False`. Do
  not report `pass` for `POSITIVE_CONTROL_SILICON` unless the on-silicon
  positive control in step 6 actually ran and actually produced a non-null.
