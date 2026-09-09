#!/bin/bash
# =============================================================================
# daemon_skew.sh [ipA ipB] -- cross-board daemon start-ordering observable.
#
# WHY: the ARQ engagement failure is bimodal, and on a bad run 148 reported
# naks_rx=0 while 146 had sent 1462 NAKs -- 148's ARQ layer inspected ZERO
# payloads (nakstat seen=0). One candidate cause is start ORDER: if the peer's
# daemon comes up after this side has already begun NAKing, the NAKs land on a
# process that is not listening yet. Until now that was unanswerable -- there was
# no timestamp either side could compare. This makes it answerable with NO code
# change and NO board modification: the kernel already records process start time.
#
# METHOD (read-only, no debugfs, cannot disturb a soak):
#   /proc/<pid>/stat field 22 = starttime in clock ticks since boot
#   absolute start = now - (uptime - starttime/HZ)
# Two clocks are involved, so the ABSOLUTE epochs are only as good as the boards'
# time sync; the SKEW is the number that matters and it inherits that error. Boards
# whose clocks differ (146 has run UTC while 148 ran local in this campaign) will
# show a bogus skew -- so the wall-clock offset is measured and reported too, and
# the skew is corrected by it rather than quietly ignored.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=${1:-10.0.0.146}; B=${2:-10.0.0.148}

probe(){
  $W "$1" 'p=$(pgrep -x qpsk_tun | head -1)
    if [ -z "$p" ]; then echo "NODAEMON"; exit 0; fi
    HZ=$(getconf CLK_TCK 2>/dev/null); [ -n "$HZ" ] || HZ=100
    st=$(awk "{print \$22}" /proc/$p/stat 2>/dev/null)
    up=$(cut -d" " -f1 /proc/uptime)
    now=$(date +%s.%N)
    echo "PID=$p HZ=$HZ START_TICKS=$st UPTIME=$up NOW=$now"
    w=$(pgrep -f "[l]ock_watchdog" | head -1)
    if [ -n "$w" ]; then echo "WD_TICKS=$(awk "{print \$22}" /proc/$w/stat 2>/dev/null)"; fi' 2>/dev/null
}

RA=$(probe "$A"); RB=$(probe "$B")
python3 - "$A" "$B" "$RA" "$RB" <<'PY'
import sys, re
def parse(raw):
    if 'NODAEMON' in raw or not raw.strip(): return None
    g = dict(re.findall(r'(\w+)=([\d.]+)', raw))
    if 'START_TICKS' not in g: return None
    hz  = float(g.get('HZ', 100))
    now = float(g['NOW']); up = float(g['UPTIME']); st = float(g['START_TICKS'])/hz
    d = {'pid': g['PID'], 'boot': now - up, 'start': now - (up - st), 'now': now}
    if 'WD_TICKS' in g:
        d['wd_start'] = now - (up - float(g['WD_TICKS'])/hz)
    return d

ipA, ipB, rawA, rawB = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
a, b = parse(rawA), parse(rawB)
for ip, x in ((ipA, a), (ipB, b)):
    if not x: print(f"  {ip}: qpsk_tun NOT RUNNING"); continue
    print(f"  {ip}: qpsk_tun pid={x['pid']}  start_epoch={x['start']:.2f}  "
          f"uptime_at_probe={x['now']-x['boot']:.0f}s" +
          (f"  watchdog_start={x['wd_start']:.2f}" if 'wd_start' in x else ""))
if a and b:
    clock = a['now'] - b['now']          # wall-clock offset between the two boards
    raw   = a['start'] - b['start']
    corr  = raw - clock
    print(f"\n  board wall-clock offset : {clock:+.2f} s  ({ipA} minus {ipB})")
    print(f"  raw daemon start skew   : {raw:+.2f} s")
    print(f"  CLOCK-CORRECTED SKEW    : {corr:+.2f} s   "
          f"({'A started first' if corr < 0 else 'B started first'})")
    print("\n  Reading: a large positive/negative skew means one side was already"
          "\n  running (and possibly NAKing) before the other's ARQ layer existed."
          "\n  Correlate against nakstat seen=0 runs before treating it as the cause;"
          "\n  the clock offset is measured, not assumed, because these boards have"
          "\n  historically run different timezones.")
PY
