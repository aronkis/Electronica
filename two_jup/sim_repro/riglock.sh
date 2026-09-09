# riglock.sh -- single-actor rig mutex (2026-08-27, after the self-arming reverse sweep
# overlapped a flash). Source it; call rig_lock <name> before touching either board and
# rig_unlock at exit. A runner that finds a foreign lock MUST refuse to start.
RIG_LOCK=/home/tcollins/modem-status/RIG_LOCK
rig_lock(){ if [ -e "$RIG_LOCK" ] && ! grep -q "pid=$$ " "$RIG_LOCK" 2>/dev/null; then
              echo "RIG_LOCKED by: $(cat $RIG_LOCK) -- refusing to start ($1)"; exit 3; fi
            echo "owner=$1 pid=$$ since=$(date +%F_%T)" > "$RIG_LOCK"; touch /home/tcollins/modem-status/SENTINEL_STOP; }
rig_unlock(){ if grep -q "pid=$$ " "$RIG_LOCK" 2>/dev/null; then rm -f "$RIG_LOCK" /home/tcollins/modem-status/SENTINEL_STOP; fi; }
