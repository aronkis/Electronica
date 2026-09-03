#!/bin/bash
# tun_ssh_key.sh -- (1) set up SSH pubkey auth OUT-OF-BAND over the wired LAN,
# (2) bring up the quiet-pair FDD link (2.00/1.90, WHITEN=0 so BOTH boards lock),
# (3) run the ENTROPY DISCRIMINATOR (blast /dev/urandom over tun0 -> does the peer's
# dma_rx_ok climb?  climbs => high-entropy payloads pass => SSH is viable; stays 0 =>
# deterministic corruption, SSH doomed), (4) SSH 146->148 OVER tun0 with pubkey +
# minimal-KEX (ed25519 hostkey, curve25519 kex, chacha20 aead) + robust timeouts.
#   146 = client = tun0 10.66.0.1     148 = server = tun0 10.66.0.2
# Entropy note: default `ping` payload is a low-entropy ramp -> will still show loss
# even when SSH (encrypted, high-entropy, self-whitening) sails through.  Judge by SSH.
set -u
TXA=2000000000; FB=1900000000        # 146 TX@2.00 -> RX@1.90
TXB=1900000000; FA=2000000000        # 148 TX@1.90 -> RX@2.00
WHITEN=${WHITEN:-0}
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
OUT=$D/resid; mkdir -p "$OUT"; LOG=$OUT/tun_ssh_key.log
exec > >(tee "$LOG") 2>&1
echo "=== tun_ssh_key $(date -Is)  WHITEN=$WHITEN ==="

# ---------------- Phase 0: quiesce both boards ----------------
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; ip addr flush dev tun0 2>/dev/null; sleep 0.3; echo "'$ip' cleared"' 2>/dev/null
done

# ---------------- Phase 1: SSH pubkey setup (wired LAN, no RF) ----------------
echo "--- Phase 1: SSH key setup (out-of-band) ---"
$W 10.0.0.146 'mkdir -p /root/.ssh; chmod 700 /root/.ssh; [ -f /root/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -q; echo "146 keypair ready"' 2>/dev/null
PUB=$($W 10.0.0.146 'cat /root/.ssh/id_ed25519.pub' 2>/dev/null | tr -d '\r')
echo "  146 pubkey: $PUB"
PUB_B64=$(printf '%s' "$PUB" | base64 -w0)
$W 10.0.0.148 "mkdir -p /root/.ssh; chmod 700 /root/.ssh; touch /root/.ssh/authorized_keys
 K=\$(echo $PUB_B64 | base64 -d)
 grep -qF \"\$K\" /root/.ssh/authorized_keys || echo \"\$K\" >> /root/.ssh/authorized_keys
 chmod 600 /root/.ssh/authorized_keys
 echo \"  148 authorized_keys lines: \$(wc -l < /root/.ssh/authorized_keys)\"
 echo \"  148 PermitRootLogin: \$(sshd -T 2>/dev/null | grep -i '^permitrootlogin' || echo unknown)\"
 echo \"  148 PubkeyAuthentication: \$(sshd -T 2>/dev/null | grep -i '^pubkeyauthentication' || echo unknown)\"
 [ -f /etc/ssh/ssh_host_ed25519_key.pub ] && echo '  148 ed25519 hostkey present'" 2>/dev/null

# ---------------- Phase 2: bring up the RF link (WHITEN=$WHITEN) ----------------
coldstart(){ # $1 ip $2 txlo $3 rxlo $4 tunaddr $5 peer
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
   cd /root/host_app_k5; QPSK_WHITEN=$WHITEN setsid ./qpsk_tun -F -i tun0 -s 30 </dev/null >/dev/shm/qpsk_tun.log 2>&1 &
   rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &
   n=0; while [ \$n -lt 15 ]; do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; n=\$((n+1)); done
   ip addr replace $4 peer $5 dev tun0; ip link set tun0 up mtu 116; ip route replace $5 dev tun0 advmss 56 rto_min 25ms 2>/dev/null
   echo '$1 cold-started (quiet 2.00/1.90, WHITEN=$WHITEN), tun0 set'" 2>/dev/null
}
echo "--- Phase 2: cold start (quiet pair, WHITEN=$WHITEN) ---"
coldstart 10.0.0.146 $TXA $FB 10.66.0.1 10.66.0.2 &
coldstart 10.0.0.148 $TXB $FA 10.66.0.2 10.66.0.1 &
wait
echo "  waiting ~40s for watchdogs to lock..."; sleep 40
for ip in 10.0.0.146 10.0.0.148; do
  echo "  --- $ip ---"
  $W $ip 'echo "    wd: $(tail -1 /dev/shm/watchdog.log 2>/dev/null)"; echo "    tun0: $(ip -o addr show tun0 2>/dev/null | grep -oE "inet [0-9.]+")"' 2>/dev/null
done

# ---------------- Phase 3: ENTROPY DISCRIMINATOR ----------------
echo "--- Phase 3: entropy discriminator (urandom 146->148 over tun0) ---"
pre=$($W 10.0.0.148 'grep "qpsk_tun stats" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1 | grep -oE "dma_rx_ok=[0-9]+ crc_drop=[0-9]+"' 2>/dev/null)
echo "  148 PRE : $pre"
$W 10.0.0.146 'python3 - <<PY 2>/dev/null
import socket,os,time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
for i in range(600):
    s.sendto(os.urandom(80),("10.66.0.2",9999))   # 80B urandom + 28B hdr = 108 <= mtu116
    time.sleep(0.01)                               # ~100 pps, within frame rate
print("sent 600 urandom UDP frames")
PY' 2>/dev/null
sleep 4
post=$($W 10.0.0.148 'grep "qpsk_tun stats" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1 | grep -oE "dma_rx_ok=[0-9]+ crc_drop=[0-9]+"' 2>/dev/null)
echo "  148 POST: $post"
echo "  (dma_rx_ok climbing on urandom => high-entropy payloads pass => SSH viable)"

# ---------------- Phase 4: SSH 146 -> 148 OVER tun0 (pubkey, minimal KEX) ----------------
echo "--- Phase 4: SSH 146 -> 148 over tun0 (pubkey + minimal-KEX + robust) ---"
$W 10.0.0.146 'timeout 150 ssh -i /root/.ssh/id_ed25519 \
   -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
   -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o PubkeyAuthentication=yes \
   -o HostKeyAlgorithms=ssh-ed25519 -o KexAlgorithms=curve25519-sha256 \
   -o Ciphers=chacha20-poly1305@openssh.com \
   -o ConnectTimeout=120 -o ConnectionAttempts=2 \
   -o ServerAliveInterval=5 -o ServerAliveCountMax=30 -o TCPKeepAlive=yes \
   -o LogLevel=ERROR -n \
   root@10.66.0.2 "echo RF-SSH-OK; hostname; uname -sr; uptime; cat /proc/loadavg" 2>&1 | sed "s/^/  ssh> /"' 2>/dev/null
rc=$?
echo "=== DONE (rc=$rc; link left UP) $(date -Is) ==="
