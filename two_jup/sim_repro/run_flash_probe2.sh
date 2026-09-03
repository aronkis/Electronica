#!/bin/bash
# chain: wait for the DMAC-probe build -> acceptance -> bank -> rig health -> flash 148 (rails, diag census,
# health gate, auto-rollback, NO retry) -> matrix -> restore the link (bring-up) -> release.
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem; B=$ROOT/jupiter_byte_probe2_build; Z=$B/hdl_prj_jupiter_composite/vivado_ip_prj
cd $ROOT/two_jup; . sim_repro/riglock.sh; trap rig_unlock EXIT
log(){ echo "$(date +%F_%T) $*" | tee -a $S/flash_probe2_chain.log; }
while ! grep -q "PROBE2_IMAGE_DONE" $B/build_probe2.log 2>/dev/null; do sleep 60; done
grep -q "PROBE2_IMAGE_DONE" $B/build_probe2.log || { log "CHAIN_STOP build failed"; exit 1; }
MD5=$(md5sum $Z/boot/BOOT.BIN | cut -c1-12); AGE=$(( $(date +%s) - $(stat -c %Y $Z/boot/BOOT.BIN) ))
[ $AGE -lt 36000 ] || { log "CHAIN_STOP BOOT.BIN not fresh"; exit 1; }
case $MD5 in fe5bd8a4fe19|602b26c25c35|$(md5sum /mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_byte_dmacprobe_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN 2>/dev/null | cut -c1-12)) log "CHAIN_STOP md5 equals a prior image"; exit 1;; esac
WNS=$(python3 - $Z/vivado_prj.runs/impl_1/system_top_timing_summary_routed.rpt <<'PY'
import sys,re
L=open(sys.argv[1]).read().splitlines()
for i,l in enumerate(L):
    if 'Design Timing Summary' in l:
        for j in range(i+1,i+12):
            m=re.match(r'\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)',L[j])
            if m: print(m.group(1)); sys.exit(0)
print('nan')
PY
)
until [ -f $S/probe1_rig_done ]; do sleep 60; done
log "BUILD_ACCEPT md5=$MD5 WNS=$WNS"
python3 -c "import sys; sys.exit(0 if float('$WNS')>=0 else 1)" || { log "CHAIN_STOP WNS negative"; exit 1; }
cp $Z/boot/BOOT.BIN $ROOT/boot_known_good/BOOT.BIN.148.probe2.$MD5
n=0; until [ $n -ge 40 ]; do h=$(bash health_probe_reset_aware.sh 10.0.0.148 6 2>/dev/null | tail -1); f=$(echo "$h" | grep -oE 'fsync=[0-9]+' | tr -dc 0-9); w=$(echo "$h" | grep -oE 'wcnt=[0-9]+' | tr -dc 0-9); [ "${f:-0}" -ge 1100 ] && [ "${w:-0}" -ge 1100 ] && break; n=$((n+1)); sleep 60; done
[ $n -lt 40 ] || { log "CHAIN_STOP 148 not healthy in 40 min: $h"; exit 1; }
while ps -eo args | grep -qE "^(/bin/bash|bash) (/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/)?(bringup_r2r3|restore_known_good|capture_r3|soak_bidir)\.sh"; do sleep 30; done
rig_lock flash_probe2_chain; systemctl --user stop 'sentinelkeeper-*' 2>/dev/null; touch /home/tcollins/modem-status/SENTINEL_STOP
log "FLASH start md5=$MD5"
BB=$Z/boot/BOOT.BIN BAK_MD5=$(bash anyssh.sh 10.0.0.148 "md5sum /boot/BOOT.BIN | cut -c1-12" 2>/dev/null) bash skidfix/flash_148_rxfifo_diag.sh $MD5 > $S/flash_probe2.log 2>&1; RC=$?
tail -4 $S/flash_probe2.log | tee -a $S/flash_probe2_chain.log
grep -q "FLASH_RXFIFO_DIAG_DONE" $S/flash_probe2.log || { log "CHAIN_STOP flash rc=$RC (rolled back or fatal; NO retry)"; exit 1; }
log "RXCHK leg 1: normal link, RXQ=1 default (link is up from the flash bring-up)"; DUR=90 bash rxchk_run.sh 2>&1 | tee -a $S/flash_probe2_chain.log
log "RXCHK leg 2: same, second window"; DUR=90 bash rxchk_run.sh 2>&1 | tee -a $S/flash_probe2_chain.log
log "RXCHK leg 3: RXQ=0 (reset-per-transfer) bring-up"; RXQ=0 GATE_DIR=A GATE_TRIES=8 bash bringup_r2r3.sh r3 > $S/probe2_rxq0_bringup.log 2>&1; tail -1 $S/probe2_rxq0_bringup.log | tee -a $S/flash_probe2_chain.log; DUR=90 bash rxchk_run.sh 2>&1 | tee -a $S/flash_probe2_chain.log
log "RESTORE link (bring-up)"; GATE_DIR=A GATE_TRIES=8 bash bringup_r2r3.sh r3 > $S/postprobe_bringup.log 2>&1; tail -2 $S/postprobe_bringup.log | tee -a $S/flash_probe2_chain.log
log "CHAIN_DONE"
