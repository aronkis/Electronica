#!/bin/bash
# serve_dashboard.sh -- regenerate chain.html every 30 s and serve modem-status
# on 8090, matching the existing dashboard pattern (python3 -m http.server).
#
# $D and $PORT are overridable via environment so tests can point this at a
# scratch directory and an unused high port instead of the live dashboard.
# DASH_NO_LOOP=1 makes the script only define functions when sourced (for
# tests that want to call start_server_if_needed directly, concurrently).
set -u
R=/mnt/onetb/scratch/qpsk-jupiter-modem
D="${D:-/home/tcollins/modem-status}"
PORT="${PORT:-8090}"
START_LOCK="$D/.http_server_start.lock.d"
START_LOCK_STALE_S="${START_LOCK_STALE_S:-60}"

mkdir -p "$D/agents"

# Mutual exclusion around the check-then-act port start. Two near-simultaneous
# invocations (a systemd unit restart racing a manual re-run) must not both
# pass the "not listening" check and spawn two http.server processes -- the
# loser would fail to bind and its traceback would sit silently in
# server.log. mkdir is atomic on POSIX; same technique as
# two_jup/agents/rigmutex.sh. The lock is held only around this check-and-start,
# never around the render loop, so a legitimate second invocation no-ops
# instead of hanging forever waiting on the lock.
acquire_start_lock() {
  if mkdir "$START_LOCK" 2>/dev/null; then
    echo "$$" > "$START_LOCK/pid" 2>/dev/null
    return 0
  fi
  # Someone else holds it. If it's stale (left behind by a killed process),
  # steal it rather than let a dead lock permanently block the server from
  # ever starting again.
  local now lock_mtime age
  now=$(date +%s)
  lock_mtime=$(stat -c %Y "$START_LOCK" 2>/dev/null || echo "$now")
  age=$(( now - lock_mtime ))
  if [ "$age" -gt "$START_LOCK_STALE_S" ]; then
    rm -rf "$START_LOCK" 2>/dev/null
    if mkdir "$START_LOCK" 2>/dev/null; then
      echo "$$" > "$START_LOCK/pid" 2>/dev/null
      return 0
    fi
  fi
  return 1
}

release_start_lock() {
  rm -rf "$START_LOCK" 2>/dev/null
}

start_server_if_needed() {
  if ! acquire_start_lock; then
    # Another invocation is starting the server right now -- no-op, not an
    # error: this is exactly the "safe to re-invoke" case the script promises.
    echo "start-lock held by another invocation, skipping"
    return 0
  fi
  trap release_start_lock EXIT INT TERM
  if ! (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ":$PORT "; then
    ( cd "$D" && nohup python3 -m http.server "$PORT" >> "$D/server.log" 2>&1 & )
    echo "started http.server on $PORT"
  else
    echo "$PORT already listening"
  fi
  release_start_lock
  trap - EXIT INT TERM
}

render_loop() {
  while true; do
    python3 "$R/two_jup/agents/render_chain.py" "$R/two_jup/chain.json" "$D/agents" "$D/chain.html" "$R/two_jup/tasks.json" >/dev/null 2>&1
    sleep 30
  done
}

if [ "${DASH_NO_LOOP:-0}" != "1" ]; then
  start_server_if_needed
  render_loop
fi
