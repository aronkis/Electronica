#!/bin/bash
# RXFIX Jupiter composite build (CFOChangeDetectThreshold 0.0015625 -> 0.0125).
# Everything else bit-exact vs fec_jupiter_nodescr (7331df2e): FEC deint+Viterbi,
# nodescr, skip reg 0x138, caps 0x13C/0x140/0x144, counters.
cd /mnt/onetb/scratch/qpsk_variants/fec_jupiter_rxfix
source /tools/Xilinx/2025.1/Vivado/settings64.sh
# canonical Jupiter build env (build_env_jupiter.sh)
export ADI_MAX_OOC_JOBS=4 ADI_LIB_JOBS=8 ADI_LIB_CACHE_DIR=/mnt/onetb/scratch/adi_lib_cache ADI_MAX_THREADS=12
# dedicated ip cache for this variant (avoid stale-cache smart-build skips)
export ADI_IP_CACHE_DIR=/mnt/onetb/scratch/adi_ipcache_rxfix
/mnt/onetb/MATLAB/R2025b/bin/matlab -batch "run('/mnt/onetb/scratch/qpsk_variants/fec_jupiter_rxfix/build_variant_fec_dbg.m')"
echo "BUILD_SCRIPT_EXIT=$?"
