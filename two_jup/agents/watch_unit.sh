#!/bin/bash
# watch_unit.sh -- controller-side watcher for a long-running systemd --user unit.
# Independent of any agent's own monitoring: this loop lives in its own unit so it
# survives the ~60 min harness reap and any agent session ending.
#
# Usage:
#   watch_unit.sh <unit> <ledger>            # run the watch loop directly (blocking)
#   watch_unit.sh --spawn <unit> <ledger>     # launch the loop as its own
#                                              # systemd-run --user --unit=watch-<unit> unit
#
# Direct mode behaviour:
#   - If <unit> has not appeared (systemd has never heard of it) within 120 s,
#     append `UNITEXIT <unit> result=missing code=NA at=<ISO8601>` and stop.
#   - Once it has appeared, poll `systemctl --user -q is-active <unit>` every 30 s.
#     The first poll that is not "active" is treated as the unit having exited:
#     append `UNITEXIT <unit> result=<Result> code=<ExecMainStatus> at=<ISO8601>`
#     to <ledger> and touch ~/modem-status/NOTIFY/<unit>.done (mkdir -p as needed).
set -u

NOTIFY_DIR="${NOTIFY_DIR:-$HOME/modem-status/NOTIFY}"
APPEAR_TIMEOUT_S=120
APPEAR_POLL_S=2
LOOP_POLL_S=30

iso_now() { date -Is; }

append_ledger() {
    # $1 = ledger path, $2 = line
    local ledger="$1" line="$2"
    mkdir -p "$(dirname "$ledger")" 2>/dev/null
    printf '%s\n' "$line" >> "$ledger"
}

touch_done() {
    # $1 = unit name
    mkdir -p "$NOTIFY_DIR"
    touch "$NOTIFY_DIR/$1.done"
}

unit_exists() {
    # $1 = unit name; returns 0 if systemd knows about it (any LoadState other than "not-found")
    local ls
    ls=$(systemctl --user show "$1" -p LoadState --value 2>/dev/null)
    [ -n "$ls" ] && [ "$ls" != "not-found" ]
}

watch_loop() {
    local unit="$1" ledger="$2"
    local waited=0

    # Wait for the unit to appear.
    while ! unit_exists "$unit"; do
        if [ "$waited" -ge "$APPEAR_TIMEOUT_S" ]; then
            append_ledger "$ledger" "UNITEXIT $unit result=missing code=NA at=$(iso_now)"
            touch_done "$unit"
            return 0
        fi
        sleep "$APPEAR_POLL_S"
        waited=$((waited + APPEAR_POLL_S))
    done

    # Unit has appeared; poll is-active until it stops being active.
    while systemctl --user -q is-active "$unit"; do
        sleep "$LOOP_POLL_S"
    done

    local result code
    result=$(systemctl --user show "$unit" -p Result --value 2>/dev/null)
    code=$(systemctl --user show "$unit" -p ExecMainStatus --value 2>/dev/null)
    [ -n "$result" ] || result="unknown"
    [ -n "$code" ] || code="NA"

    append_ledger "$ledger" "UNITEXIT $unit result=$result code=$code at=$(iso_now)"
    touch_done "$unit"
    return 0
}

main() {
    if [ "${1:-}" = "--spawn" ]; then
        shift
        if [ "$#" -lt 2 ]; then
            echo "usage: watch_unit.sh --spawn <unit> <ledger>" >&2
            exit 2
        fi
        local target_unit="$1" ledger="$2"
        local abs_script
        abs_script=$(readlink -f "$0") || { echo "cannot resolve absolute path of $0" >&2; exit 2; }
        local abs_ledger="$ledger"
        case "$ledger" in
            /*) : ;;
            *) abs_ledger=$(readlink -f "$ledger" 2>/dev/null || echo "$PWD/$ledger") ;;
        esac
        exec systemd-run --user --unit="watch-$target_unit" --collect \
            /bin/bash "$abs_script" "$target_unit" "$abs_ledger"
    fi

    if [ "$#" -lt 2 ]; then
        echo "usage: watch_unit.sh <unit> <ledger>  |  watch_unit.sh --spawn <unit> <ledger>" >&2
        exit 2
    fi
    watch_loop "$1" "$2"
}

main "$@"
