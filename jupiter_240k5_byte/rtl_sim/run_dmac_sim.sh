#!/bin/bash
# run_dmac_sim.sh -- build (once) and run the real-axi_dmac harness. Env knobs: see sim_byte_dmac.cpp header.
set -u
cd "$(dirname "$0")"
LB=../../jupiter_byte_rxfifo4k_build/hdl_prj_jupiter_composite/vivado_ip_prj/library
if [ ! -x obj_dmac/Vwrap_byte_dmac ] || [ "${REBUILD:-0}" = 1 ]; then
  verilator -O3 --cc --exe --build -j 8 -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH \
    -y dmac_src -y $LB/common -y $LB/util_axis_fifo -y $LB/util_cdc -Idmac_src \
    --top-module wrap_byte_dmac wrap_byte_dmac.v sim_byte_dmac.cpp -Mdir obj_dmac > obj_dmac_build.log 2>&1 \
    || { echo BUILD_FAILED; grep -E "%Error|error:" obj_dmac_build.log | head; exit 1; }
fi
exec ./obj_dmac/Vwrap_byte_dmac "$@"
