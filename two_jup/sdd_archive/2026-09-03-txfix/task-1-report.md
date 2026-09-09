# Task 1 (T4 monitoring) report

## Files delivered
- `two_jup/agents/watch_unit.sh` -- controller-side per-unit watcher (own `systemd-run --user` unit
  via `--spawn`); appends `UNITEXIT <unit> result=<Result> code=<ExecMainStatus> at=<ISO8601>` to the
  ledger and touches `~/modem-status/NOTIFY/<unit>.done` when the watched unit stops being `is-active`;
  120 s appearance wait -> `result=missing` if the unit never shows up.
- `two_jup/agents/stall_detector.py` -- reads `lanes.json` (unit active + log-mtime staleness) and scans
  every `progress.md` under `two_jup/sdd_archive/2026-09-03-txfix/` for `HEARTBEAT <agent> <ISO8601>`
  lines vs. the agent's last `Task N: <status>` line; writes de-duplicated `STALL`/`CLEAR` lines to the
  relevant ledger and the full current set (with timestamps) to `~/modem-status/stalls.json`; reports
  `~/modem-status/NOTIFY/*.done`.
- `two_jup/agents/lanes.json` -- `[]` (empty; lane agents populate it).
- `two_jup/agents/stall-detector.service` + `.timer` -- installed and enabled as **user** units
  (`~/.config/systemd/user/`, `systemctl --user enable --now`), `OnBootSec=2min OnUnitActiveSec=5min`,
  modelled on `pipeline-dash.{service,timer}` (untouched).
- `two_jup/agents/render_pipeline.py` -- new "Lanes / stalls" block (lane rows with `is-active` state +
  log age, `stalls.json` contents, `NOTIFY/*.done` list), inserted near the top right after "Next
  steps"; `render()`/`lanes_block()` take `is_active`/`stalls_path`/`notify_dir` params so tests don't
  touch the live host. Existing `Task N:` parser/tests untouched.
- `two_jup/tests/test_stall_detector.py` (5 tests), `two_jup/tests/test_render_pipeline.py` (+2 tests,
  2 pre-existing kept green) -- 9/9 pass.
- `two_jup/NEXT_STEPS.md` -- new "TXFIX campaign running" block at the top.

## Commands / evidence

Tests:
```
python3 -m pytest two_jup/tests/test_render_pipeline.py two_jup/tests/test_stall_detector.py -q
adi_lg_plugins: driver 'kasadriver' not registered (No module named 'kasa')
.........                                                                [100%]
9 passed in 1.28s
```

Units installed:
```
systemctl --user enable --now stall-detector.timer
Created symlink /home/tcollins/.config/systemd/user/timers.target.wants/stall-detector.timer -> ...
systemctl --user list-timers stall-detector.timer --no-pager
NEXT LEFT LAST                          PASSED UNIT                 ACTIVATES
-       - Thu 2026-09-03 10:01:30 EDT 32ms ago stall-detector.timer stall-detector.service
```
Manual oneshot run against the real (empty) lanes.json:
```
systemctl --user start stall-detector.service
journalctl --user -u stall-detector.service --no-pager -n 3
Sep 03 10:01:33 nemo python3[4068123]: STALL_DETECTOR active=0 new=0 cleared=0 notify_pending=0
```

## Live self-test proof (2026-09-03, 10:03-10:06)

1. Throwaway transient unit:
```
systemd-run --user --unit=txfix-selftest-1788444191 sleep 200
```
2. Spawn watcher (absolute script + ledger paths):
```
bash two_jup/agents/watch_unit.sh --spawn txfix-selftest-1788444191 \
  two_jup/sdd_archive/2026-09-03-txfix/progress.md
Running as unit: watch-txfix-selftest-1788444191.service ...
systemctl --user -q is-active watch-txfix-selftest-1788444191   -> active
```
3. Registered in `lanes.json` with a stale (touch -d '5 minutes ago') log and `max_age_min: 1`,
   ran the detector by hand:
```
python3 two_jup/agents/stall_detector.py
STALL_DETECTOR active=1 new=1 cleared=0 notify_pending=0
  NEW: lane:selftest age=5.1
```
   Ledger line: `STALL lane=selftest age=5.1 at=2026-09-03T10:03:27-04:00`
   `stalls.json`: one record, `"key": "lane:selftest"`.
4. Ran the detector a second time with the log still stale -- **no duplicate**:
```
python3 two_jup/agents/stall_detector.py
STALL_DETECTOR active=1 new=0 cleared=0 notify_pending=0
grep -c "STALL lane=selftest" progress.md   -> 1
```
5. Waited for the `sleep 200` unit to exit and the 30 s watcher poll to catch it:
```
UNITEXIT txfix-selftest-1788444191 result=success code=0 at=2026-09-03T10:06:50-04:00
```
   `~/modem-status/NOTIFY/txfix-selftest-1788444191.done` present (0-byte, confirmed via `ls -la` and
   direct read).
6. Set `lanes.json` back to `[]`; the automatic `stall-detector.timer` firing (OnBootSec=2min) had
   already cleared the lane by 10:06:36 -- ledger line `CLEAR lane=selftest at=2026-09-03T10:06:36-04:00`
   confirms the timer path independently of the manual-run path. Re-ran the detector once more by hand
   after clearing `lanes.json`: `cleared=0` (already clean), `stalls.json` -> `[]`.
7. Cleanup: removed the test `.done` file, confirmed the transient `txfix-selftest-*` and
   `watch-txfix-selftest-*` units were already collected (`--collect`), `stall_detector.py` now reports
   `active=0 new=0 cleared=0 notify_pending=0`. `lanes.json` left as `[]` for the lane agents.

## Commits
- `1d13466` -- watch_unit.sh, stall_detector.py, lanes.json, stall-detector.service/.timer,
  test_stall_detector.py.
- `8fae11b` -- render_pipeline.py Lanes/stalls block + tests.
- (this report + NEXT_STEPS.md campaign-running block committed separately below.)

## Concerns
- `stall_detector.py`'s lane-based `STALL`/`CLEAR` lines always go to the single campaign ledger
  (`two_jup/sdd_archive/2026-09-03-txfix/progress.md`), since `lanes.json` entries carry no `ledger`
  field per the spec -- agent-heartbeat stalls/clears correctly target the ledger the heartbeat was
  found in.
- Lane staleness treats a missing log file as infinite age (always stalls while the unit is active) --
  not exercised live here (the self-test log existed but was stale), only covered by the injected
  `is_active` unit test path, not a live missing-file run.
- No locking around ledger appends (plain `>>`/open-append); acceptable at the current single-writer-
  per-file cadence (watch_unit.sh instances write only their own UNITEXIT line; stall_detector.py runs
  as a single oneshot every 5 min) but not fsync/flock-hardened against a true concurrent writer race.
- `stall-detector.timer`/`.service` are installed live on this host (`nemo`, matches HOSTS.md) under
  `~/.config/systemd/user/`; not itself committed to git (units are copied at install time per the
  ddrcap2/pipeline-dash convention) -- the source files under `two_jup/agents/` are the source of truth
  and are committed.
