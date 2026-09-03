#!/bin/bash
# run_dmac_sim_rtl.sh -- real egress RTL + real axi_dmac. FIFO=orig64|v4 selects the ByteRxFifo build.
set -u
cd "$(dirname "$0")"
LB=../../jupiter_byte_rxfifo4k_build/hdl_prj_jupiter_composite/vivado_ip_prj/library
FIFO=${FIFO:-orig64}; V4=0; [ "$FIFO" = v4 ] && V4=1
OBJ=obj_dmac_rtl_$FIFO
if [ ! -x $OBJ/Vwrap_byte_dmac_rtl ] || [ "${REBUILD:-0}" = 1 ]; then
  verilator -O3 --cc --exe --build -j 8 -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -GFIFO_V4=$V4 \
    -y dmac_src -y dmac_src/egress -y $LB/common -y $LB/util_axis_fifo -y $LB/util_cdc -Idmac_src \
    --top-module wrap_byte_dmac_rtl wrap_byte_dmac_rtl.v sim_byte_dmac_rtl.cpp -Mdir $OBJ > ${OBJ}_build.log 2>&1 \
    || { echo BUILD_FAILED; grep -E "%Error|error:" ${OBJ}_build.log | head; exit 1; }
fi
FIFO_TAG=$FIFO exec ./$OBJ/Vwrap_byte_dmac_rtl "$@"
