#!/bin/bash
# =============================================================================
# tap_smoke.sh [target=A] -- Phase D smoke test of the DEBUG-TAP image:
#   1. arm both boards (radiators-first -S, verified lock, 148 gain pin --
#      exact error_hunt.sh discipline)
#   2. state-pair regs 0x160-0x16C: read twice 1 s apart; must be nonzero and
#      CHANGING (StatePairProbe latches every 4096th rail beat, free-running)
#   3. iq_debug_mux 0x10C: for each mode 0..3 capture 1M samples of the TAP
#      stream (axi-adrv9002-rx2-lpc voltage0 = mux out; dual-DMA layout from
#      bd_tap_dualdma -- the driver exposes one complex pair per device, so the
#      tap rides the rx2 DMA on BOTH images) + one rx-lpc capture (receiver
#      input) per mode for datapath-stability
#   4. offline python check: rx-lpc RMS stable across modes (datapath
#      untouched by the mux), tap alive in every mode, mode-3 (constellation)
#      magnitude CV < 0.35 (pi/4-QPSK is constant-modulus -- the strongest
#      single-number check)
# Prints TAP_SMOKE_PASS / TAP_SMOKE_FAIL. Artifacts in two_jup/tapsmoke/<ts>/.
# Modes: 0=AGC out (reset default), 1=postSymbolSync, 2=postCarrierSync,
#        3=constellation (FTS/1). Regs: 0x160 AGC_IN 0x164 AGC_OUT 0x168 CS_IN
#        0x16C CS_OUT, packed (uint16 I)<<16|(uint16 Q), stored-int.
# KNOWN LIMITATION: 0x168/0x16C (CS pairs) latch hard zeros (model-level probe
# input wiring; redundant with mux modes 2/3, not worth an IP regen) -- the
# state-reg gate keys on the AGC pairs only.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A_IP=10.0.0.148; B_IP=10.0.0.146
FWD=2000000000; REV=1900000000
TGT=${1:-A}
case "$TGT" in
  A) T_IP=$A_IP;; B) T_IP=$B_IP;; *) echo "target must be A or B" >&2; exit 2;;
esac
OUT=$D/tapsmoke/$(date +%Y%m%d_%H%M%S)_$TGT
mkdir -p "$OUT"
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
lastrow(){ $W $1 'grep "seq: t=" /dev/shm/acc.log 2>/dev/null | tail -1' 2>/dev/null; }
okof(){ echo "$1" | grep -oE 'ok=[0-9]+' | grep -oE '[0-9]+'; }
resync(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; busybox devmem 0x9D300000 32 0x1' 2>/dev/null; }

arm(){ # $1 ip $2 txlo $3 rxlo   (VERBATIM error_hunt.sh arm)
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

echo "=== TAP SMOKE $(date -Is): tap board $T_IP ==="
for ip in $B_IP $A_IP; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; pkill -x iio_readdev 2>/dev/null; sleep 0.4' 2>/dev/null
done
arm $B_IP $FWD $REV
arm $A_IP $REV $FWD
for ip in $B_IP $A_IP; do
  $W $ip "cd /root/host_app_k5; rm -f /dev/shm/acc.log /dev/shm/seq_events.log /dev/shm/seq_raw.log; setsid sh -c './qpsk_tun -S -d 300 > /dev/shm/acc.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
done
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
[ "$OK" = 1 ] || { echo "TAP_SMOKE_FAIL: no verified lock"; exit 1; }
G=$($W $A_IP 'cat /sys/bus/iio/devices/iio:device2/in_voltage0_hardwaregain' 2>/dev/null)
GV=$(echo "$G" | grep -oE '^[0-9.]+')
$W $A_IP "P=/sys/bus/iio/devices/iio:device2; echo spi > \$P/in_voltage0_gain_control_mode; echo $GV > \$P/in_voltage0_hardwaregain" 2>/dev/null
echo "  148 Rx gain pinned: $GV dB; link locked"

# --- 2. state-pair regs: two reads, 1 s apart -------------------------------
echo "--- state regs (0x160 AGC_IN / 0x164 AGC_OUT / 0x168 CS_IN / 0x16C CS_OUT) ---"
SREAD='DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  for r in 0x160 0x164 0x168 0x16C; do echo $r > $DRA; printf "%s=%s " $r $(cat $DRA); done; echo'
S1=$($W $T_IP "$SREAD" 2>/dev/null); sleep 1; S2=$($W $T_IP "$SREAD" 2>/dev/null)
echo "  t0: $S1"; echo "  t1: $S2"
echo "$S1" > "$OUT/state_reads.txt"; echo "$S2" >> "$OUT/state_reads.txt"
SOK=PASS
[ -z "$S1" ] && SOK="FAIL(empty)"
echo "$S1" | grep -qE '=0x[0-9a-fA-F]*[1-9a-fA-F]' || SOK="FAIL(all-zero)"
[ "$S1" = "$S2" ] && SOK="FAIL(frozen)"   # free-running latch must move between reads
echo "  state regs: $SOK"

# --- 3. per-mode captures: tap (rx2-lpc) + receiver input (rx-lpc) -----------
for m in 0 1 2 3; do
  echo "--- mux mode $m ---"
  $W $T_IP "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo '0x10C 0x$m' > \$DRA
    rm -f /dev/shm/tap_m$m.bin /dev/shm/in_m$m.bin
    iio_readdev -u local: -b 65536 -s 1048576 axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /dev/shm/tap_m$m.bin 2>/dev/shm/tap_err.txt \
      || cat /dev/shm/tap_err.txt
    iio_readdev -u local: -b 65536 -s 1048576 axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/in_m$m.bin 2>>/dev/shm/tap_err.txt \
      || cat /dev/shm/tap_err.txt
    ls -l /dev/shm/tap_m$m.bin /dev/shm/in_m$m.bin" 2>/dev/null
  scpput root@$T_IP:/dev/shm/tap_m$m.bin "$OUT/tap_m$m.bin" || { echo "TAP_SMOKE_FAIL: pull tap m$m"; exit 1; }
  scpput root@$T_IP:/dev/shm/in_m$m.bin "$OUT/in_m$m.bin"   || { echo "TAP_SMOKE_FAIL: pull in m$m"; exit 1; }
  for f in "$OUT/tap_m$m.bin" "$OUT/in_m$m.bin"; do
    [ "$(stat -c %s "$f")" -gt 1000000 ] || { echo "TAP_SMOKE_FAIL: $f empty/short"; exit 1; }
  done
done
$W $T_IP "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo '0x10C 0x0' > \$DRA; rm -f /dev/shm/tap_m*.bin /dev/shm/in_m*.bin /dev/shm/tap_err.txt" 2>/dev/null
for ip in $B_IP $A_IP; do $W $ip 'pkill -x qpsk_tun 2>/dev/null' 2>/dev/null; done

# --- 4. offline checks --------------------------------------------------------
python3 - "$OUT" <<'PYEOF'
import sys, numpy as np
out = sys.argv[1]; fails = []
def cplx(path, nch):
    d = np.fromfile(path, dtype="<i2")
    d = d[: (len(d)//nch)*nch ].reshape(-1, nch).astype(np.float64)
    return d[:,0] + 1j*d[:,1]
v0rms = {}
for m in range(4):
    v0 = cplx(f"{out}/in_m{m}.bin", 2)
    v1 = cplx(f"{out}/tap_m{m}.bin", 2)
    v0rms[m] = np.sqrt(np.mean(np.abs(v0)**2))
    r1 = np.sqrt(np.mean(np.abs(v1)**2))
    mag = np.abs(v1); mcv = mag.std()/mag.mean() if mag.mean() > 0 else 9.9
    print(f"  mode {m}: in_rms={v0rms[m]:8.1f}  tap_rms={r1:8.1f}  tap_magCV={mcv:.3f}")
    if r1 < 10: fails.append(f"mode{m} tap dead (rms={r1:.1f})")
    if m == 3 and mcv > 0.35: fails.append(f"mode3 magCV={mcv:.3f} not constellation-like")
r = list(v0rms.values())
if max(r) > 1.5*min(r): fails.append(f"receiver-input rms unstable across modes: {r}")
print("TAP_SMOKE_" + ("FAIL: " + "; ".join(fails) if fails else "PASS"))
PYEOF
echo "artifacts: $OUT"
