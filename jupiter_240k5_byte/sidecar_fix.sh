#!/bin/bash
# jupiter sidecar v4: the split workflow's state-lossy generation emits a
# vivado_insert_ip.tcl truncated at a NONDETERMINISTIC point (seen: after
# create_bd_cell; after the rx connects; after IPCORE_CLK but before the
# save/constraints tail) and with the degraded '-add_ip {./ipcore}' path.
# The only robust repair: unconditionally enforce the canonical template
# (from the v3-era sibling build fec_jupiter_dbg8; verified drop-in: identical
# header vars, dut pins, instance name, address; net-joins made conditional).
BP=$1
VP=/mnt/onetb/scratch/qpsk_variants/jupiter_240k5_byte/hdl_prj_jupiter_composite/vivado_ip_prj
TPL=/mnt/onetb/scratch/qpsk_variants/jupiter_240k5_byte/vivado_insert_ip_TEMPLATE.tcl
while kill -0 "$BP" 2>/dev/null; do
  T="$VP/vivado_insert_ip.tcl"
  if [ -f "$T" ] && ! cmp -s "$T" "$TPL"; then
    cp "$TPL" "$T"
    echo "SIDECAR tcl replaced with canonical template $(date +%H:%M:%S.%N)"
  fi
  sleep 0.2
done
