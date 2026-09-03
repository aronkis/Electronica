#!/bin/bash
LOG=/mnt/onetb/scratch/qpsk_variants/jupiter_240k5/build_t8pn_orchestrator.log
until grep -qE 'T8FIX_BUILD_DONE|T8FIX_BUILD_FAILED|FATAL' "$LOG" 2>/dev/null; do sleep 120; done
if ! grep -q 'T8FIX_BUILD_DONE' "$LOG"; then echo "CHAIN ABORT: build failed"; tail -4 "$LOG"; exit 1; fi
B=/mnt/onetb/scratch/qpsk_variants/jupiter_t8pn/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN
echo "CHAIN: build done ($(md5sum $B | cut -c1-12)) -> deploy+G1"
exec /mnt/onetb/scratch/qpsk_variants/two_jup/g1_pn.sh "$B"
