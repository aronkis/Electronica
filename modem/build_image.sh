#!/bin/bash
# =============================================================================
# build_image.sh [TARGET_DIR] -- THE canonical one-command HDL-Coder -> BOOT.BIN
# driver for the modem K5 QPSK modem. It wires the pre-conditions
# (env + the full gate suite) IN FRONT of the image build so you cannot ship an
# ungated or wrong-lineage image:
#
#   0. source build_env_jupiter.sh            (ADI_* caches/jobs)
#   1. GATES  -> run_full_gates_t8.sh         (assemble -> model oracle ->
#                                              checkhdl+makehdl -> golden vectors
#                                              -> S1B Verilator -> S1 iverilog)
#   2. IMAGE  -> build_byte_image.sh TARGET   (fresh kit copy -> MATLAB assemble
#                                              + IP core [CreateProject failure
#                                              EXPECTED/benign] -> Vivado
#                                              synth/impl -> bootgen -> BOOT.BIN)
#
# TARGET_DIR default = the sanctioned rxfix build dir. For a reproducibility
# rebuild that must NOT clobber the deployed-image provenance, pass a fresh dir
# (e.g. .../jupiter_byte_verify_build -- matches the jupiter_*_build/ gitignore).
#
# Prints exactly ONE terminal line:
#   BUILD_IMAGE_DONE md5=<32hex>  path=<...>      on success
#   BUILD_IMAGE_FAIL (<stage>)                    on any failure
#
# LONG (~2 h: ~30 min gates + ~1.5 h Vivado). Launch DETACHED so no task cap can
# kill it, and watch the log for the marker:
#   cd modem
#   setsid nohup ./build_image.sh <target> > build_image.log 2>&1 </dev/null &
#   # then: grep -E 'BUILD_IMAGE_(DONE|FAIL)' build_image.log
# =============================================================================
set -u
KIT=$(cd "$(dirname "$0")" && pwd)
ENVF="$(dirname "$KIT")/build_env_jupiter.sh"
TARGET=${1:-$(dirname "$KIT")/jupiter_byte_rxfix_build}
export PATH=/mnt/onetb/MATLAB/R2025b/bin:/tools/Xilinx/2025.1/Vivado/bin:/usr/local/bin:/usr/bin:/bin
cd "$KIT" || { echo "BUILD_IMAGE_FAIL (no KIT $KIT)"; exit 1; }

echo "=== build_image.sh  $(date -Is)  TARGET=$TARGET ==="

# 0) ADI build env (harmless if unused by the Vivado-completion path; parity
#    with the ADI adi_build.tcl flow).
if [ -f "$ENVF" ]; then . "$ENVF"; echo "sourced $(basename "$ENVF")"; else echo "WARN: $ENVF missing"; fi

# 1) GATES -- the full model + netlist suite. run_full_gates_t8.sh is strict
#    (set -e -o pipefail; greps each stage's PASS marker) so any failure aborts.
echo "=== [1/2] GATES: run_full_gates_t8.sh ==="
if ! ./run_full_gates_t8.sh; then echo "BUILD_IMAGE_FAIL (gates)"; exit 1; fi
for s in SIM_BYTE_GATE_K5.txt S1_GATE.txt S1B_GATE.txt; do
  grep -qi 'result: PASS' "$KIT/$s" || { echo "BUILD_IMAGE_FAIL (stamp $s not PASS)"; exit 1; }
done
echo "GATES: all PASS"

# 2) IMAGE -- fresh copy assemble + IP core + Vivado + bootgen.
echo "=== [2/2] IMAGE: build_byte_image.sh $TARGET ==="
if ! ./build_byte_image.sh "$TARGET"; then echo "BUILD_IMAGE_FAIL (image)"; exit 1; fi

B="$TARGET/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN"
if [ -f "$B" ]; then
  echo "BUILD_IMAGE_DONE md5=$(md5sum "$B" | cut -d' ' -f1)  path=$B  $(date -Is)"
else
  echo "BUILD_IMAGE_FAIL (no BOOT.BIN at $B)"; exit 1
fi
