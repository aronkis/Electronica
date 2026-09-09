# rigmutex.sh -- rig arbiter for multiple actors. Source it.
# Replaces sim_repro/riglock.sh, which check-then-writes a plain file (TOCTOU)
# and exits the loser instead of queueing. mkdir is atomic on POSIX.
RIG_DIR="${RIG_DIR:-/home/tcollins/modem-status}"
RIG_MUTEX="$RIG_DIR/RIG_MUTEX.d"
RIG_HALT_F="$RIG_DIR/RIG_HALT"
RIG_LEGACY="$RIG_DIR/RIG_LOCK"
RIG_SENT_STOP="$RIG_DIR/SENTINEL_STOP"
RIG_STALE_S="${RIG_STALE_S:-600}"

rig_halt_active(){ [ -e "$RIG_HALT_F" ]; }
rig_halt_set(){ mkdir -p "$RIG_DIR"; printf '%s at=%s pid=%s\n' "$1" "$(date -Is)" "$$" > "$RIG_HALT_F"; }
rig_halt_clear(){ rm -f "$RIG_HALT_F"; }

rig_acquire(){            # $1 agent, $2 budget seconds (0 = try once)
  local agent="$1" budget="${2:-0}" waited=0 hb age
  mkdir -p "$RIG_DIR"
  while :; do
    if rig_halt_active; then echo "RIG_HALT: $(cat "$RIG_HALT_F")"; return 2; fi
    if mkdir "$RIG_MUTEX" 2>/dev/null; then
      RIG_AGENT="$agent"
      RIG_TOKEN=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$RANDOM$RANDOM$(date +%s%N)")
      export RIG_TOKEN
      printf 'agent=%s pid=%s token=%s phase=acquired at=%s\n' "$agent" "$$" "$RIG_TOKEN" "$(date -Is)" > "$RIG_MUTEX/owner"
      : > "$RIG_MUTEX/heartbeat"
      printf 'owner=%s pid=%s since=%s\n' "$agent" "$$" "$(date +%F_%T)" > "$RIG_LEGACY"
      : > "$RIG_SENT_STOP"
      return 0
    fi
    # A missing/unreadable heartbeat means the winner is still between mkdir and
    # writing heartbeat -- that is "just acquired", not stale. Do not compute an
    # age against a 0 epoch; just fall through to the normal wait/timeout path.
    if hb=$(stat -c %Y "$RIG_MUTEX/heartbeat" 2>/dev/null); then
      age=$(( $(date +%s) - hb ))
      if [ "$age" -gt "$RIG_STALE_S" ]; then
        echo "RIG_STALE owner='$(cat "$RIG_MUTEX/owner" 2>/dev/null)' heartbeat ${age}s old -- NOT stealing"
        return 4
      fi
    fi
    [ "$budget" -le 0 ] && return 3
    sleep 5; waited=$(( waited + 5 ))
    [ "$waited" -ge "$budget" ] && return 3
  done
}

rig_heartbeat(){ : > "$RIG_MUTEX/heartbeat" 2>/dev/null; }
rig_phase(){ printf 'agent=%s pid=%s token=%s phase=%s at=%s\n' "${RIG_AGENT:-?}" "$$" "${RIG_TOKEN:-}" "$1" "$(date -Is)" > "$RIG_MUTEX/owner" 2>/dev/null; }
rig_release(){
  [ -n "${RIG_TOKEN:-}" ] || return 1
  grep -q "token=$RIG_TOKEN " "$RIG_MUTEX/owner" 2>/dev/null || return 1
  rm -rf "$RIG_MUTEX"; rm -f "$RIG_LEGACY" "$RIG_SENT_STOP"; return 0
}
