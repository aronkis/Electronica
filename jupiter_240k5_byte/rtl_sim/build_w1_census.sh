#!/bin/bash
# [sim] Task 9: extract rh_w1_census VERBATIM from the RXFIX_W1-patched
# Frequency_and_Time_Synchronizer.v and build its standalone unit test.
# The extraction is re-done on every build so the test can never drift from the
# module the injector actually emits.
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte
cd "$KIT/rtl_sim"
SRC=s1_rtl_rxfix_W1/Frequency_and_Time_Synchronizer.v
[ -f "$SRC" ] || { echo "BUILD_W1_CENSUS_NO_TREE $SRC (run rxfix_inject.py ... W1 --sim-tree first)"; exit 1; }
python3 - "$SRC" <<'PY'
import sys
s=open(sys.argv[1]).read()
i=s.index('module rh_w1_census')
open('rh_w1_census_extracted.v','w').write(
  "// EXTRACTED VERBATIM from the RXFIX_W1-patched Frequency_and_Time_Synchronizer.v\n"
  "// by build_w1_census.sh -- a TEST FIXTURE, not a source of truth.  Regenerate it;\n"
  "// never hand-edit it.\n" + s[i:])
PY
rm -rf obj_w1_census
verilator -O2 -Wno-fatal --cc rh_w1_census_extracted.v --exe sim_w1_census.cpp \
  -Mdir obj_w1_census --top-module rh_w1_census > obj_w1_census_verilate.log 2>&1
make -s -j4 -C obj_w1_census -f Vrh_w1_census.mk Vrh_w1_census > obj_w1_census_make.log 2>&1
echo "BUILD_W1_CENSUS_DONE $KIT/rtl_sim/obj_w1_census/Vrh_w1_census"
