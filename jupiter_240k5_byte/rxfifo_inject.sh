#!/bin/bash
# rxfifo_inject.sh <BUILD_DIR> [DEPTH] -- inject the BRAM drop-in ByteRxFifo
# (rxfifo_bram/ByteRxFifo.v, module renamed to the packaged-IP name
# TxRxCompo_ip_src_ByteRxFifo) into EVERY copy of the generated module in a
# byte-image build tree: loose hdlsrc, ipcore dirs, the packaged IP zips, and
# the already-extracted BD ipshared copies (the tmr_attr_inject.sh lesson:
# Vivado synthesizes the zip/ipshared copy, not the loose file). Hard-verifies.
set -u
B=${1:?build dir}; DEPTH=${2:-4096}
SRC=$(cd "$(dirname "$0")" && pwd)/rxfifo_bram/ByteRxFifo.v
MOD=TxRxCompo_ip_src_ByteRxFifo.v
AW=$(python3 -c "import math;print(int(math.log2($DEPTH)))")
TMP=$(mktemp); sed -e "s/^module ByteRxFifo #(parameter DEPTH = 4096, parameter AW = 12)/module TxRxCompo_ip_src_ByteRxFifo #(parameter DEPTH = $DEPTH, parameter AW = $AW)/" -e 's/^endmodule  \/\/ ByteRxFifo (BRAM drop-in v5, injected by rxfifo_inject.sh)/endmodule  \/\/ TxRxCompo_ip_src_ByteRxFifo (BRAM drop-in v5, injected by rxfifo_inject.sh)/' "$SRC" > "$TMP"
grep -q "^module TxRxCompo_ip_src_ByteRxFifo" "$TMP" || { echo "RXFIFO_FATAL rename failed"; exit 1; }
N=0
for f in $(find "$B" -name "$MOD" 2>/dev/null); do cp "$TMP" "$f"; N=$((N+1)); echo "  replaced: $f"; done
for z in $(find "$B" -name "TxRxCompo_ip_v1_0.zip" 2>/dev/null); do
  TD=$(mktemp -d); mkdir -p "$TD/hdl"; cp "$TMP" "$TD/hdl/$MOD"
  ( cd "$TD" && zip -q "$z" "hdl/$MOD" ) || { echo "RXFIFO_FATAL rezip $z"; exit 1; }
  ( cd "$TD" && unzip -o -q "$z" "hdl/$MOD" && grep -q "BRAM drop-in" "hdl/$MOD" ) || { echo "RXFIFO_FATAL zip verify $z"; exit 1; }
  rm -rf "$TD"; N=$((N+1)); echo "  zip patched: $z"
done
rm -f "$TMP"
C=$(grep -rl "injected by rxfifo_inject.sh" "$B" --include="$MOD" | wc -l)
echo "RXFIFO_INJECT_OK depth=$DEPTH files+zips=$N verified_loose=$C"
