#!/bin/bash
# sweep.sh -- one governor liveness pass. Silent when healthy; prints
# SWEEP_ALERT lines otherwise. Exit 0 healthy, 1 alert.
#
# The halt decision is structural: it reads $RIG_MUTEX.d directly (the
# holder's own heartbeat file), never agent fragments. A stale rig holder
# is detected and RIG_HALT written even if every fragment is missing,
# corrupt, or lying -- a fragment must never be able to mask a real stale
# holder, and a real stale holder must never depend on a fragment existing.
#
# Agent fragments ($RIG_DIR/agents/*.json) are attribution/requeue
# information only. A bad fragment produces an "unreadable-fragment" alert
# and processing continues to the next fragment -- it never aborts the pass
# and never silently disappears.
set -u
RIG_DIR="${RIG_DIR:-/home/tcollins/modem-status}"
RIG_STALE_S="${RIG_STALE_S:-600}"
AGENTS="$RIG_DIR/agents"
MUTEX_DIR="$RIG_DIR/RIG_MUTEX.d"
HALT_F="$RIG_DIR/RIG_HALT"
ALERT=0
now=$(date +%s)

# --- 1. Structural halt check: source of truth is the mutex itself. ---
if [ -e "$HALT_F" ]; then
  # Already halted. Report it, but NEVER touch the file -- the original
  # cause and onset time must survive every later sweep pass.
  echo "SWEEP_ALERT rig-halted $(cat "$HALT_F")"
  ALERT=1
elif [ -d "$MUTEX_DIR" ]; then
  # Age comes from the heartbeat file's mtime when it exists. In the window
  # right after mkdir but before the holder's first heartbeat write, there
  # is no heartbeat file yet -- that is NOT staleness, so fall back to the
  # mutex directory's own mtime (which mkdir sets at creation) rather than
  # to a 0 epoch, which would read as decades old and false-halt a brand
  # new, healthy lock.
  if [ -e "$MUTEX_DIR/heartbeat" ]; then
    hb_mtime=$(stat -c %Y "$MUTEX_DIR/heartbeat" 2>/dev/null || echo "$now")
  else
    hb_mtime=$(stat -c %Y "$MUTEX_DIR" 2>/dev/null || echo "$now")
  fi
  age=$(( now - hb_mtime ))
  if [ "$age" -gt "$RIG_STALE_S" ]; then
    owner="owner unknown"
    if [ -r "$MUTEX_DIR/owner" ]; then
      oname=$(sed -n 's/.*agent=\([^ ]*\).*/\1/p' "$MUTEX_DIR/owner" | head -1)
      [ -n "$oname" ] && owner="$oname"
    fi
    echo "SWEEP_ALERT stale-holder $owner heartbeat ${age}s old -- writing RIG_HALT"
    printf 'stale holder %s at=%s\n' "$owner" "$(date -Is)" > "$HALT_F"
    if [ -z "${SWEEP_NO_PING:-}" ]; then
      ping -c1 -W2 10.0.0.148 >/dev/null 2>&1 \
        && echo "SWEEP_ALERT board-148 still reachable" \
        || echo "SWEEP_ALERT board-148 UNREACHABLE -- dark-board case, operator attention"
    fi
    ALERT=1
  fi
fi

# --- 2. Fragment sweep: attribution/requeue info only, never authoritative
#        for the halt decision, never allowed to abort the pass. ---
for f in "$AGENTS"/*.json; do
  [ -e "$f" ] || continue
  py_out=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    agent = d["agent"]
    hb = d["last_heartbeat"]
    held_raw = d.get("rig_held")
    if held_raw is True or held_raw == "true":
        held = "true"
    elif held_raw is False or held_raw == "false":
        held = "false"
    else:
        held = "unknown"
    phase = d.get("phase", "")
    print("OK")
    print(agent)
    print(held)
    print(hb)
    print(phase)
except Exception:
    print("ERR")
' "$f" 2>/dev/null)
  status=$(printf '%s\n' "$py_out" | sed -n '1p')
  if [ "$status" != "OK" ]; then
    echo "SWEEP_ALERT unreadable-fragment $f"
    ALERT=1
    continue
  fi
  name=$(printf '%s\n' "$py_out" | sed -n '2p')
  held=$(printf '%s\n' "$py_out" | sed -n '3p')
  hb=$(printf '%s\n' "$py_out" | sed -n '4p')
  phase=$(printf '%s\n' "$py_out" | sed -n '5p')
  hbs=$(date -d "$hb" +%s 2>/dev/null)
  if [ -z "$hbs" ]; then
    echo "SWEEP_ALERT unreadable-fragment $f"
    ALERT=1
    continue
  fi
  age=$(( now - hbs ))
  [ "$age" -le "$RIG_STALE_S" ] && continue
  # A finished agent's fragment ages forever. Without this, every normal
  # completion becomes a permanent 10-minute alert and the channel trains the
  # reader to ignore it -- which is how a real stale agent gets missed. Only a
  # terminal phase that has also let go of the rig is exempt: phase=complete
  # with rig_held=true is a LEAK and must still alert.
  if [ "$phase" = "complete" ] && [ "$held" = "false" ]; then
    continue
  fi
  case "$held" in
    true)
      echo "SWEEP_ALERT stale-holder $name heartbeat ${age}s old (self-reported; verify RIG_MUTEX.d)"
      ALERT=1
      ;;
    false)
      echo "SWEEP_ALERT stale-no-rig $name heartbeat ${age}s old -- requeue as a fresh agent"
      ALERT=1
      ;;
    *)
      echo "SWEEP_ALERT unrecognised-rig-held $name value=$held"
      ALERT=1
      ;;
  esac
done

exit $ALERT
