#!/bin/bash
# final_restore.sh -- Task 6 end state: restore both boards and quiesce 148's injectors.
# Every write is followed by a read-back; an empty ssh is "unreachable", never "done".
set -u
D=$(cd "$(dirname "$0")/.." && pwd); W=$D/anyssh.sh; A=10.0.0.148; B=10.0.0.146
log(){ echo "$(date -Is) [restore] $*"; }
log "--- 148: TX gain -> 0 dB, TGEN off, sink off ---"
R=$($W $A 'DM=$(command -v devmem || echo "busybox devmem")
P=/sys/bus/iio/devices/iio:device2
echo 0 > $P/out_voltage0_hardwaregain 2>/dev/null; sleep 0.5
$DM 0x9D400000 32 0 >/dev/null
C=$($DM 0x9D410000); $DM 0x9D410000 32 $(( C & ~1 )) >/dev/null
echo "txgain=$(cat $P/out_voltage0_hardwaregain) rxgain=$(cat $P/in_voltage0_hardwaregain) tgen=$($DM 0x9D400000) tgenrx=$($DM 0x9D410000) tun=$(pgrep -x qpsk_tun | tr "\n" ",") wd=$(pgrep -f "[l]ock_watchdog" | tr "\n" ",")"' 2>/dev/null | tr -d '\r')
log "148: $R"
case "$R" in *txgain=*) : ;; *) log "148 UNREACHABLE"; echo "RESTORE_FAIL_148"; exit 3;; esac
log "--- 146: ensm -> rf_enabled ---"
R2=$($W $B 'P=/sys/bus/iio/devices/iio:device2
echo rf_enabled > $P/out_voltage0_ensm_mode 2>/dev/null; sleep 1
echo "ensm=$(cat $P/out_voltage0_ensm_mode) txgain=$(cat $P/out_voltage0_hardwaregain) tun=$(pgrep -x qpsk_tun | tr "\n" ",") wd=$(pgrep -f "[l]ock_watchdog" | tr "\n" ",")"' 2>/dev/null | tr -d '\r')
log "146: $R2"
case "$R2" in *ensm=rf_enabled*) log "146_RESTORE_VERIFIED=1";; *) log "146_RESTORE_VERIFIED=0 *** $R2 ***";; esac
case "$R" in *"txgain=0.000000"*) log "148_TXGAIN_VERIFIED=1";; *) log "148_TXGAIN_VERIFIED=0";; esac
case "$R" in *"tgen=0x00000000"*) log "148_TGEN_OFF_VERIFIED=1";; *) log "148_TGEN_OFF_VERIFIED=0";; esac
echo "FINAL_RESTORE_DONE"
