# Task 3 (T0c) re-review — fix round 1 (commit 4b8e88b)

**Verdict: Approved**

- C-1 fixed: `two_jup/rxfix/slackleg_go.sh:160-165` — `restore()` unconditionally
  `kill`s+`wait`s `$PEER_PID` first, before either restore write (:171 `RESTORE 1/2: 146`,
  :177 `RESTORE 2/2: 148`), in both the trap and normal-completion paths. New test
  `test_slackleg_restore_kills_peer_watcher_before_restoring_146_then_148` runs `DRY=0`
  (PATH-shimmed ssh, zero real network) with `PEER_POKE_TEST_SLEEP=120` as a fake sleeping
  peer watcher, sends SIGTERM, and asserts (a) the watcher never reached its own write
  ("finished WITHOUT being killed" absent), (b) `run.log` order is kill-watcher →
  `RESTORE 1/2: 146` → `RESTORE 2/2: 148`, (c) exactly two `0x208 0x0` shim calls, 146 then
  148. Confirmed this is not DRY-skipped: ran it in isolation
  (`pytest -k restore_kills_peer_watcher -v`) — 1 passed, no skip, real subprocess with
  SIGTERM sent to the process group.
- I-1 fixed: `slackleg_go.sh:118-135` (`peer_poke_bg`) now triggers on the `"wedge verdict:"`
  marker with no fixed settle, replacing the wrong radioprobe_go.sh citation and the
  unbounded `WAIT_146=20`. Walked `two_jup/capture_r3.sh` directly: `"wedge verdict:"` at
  capture_r3.sh:198, 5b `LOOP_POKE` hook at :211, framelog rotate at :272, `CAP_SETTLE`
  sleep at :291-293, `"traffic remaining"` watchdog at :320 — all lines match the commit's
  citations, and firing on :198 lands strictly before :211/:272/:320, i.e. inside the
  arm-to-window gap at the health-gate pass. `meta.txt` now carries
  `peer_poke_trigger=wedge_verdict_marker` in place of `wait_146_s=`.

`python3 -m pytest two_jup/tests/test_rxfix_rig_scripts.py -q` → 18 passed in 3.08s.
