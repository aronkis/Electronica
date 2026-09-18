for h in 10.0.0.146 10.0.0.148; do
  echo "=== $h ==="
  ./anyssh.sh $h 'PF=/dev/shm/watchdog.pid
  if [ -f $PF ]; then pid=$(cat $PF)
    if [ -n "$pid" ] && [ -d /proc/$pid ] && tr "\0" " " < /proc/$pid/cmdline | grep -q lock_watchdog; then
      kill "$pid" 2>/dev/null; echo "killed watchdog pid=$pid"
    else echo "pidfile stale or mismatched, not killing"; fi
  else echo "no pidfile"; fi'
done