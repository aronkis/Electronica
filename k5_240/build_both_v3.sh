#!/bin/bash
# sequential: zed (fit-critical) then jupiter
cd /mnt/onetb/scratch/qpsk_variants/zed_240k5
rm -rf hdl_prj_zed_composite
source ./build_env_zed.sh 2>/dev/null
/mnt/onetb/MATLAB/R2025b/bin/matlab -batch "run('/mnt/onetb/scratch/qpsk_variants/zed_240k5/build_variant_zed_240k5.m')" > build_zed_240k5_v3.log 2>&1
Z=$(find hdl_prj_zed_composite -name BOOT.BIN 2>/dev/null | head -1)
echo "ZED_BUILD_DONE artifact=${Z:-NONE} $(test -n "$Z" && md5sum "$Z")"
cd /mnt/onetb/scratch/qpsk_variants/jupiter_240k5
rm -rf hdl_prj_jupiter_composite
/mnt/onetb/MATLAB/R2025b/bin/matlab -batch "run('/mnt/onetb/scratch/qpsk_variants/jupiter_240k5/build_variant_jupiter_240k5.m')" > build_jupiter_240k5_v3.log 2>&1
J=$(find hdl_prj_jupiter_composite -name BOOT.BIN 2>/dev/null | head -1)
echo "JUP_BUILD_DONE artifact=${J:-NONE} $(test -n "$J" && md5sum "$J")"
