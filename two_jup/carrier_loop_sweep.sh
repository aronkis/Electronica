#!/bin/bash
# =============================================================================
# carrier_loop_sweep.sh -- tune the reverse-link carrier loop at RUNTIME via the
# loop_gain AXI regs (0x170-0x184, LEAN) to reduce the ROM-confirmed PHY dither.
#
# Reverse ROM/BIST at +20k off-null showed a real PHY floor: cap_out golden ~94%,
# cfc dither std~694, rstcs ~1.5/s -> the carrier loop hunts/dithers. This sweeps
# the loop constants and measures, in FABRIC (BIST, DMA-plane-independent):
#   golden% (0x144==0x04922282), cfc-std (0x154), rstcs rate (0x150), BIST (0x108).
#
# loop_gain regs (write to override the synthesized default; readback=0 is normal):
#   0x170 cs_prop_gain  ufix16_En16  default SI 98
#   0x174 cs_integ_gain ufix16_En16  default SI 1
#   0x178 ss_prop_gain  sfix24_En24  default SI -163506
#   0x17C ss_integ_gain sfix24_En24  default SI -2180
#   0x180 agc_loop_gain ufix32_En31
#   0x184 cfo_threshold fi[1 22 21]  default SI 26214 (=0.0125 norm)
#
# Usage: carrier_loop_sweep.sh              # full sweep
#        LO_B_RX=1900020000 carrier_loop_sweep.sh
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146            # A=148 reverse TX, B=146 reverse RX (tune target)
PROF=lvds_61p44_fdd_jupiter
LO_A_TX=1900000000; LO_A_RX=2000000000
LO_B_TX=2000000000; LO_B_RX=${LO_B_RX:-1900020000}   # +20k off-null
SOAK=${SOAK:-15}                      # seconds per setting
OUT=$D/loopsweep/$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
GOLDEN=0x04922282

arm_rom(){ # $1 ip $2 txlo $3 rxlo  (identical to reverse_rom_soak.sh)
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
 echo '$1 armed ROM'" 2>/dev/null
}
rearm_rom(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }

# poke a loop reg on B: $1=offset $2=value(dec)  (empty value -> skip = default)
poke(){ [ -z "${2:-}" ] && return 0; local hv=$(printf '0x%x' "$2")
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; echo '$1 $hv'>\$DRA" 2>/dev/null; }

# soak+log B registers @10Hz for $SOAK s, pull, analyze -> one line of metrics
measure(){ # $1 label
  local lbl="$1" N=$(( SOAK * 10 ))
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; rd(){ echo \"\$1\">\$DRA;cat \$DRA; }
   : > /dev/shm/lsw.log
   for i in \$(seq $N); do echo \"cap=\$(rd 0x144) rstcs=\$(rd 0x150) cfc=\$(rd 0x154) biterr=\$(rd 0x108) g170=\$(rd 0x170) g184=\$(rd 0x184)\" >> /dev/shm/lsw.log; sleep 0.1; done" 2>/dev/null
  SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no root@$B:/dev/shm/lsw.log "$OUT/$lbl.log" </dev/null 2>/dev/null
  python3 - "$OUT/$lbl.log" "$lbl" <<'PY'
import re,sys,numpy as np
rows=[]
for ln in open(sys.argv[1]):
    m=re.search(r"cap=0x([0-9a-fA-F]+).*rstcs=0x([0-9a-fA-F]+).*cfc=0x([0-9a-fA-F]+).*biterr=0x([0-9a-fA-F]+)",ln)
    if m: rows.append([int(m.group(i),16) for i in range(1,5)])
a=np.array(rows)
if a.shape[0]<5: print(f"{sys.argv[2]}: too few"); sys.exit()
cap,rst,cfc,be=a[:,0],a[:,1],a[:,2],a[:,3]
def sx21(u):
    u=int(u)&0x1FFFFF; return u-(1<<21) if u>=(1<<20) else u
cfcs=np.array([sx21(v) for v in cfc])
gold=100*np.mean(cap==0x04922282)
print(f"{sys.argv[2]:22s} golden={gold:5.1f}%  cfc_std={cfcs.std():5.0f}  rstcs/s={(rst[-1]-rst[0])/(len(rst)*0.1):.2f}  biterr/s={(be[-1]-be[0])/(len(be)*0.1):.0f}")
PY
}

echo "=== carrier_loop_sweep: reverse ROM +20k off-null ($LO_B_RX) -> $OUT ==="
arm_rom $B $LO_B_TX $LO_B_RX & arm_rom $A $LO_A_TX $LO_A_RX & wait
echo "146: $($D/apply_146_ssi_fix.sh $B 3 4 2>&1 | tail -1)"
echo "148: $(FORCE=1 $D/apply_146_ssi_fix.sh $A 5 3 2>&1 | tail -1)"
rearm_rom $B; rearm_rom $A; sleep 3; rearm_rom $B; rearm_rom $A
# golden gate
for t in 1 2 3 4 5 6; do sleep 2
  cap=$($W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo "0x144">$DRA; cat $DRA' 2>/dev/null)
  echo "  gate $t: cap=$cap"
  [ "$(( ${cap:-0} ))" -eq "$(( 0x04922282 ))" ] && { echo "  LOCKED GOLDEN"; break; }
  rearm_rom $B; rearm_rom $A; sleep 2; rearm_rom $B; rearm_rom $A
done

{
echo "# baseline (no poke)"; measure "baseline"
# --- FUNCTIONAL VERIFY: poke cs_prop to a clearly different value, expect change ---
echo "# VERIFY cs_prop 0x170=300 (should perturb the loop if regs are live)"; poke 0x170 300; sleep 3; measure "verify_csprop300"
poke 0x170 98; sleep 2   # restore default explicitly
echo "# --- cfo_threshold 0x184 sweep (deadband: wider -> fewer CFO resets) ---"
for v in 0 13107 26214 52428 104857; do poke 0x184 $v; sleep 3; measure "cfo_thr_$v"; done
poke 0x184 26214; sleep 2
echo "# --- cs_prop_gain 0x170 sweep (carrier loop bandwidth) ---"
for v in 24 49 98 196; do poke 0x170 $v; sleep 3; measure "csprop_$v"; done
poke 0x170 98; sleep 2
echo "# --- cs_integ_gain 0x174 sweep ---"
for v in 0 1 2 4; do poke 0x174 $v; sleep 3; measure "csinteg_$v"; done
poke 0x174 1
} 2>&1 | tee "$OUT/sweep.txt"

# quiesce
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; busybox devmem 0x9D000000 32 0 2>/dev/null' 2>/dev/null
$W $A 'busybox devmem 0x9D000000 32 0 2>/dev/null' 2>/dev/null
echo "CARRIER_LOOP_SWEEP_DONE $OUT"
