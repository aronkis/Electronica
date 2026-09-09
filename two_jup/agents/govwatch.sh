#!/bin/bash
# govwatch.sh -- one governor watchdog pass for a 10-minute Monitor loop.
# Silent + exit 0 when healthy; prints WATCH_*/SWEEP_* lines and exits 1 otherwise.
# NOTE: an earlier version could error internally and still exit 0 -- a watchdog
# that looks healthy while doing nothing is exactly a dead counter. Hence
# `set -o pipefail`, explicit counting, and a self-test (--selftest).
set -u -o pipefail
R=/mnt/onetb/scratch/qpsk-jupiter-modem
S=${GOVWATCH_STATE_DIR:-/home/tcollins/modem-status}
ST=${GOVWATCH_STATE:-$R/.superpowers/sdd/2026-08-31-parallel-datapath-agents/.govwatch_state}
IDLE_LIMIT=${IDLE_LIMIT:-1500}
OUT=0; say(){ printf '%s\n' "$*"; OUT=1; }
count(){ local n; n=$(pgrep -c -f "$1" 2>/dev/null) || true; printf %s "${n:-0}"; }
# NOTE: pgrep -c PRINTS 0 and EXITS 1 when there are no matches, so a `|| printf 0`
# fallback emits "0\n0". And a bare "vivado" pattern matches `tail -F ...vivado.log`,
# which reported 4 phantom builds. Match the executable, not the word.
countx(){ local n; n=$(pgrep -c -x "$1" 2>/dev/null) || true; printf %s "${n:-0}"; }
# Count by process NAME (comm), never the command line: a `-f` pattern also
# matches the shell wrappers carrying the binary's name in their argv, which
# counted one running sim as four. The previous pattern here was
# '[V]wrap_byte_ce' -- a binary that does not exist, so this counter had never
# once returned non-zero while a sim ran. A watchdog whose compute detector is
# dead reports WATCH_STALL over healthy work.
countc(){ ps -eo comm= | grep -cE "$1" || true; }

sw=$(bash "$R/two_jup/agents/sweep.sh" 2>&1) || true
[ -n "$sw" ] && say "$sw"

if [ -d "$S/RIG_MUTEX.d" ]; then
  hb=$(stat -c %Y "$S/RIG_MUTEX.d/heartbeat" 2>/dev/null || stat -c %Y "$S/RIG_MUTEX.d" 2>/dev/null || printf 0)
  age=$(( $(date +%s) - hb ))
  [ "$age" -gt 900 ] && say "WATCH_STALL rig held ${age}s without heartbeat: $(cat "$S/RIG_MUTEX.d/owner" 2>/dev/null)"
fi

# NB: comma-separated, NO SPACES -- the state file is read with awk '{print $2}',
# so any space in the fingerprint truncates it on read and every pass then looks
# like a change. Cost one broken commit to find.
BOARDS=""
for ip in 10.0.0.148 10.0.0.146; do
  if ping -c1 -W2 "$ip" >/dev/null 2>&1; then
    BOARDS="${BOARDS}${ip}:up,"
  else
    BOARDS="${BOARDS}${ip}:DOWN,"
    say "WATCH_ALERT $ip UNREACHABLE"
  fi
done

now=$(date +%s)
head=$(cd "$R" && git rev-parse --short HEAD)
ver=$(countc '^(Vwrap_byte|verilator_bin|verilator)')
viv=$(countx vivado)
rem=$(timeout 15 ssh -o ConnectTimeout=6 -o BatchMode=yes hdl-dev-2 'pgrep -c vivado || true' 2>/dev/null | tr -dc '0-9')
[ -z "$rem" ] && rem=x
# Board reachability belongs IN the fingerprint. Without it the watchdog alerts
# when a board goes DOWN but is silent when it comes back, so a recovery is never
# an event and nobody learns the rig is usable again. 2026-09-01: a separate
# board-return waiter was reaped by the harness, and this was the only other
# mechanism -- it would not have fired.
cur="${head}|${ver}|${viv}|${rem}|${BOARDS}"

prev=""; prevt=0
if [ -f "$ST" ]; then prevt=$(awk '{print $1}' "$ST"); prev=$(awk '{print $2}' "$ST"); fi
if [ "$cur" != "$prev" ]; then
  say "WATCH_CHANGE head=$head verilator=$ver vivado_local=$viv vivado_hdldev2=$rem boards=$BOARDS"
  printf '%s %s\n' "$now" "$cur" > "$ST"
else
  idle=$(( now - prevt ))
  if [ "$idle" -gt "$IDLE_LIMIT" ] && [ "$ver" -eq 0 ] && [ "$viv" -eq 0 ] && { [ "$rem" = "0" ] || [ "$rem" = "x" ]; }; then
    say "WATCH_STALL no commit and no compute for ${idle}s (head $head) -- an agent has probably died"
    printf '%s %s\n' "$now" "$cur" > "$ST"
  fi
fi
exit $OUT
