#!/bin/bash
# start_daemon_146.sh -- start ONLY 146's plain daemon, with bringup_r2r3.sh's own
# start_daemon() launch line (R3: -G -M 16 -r 15360 -i tun0 -s 5, RXQ=1, RXCYC=0 on B),
# as the RX drain for the reverse fabric leg when the cyclic ring will not drain.
# It does NOT re-arm the radio and does NOT touch 0x158/0x114 -- the leg owns those.
# Verified by read-back. Env: DRY=1 (default).
set -u
D=$(cd "$(dirname "$0")/.." && pwd); W=$D/anyssh.sh
B=10.0.0.146; TB=10.66.0.1; TA=10.66.0.2
DRY=${DRY:-1}
if [ "$DRY" = 1 ]; then echo "[dry] start qpsk_tun on $B (-G -M 16 -r 15360 -i tun0 -s 5, QPSK_RX_QUEUED=1, QPSK_RX_CYCLIC=0)"; exit 0; fi
$W $B "cd /root/host_app_k5; QPSK_WHITEN=0 QPSK_RX_CYCLIC=0 QPSK_RX_QUEUED=1 setsid chrt -f 50 ./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5 </dev/null >/dev/shm/qpsk_tun.log 2>&1 &
 n=0; while [ \$n -lt 15 ]; do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; n=\$((n+1)); done
 ip addr replace $TB peer $TA dev tun0; ip link set tun0 up mtu 1516; ip route replace $TA dev tun0 advmss 1476 rto_min 25ms 2>/dev/null
 echo DAEMON=\$(pgrep -x qpsk_tun | tr '\n' ',')" 2>&1 | tr -d '\r'
