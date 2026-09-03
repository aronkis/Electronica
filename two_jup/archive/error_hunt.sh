#!/bin/bash
# =============================================================================
# error_hunt.sh [dur=600] [target=A] -- the ERROR-TRIGGERED IQ CAPTURE session:
# continuous -S both directions (loss-proof accounting), a continuous Tap-A IQ
# ring on the target board, an ON-BOARD trigger listener that saves a
# pre/post window around biterr/lost events, and an on-board scalar poller
# (rstcs/cfc/rssi @5 Hz). Artifacts land in two_jup/hunt/<ts>/ for the offline
# three-way diff (decode_seq_k5 float / replay_capture fixed / live).
#
#   target A = hunt the FORWARD link (ring+listener on 148)
#   target B = hunt the REVERSE link (ring+listener on 146)
#
# Ring: iio_readdev rx-lpc voltage0 (receiver input) | qpsk_ringwrite tmpfs
# ring. Saves: pre=16M post=8M (~2.1 s + 1.05 s) rate-limited to MAX_SAVES with
# MIN_SPACING; all on the safe ADI DMA (never S2MM).
# TAP RING (dual-DMA tap images, bd_tap_dualdma): set TAPMODE=0..3 to also set
# iq_debug_mux 0x10C and run a SECOND ring on axi-adrv9002-rx2-lpc voltage0
# (= the mux stream; TAPMODE=3 -> live constellation). Both rings ride the same
# fabric clock+enable (sample-locked content, independent start offsets); the
# listener saves a window from each per event. RINGMB drops to 256 per ring.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=$(cd "$D/.." && pwd)/host_app_k5
A_IP=10.0.0.148; B_IP=10.0.0.146
FWD=${FWD:-2000000000}; REV=${REV:-1900000000}
DUR=${1:-600}
TGT=${2:-A}
TAPMODE=${TAPMODE:-}       # empty = no tap ring; 0..3 = mux mode + second ring
RINGMB=${RINGMB:-384}
[ -n "$TAPMODE" ] && RINGMB=${RINGMB2:-256}   # two rings must fit tmpfs together
MAX_SAVES=${MAX_SAVES:-6}
MIN_SPACING=${MIN_SPACING:-20}
case "$TGT" in
  A) T_IP=$A_IP; DIRN=fwd;;
  B) T_IP=$B_IP; DIRN=rev;;
  *) echo "target must be A or B" >&2; exit 2;;
esac
OUT=$D/hunt/$(date +%Y%m%d_%H%M%S)_${DIRN}
mkdir -p "$OUT"
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
lastrow(){ $W $1 'grep "seq: t=" /dev/shm/acc.log 2>/dev/null | tail -1' 2>/dev/null; }
okof(){ echo "$1" | grep -oE 'ok=[0-9]+' | grep -oE '[0-9]+'; }
resync(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; busybox devmem 0x9D300000 32 0x1' 2>/dev/null; }

arm(){ # $1 ip $2 txlo $3 rxlo
  $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
   for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
   echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
   echo $3 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
   busybox devmem 0x9D300000 32 0x1; echo '$1 armed'" 2>/dev/null
}

echo "=== ERROR HUNT $(date -Is): ${DUR}s -S, ring+listener on $T_IP ($DIRN) ==="
# --- deploy host tools everywhere (incl. ringwrite on the target) ---
for ip in $B_IP $A_IP; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; pkill -x qpsk_ringwrite 2>/dev/null; pkill -x iio_readdev 2>/dev/null; pkill -f "[h]unt_listener" 2>/dev/null; sleep 0.4' 2>/dev/null
  $W $ip 'mkdir -p /root/host_app_k5' 2>/dev/null
  scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" \
         "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" \
         "$SRC/qpsk_ringwrite.c" root@$ip:/root/host_app_k5/ || { echo "scp $ip FAIL"; exit 1; }
  R=$($W $ip 'cd /root/host_app_k5 && gcc -O2 -Wall -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c 2>/tmp/gcc.err && gcc -O2 -Wall -o qpsk_ringwrite qpsk_ringwrite.c 2>>/tmp/gcc.err && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }' 2>/dev/null)
  echo "  $ip build: $(echo "$R" | tail -1)"; echo "$R" | grep -q BUILD_OK || exit 1
done

# --- on-board trigger listener (deployed via heredoc) ---
$W $T_IP "cat > /root/hunt_listener.sh <<'EOF'
#!/bin/sh
# tail -S events; save a ring window per biterr/lost event (rate-limited)
RING=/dev/shm/iqring.bin; OUT=/dev/shm/hunt; mkdir -p \$OUT
LAST=0; N=0
touch /dev/shm/seq_events.log
tail -n0 -F /dev/shm/seq_events.log 2>/dev/null | while read line; do
  case \"\$line\" in *type=biterr*|*type=lost*) ;; *) continue;; esac
  NOW=\$(date +%s)
  [ \$((NOW-LAST)) -lt $MIN_SPACING ] && continue
  [ \$N -ge $MAX_SAVES ] && continue
  LAST=\$NOW; N=\$((N+1))
  SEQ=\$(echo \"\$line\" | sed 's/.*seq=\\([0-9]*\\).*/\\1/')
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  SR=\$(for r in 0x160 0x164 0x168 0x16C; do echo \$r > \$DRA; printf '%s=%s ' \$r \$(cat \$DRA); done)
  /root/host_app_k5/qpsk_ringwrite --save \$RING \$OUT/ev\${N}_seq\${SEQ}.iq 16M 8M 2>>\$OUT/hunt.log
  [ -f /dev/shm/iqring2.bin ] && /root/host_app_k5/qpsk_ringwrite --save /dev/shm/iqring2.bin \$OUT/ev\${N}_seq\${SEQ}_tap.iq 16M 8M 2>>\$OUT/hunt.log
  echo \"SAVED ev\$N seq=\$SEQ state: \$SR | \$line\" >> \$OUT/hunt.log
done
EOF
chmod +x /root/hunt_listener.sh; rm -rf /dev/shm/hunt; echo listener staged" 2>/dev/null

arm $B_IP $FWD $REV
arm $A_IP $REV $FWD

# --- ring FIRST (history from the start), then radiators, then listener ---
$W $T_IP "rm -f /dev/shm/iqring.bin /dev/shm/iqring2.bin; setsid sh -c 'iio_readdev -u local: -b 65536 axi-adrv9002-rx-lpc voltage0_i voltage0_q | /root/host_app_k5/qpsk_ringwrite /dev/shm/iqring.bin ${RINGMB}M' </dev/null >/dev/null 2>&1 &" 2>/dev/null
if [ -n "$TAPMODE" ]; then
  $W $T_IP "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; echo '0x10C 0x$TAPMODE' > \$DRA
    setsid sh -c 'iio_readdev -u local: -b 65536 axi-adrv9002-rx2-lpc voltage0_i voltage0_q | /root/host_app_k5/qpsk_ringwrite /dev/shm/iqring2.bin ${RINGMB}M' </dev/null >/dev/null 2>&1 &" 2>/dev/null
  echo "  tap ring armed: 0x10C=$TAPMODE, rx2-lpc -> iqring2 (${RINGMB}M)"
fi
for ip in $B_IP $A_IP; do
  $W $ip "cd /root/host_app_k5; rm -f /dev/shm/acc.log /dev/shm/seq_events.log /dev/shm/seq_raw.log; setsid sh -c './qpsk_tun -S -M 32 -d $DUR > /dev/shm/acc.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
done
$W $T_IP 'setsid /root/hunt_listener.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
# on-board scalar poller (5 Hz): rstcs/cfc/rssi
$W $T_IP "setsid sh -c 'rm -f /dev/shm/poll.log; END=\$(( \$(date +%s) + $DUR )); DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  while [ \$(date +%s) -lt \$END ]; do
    echo 0x150 > \$DRA; R=\$(cat \$DRA); echo 0x154 > \$DRA; C=\$(cat \$DRA); echo 0x15C > \$DRA; F=\$(cat \$DRA)
    echo 0x170 > \$DRA; PD=\$(cat \$DRA); echo 0x178 > \$DRA; ID=\$(cat \$DRA); echo 0x184 > \$DRA; SF=\$(cat \$DRA)
    echo 0x18C > \$DRA; PC=\$(cat \$DRA); echo 0x190 > \$DRA; IC=\$(cat \$DRA); echo 0x198 > \$DRA; CL=\$(cat \$DRA); echo 0x1A0 > \$DRA; NC=\$(cat \$DRA)
    echo 0x124 > \$DRA; FS=\$(cat \$DRA); echo 0x130 > \$DRA; DB=\$(cat \$DRA); echo 0x104 > \$DRA; PO=\$(cat \$DRA)
    echo 0x1A4 > \$DRA; V2=\$(cat \$DRA); echo 0x1A8 > \$DRA; V3=\$(cat \$DRA); echo 0x1AC > \$DRA; BW=\$(cat \$DRA)
    echo 0x1B0 > \$DRA; OV=\$(cat \$DRA)
    echo 0x1B4 > \$DRA; PD1=\$(cat \$DRA); echo 0x1B8 > \$DRA; PD2=\$(cat \$DRA); echo 0x1BC > \$DRA; PD3=\$(cat \$DRA)
    echo 0x1C0 > \$DRA; PC1=\$(cat \$DRA); echo 0x1C4 > \$DRA; PC2=\$(cat \$DRA); echo 0x1C8 > \$DRA; PA1=\$(cat \$DRA)
    G=\$(cat /sys/bus/iio/devices/iio:device2/in_voltage0_rssi 2>/dev/null | cut -d\" \" -f1)
    echo \"t=\$(date +%s.%N) rstcs=\$R cfc=\$C forensic=\$F pdiv=\${PD:-na} idiv=\${ID:-na} strobe=\${SF:-na} path=\${PC:-na} icdiv=\${IC:-na} csdiv=\${CL:-na} ncodiv=\${NC:-na} fstart=\${FS:-na} decbits=\${DB:-na} pkts=\${PO:-na} vlf=\${V2:-na} vout=\${V3:-na} rxw=\${BW:-na} fovf=\${OV:-na} pd1=\${PD1:-na} pd2=\${PD2:-na} pd3=\${PD3:-na} pc1=\${PC1:-na} pc2=\${PC2:-na} pa1=\${PA1:-na} rssi=\$G\" >> /dev/shm/poll.log
    sleep 0.2
  done' </dev/null >/dev/null 2>&1 &" 2>/dev/null

# --- acquisition + verified lock + gain pin (BRINGUP discipline) ---
for ip in $B_IP $A_IP; do
  $W $ip 'setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
done
sleep 12
for ip in $B_IP $A_IP; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null' 2>/dev/null; done
CA1=0; CB1=0
for try in 1 2 3 4; do
  sleep 10
  CA0=$CA1; CB0=$CB1
  CA1=$(okof "$(lastrow $A_IP)"); CB1=$(okof "$(lastrow $B_IP)"); CA1=${CA1:-0}; CB1=${CB1:-0}
  echo "  lock check try$try: A ok=$CA1 (was $CA0) | B ok=$CB1 (was $CB0)"
  OK=1
  if [ "$CA1" -le "$CA0" ]; then resync $A_IP; OK=0; fi
  if [ "$CB1" -le "$CB0" ]; then resync $B_IP; OK=0; fi
  [ $OK = 1 ] && break
done
G=$($W $A_IP 'cat /sys/bus/iio/devices/iio:device2/in_voltage0_hardwaregain' 2>/dev/null)
GV=$(echo "$G" | grep -oE '^[0-9.]+')
$W $A_IP "P=/sys/bus/iio/devices/iio:device2; echo spi > \$P/in_voltage0_gain_control_mode; echo $GV > \$P/in_voltage0_hardwaregain" 2>/dev/null
# re-assert the tap mux AFTER lock: any watchdog re-arm's 0x000 toggle resets 0x10C to 0
if [ -n "$TAPMODE" ]; then
  $W $T_IP "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo '0x10C 0x$TAPMODE' > \$DRA; echo 0x10C > \$DRA; echo \"  mux post-lock: \$(cat \$DRA)\"" 2>/dev/null
fi
echo "  148 Rx gain pinned: $GV dB -- hunting for ${DUR}s ..."

sleep $DUR
for ip in $B_IP $A_IP; do
  $W $ip 'pkill -x qpsk_tun 2>/dev/null; pkill -f "[h]unt_listener" 2>/dev/null; pkill -x iio_readdev 2>/dev/null; sleep 1; pkill -x qpsk_ringwrite 2>/dev/null' 2>/dev/null
done

# --- collect ---
for tag in "FWD_into_148:$A_IP" "REV_into_146:$B_IP"; do
  name=${tag%%:*}; ip=${tag##*:}
  echo "--- $name ---"
  $W $ip 'grep -E "SEQTX|SEQRX" /dev/shm/acc.log | head -6' 2>/dev/null
  scpput root@$ip:/dev/shm/acc.log "$OUT/${name}_acc.log" 2>/dev/null || true
  scpput root@$ip:/dev/shm/seq_events.log "$OUT/${name}_events.log" 2>/dev/null || true
  scpput root@$ip:/dev/shm/seq_raw.log "$OUT/${name}_raw.log" 2>/dev/null || true
done
scpput root@$T_IP:/dev/shm/poll.log "$OUT/poll.log" 2>/dev/null || true
SAVES=$($W $T_IP 'ls /dev/shm/hunt/*.iq 2>/dev/null' 2>/dev/null)
echo "ring saves: ${SAVES:-none}"
for f in $SAVES; do
  scpput root@$T_IP:$f "$OUT/$(basename $f)" || echo "pull $f FAIL"
  scpput root@$T_IP:$f.meta "$OUT/$(basename $f).meta" 2>/dev/null || true
done
scpput root@$T_IP:/dev/shm/hunt/hunt.log "$OUT/hunt.log" 2>/dev/null || true
$W $T_IP 'rm -rf /dev/shm/hunt /dev/shm/iqring.bin /dev/shm/iqring2.bin; DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo "0x10C 0x0" > $DRA 2>/dev/null' 2>/dev/null
echo "ERROR_HUNT_DONE $OUT"
