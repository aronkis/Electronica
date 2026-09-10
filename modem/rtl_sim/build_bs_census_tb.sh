#!/bin/bash
# [sim] Task 46: extract bs_seam_census FROM THE PATCHED TREE and run its unit gate.
# The module text is not re-typed: it is cut out of s1_rtl_bs/TxRxComposite.v, which is
# what rxfix_inject.py BS produced and what build_sro_bs.sh compiled into the legs.
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
cd "$(dirname "$0")"
SRC=s1_rtl_bs/TxRxComposite.v
test -f "$SRC" || { echo "TB_BS_FAIL no $SRC (run build_sro_bs.sh first)"; exit 1; }
awk '/^module bs_seam_census$/,/^endmodule  \/\/ bs_seam_census$/' "$SRC" > bs_census_extract.v
grep -q "^module bs_seam_census$" bs_census_extract.v || { echo "TB_BS_FAIL extraction found no module"; exit 1; }
grep -q "^endmodule  // bs_seam_census$" bs_census_extract.v || { echo "TB_BS_FAIL extraction found no endmodule"; exit 1; }
N=$(wc -l < bs_census_extract.v)
[ "$N" -gt 60 ] || { echo "TB_BS_FAIL extraction is only $N lines"; exit 1; }
iverilog -g2005 -o bs_census_tb.vvp tb_bs_census.v bs_census_extract.v
vvp bs_census_tb.vvp | tee bs_census_tb.log
grep -q TB_BS_CENSUS_PASS bs_census_tb.log || { echo "TB_BS_FAIL see bs_census_tb.log"; exit 1; }
echo "TB_BS_CENSUS_DONE ($N lines extracted from $SRC)"
