#!/bin/bash
# tests/fake_anyssh_rung.sh HOST CMD -- variant of fake_anyssh.sh that proves the
# golden-or-known-rung capture credit path (Task 8 fix round 1): the 2nd 0x20C
# read (mid's PRE-capture read) returns a known burst word instead of golden;
# every other 0x20C read (arm-time check, mid POST, onset PRE/POST) stays golden.
# Everything else is identical to fake_anyssh.sh. State in $FAKE_STATE.
S=${FAKE_STATE:-/tmp/fake148_rung}; mkdir -p "$S"; CMD=$2
case "$CMD" in
  *"echo 0x104 >"*) n=$(( $(cat "$S/p" 2>/dev/null || echo 0) + 2500 )); echo $n > "$S/p"; echo $n ;;
  *"echo 0x108 >"*) k=$(( $(cat "$S/k" 2>/dev/null || echo 0) + 1 )); echo $k > "$S/k"
                     e=$(cat "$S/e" 2>/dev/null || echo 0); [ $k -ge 4 ] && e=$((e+20000)) || e=$((e+51)); echo $e > "$S/e"; echo $e ;;
  *"echo 0x20C >"*) c=$(( $(cat "$S/c20c" 2>/dev/null || echo 0) + 1 )); echo $c > "$S/c20c"
                     if [ "$c" -eq 2 ]; then echo 0xD71F70D3; else echo 0xBCF94856; fi ;;
  *iio_readdev*)     echo "BOARD $(( ${SZ:-134217728}*4 ))" ;;
  *"cat /tmp/g.bin"*) head -c $(( ${SZ:-1024}*4 )) /dev/zero ;;
  *) : ;;
esac
