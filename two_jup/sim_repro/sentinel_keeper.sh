#!/bin/bash
# Relaunch the sentinel (it exits on SENTINEL_STOP) whenever the hold is absent and no
# sentinel unit is running; checks every 2 min. Never starts one while the hold exists.
while true; do
  if [ ! -e /home/tcollins/modem-status/SENTINEL_STOP ] && [ ! -e /home/tcollins/modem-status/RIG_LOCK ]; then
    if ! ps -eo args | grep -qE "^(/bin/bash|bash) /home/tcollins/modem-status/delivery_sentinel.sh"; then
      systemd-run --user --unit=sentinel-$(date +%H%M%S) --collect /home/tcollins/modem-status/delivery_sentinel.sh >/dev/null 2>&1
      echo "$(date +%F_%T) sentinel (re)launched by keeper" >> /home/tcollins/modem-status/sentinel.log
    fi
  fi
  sleep 120
done
