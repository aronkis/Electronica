# Task 4 (T0d) report — LAN dashboard + 5-minute agent checks

## Deliverables
1. `render-pipeline.timer`/`.service` (systemd --user, `OnUnitActiveSec=5min`,
   `WorkingDirectory=/mnt/onetb/scratch/qpsk-jupiter-modem`), installed to
   `~/.config/systemd/user/`, `daemon-reload`d, `enable --now`. The existing
   `pipeline-dash.timer` (30 min, render-on-ledger-event pattern) is left in place —
   not asked to be removed, and both writes to `~/modem-status/pipeline.html` are
   harmless (atomic `os.replace`).
2. `two_jup/agents/render_pipeline.py`:
   - moved `plan_tasks`/`ledger_state` into the new shared module `agent_watch.py`
     (re-exported from `render_pipeline` for back-compat with existing imports/tests).
   - new "Agents" block near the top: one row per task in the newest ledger *and*
     the previous one with a non-terminal status — campaign, task id, title, ledger
     status, last heartbeat time/age, last action, and an ON-TASK / STALE / PENDING
     flag. A task never heartbeated with ledger status `pending` shows PENDING, not
     STALE (a naive age-only rule would falsely flag every not-yet-started task).
     STALE = heartbeat age > 5 min AND no matching rig unit active
     (`systemctl --user list-units`, matched by a `T<N>` token or `task<N>` in the
     unit name).
   - extended "Rig" section: hold-file presence (`SENTINEL_STOP`, `RIG_LOCK`) +
     per-board image md5 via text lookup in `two_jup/RXFIX_STATE.md` (falls back to
     `SEQBIST_STATE.md`, since RXFIX_STATE.md doesn't exist yet; degrades to
     "unknown" rather than raising) + the existing sentinel log tail.
   - page `<title>`/`<h1>` now show the newest campaign name (`2026-09-04-rxfix`,
     from the newest ledger's directory basename).
3. `two_jup/agents/stall_detector.py`: `HEARTBEAT_STALE_MIN` resolved at call time
   from env `STALL_STALE_MIN` (fallback 25 for callers that don't set it, so the
   existing tests are unaffected); `DEFAULT_SDD_ROOT` repointed at
   `2026-09-04-rxfix`. `stall-detector.service` now sets `Environment=STALL_STALE_MIN=5`
   for this campaign; its timer was already 5 min.
4. `two_jup/agents/agent_digest.sh`: thin wrapper over `agent_watch.py --digest`,
   prints `task<N> hb_age=<min> unit=<running unit or -> last=<state text ≤80 chars>
   flag=<ON-TASK|STALE>` for the newest ledger's active (non-pending) tasks —
   the controller's 5-minute Monitor input.
5. `two_jup/tests/test_agent_watch.py` (16 tests): ledger/heartbeat/unit parsers,
   the STALE-vs-ON-TASK-vs-PENDING gating, `agent_digest.sh` end to end, and
   `render_pipeline.render()` on a synthetic ledger.

## Verify
- `systemctl --user list-timers --all` shows `render-pipeline.timer` next in ~5 min
  and `stall-detector.timer` next in ~5 min (confirmed).
- `curl -s http://10.0.0.71:8090/pipeline.html | grep Agents` → `Agents (5-min
  heartbeat check)` present (confirmed against the live rendered page).
- `python3 -m pytest two_jup/tests/test_agent_watch.py two_jup/tests/test_render_pipeline.py two_jup/tests/test_stall_detector.py -q` → 24 passed.

No board contact, no subagents, no push.
