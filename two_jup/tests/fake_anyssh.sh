#!/bin/bash
# tests/fake_anyssh.sh HOST CMD -- canned 148 for beat_tap_capture.sh dry runs. State in $FAKE_STATE.
S=${FAKE_STATE:-/tmp/fake148}; mkdir -p "$S"; CMD=$2
case "$CMD" in
  *"echo 0x104 >"*) n=$(( $(cat "$S/p" 2>/dev/null || echo 0) + 2500 )); echo $n > "$S/p"; echo $n ;;
  *"echo 0x108 >"*) k=$(( $(cat "$S/k" 2>/dev/null || echo 0) + 1 )); echo $k > "$S/k"
                     e=$(cat "$S/e" 2>/dev/null || echo 0); [ $k -ge 4 ] && e=$((e+20000)) || e=$((e+51)); echo $e > "$S/e"; echo $e ;;
  *"echo 0x20C >"*) echo 0xBCF94856 ;;
  *iio_readdev*)     echo "BOARD $(( ${SZ:-134217728}*4 ))" ;;
  *"cat /tmp/g.bin"*) head -c $(( ${SZ:-1024}*4 )) /dev/zero ;;
  *) : ;;
esac
