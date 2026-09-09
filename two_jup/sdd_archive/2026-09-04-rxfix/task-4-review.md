# Task 4 (T0d) review — dashboard + agent watch

## Verdict: PASS (one minor gap, no blocker)

## Findings
1. **Agent flag logic (agent_watch.py:agent_rows)** matches spec exactly: ON-TASK
   when `age_min <= stale_min` OR a matching rig unit is running; STALE otherwise;
   terminal (`complete`) tasks excluded via `TERMINAL_STATUSES`/`continue`. `parse_iso`
   uses `datetime.fromisoformat`, which under the deployed Python 3.12 parses both
   `...-04:00` and `...Z` correctly (verified directly: both round-trip to aware
   datetimes). Not independently unit-tested for the `Z` form in
   `test_agent_watch.py` (only `-04:00`-style timestamps appear) — a latent gap if
   ever run under Python < 3.11, where `fromisoformat` rejects `Z`.
2. `python3 two_jup/agents/render_pipeline.py` ran clean; output HTML has the
   `Agents (5-min heartbeat check)` table, the `Rig legs (COMB campaign)` SVG block,
   and the `<h2>Rig</h2>` hold/md5 + sentinel-tail block, plus unmodified task
   tables for the older seqbist/comb/txfix ledgers (diff confirms `plan_tasks`/
   `ledger_state`/rulings/legs loop untouched, only re-imported from `agent_watch`).
3. Systemd units: `render-pipeline.timer`/`.service` and `stall-detector.service`
   all have `WorkingDirectory=/mnt/onetb/scratch/qpsk-jupiter-modem`,
   `OnUnitActiveSec=5min`, both `enabled` (confirmed via `systemctl --user
   list-timers`/`is-enabled`), and `stall-detector.service` sets
   `Environment=STALL_STALE_MIN=5`. Runtime journal shows both exiting
   `status=0/SUCCESS` on schedule. **No unit sets `Environment=PATH=...`** — the
   scripts call bare `systemctl`/`git` via subprocess, relying on systemd's default
   user-manager PATH. This matches the pre-existing `pipeline-dash.service`/old
   `stall-detector.service` convention (not a regression), and both units run
   successfully in practice, but it does not satisfy a literal "PATH set" reading
   of the brief.
4. `agent_digest.sh` output format matches the brief exactly:
   `task<N> hb_age=<min> unit=<running unit or -> last=<state text <=80 chars>
   flag=<ON-TASK|STALE>`, sourced from `digest_lines()` which skips PENDING tasks.
   A task with no heartbeat and no running unit correctly falls through to STALE
   (or ON-TASK if a unit happens to be running) rather than crashing.
5. Tests: `python3 -m pytest two_jup/tests/test_agent_watch.py
   two_jup/tests/test_seqbist_tools.py two_jup/tests/test_comb_rig_scripts.py -q`
   → 96 passed, 1 skipped (skip is a pre-existing/unrelated `kasa` plugin import,
   not from this change). No regression from the `plan_tasks`/`ledger_state`
   parser move to `agent_watch.py`.

## Not checked (read-only per brief)
No board contact made; no files edited.
