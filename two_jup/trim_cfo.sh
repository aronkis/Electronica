#!/bin/bash
# trim_cfo.sh — measure the XO offset (unarmed capture on RX board) and compute the
# trimmed TX LO. Prints "TXLO=<hz> CFO=<hz>" and exits 0 when |residual| would be <300 Hz.
# Usage: trim_cfo.sh [TX_IP RX_IP CARRIER_HZ]   (TX must already be transmitting, RX unarmed)
# NOTE: the RX board's modem must be UNARMED (capture taps raw ADC only when unarmed).
set -u
TX=${1:-10.0.0.146}; RX=${2:-10.0.0.148}; CARRIER=${3:-2000000000}
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
scpget(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
$W $RX 'rm -f /dev/shm/tc.iq; timeout 6 iio_readdev -u local: -b 32768 -s 250000 axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/tc.iq 2>/dev/null' 2>/dev/null
scpget root@$RX:/dev/shm/tc.iq /tmp/trim_cfo_cap.iq
V=$(python3 "$D/gonogo_verdict.py" /tmp/trim_cfo_cap.iq)
CFO=$(echo "$V" | grep -oE 'cfo=[+-][0-9]+' | cut -d= -f2)
if [ -z "${CFO:-}" ]; then echo "TRIM_FAIL verdict='$V'"; exit 2; fi
CURTX=$($W $TX 'cat /sys/bus/iio/devices/iio:device2/out_altvoltage2_TX1_LO_frequency' 2>/dev/null)
NEWTX=$((CURTX - CFO))
echo "measured CFO=${CFO}Hz at TXLO=${CURTX} -> trimmed TXLO=${NEWTX} (verdict: $V)"
echo "TXLO=$NEWTX CFO=$CFO"
if [ ${CFO#-} -lt 300 ]; then exit 0; else exit 1; fi
