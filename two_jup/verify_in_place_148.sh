#!/bin/bash
# verify_in_place_148.sh -- operator option 1 (2026-09-02): run the flash chain's post-flash steps by hand on the
# image already booted on 148: two-pass mode-1 gate (ARM_OK, fps>=1120, golden capTAP), then the sel6 witness
# capture decoded with ddrcap2_decode.py. On gate failure: restore /boot from /root/BOOT.BIN.1cd0cd752aa6.bak,
# reboot, wait for ssh, one baseline arm, STOP (no retry). 148 only; 146 never touched.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; A=10.0.0.148; EXP=638b36de3493; BAK=1cd0cd752aa6
L=$D/skidfix/ddrcap2_verify_$(date +%Y%m%d_%H%M%S).log
say(){ echo "$(date +%T) $*" | tee -a "$L"; }
brd(){ $W $A "$@" 2>/dev/null | tr -d '\r'; }
poll_md5(){ local t=0 m=""; while [ $t -lt 360 ]; do m=$(brd 'md5sum /boot/BOOT.BIN | cut -c1-12'); [ -n "$m" ] && { echo "$m"; return 0; }; sleep 10; t=$((t+10)); done; echo ""; return 1; }
gate(){ local o f; o=$(bash "$D/arm148_mode1.sh" 2>&1); echo "$o" | grep -E "found:|post-arm|ARM_" | tee -a "$L"
  echo "$o" | grep -q ARM_OK || return 1; f=$(echo "$o" | sed -n 's/.*ARM_OK.*fps=\([0-9]*\).*/\1/p' | tail -1); [ "${f:-0}" -ge 1120 ]; }
restore(){ say "=== RESTORE to $BAK (gate failed; rail: no retry) ==="
  R=$(brd "cp -f /root/BOOT.BIN.$BAK.bak /boot/BOOT.BIN && sync && md5sum /boot/BOOT.BIN | cut -c1-12"); say "  restore-copy: $R"
  [ "$R" = "$BAK" ] || { say "VERIFY_FATAL: restore-copy failed -- PHYSICAL ATTENTION (no reboot issued)"; exit 2; }
  brd 'sync; (sleep 1; reboot) &'; sleep 45; local n=0; until ping -c1 -W2 $A >/dev/null 2>&1; do sleep 5; n=$((n+5)); [ $n -gt 240 ] && { say "VERIFY_FATAL: not back after restore reboot -- PHYSICAL ATTENTION"; exit 2; }; done
  M=$(poll_md5); say "  restored image booted: $M (expect $BAK)"; gate || say "  WARN: post-restore baseline arm not ARM_OK"; say "VERIFY_RESTORED_$BAK"; exit 1; }
say "=== verify-in-place on 148: image $(brd 'md5sum /boot/BOOT.BIN | cut -c1-12') (expect $EXP) ==="
say "=== gate pass 1 ==="; gate || restore
say "=== gate pass 2 ==="; gate || restore
say "  GATE_PASS x2"
say "=== Tier-2 witness: sel6, 1 M records, decoded ==="
brd "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; echo '0x10C 0x60003' > /sys/kernel/debug/iio/iio:device0/direct_reg_access; sleep 1; cd /tmp && rm -f w.bin && timeout 120 iio_readdev -b 4096 -s 1048576 axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /tmp/w.bin 2>/dev/null; stat -c 'BOARD %s' /tmp/w.bin" | tee -a "$L"
timeout 180 $W $A 'cat /tmp/w.bin' > "$D/skidfix/ddrcap2_witness_$EXP.bin" 2>/dev/null; say "  witness bytes: $(stat -c %s "$D/skidfix/ddrcap2_witness_$EXP.bin" 2>/dev/null || echo 0)"
python3 "$D/ddrcap2_decode.py" "$D/skidfix/ddrcap2_witness_$EXP.bin" --summary 2>&1 | tee -a "$L"
say "VERIFY_IN_PLACE_OK $EXP"
