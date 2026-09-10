#!/bin/bash
# CANONICAL COPY of the delivery sentinel. Installed at /home/tcollins/modem-status/delivery_sentinel.sh
# (the keeper, sentinel_keeper.sh, launches THAT path). To change it: edit here, `mv` a copy over the
# installed file (new inode), then stop the running sentinel-* unit during its 290 s sleep; the keeper
# relaunches within 2 min. 2026-09-08: crc=/tx=/rev=/rcrc=/rtx= columns added (ledger FWD_CRC_REGRESSION_0907 §46.3).
# Delivery sentinel (nemo-side): auto-recovers the #48 delivery wedge.
# Disable: touch /home/tcollins/modem-status/SENTINEL_STOP   (checked every cycle)
# Log: /home/tcollins/modem-status/sentinel.log
D=/mnt/onetb/scratch/qpsk-jupiter-modem/ops
STOP=/home/tcollins/modem-status/SENTINEL_STOP
LOG=/home/tcollins/modem-status/sentinel.log
# sprobe <ip>: prints "<idle_rx> <crc_drop>" from the daemon's last stats line, or nothing.
sprobe() {
  $D/anyssh.sh "$1" 'grep "qpsk_tun stats" /dev/shm/qpsk_tun.log | tail -1' 2>/dev/null \
    | awk '{i="";c="";x=""; for(k=1;k<=NF;k++){ if($k ~ /^idle_rx=/) i=substr($k,9); if($k ~ /^crc_drop=/) c=substr($k,10); if($k ~ /^dma_tx=/) x=substr($k,8) } if(i!="" && c!="") print i, c, x}'
}
# txfmt "<i0 c0 x0>" "<i1 c1 x1>": "tx=N/s" = the board's own dma_tx rate (is its transmitter being fed?)
txfmt() { local _a _b x0 x1; read -r _a _b x0 <<< "$1"; read -r _a _b x1 <<< "$2"; [ -n "${x0:-}" ] && [ -n "${x1:-}" ] && printf 'tx=%d/s' $(( (x1 - x0) / 10 )) || printf 'tx=-'; }
# crcfmt "<i0 c0>" "<i1 c1>" <label>: "<label>=NN.N%" = ok/(ok+crcfail) over the window, "-" if none received.
crcfmt() {
  local i0 c0 i1 c1 _ ; read -r i0 c0 _ <<< "$1"; read -r i1 c1 _ <<< "$2"
  local ok=$(( i1 - i0 )) bad=$(( c1 - c0 ))
  if [ $((ok+bad)) -gt 0 ]; then awk -v o=$ok -v b=$bad -v l="$3" 'BEGIN{printf "%s=%.1f%%", l, 100*o/(o+b)}'; else printf '%s=-' "$3"; fi
}
while true; do
  r=""            # 2026-08-29 FIX: clear per iteration -- a stale r from an earlier
                  # successful cycle used to reset PF below on every pass, so the
                  # "probe failed x2 + both pingable" recovery path could NEVER fire.
  [ -e "$STOP" ] && { echo "$(date +%F_%T) STOP-file present, sentinel exiting" >> $LOG; exit 0; }
  # 2026-09-08: also read crc_drop on 148 and idle_rx/crc_drop on 146 from the SAME daemon
  # stats line (no register traffic -- see the DRA/no-ping-hang rule). The forward CRC
  # collapse of 09-07 delivered every frame with ~40 % failing CRC and this sentinel
  # could not see it (gates on idle_rx delta only). crc= is the fraction of received
  # frames that passed CRC over the 10 s window; rev=/rcrc= are the same for 146
  # (reverse leg). The recovery trigger is UNCHANGED (148 idle_rx rate < 100/s).
  s0=$(sprobe 10.0.0.148); s0b=$(sprobe 10.0.0.146)
  sleep 10
  s1=$(sprobe 10.0.0.148); s1b=$(sprobe 10.0.0.146)
  i0=${s0%% *}; i1=${s1%% *}
  if [ -n "$i0" ] && [ -n "$i1" ]; then
    r=$(( (i1-i0)/10 ))
    xtra=$(crcfmt "$s0" "$s1" crc)
    xtra="$xtra $(txfmt "$s0" "$s1")"
    [ -n "$s0b" ] && [ -n "$s1b" ] && xtra="$xtra rev=$(( (${s1b%% *}-${s0b%% *})/10 ))/s $(crcfmt "$s0b" "$s1b" rcrc) r$(txfmt "$s0b" "$s1b")"
    if [ "$r" -lt 100 ]; then
      echo "$(date +%F_%T) WEDGE detected (rate=$r/s) -- recovering" >> $LOG
      [ -e "$STOP" ] && exit 0
      # 2026-08-26: snapshot watchdog logs BEFORE recovery -- the restart below
      # truncates them, which destroyed all watchdog-attempt evidence on 08-25
      # (Task 8 named measurement gap). Snapshots land next to sentinel.log.
      WTS=$(date +%Y%m%d_%H%M%S)
      # 2026-08-26 fix: lock_watchdog.sh execs its output to /dev/shm/watchdog.log
      # (its LOGFILE default) regardless of the launcher redirect -- the previous
      # path /dev/shm/lock_watchdog.log is ALWAYS empty (8/8 zero-byte snapshots).
      # Snapshot the real watchdog log AND the daemon-log tail.
      for B in 10.0.0.146 10.0.0.148; do
        $D/anyssh.sh $B 'echo ===watchdog.log===; cat /dev/shm/watchdog.log 2>/dev/null; echo ===qpsk_tun.log tail===; tail -c 40000 /dev/shm/qpsk_tun.log 2>/dev/null' \
          > /home/tcollins/modem-status/wdlog_${B}_${WTS}.txt 2>/dev/null
      done
      GATE_DIR=A GATE_TRIES=8 $D/bringup_r2r3.sh r3 >> $LOG 2>&1
      for B in 10.0.0.146 10.0.0.148; do
        $D/anyssh.sh $B 'pkill -f lock_watchdog' 2>/dev/null
        $D/anyssh.sh $B 'chmod +x /root/lock_watchdog.sh; : > /dev/shm/lock_watchdog.log' 2>/dev/null
        $D/anyssh.sh $B 'nohup /root/lock_watchdog.sh > /dev/shm/lock_watchdog.log 2>&1 &' 2>/dev/null
      done
      echo "$(date +%F_%T) recovery chain done" >> $LOG
    else
      RECOV_N=0; RECOV_CAPPED=0
      echo "$(date +%F_%T) ok rate=$r/s $xtra" >> $LOG
    fi
  else
    # 2026-08-27: a failed probe used to be a no-op forever -- after a board reboot (no daemon,
    # no /dev/shm/qpsk_tun.log) the link never came back (148 H-7 reboot, 13:54). Now: if the
    # board answers ping but the probe fails twice in a row, run the recovery chain.
    echo "$(date +%F_%T) probe failed (ssh?)" >> $LOG
    PF=$((${PF:-0}+1))
    # 2026-08-29: cap consecutive post-reboot recoveries (standing rule: no retry loops). After
    # RECOV_MAX attempts with no successful probe in between, stop attempting and keep probing only,
    # so a genuinely dark board is left in a diagnosable state for the operator. RECOV_N resets on
    # any successful probe (below).
    if [ "${RECOV_N:-0}" -ge "${RECOV_MAX:-3}" ]; then
      [ "${RECOV_CAPPED:-0}" = 1 ] || { echo "$(date +%F_%T) recovery CAPPED after ${RECOV_MAX:-3} attempts with no successful probe -- probing only, operator attention" >> $LOG; RECOV_CAPPED=1; }
    elif [ $PF -ge 2 ] && ping -c1 -W2 10.0.0.148 >/dev/null 2>&1 && ping -c1 -W2 10.0.0.146 >/dev/null 2>&1; then
      RECOV_N=$(( ${RECOV_N:-0} + 1 ))
      [ -e "$STOP" ] && exit 0
      echo "$(date +%F_%T) probe failed x$PF with both boards pingable -- recovering (post-reboot bring-up)" >> $LOG
      PF=0
      GATE_DIR=A GATE_TRIES=8 $D/bringup_r2r3.sh r3 >> $LOG 2>&1
      for B in 10.0.0.146 10.0.0.148; do
        $D/anyssh.sh $B 'pkill -f lock_watchdog' 2>/dev/null
        $D/anyssh.sh $B 'chmod +x /root/lock_watchdog.sh; : > /dev/shm/lock_watchdog.log' 2>/dev/null
        $D/anyssh.sh $B 'nohup /root/lock_watchdog.sh > /dev/shm/lock_watchdog.log 2>&1 &' 2>/dev/null
      done
      echo "$(date +%F_%T) recovery chain done (post-reboot, attempt $RECOV_N/${RECOV_MAX:-3})" >> $LOG
    fi
  fi
  [ -n "$r" ] && PF=0
  sleep 290
done
