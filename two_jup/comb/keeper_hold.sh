#!/bin/bash
# keeper_hold.sh hold|release -- COMB campaign rig hold, T0c (happy-bubbling-owl §T0c).
#
# hold:    create SENTINEL_STOP and RIG_LOCK (ONLY if each is absent; a marker file
#          records exactly which of the two THIS invocation created), stop any
#          sentinel-*/sentinelkeeper-* systemd --user units, and kill lock_watchdog on
#          BOTH boards with the bracket pkill pattern (`pkill -9 -f "[l]ock_watchdog"`,
#          a board action -- DRY-guarded).
# release: remove ONLY the hold files this tool created (per the marker), then
#          relaunch the keeper via launch_rig_unit.sh.
#
# Never kill a bring-up mid-arm: this script does not probe or interrupt an in-flight
# arm sequence; it only touches the hold files, idle sentinel/keeper units, and the
# watchdog process (which bring-up itself always kills first anyway -- see
# bringup_r2r3.sh's arm_rom()).
#
# DRY=1 (default for this campaign) gates every stateful action. Two independent
# sub-gates exist so tests can prove real local file bookkeeping without ever risking
# a real systemd/ssh side effect:
#   FILE_DRY (default = DRY) -- hold-file create/remove (HOLD_SENTINEL/HOLD_RIGLOCK/
#     HOLD_MARK). Safe to run for real in a test because those three paths are always
#     env-overridable to temp files -- it never touches ~/modem-status unless the
#     caller left the defaults AND set FILE_DRY=0.
#   NET_DRY (default = DRY) -- systemctl --user stop (real sentinel/keeper units),
#     ssh pkill on either board, and the launch_rig_unit relaunch. These are
#     system-wide/board actions with no per-test-safe override, so a test suite must
#     NEVER set NET_DRY=0 -- it stays DRY even when FILE_DRY=0 is used to exercise the
#     real create/remove logic on temp paths.
# Plain `DRY=1` (the default) is the safe, fully-inert mode: both sub-gates inherit it.
#
# Env overrides:
#   HOLD_SENTINEL   default $HOME/modem-status/SENTINEL_STOP
#   HOLD_RIGLOCK    default $HOME/modem-status/RIG_LOCK
#   HOLD_MARK       default <dir of HOLD_RIGLOCK>/.keeper_hold_created
#   A / B           board IPs, default 10.0.0.148 / 10.0.0.146
#   W               ssh wrapper, default two_jup/anyssh.sh
set -u
D=$(cd "$(dirname "$0")" && pwd)          # two_jup/comb
TJ=$(cd "$D/.." && pwd)                   # two_jup
W=${W:-$TJ/anyssh.sh}
A=${A:-10.0.0.148}; B=${B:-10.0.0.146}
DRY=${DRY:-1}
FILE_DRY=${FILE_DRY:-$DRY}
NET_DRY=${NET_DRY:-$DRY}

HOLD_SENTINEL=${HOLD_SENTINEL:-$HOME/modem-status/SENTINEL_STOP}
HOLD_RIGLOCK=${HOLD_RIGLOCK:-$HOME/modem-status/RIG_LOCK}
HOLD_MARK=${HOLD_MARK:-$(dirname "$HOLD_RIGLOCK")/.keeper_hold_created}

log(){ echo "$(date -Is) $*"; }

mode=${1:?usage: keeper_hold.sh hold|release}

# ---- unit discovery (local systemctl -- NOT ssh/scp; still DRY-gated, see header) ----
list_keeper_units(){
  if [ "$NET_DRY" = 1 ]; then
    echo "sentinel-000000"
  else
    systemctl --user list-units --plain --no-legend 'sentinel-*' 'sentinelkeeper-*' 2>/dev/null \
      | awk '{print $1}'
  fi
}

stop_units(){
  local units; units=$(list_keeper_units)
  if [ -z "$units" ]; then log "no sentinel-*/sentinelkeeper-* units found"; return 0; fi
  local u
  for u in $units; do
    if [ "$NET_DRY" = 1 ]; then
      log "[dry] systemctl --user stop $u"
    else
      systemctl --user stop "$u" >/dev/null 2>&1 && log "stopped $u" || log "WARN: stop $u failed"
    fi
  done
}

kill_watchdog_board(){ # $1 ip
  if [ "$NET_DRY" = 1 ]; then
    log "[dry] $W $1 pkill -9 -f \"[l]ock_watchdog\""
  else
    $W "$1" 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; echo done' 2>/dev/null
    log "$1: lock_watchdog kill sent"
  fi
}

do_hold(){
  created=""
  if [ -e "$HOLD_SENTINEL" ]; then
    log "SENTINEL_STOP already present ($HOLD_SENTINEL) -- leaving as-is"
  else
    if [ "$FILE_DRY" = 1 ]; then
      log "[dry] create $HOLD_SENTINEL"
    else
      mkdir -p "$(dirname "$HOLD_SENTINEL")"; touch "$HOLD_SENTINEL"
    fi
    created="$created SENTINEL"
    log "created SENTINEL_STOP ($HOLD_SENTINEL)"
  fi
  if [ -e "$HOLD_RIGLOCK" ]; then
    log "RIG_LOCK already present ($HOLD_RIGLOCK) -- leaving as-is"
  else
    if [ "$FILE_DRY" = 1 ]; then
      log "[dry] create $HOLD_RIGLOCK"
    else
      mkdir -p "$(dirname "$HOLD_RIGLOCK")"
      echo "owner=keeper_hold pid=$$ since=$(date -Is)" > "$HOLD_RIGLOCK"
    fi
    created="$created RIGLOCK"
    log "created RIG_LOCK ($HOLD_RIGLOCK)"
  fi
  if [ -n "$created" ]; then
    if [ "$FILE_DRY" = 1 ]; then
      log "[dry] write hold marker ($HOLD_MARK): $created"
    else
      mkdir -p "$(dirname "$HOLD_MARK")"
      echo "$created" > "$HOLD_MARK"
    fi
  else
    log "created nothing (both hold files pre-existed) -- no marker written"
  fi
  stop_units
  kill_watchdog_board "$A"
  kill_watchdog_board "$B"
  echo "KEEPER_HOLD_OK created=[${created:- none}]"
}

do_release(){
  local created=""
  if [ -f "$HOLD_MARK" ]; then
    created=$(cat "$HOLD_MARK" 2>/dev/null)
  else
    log "no hold marker at $HOLD_MARK -- this invocation created nothing to release"
  fi
  case "$created" in
    *SENTINEL*)
      if [ "$FILE_DRY" = 1 ]; then
        log "[dry] remove $HOLD_SENTINEL"
      else
        rm -f "$HOLD_SENTINEL"
      fi
      log "removed SENTINEL_STOP" ;;
    *) log "SENTINEL_STOP not ours -- leaving in place" ;;
  esac
  case "$created" in
    *RIGLOCK*)
      if [ "$FILE_DRY" = 1 ]; then
        log "[dry] remove $HOLD_RIGLOCK"
      else
        rm -f "$HOLD_RIGLOCK"
      fi
      log "removed RIG_LOCK" ;;
    *) log "RIG_LOCK not ours -- leaving in place" ;;
  esac
  if [ "$FILE_DRY" = 1 ]; then
    log "[dry] rm $HOLD_MARK"
  else
    rm -f "$HOLD_MARK"
  fi
  # relaunch the keeper via the sanctioned launcher (launch_rig_unit.sh), never a bare
  # systemd-run: a plain unit's default TimeoutStopSec can SIGKILL it mid-arm later.
  UNIT="sentinelkeeper-$(date +%H%M%S)"
  if [ "$NET_DRY" = 1 ]; then
    log "[dry] $TJ/launch_rig_unit.sh $UNIT $TJ/sim_repro/sentinel_keeper.sh"
  else
    "$TJ/launch_rig_unit.sh" "$UNIT" "$TJ/sim_repro/sentinel_keeper.sh" >/dev/null 2>&1 \
      && log "relaunched keeper as $UNIT" || log "WARN: keeper relaunch failed"
  fi
  echo "KEEPER_RELEASE_OK released=[${created:- none}]"
}

case "$mode" in
  hold) do_hold ;;
  release) do_release ;;
  *) echo "usage: keeper_hold.sh hold|release" >&2; exit 2 ;;
esac
