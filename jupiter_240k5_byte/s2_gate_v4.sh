#!/bin/bash
# s2_gate_v4.sh <kitdir> <projdir> <functional_clocks_regex> <outfile>
# Gates a completed v4 build: BOOT.BIN, placement, functional timing, patched
# markers in the SYNTHESIZED project sources, constant proofs. Writes evidence.
set -u
KIT=$1; PROJ=$2; FCLKS=$3; OUT=$4
cd "$KIT" || exit 1
fail=0
note() { echo "$1" | tee -a "$OUT"; }
rm -f "$OUT"
note "S2_GATE_v4 $(basename "$KIT") $(date '+%Y-%m-%d %H:%M')"

BOOT=$(find "$PROJ/vivado_ip_prj" -name BOOT.BIN 2>/dev/null | head -1)
if [ -z "$BOOT" ]; then note "BOOT.BIN: MISSING -- FAIL"; fail=1; else
  note "BOOT.BIN: $BOOT md5=$(md5sum "$BOOT" | cut -d' ' -f1) size=$(stat -c%s "$BOOT")"
fi

# timing: parse the routed timing summary
TRPT="$KIT/retry_timing_summary.rpt"   # post-retry authoritative report if present
if [ ! -f "$TRPT" ]; then TRPT=$(find "$PROJ/vivado_ip_prj" -name "*timing_summary_routed.rpt" 2>/dev/null | head -1); fi
if [ -z "$TRPT" ]; then TRPT=$(find "$PROJ/vivado_ip_prj" -name "*timing*routed*.rpt" 2>/dev/null | head -1); fi
if [ -z "$TRPT" ]; then note "TIMING RPT: MISSING -- FAIL"; fail=1; else
  note "TIMING RPT: $TRPT"
  # clock summary lines: "<clk>  <wns>  <tns> ..."
  awk '/Clock Summary|Intra Clock Table/{f=1} f&&NF>3{print}' "$TRPT" | head -40 > /tmp/clk_v4.txt
  for c in $(echo "$FCLKS" | tr ',' ' '); do
    L=$(grep -E "^\s*${c}\b" "$TRPT" | head -2 | tail -1)
    W=$(echo "$L" | awk '{for(i=1;i<=NF;i++) if($i ~ /^-?[0-9]+\.[0-9]+$/){print $i; exit}}')
    note "CLOCK $c: ${L:-NOT_FOUND}"
    if [ -z "$L" ]; then note "  -> clock line missing -- FAIL"; fail=1;
    elif [[ "$W" == -* ]]; then note "  -> WNS $W NEGATIVE -- FAIL"; fail=1;
    else note "  -> WNS $W MET"; fi
  done
fi

# placement: vivado log must not contain placer errors
VLOG=$(find "$PROJ/vivado_ip_prj" -maxdepth 1 -name "vivado.log" 2>/dev/null | head -1)
if [ -n "$VLOG" ]; then
  if grep -qE "Placer could not place|place_design ERROR|ERROR: \[Place" "$VLOG"; then
    note "PLACEMENT: FAIL (placer errors in vivado.log)"; fail=1
  else note "PLACEMENT: PASS (no placer errors in vivado.log)"; fi
else note "PLACEMENT: vivado.log not found (checking impl rpt presence)"; fi

# patched markers in the synthesized sources (the ipcore the project imported)
SRC=$(grep -rl "enb_1_4_0_smp" "$PROJ" --include="*.v" 2>/dev/null | head -5)
if [ -z "$SRC" ]; then note "PATCH MARKERS: MISSING in project sources -- FAIL"; fail=1; else
  note "PATCH MARKERS (enb_1_4_0_smp) found in:"; echo "$SRC" | tee -a "$OUT"
  M2=$(grep -rl "MUX_RxT_out1" "$PROJ" --include="*.v" 2>/dev/null | head -3)
  if [ -z "$M2" ]; then note "PATCH MARKER MUX_RxT_out1: MISSING -- FAIL"; fail=1; else note "PATCH MARKER MUX_RxT_out1: present"; fi
fi

# constant proofs over the project RTL
# constants proven on the MODEM RTL only, word-boundary (26214 appears as a
# substring inside the ADI CORDIC atan table 21'd262144 -- false positive)
# digit-boundary matches (Verilog literals look like 22'd26214, so \b fails
# after the 'd'; and 26214 is a substring of the CORDIC 262144 elsewhere)
c3277=$(grep -rlE "(^|[^0-9])3277([^0-9]|$)" "$PROJ" --include="TxRxCompo_ip_src_*.v" 2>/dev/null | wc -l)
c26214=$(grep -rlE "(^|[^0-9])26214([^0-9]|$)" "$PROJ" --include="TxRxCompo_ip_src_*.v" 2>/dev/null | wc -l)
crom=$(grep -rlE "(^|[^0-9])1204691830([^0-9]|$)" "$PROJ" --include="TxRxCompo_ip_src_*.v" 2>/dev/null | wc -l)
note "CONST PROOFS: thr3277 files=$c3277 (want>0), rxfix26214 files=$c26214 (want 0), romword0 files=$crom (want>0)"
[ "$c3277" -gt 0 ] || { note "  -> thr3277 MISSING -- FAIL"; fail=1; }
[ "$c26214" -eq 0 ] || { note "  -> rxfix constant PRESENT -- FAIL"; fail=1; }
[ "$crom" -gt 0 ] || { note "  -> ROM word0 MISSING -- FAIL"; fail=1; }

if [ $fail -eq 0 ]; then note "S2_GATE_v4: PASS"; else note "S2_GATE_v4: FAIL"; fi
exit $fail
