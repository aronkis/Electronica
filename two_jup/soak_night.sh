#!/bin/bash
# soak_night.sh -- RX-seam zero-loss soak, 3x600s, reboot-based recovery on arm
# lottery misses (146-down contingency: no two-board restore available).
cd /mnt/onetb/scratch/qpsk-jupiter-modem
reboot148(){
  two_jup/anyssh.sh 10.0.0.148 'sync; ( sleep 2; reboot ) >/dev/null 2>&1 & exit 0' 2>/dev/null
  sleep 40
  for i in $(seq 1 60); do sleep 10
    U=$(two_jup/anyssh.sh 10.0.0.148 'cut -d" " -f1 /proc/uptime' 2>/dev/null)
    case "$U" in [0-9]*) return 0;; esac
  done
  return 1
}
: > rxseam_soak_status.txt
for i in 1 2 3; do
  for try in 1 2 3; do
    DUR=600 bash two_jup/rxseam_zeroloss.sh > rxseam_soak_${i}_v2.log 2>&1
    OK=$(grep -oE "ok=[0-9]+" rxseam_soak_${i}_v2.log | head -1 | tr -dc 0-9)
    if [ "${OK:-0}" -gt 1000 ]; then break; fi
    echo "soak $i attempt $try miss (ok=${OK:-0}) -- full restore recovery" >> rxseam_soak_status.txt
    bash two_jup/restore_known_good.sh > /tmp/soak_restore.log 2>&1
  done
  grep -E "RXSEAM_ZEROLOSS|SEQRX frames" rxseam_soak_${i}_v2.log | head -2 >> rxseam_soak_status.txt
done
echo SOAK_V2_DONE >> rxseam_soak_status.txt
