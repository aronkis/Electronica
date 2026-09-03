#!/bin/bash
# =============================================================================
# wedge_offnull_sweep.sh -- measure the reverse-link WEDGE RATE vs RX LO off-null.
#
# The DOMINANT loss is spontaneous loss-of-lock ("wedge": golden->0, cfc_std->~18000)
# ~1/20s, each ~1s. Hypothesis: wedges are CFO drifting back toward the dead-zone
# (CFO~=0 4th-power ambiguity); MORE off-null margin should reduce their rate. This
# soaks reverse ROM at several off-null LOs and counts wedge EPISODES + golden%/BIST,
# in fabric (BIST), DMA-plane-independent.
#
# Usage: wedge_offnull_sweep.sh [soak_secs]   (default 60s/point)
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
PROF=lvds_61p44_fdd_jupiter
LO_A_TX=1900000000; LO_A_RX=2000000000; LO_B_TX=2000000000
SOAK=${1:-60}
OUT=$D/wedgesweep/$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
NULL=1900000000   # reverse RX true null (146 RX for 148 TX @1.9G)

arm_rom(){ # $1 ip $2 txlo $3 rxlo
  $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 pkill -x qpsk_tun 2>/dev/null; pkill -9 -f '[l]ock_watchdog' 2>/dev/null; sleep 0.5
 cat /root/$PROF.bin > \$P/stream_config 2>/dev/null; cat /root/$PROF.json > \$P/profile_config 2>/dev/null; sleep 2
 echo calibrated > \$P/out_voltage1_ensm_mode 2>/dev/null; echo calibrated > \$P/in_voltage1_ensm_mode 2>/dev/null
 for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
 echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
 echo calibrated > \$P/in_voltage0_ensm_mode 2>/dev/null; echo $3 > \$P/out_altvoltage0_RX1_LO_frequency
 echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x0'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
 TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
 echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
 echo '$1 armed'" 2>/dev/null
}
rearm(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }

soak_count(){ # $1 label  -- soak SOAK s @10Hz, count wedge episodes (golden->nongolden edges)
  local lbl="$1" N=$(( SOAK * 10 ))
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; rd(){ echo \"\$1\">\$DRA;cat \$DRA; }
   : > /dev/shm/wsw.log
   for i in \$(seq $N); do echo \"cap=\$(rd 0x144) biterr=\$(rd 0x108) cfc=\$(rd 0x154) rstcs=\$(rd 0x150)\" >> /dev/shm/wsw.log; sleep 0.1; done" 2>/dev/null
  SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no root@$B:/dev/shm/wsw.log "$OUT/$lbl.log" </dev/null 2>/dev/null
  python3 - "$OUT/$lbl.log" "$lbl" "$SOAK" <<'PY'
import re,sys,numpy as np
rows=[]
for ln in open(sys.argv[1]):
    m=re.search(r"cap=0x([0-9a-fA-F]+).*biterr=0x([0-9a-fA-F]+).*cfc=0x([0-9a-fA-F]+).*rstcs=0x([0-9a-fA-F]+)",ln)
    if m: rows.append([int(m.group(i),16) for i in range(1,5)])
a=np.array(rows)
if a.shape[0]<10: print(f"{sys.argv[2]}: too few"); sys.exit()
cap,be=a[:,0],a[:,1]
g=(cap==0x04922282).astype(int)
gold=100*g.mean()
# wedge episodes = falling edges golden->nongolden that persist >=3 samples (0.3s)
edges=0; i=0; n=len(g)
while i<n-1:
    if g[i]==1 and g[i+1]==0:
        j=i+1
        while j<n and g[j]==0: j+=1
        if j-(i+1)>=3: edges+=1
        i=j
    else: i+=1
dur=float(sys.argv[3])
print(f"{sys.argv[2]:14s} golden={gold:5.1f}%  wedges={edges} ({edges/dur*60:.1f}/min)  biterr/s={(be[-1]-be[0])/(len(be)*0.1):.0f}")
PY
}

echo "=== wedge_offnull_sweep: reverse ROM, ${SOAK}s/point -> $OUT ==="
declare -a OFFS=(20000 40000 80000 160000 320000)   # Hz off-null
for off in "${OFFS[@]}"; do
  rxlo=$(( NULL + off ))
  echo "# off-null +${off}Hz (RX LO $rxlo)"
  arm_rom $B $LO_B_TX $rxlo & arm_rom $A $LO_A_TX $LO_A_RX & wait
  $D/apply_146_ssi_fix.sh $B 3 4 >/dev/null 2>&1; FORCE=1 $D/apply_146_ssi_fix.sh $A 5 3 >/dev/null 2>&1
  rearm $B; rearm $A; sleep 3; rearm $B; rearm $A
  # gate to golden (up to 5 tries)
  for t in 1 2 3 4 5; do sleep 2
    cap=$($W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo "0x144">$DRA;cat $DRA' 2>/dev/null)
    [ "$(( ${cap:-0} ))" -eq "$(( 0x04922282 ))" ] && break
    rearm $B; rearm $A; sleep 2; rearm $B; rearm $A
  done
  soak_count "off_${off}"
done 2>&1 | tee "$OUT/wedge.txt"
$W $B 'busybox devmem 0x9D000000 32 0 2>/dev/null' 2>/dev/null; $W $A 'busybox devmem 0x9D000000 32 0 2>/dev/null' 2>/dev/null
echo "WEDGE_OFFNULL_SWEEP_DONE $OUT"
