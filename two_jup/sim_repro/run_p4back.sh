#!/bin/bash
# Re-flash probe-4 (02e8c97d6181) onto 148 after the 146 series restores the link (health precondition needs a live link).
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad
ROOT=/mnt/onetb/scratch/qpsk-jupiter-modem; cd $ROOT/two_jup; . sim_repro/riglock.sh; W=./anyssh.sh; A=10.0.0.148
log(){ echo "$(date +%F_%T) $*" | tee -a $S/p4back_chain.log; }
until grep -q "T146_CHAIN_DONE\|T146_STOP" $S/tseries_146.log 2>/dev/null; do sleep 30; done; until [ ! -e "$RIG_LOCK" ]; do sleep 20; done; sleep 30
n=0; until [ $n -ge 20 ]; do h=$(bash health_probe_reset_aware.sh $A 6 2>/dev/null | tail -1); f=$(echo "$h" | grep -oE 'fsync=[0-9]+' | tr -dc 0-9); w=$(echo "$h" | grep -oE 'wcnt=[0-9]+' | tr -dc 0-9); [ "${f:-0}" -ge 1100 ] && [ "${w:-0}" -ge 1100 ] && break; n=$((n+1)); sleep 60; done
[ $n -lt 20 ] || { log "P4B_STOP 148 not healthy: $h"; exit 1; }
rig_lock p4back || { log "P4B_STOP lock busy"; exit 1; }; trap rig_unlock EXIT
systemctl --user stop 'sentinelkeeper-*' 2>/dev/null; for p in $(pgrep -f "[d]elivery_sentinel.sh"); do kill $p; done; touch /home/tcollins/modem-status/SENTINEL_STOP
CUR=$($W $A "md5sum /boot/BOOT.BIN | cut -c1-12" 2>/dev/null); log "148 runs $CUR; flashing probe-4 02e8c97d6181"
BB=$ROOT/jupiter_byte_probe4_build/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN BAK_MD5=$CUR bash skidfix/flash_148_rxfifo_diag.sh 02e8c97d6181 > $S/flash_p4back2.log 2>&1; RC=$?
tail -3 $S/flash_p4back2.log | tee -a $S/p4back_chain.log
grep -q "FLASH_RXFIFO_DIAG_DONE" $S/flash_p4back2.log || { log "P4B_STOP flash rc=$RC -- rig stays held"; exit 1; }
rig_unlock; rm -f /home/tcollins/modem-status/SENTINEL_STOP; systemd-run --user --unit=sentinelkeeper-$(date +%H%M%S) --collect bash $S/sentinel_keeper.sh; log "rig released, keeper relaunched"
log "P4B_CHAIN_DONE"
