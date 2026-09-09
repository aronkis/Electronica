#!/bin/bash
# =============================================================================
# modem_status.sh [--json] [--watch N] -- READ-ONLY health readout for the R3 link.
#
# SAFETY CONTRACT (this is the whole design, not a footnote):
#   1. It NEVER writes a register. No direct_reg_access writes, no re-arms, no
#      profile touches. Running it can never change link state.
#   2. It NEVER reads direct_reg_access either. That interface is a single
#      address latch shared by every reader, and concurrent readers corrupt each
#      other -- measured 2026-08-07: stallpoll and lock_watchdog running together
#      put a foreign register's value (0xC010180 = adc_forensic 0x15C) into the
#      packet-count column of 0.08% of soak rows, which silently poisoned run-based
#      statistics. A monitor that polls debugfs would be a THIRD reader and would
#      corrupt whatever measurement is in flight.
#   => Every field below is sourced from a file that no one holds a latch on:
#      the daemon's own stats line, the watchdog's own log, sysfs, procfs.
#      The daemon and watchdog already read the registers; we read what they wrote.
#      This is strictly better than polling: same data, zero contention.
#
# Consequence worth knowing: fields are as fresh as their WRITER, not as fresh as
# the call. The daemon dumps stats on its own cadence and the watchdog decides every
# ~5 s, so "age" is reported per field rather than pretending everything is current.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=${A_IP:-10.0.0.146}; B=${B_IP:-10.0.0.148}
JSON=0; WATCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json)  JSON=1; shift ;;
    --watch) WATCH=${2:-10}; shift 2 ;;
    *) echo "usage: modem_status.sh [--json] [--watch SECONDS]" >&2; exit 2 ;;
  esac
done

# One ssh round trip per board; everything is a file read.
# $2 = "skipimg" to omit the boot-image md5. That md5 hashes 7 MB off the SD card,
# which is fine once but wasteful every tick of a --watch loop, and the image cannot
# change without a reboot -- so watch mode reads it on the first pass and reuses it.
probe(){
  local skip=${2:-}
  $W "$1" '
    IMG=""
    [ "'"$skip"'" = skipimg ] || IMG=$(md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-12)
    pgrep -x qpsk_tun       >/dev/null && DAEMON=up   || DAEMON=down
    pgrep -f "[l]ock_watchdog" >/dev/null && WD=up     || WD=down
    pgrep -f "[s]tallpoll"  >/dev/null && POLL=up      || POLL=down
    L=/dev/shm/qpsk_tun.log
    STATS=$(grep "stats:" $L 2>/dev/null | tail -1)
    NAK=$(grep "nakstat:" $L 2>/dev/null | tail -1)
    ARQ=$(grep -c "cross-link NAK ARQ ON" $L 2>/dev/null)
    SAGE=$([ -f $L ] && echo $(( $(date +%s) - $(stat -c %Y $L) )) || echo -1)
    WL=/dev/shm/watchdog.log
    WLAST=$(grep -oE "(LOCKED|NOT-LOCKED)[^)]*\)" $WL 2>/dev/null | tail -1)
    WREARM=$(grep -c "FULL RE-ARM" $WL 2>/dev/null)
    WAGE=$([ -f $WL ] && echo $(( $(date +%s) - $(stat -c %Y $WL) )) || echo -1)
    UP=$(cut -d" " -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
    LOAD=$(cut -d" " -f1 /proc/loadavg 2>/dev/null)
    TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    echo "IMG=$IMG"; echo "DAEMON=$DAEMON"; echo "WD=$WD"; echo "POLL=$POLL"
    echo "ARQ=$ARQ"; echo "STATS_AGE=$SAGE"; echo "WD_AGE=$WAGE"
    echo "REARMS=$WREARM"; echo "UPTIME=$UP"; echo "LOAD=$LOAD"; echo "TEMP=$TEMP"
    echo "WLAST=$WLAST"; echo "STATS=$STATS"; echo "NAK=$NAK"
  ' 2>/dev/null
}

fld(){ echo "$1" | grep "^$2=" | head -1 | cut -d= -f2-; }
sget(){ echo "$1" | tr " " "\n" | grep "^$2=" | head -1 | cut -d= -f2; }

render_board(){
  local ip=$1 raw=$2
  local img=$(fld "$raw" IMG) dmn=$(fld "$raw" DAEMON) wd=$(fld "$raw" WD)
  local poll=$(fld "$raw" POLL) arq=$(fld "$raw" ARQ) sage=$(fld "$raw" STATS_AGE)
  local wage=$(fld "$raw" WD_AGE) rearm=$(fld "$raw" REARMS) up=$(fld "$raw" UPTIME)
  local load=$(fld "$raw" LOAD) temp=$(fld "$raw" TEMP)
  local wlast=$(fld "$raw" WLAST) stats=$(fld "$raw" STATS) nak=$(fld "$raw" NAK)
  # in watch mode the md5 is fetched once; reuse the cached value on later passes
  [ -z "$img" ] && img="${IMG_CACHE:-?}"
  [ "$img" = "?" ] && { printf "  %-12s UNREACHABLE\n" "$ip"; return; }
  local tc="n/a"; [ -n "$temp" ] && tc="$(( temp / 1000 ))C"
  printf "  %-12s image %-14s uptime %ss  load %s  %s\n" "$ip" "$img" "${up:-?}" "${load:-?}" "$tc"
  printf "               daemon %-5s watchdog %-5s poller %-5s arq %s\n" \
         "$dmn" "$wd" "$poll" "$([ "${arq:-0}" -gt 0 ] 2>/dev/null && echo ON || echo off)"
  printf "               watchdog: %s   re-arms %s  (log %ss old)\n" \
         "${wlast:-none}" "${rearm:-0}" "${wage:--}"
  if [ -n "$stats" ]; then
    printf "               rx_ok %-9s crc_drop %-9s seq_gap %-7s (stats %ss old)\n" \
      "$(sget "$stats" dma_rx_ok)" "$(sget "$stats" crc_drop)" "$(sget "$stats" seq_gap)" "${sage:--}"
    printf "               arq: recovered %-7s dups %-7s naks_tx %-7s naks_rx %-7s lost %s\n" \
      "$(sget "$stats" recovered)" "$(sget "$stats" dups)" "$(sget "$stats" naks_tx)" \
      "$(sget "$stats" naks_rx)" "$(sget "$stats" arq_lost)"
  else
    printf "               no stats line yet in /dev/shm/qpsk_tun.log\n"
  fi
  [ -n "$nak" ] && printf "               nakstat: seen %-8s magic %-8s parsed %s\n" \
      "$(sget "$nak" seen)" "$(sget "$nak" magic)" "$(sget "$nak" parsed)"
}

IMG_A=""; IMG_B=""
once(){
  # first pass reads the boot-image md5; later passes skip it (see probe())
  if [ -z "$IMG_A" ]; then RA=$(probe "$A"); IMG_A=$(fld "$RA" IMG)
  else RA=$(probe "$A" skipimg); fi
  if [ -z "$IMG_B" ]; then RB=$(probe "$B"); IMG_B=$(fld "$RB" IMG)
  else RB=$(probe "$B" skipimg); fi
  if [ "$JSON" = 1 ]; then
    esc(){ echo "$1" | sed 's/"/\\"/g'; }
    printf '{"t":"%s",' "$(date -Is)"
    for pair in "a:$A:$RA" "b:$B:$RB"; do
      k=${pair%%:*}; rest=${pair#*:}; ip=${rest%%:*}; raw=${rest#*:}
      printf '"%s":{"ip":"%s"' "$k" "$ip"
      for f in IMG DAEMON WD POLL ARQ REARMS STATS_AGE WD_AGE UPTIME LOAD TEMP; do
        printf ',"%s":"%s"' "$(echo $f | tr A-Z a-z)" "$(esc "$(fld "$raw" $f)")"
      done
      printf ',"wlast":"%s"' "$(esc "$(fld "$raw" WLAST)")"
      printf '}'
      [ "$k" = a ] && printf ','
    done
    printf '}\n'
  else
    echo "=== R3 link status  $(date +%H:%M:%S) ==="
    IMG_CACHE=$IMG_A render_board "$A" "$RA"
    IMG_CACHE=$IMG_B render_board "$B" "$RB"
    echo "  (read-only: no register writes, no direct_reg_access reads -- see header)"
  fi
}

if [ "$WATCH" -gt 0 ] 2>/dev/null; then
  while :; do clear 2>/dev/null; once; sleep "$WATCH"; done
else
  once
fi
