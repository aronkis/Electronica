#!/bin/bash
# build_ddrcap.sh -- full BD-regenerating build for the DDR-capture image.
# Modeled on jupiter_byte_final_build/build_final.sh, but since Task 4 step 1
# regenerated and saved the BD (ddrcap_bd.tcl -> system.bd), this build must
# run the full flow (build_ddrcap.tcl: generate_target/synth/timing-gate/
# impl/bootgen), not a resynth_*.tcl.
#
# Builds on hdl-dev-2 (/opt/Xilinx/2025.1/Vivado, ~/qpsk-builds/) to leave
# this host free, per the Task 4 brief. hdl-dev-2 does not share this host's
# filesystem, so the tree is rsync'd over first. The long Vivado run itself is
# launched as a transient systemd --user unit ON hdl-dev-2 so it survives
# this session ending (setsid nohup children were killed at session exit on
# this host before -- see MEMORY.md "Background jobs: use systemd-run --user").
set -u
KIT_LOCAL=$(cd "$(dirname "$0")" && pwd)
REMOTE_HOST=hdl-dev-2
REMOTE_DIR='~/qpsk-builds/jupiter_byte_ddrcap2_build'
REMOTE_DIR_EXPANDED=/home/tcollins/qpsk-builds/jupiter_byte_ddrcap2_build

echo "DDRCAP_BUILD sync start $(date -Is)"
rsync -a --delete \
  --exclude 'vivado_prj.runs/synth_1/' \
  --exclude 'vivado_prj.runs/impl_1/' \
  --exclude 'vivado_prj.cache/' \
  --exclude 'vivado_prj.sim/' \
  --exclude 'vivado_prj.hw/' \
  --exclude '*.log' --exclude '*.jou' --exclude '*.str' \
  --exclude 'boot/BOOT.BIN' \
  "$KIT_LOCAL"/ "$REMOTE_HOST:$REMOTE_DIR"/
RC=$?
if [ $RC -ne 0 ]; then echo "DDRCAP_BUILD_SYNC_FAILED rc=$RC"; exit 1; fi
echo "DDRCAP_BUILD sync done $(date -Is)"

UNIT="ddrcap-build-$(date +%s)"
ssh "$REMOTE_HOST" "REMOTE_DIR='$REMOTE_DIR_EXPANDED' UNIT='$UNIT' bash -s" <<'REMOTE'
set -u
export PATH=/opt/Xilinx/2025.1/Vivado/bin:/usr/bin:/bin
Z="$REMOTE_DIR/hdl_prj_jupiter_composite/vivado_ip_prj"
rm -f "$Z/boot/BOOT.BIN"
systemd-run --user --unit="$UNIT" --collect \
  --working-directory="$Z" \
  --setenv=PATH=/opt/Xilinx/2025.1/Vivado/bin:/usr/bin:/bin \
  bash -c "timeout 14400 vivado -mode batch -notrace -source \"$REMOTE_DIR/build_ddrcap.tcl\" > \"$REMOTE_DIR/build_ddrcap_vivado.log\" 2>&1"
echo "DDRCAP_UNIT $UNIT started $(date -Is)"
REMOTE
echo "DDRCAP_BUILD launched on $REMOTE_HOST as unit $UNIT ; remote tree: $REMOTE_DIR_EXPANDED"
echo "  check with: ssh $REMOTE_HOST systemctl --user status $UNIT"
echo "  log at:     ssh $REMOTE_HOST tail -f $REMOTE_DIR_EXPANDED/build_ddrcap_vivado.log"
