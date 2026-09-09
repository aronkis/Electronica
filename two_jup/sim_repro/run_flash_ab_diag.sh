#!/bin/bash
# Self-gating chain: wait for the FIFO-4k build -> verify build acceptance (fresh BOOT.BIN,
# WNS >= 0, BRAM tiles grew) -> wait for rig health -> flash 148 under the rails
# (auto-rollback, no retry) -> A/B legs: FIFO alone (RXQ=0, vs the 13.9 % baseline) then
# FIFO + queued default (RXQ=1). Any gate failure stops the chain; nothing is retried.
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad
B=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_byte_rxfifo4k_build
Z=$B/hdl_prj_jupiter_composite/vivado_ip_prj
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
. sim_repro/riglock.sh; trap rig_unlock EXIT
log(){ echo "$(date +%F_%T) $*" | tee -a $S/flash_ab_chain.log; }
while ! grep -q "BUILD_EXIT" $S/rxfifo_build.log 2>/dev/null; do sleep 120; done
grep -q "RXFIFO_IMAGE_BUILD_DONE" $S/rxfifo_build.log || { log "CHAIN_STOP build failed"; exit 1; }
MD5=$(md5sum $Z/boot/BOOT.BIN | cut -c1-12); AGE=$(( $(date +%s) - $(stat -c %Y $Z/boot/BOOT.BIN) ))
[ $AGE -lt 36000 ] || { log "CHAIN_STOP BOOT.BIN not fresh (age ${AGE}s)"; exit 1; }
[ "$MD5" != "fe5bd8a4fe19" ] || { log "CHAIN_STOP image md5 equals the comb image"; exit 1; }
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
BRAM=$(grep -E "^\| Block RAM Tile " $Z/vivado_prj.runs/impl_1/system_top_utilization_placed.rpt | awk -F'|' '{print $3}' | tr -d ' ')
REGS=$(grep -E "^\| CLB Registers " $Z/vivado_prj.runs/impl_1/system_top_utilization_placed.rpt | head -1 | awk -F'|' '{print $3}' | tr -d ' ')
log "BUILD_ACCEPT md5=$MD5 WNS=$WNS BRAM=$BRAM regs=$REGS"
python3 -c "import sys; sys.exit(0 if float('$WNS')>=0 else 1)" || { log "CHAIN_STOP WNS negative"; exit 1; }
python3 -c "import sys; sys.exit(0 if float('${BRAM:-0}')>=66 else 1)" || { log "CHAIN_STOP BRAM tiles $BRAM < 66 -- FIFO did not infer BRAM"; exit 1; }
cp $Z/boot/BOOT.BIN /mnt/onetb/scratch/qpsk-jupiter-modem/boot_known_good/BOOT.BIN.148.rxfifo4k.$MD5
# rig health precondition (the flash script re-checks; this just avoids flashing into a recovery)
n=0; until [ $n -ge 40 ]; do h=$(bash health_probe_reset_aware.sh 10.0.0.148 6 2>/dev/null | tail -1); f=$(echo "$h" | grep -oE 'fsync=[0-9]+' | tr -dc 0-9); w=$(echo "$h" | grep -oE 'wcnt=[0-9]+' | tr -dc 0-9); [ "${f:-0}" -ge 1100 ] && [ "${w:-0}" -ge 1100 ] && break
  # the sentinel is held while this chain is armed, so recover the link ourselves (single actor) after 3 unhealthy probes
  if [ $n -ge 3 ] && [ $((n % 8)) -eq 3 ] && ping -c1 -W2 10.0.0.148 >/dev/null 2>&1 && ping -c1 -W2 10.0.0.146 >/dev/null 2>&1; then
    while ps -eo args | grep -qE "^(/bin/bash|bash) (/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/)?(bringup_r2r3|restore_known_good|capture_r3|soak_bidir)\.sh"; do sleep 30; done; [ -e "$RIG_LOCK" ] && { sleep 60; continue; }; log "148 unhealthy ($h) -- single-actor restore before the flash"; rig_lock flash_ab_chain_restore; bash restore_known_good.sh > $S/chain_restore_$n.log 2>&1; rig_unlock; fi
  n=$((n+1)); sleep 60; done
[ $n -lt 40 ] || { log "CHAIN_STOP 148 not healthy in 40 min: $h"; exit 1; }
# single-actor: never start while any bring-up / capture / sentinel recovery is mid-flight
while ps -eo args | grep -qE "^(/bin/bash|bash) (/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/)?(bringup_r2r3|restore_known_good|capture_r3|soak_bidir)\.sh"; do sleep 30; done
rig_lock flash_ab_chain
log "FLASH start md5=$MD5 (RIG_LOCK held for flash + both A/B arms)"
bash skidfix/flash_148_rxfifo_diag.sh $MD5 > $S/flash_rxfifo.log 2>&1; RC=$?
tail -4 $S/flash_rxfifo.log | tee -a $S/flash_ab_chain.log
grep -q "FLASH_RXFIFO_DIAG_DONE" $S/flash_rxfifo.log || { log "CHAIN_STOP flash rc=$RC (rolled back or fatal; NO retry)"; exit 1; }
log "AB arm 1: FIFO alone (RXQ=0)"; RIGLOCK_PARENT=1 RXQ=0 bash sim_repro/ab_fifo_legs.sh fifo4k_rxq0; cat $S/ab_fifo4k_rxq0.txt >> $S/flash_ab_chain.log
log "AB arm 2: FIFO + queued default (RXQ=1)"; RIGLOCK_PARENT=1 RXQ=1 bash sim_repro/ab_fifo_legs.sh fifo4k_rxq1; cat $S/ab_fifo4k_rxq1.txt >> $S/flash_ab_chain.log
log "CHAIN_DONE"; echo done > $S/flash_ab_chain.done
