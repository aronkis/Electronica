#!/bin/bash
# stall_catch.sh <board-ip> [duration_s] -- T8.5 canary stall-catch poller.
# Pushes + launches an on-board loop sampling the modem regfile via debugfs
# direct_reg_access (same mechanism as burst_hunt.sh): 0x104 packets, 0x150
# rstcs, plus the T8.5 canaries:
#   0x170 shdw_pdiv_cnt   P-path upset events         (tear detector)
#   0x174 shdw_pdiv_beat  beat of last P-path event
#   0x178 shdw_idiv_beat  beat of FIRST integrator divergence (0=none)
#   0x17C/0x180 primary/shadow integrator latches
#   0x184 {maxInterStrobeGap[31:16]|skipCnt[15:0]}    (enable starvation)
#   0x188 free-running beat counter
# One CSV line per sweep (~20-80ms) to /dev/shm/stallcatch.csv. The canaries
# LATCH, so cadence only needs to bound the 0x104-freeze localization.
# RULE: start ONLY AFTER bring-up completes (never across profile reloads).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
IP=${1:?usage: stall_catch.sh <ip> [secs]}; DUR=${2:-14400}
echo "=== stall_catch $IP dur=${DUR}s $(date -Is) ==="
$W $IP "cat > /root/stallpoll.sh <<'EOF'
#!/bin/sh
DUR=\$1; O=/dev/shm/stallcatch.csv
DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
echo 't_ns,pkts,rstcs,pdiv_cnt,pdiv_beat,idiv_beat,ip,is,strobe,beat' > \$O
END=\$((\$(date +%s) + DUR))
while [ \$(date +%s) -lt \$END ]; do
  L=\$(date +%s%N)
  for R in 0x104 0x150 0x170 0x174 0x178 0x17C 0x180 0x184 0x188; do
    echo \$R > \$DRA 2>/dev/null
    L=\"\$L,\$(cat \$DRA 2>/dev/null)\"
  done
  echo \"\$L\" >> \$O
done
EOF
chmod +x /root/stallpoll.sh
pkill -f stallpoll.sh 2>/dev/null
setsid /root/stallpoll.sh $DUR </dev/null >/dev/shm/stallpoll.log 2>&1 &
sleep 3; wc -l /dev/shm/stallcatch.csv; head -3 /dev/shm/stallcatch.csv" 2>/dev/null
