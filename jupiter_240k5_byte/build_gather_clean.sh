#!/usr/bin/env bash
# =============================================================================
# build_gather_clean.sh
# -----------------------------------------------------------------------------
# ONE reproducible command that takes the jupiter_240k5 kit from clean and
# produces a BOOT.BIN with tx_dac_gather integrated (fixes the half-rate QPSK
# transmit on the Jupiter / ADRV9002 / xczu3eg modem).
#
# INTEGRATION APPROACH: (a) orchestration.
#   Run the normal MATLAB build_variant flow in a FRESH copy dir, let it fail at
#   the known "Create Project" step (its generated vivado_insert_ip.tcl uses the
#   wrong add_ip path), then apply ONE combined Vivado script
#   (complete_and_gather.tcl) that (i) inserts+wires the modem IP with the
#   corrected add_ip path, (ii) disconnects sync_output from the DAC and
#   interposes tx_dac_gather on all 4 DAC lanes, (iii) synth/impl/bitstream/
#   bootgen. Approach (b) -- editing matlab_processors.tcl -- was rejected
#   because that file lives in the READ-ONLY master repo (/home/tcollins/dev/
#   qpsk_ai) and the workflow-local copy only exists AFTER the failing
#   CreateProject regenerates it, so it cannot be edited up front.
#
# Self-contained inputs (kept alongside this script in jupiter_240k5):
#   - build_gather_clean.sh      (this file)
#   - complete_and_gather.tcl    (the combined Vivado surgery + build)
#   - tx_dac_gather.v            (the gather module)
#
# Usage:
#   /mnt/onetb/scratch/qpsk_variants/jupiter_240k5_byte/build_gather_clean.sh [FRESHDIR]
# Default FRESHDIR = /mnt/onetb/scratch/qpsk_variants/jupiter_gather_clean
# =============================================================================
set -u
set -o pipefail

SRC=/mnt/onetb/scratch/qpsk_variants/jupiter_240k5_byte
FRESH=${1:-/mnt/onetb/scratch/qpsk_variants/jupiter_gather_clean}
VIVADO_IP="$FRESH/hdl_prj_jupiter_composite/vivado_ip_prj"
LOG="$FRESH/build_gather_clean.log"

export PATH=/mnt/onetb/MATLAB/R2025b/bin:/tools/Xilinx/2025.1/Vivado/bin:/usr/bin:$PATH

echo "=== [1/5] fresh copy $SRC -> $FRESH ==="
rm -rf "$FRESH"
mkdir -p "$FRESH"
# copy the kit but EXCLUDE regenerable build outputs + logs (build_variant
# regenerates hdl_prj_jupiter_composite + slprj anyway).
rsync -a \
  --exclude 'hdl_prj_jupiter_composite/' \
  --exclude 'slprj/' \
  --exclude 'rtl_sim/' \
  --exclude 's1_rtl/' \
  --exclude 'txnco_fix/' \
  --exclude '*.log' \
  --exclude '*.bak' \
  --exclude '*.mult1bak' \
  "$SRC/" "$FRESH/"

echo "=== [2/5] repoint hardcoded KITDIR paths to the fresh dir ==="
# build_variant + assemble hardcode (and assert) the jupiter_240k5 path.
grep -rl "qpsk_variants/jupiter_240k5_byte" "$FRESH"/*.m 2>/dev/null | while read -r f; do
  sed -i "s#/mnt/onetb/scratch/qpsk_variants/jupiter_240k5_byte#$FRESH#g" "$f"
  echo "  patched $f"
done
# make sure the gather module + combined tcl are present in the fresh dir
cp -f "$SRC/tx_dac_gather.v"        "$FRESH/tx_dac_gather.v"
cp -f "$SRC/complete_and_gather.tcl" "$FRESH/complete_and_gather.tcl"

echo "=== [3/5] MATLAB build_variant (Stage 1 RTL+IP; will FAIL at Create Project -- expected) ==="
echo "        log: $LOG"
cd "$FRESH"
# build_variant throws at CreateProject (add_ip path bug) -> matlab -batch exits
# nonzero. That is EXPECTED; we do NOT abort on it.
matlab -batch "run('$FRESH/build_variant_jupiter_240k5.m')" >"$LOG" 2>&1
echo "  matlab exit=$? (nonzero at Create Project is expected)"

echo "=== [4/5] verify insertable post-failure state ==="
fail=0
[ -f "$VIVADO_IP/ipcore/TxRxCompo_ip_v1_0.zip" ] || { echo "  MISSING patched ipcore zip"; fail=1; }
[ -f "$VIVADO_IP/vivado_prj.xpr" ]                || { echo "  MISSING vivado_prj.xpr";     fail=1; }
BD="$VIVADO_IP/vivado_prj.srcs/sources_1/bd/system/system.bd"
[ -f "$BD" ]                                       || { echo "  MISSING system.bd";          fail=1; }
if [ -f "$BD" ]; then
  grep -q 'axi_adrv9001' "$BD" && grep -q 'sync_output' "$BD" || { echo "  system.bd lacks reference cells"; fail=1; }
fi
if [ "$fail" -ne 0 ]; then
  echo "ABORT: build_variant did not leave an insertable project (see $LOG)"; exit 1
fi
echo "  OK: ipcore zip + vivado_prj.xpr + system.bd (with ref cells) all present"

echo "=== [5/5] combined Vivado surgery + build (insert modem IP + gather + synth/impl/bit/bootgen) ==="
cd "$VIVADO_IP"
vivado -mode batch -notrace -source "$FRESH/complete_and_gather.tcl" \
       -tclargs "$FRESH/tx_dac_gather.v" >>"$LOG" 2>&1
rc=$?
echo "  vivado exit=$rc"

BOOT="$VIVADO_IP/boot/BOOT.BIN"
if [ -f "$BOOT" ]; then
  echo "=== SUCCESS ==="
  md5sum "$BOOT"
  echo "BOOT.BIN: $BOOT"
else
  echo "=== FAILED: no BOOT.BIN produced -- see $LOG ==="
  exit 1
fi
