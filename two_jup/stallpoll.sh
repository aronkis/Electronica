#!/bin/sh
# T8.5 stall-catch on-board poller: samples 0x104/0x150 + canaries 0x170-0x188
# via debugfs direct_reg_access into /dev/shm/stallcatch.csv. Arg1 = seconds.
DUR=${1:-14400}; O=/dev/shm/stallcatch.csv
DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
echo "t_ns,pkts,rstcs,pdiv_cnt,pdiv_beat,idiv_beat,ip,is,strobe,beat,ta_ops,ta_diag,biterr" > $O
END=$(( $(date +%s) + DUR ))
while [ $(date +%s) -lt $END ]; do
  L=$(date +%s%N)
  for R in 0x104 0x150 0x170 0x174 0x178 0x17C 0x180 0x184 0x188 0x1E0 0x1E4 0x108; do
    echo $R > $DRA 2>/dev/null
    L="$L,$(cat $DRA 2>/dev/null)"
  done
  echo "$L" >> $O
done
