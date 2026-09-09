#!/bin/bash
# =============================================================================
# lna_experiment.sh -- measure the RX1A HMC8414 LNA's effect on the REVERSE
# link's EVM/SNR floor by toggling adrv9002 AGPIO4 (RX1A LNA bypass control).
#
#   Reverse link: 148 TX@1.90 GHz -> 146 RX@1.90 GHz.  Receiver / tap = 146 (B).
#   Mechanism: /sys/kernel/debug/iio/iio:device2 (adrv9002-phy) agpio4_value
#              (HIGH=LNA on, LOW=bypass), per Jupiter HW doc RX1A->agpio4.
#
#   IMPORTANT: the standard arm() (link_test.sh / capture_evm.sh) sets the
#   BLOCK agpio4,5,6,7 = HIGH -- so the LNA is ALREADY ON in every armed
#   baseline (incl. the C2 EVM-budget captures). This script measures what
#   happens when RX1A's LNA is turned OFF (agpio4=0) relative to that baseline.
#   It touches ONLY agpio4 (5/6/7 left as arm set them -- likely T/R switch /
#   PA controls). It does NOT re-arm between the two captures (a re-arm would
#   silently restore agpio4=1).
#
# Discipline: one anyssh per board; /dev/shm scratch; rx2-lpc tap only; no
# S2MM capture; never flashes; restores agpio4=1 + quiesces both boards on exit.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A_IP=10.0.0.148; B_IP=10.0.0.146
FWD_HZ=2000000000; REV_HZ=1900000000
RX=$B_IP                       # reverse receiver / tap board = 146
NSAMP=${NSAMP:-2000000}        # reverse is tick-free; 2M ~= 1 s (matches rev1/gate)
DUR=${DUR:-60}                 # per-state BER window, seconds
TS=$(date +%Y%m%d_%H%M%S)
L1=$D/evmcap/${TS}_rev_lna1    # baseline (LNA on) session dir
L0=$D/evmcap/${TS}_rev_lna0    # LNA-off session dir

scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

# Receiver RF/AGC state -- hwgain is the linchpin: with AGC in 'automatic' it
# should JUMP ~17-19 dB when the LNA turns OFF (proving agpio4 is the live
# RX1A LNA control and the modem RX is on RX1A).
rxstate(){ $W $RX 'P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
  echo "  agpio4=$(cat $DB/agpio4_value 2>/dev/null) hwgain=$(cat $P/in_voltage0_hardwaregain 2>/dev/null) rssi=$(cat $P/in_voltage0_rssi 2>/dev/null) decpow=$(cat $P/in_voltage0_decimated_power 2>/dev/null) gainmode=$(cat $P/in_voltage0_gain_control_mode 2>/dev/null)"' 2>/dev/null; }

# modem FPGA regs (device0): pkts climbing == link locked & scoring
snap(){ $W $RX 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo "$1">$DRA;cat $DRA; }; echo "  pkts=$(rd 0x104) rstcs=$(rd 0x150) level=$(rd 0x15C)"' 2>/dev/null; }

setmode(){ $W $RX "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; echo '0x10C 0x$1' > \$DRA" 2>/dev/null; }
setlna(){ $W $RX "echo $1 > /sys/kernel/debug/iio/iio:device2/agpio4_value; echo '  agpio4 now='\$(cat /sys/kernel/debug/iio/iio:device2/agpio4_value)" 2>/dev/null; }

# capture ONE mode-3 rx2-lpc tap + one raw rx-lpc passthrough into $1, no re-arm
cap_session(){ # $1 outdir  $2 label
  mkdir -p "$1"
  setmode 3; sleep 0.5
  $W $RX "rm -f /dev/shm/tap_m3.bin; iio_readdev -u local: -b 65536 -s $NSAMP axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /dev/shm/tap_m3.bin 2>/tmp/iio.err || cat /tmp/iio.err; ls -l /dev/shm/tap_m3.bin" 2>/dev/null
  setmode 0; sleep 0.3
  $W $RX "rm -f /dev/shm/raw.iq; iio_readdev -u local: -b 65536 -s $NSAMP axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/raw.iq 2>/tmp/iior.err || cat /tmp/iior.err; ls -l /dev/shm/raw.iq" 2>/dev/null
  scpput root@$RX:/dev/shm/tap_m3.bin "$1/tap_m3.bin"
  scpput root@$RX:/dev/shm/raw.iq "$1/raw.iq"
  $W $RX 'rm -f /dev/shm/tap_m3.bin /dev/shm/raw.iq /tmp/iio*.err' 2>/dev/null
  { echo "target=B dir=rev tap_ip=$RX modes=[3] nsamp=$NSAMP fwd=$FWD_HZ rev=$REV_HZ ts=$(date -Is)"; echo "label=$2"; } > "$1/meta.txt"
  echo "  captured -> $1 ($(stat -c %s "$1/tap_m3.bin" 2>/dev/null||echo 0) B tap)"
}

# 60 s BER per state (reverse scored by 146). No watchdog launched here to avoid
# re-arm churn; rxfix image holds lock on the quiet pair for the window.
ber_run(){ # $1 label
  $W $B_IP "cd /root/host_app_k5; setsid sh -c './qpsk_tun -B -d $DUR >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
  $W $A_IP "cd /root/host_app_k5; setsid sh -c './qpsk_tun -B -d $DUR >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
  sleep $((DUR+10))
  echo "--- BER reverse ($1), scored by 146 ---"
  $W $B_IP 'cat /dev/shm/ber.log' 2>/dev/null | grep -E 'full-packet report|frames_scored=|buckets:|^ber:' | tail -4 | sed 's/^/  /'
  $W $B_IP 'pkill -x qpsk_tun 2>/dev/null' 2>/dev/null; $W $A_IP 'pkill -x qpsk_tun 2>/dev/null' 2>/dev/null
}

quiesce_both(){
  $W $B_IP 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; pkill -x iio_readdev 2>/dev/null; ip addr flush dev tun0 2>/dev/null; echo "  146 cleared"' 2>/dev/null
  $W $A_IP 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; pkill -x iio_readdev 2>/dev/null; ip addr flush dev tun0 2>/dev/null; echo "  148 cleared"' 2>/dev/null
}

# always leave RX1A LNA ON (baseline) + boards idle, even on error/interrupt
cleanup(){ echo "== cleanup: restore agpio4=1 + quiesce =="; setlna 1 >/dev/null 2>&1; setmode 0 >/dev/null 2>&1; quiesce_both; }
trap cleanup EXIT INT TERM

echo "############ LNA EXPERIMENT (reverse; receiver=146; agpio4 only) ############"
echo "NSAMP=$NSAMP  DUR=${DUR}s  L1=$L1  L0=$L0"

# ---- 1. BASELINE (LNA ON): arm both + mode-3 capture via tested capture_evm.sh
echo; echo "==== [1] baseline lna1: arm both (agpio4=1 set by arm) + capture ===="
"$D/capture_evm.sh" B -m 3 -n "$NSAMP" -o "$L1" 2>&1 | sed 's/^/  cap> /'
echo "-- baseline receiver state (expect agpio4=1) --"; rxstate; snap; sleep 3; snap
ber_run lna1

# ---- 2. TOGGLE: LNA OFF (agpio4=0 on 146 only) -- NO re-arm --------------------
echo; echo "==== [2] set RX1A LNA OFF (agpio4=0) -- LINCHPIN: watch hwgain jump ===="
setlna 0; sleep 4
echo "-- lna0 receiver state (hwgain should JUMP ~+17-19 dB if LNA was live) --"; rxstate; snap; sleep 3; snap
cap_session "$L0" rev_lna0
ber_run lna0

# ---- 3. RESTORE + quiesce (also enforced by trap) -----------------------------
echo; echo "==== [3] restore agpio4=1 ===="; setlna 1; sleep 2; rxstate
echo; echo "LNA_EXP_DONE  L1=$L1  L0=$L0"
