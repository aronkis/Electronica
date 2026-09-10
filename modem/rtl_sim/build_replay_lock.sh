#!/bin/bash
# build_replay_lock.sh -- build the lock/dip replay harness against a CHOSEN netlist.
#
# WHY THIS EXISTS (2026-08-15). The sim_byte_{lock,dip,qtick,tickfix} family had NO build
# script: the binaries in obj_byte_*_f1536_jul25/ were produced by hand-written verilator
# invocations pointed at the Jul-25 worktree netlist, and every other build_*.sh in this
# directory hardcodes $KIT/s1_rtl. That made the campaign's most-cited sim results
# unreproducible AND silently bound them to the wrong RTL generation:
#
#   flashed image skid3 (6c06ecb7e888) DUT netlist, recovered from
#   hdl_prj_jupiter_composite/vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0.zip
#   (hdl/TxRxCompo_ip_src_TxRxComposite.v), differs from
#     modem/s1_rtl ....... 8 lines (filename/timestamp/model 11.330 vs .331)
#     jupiter_byte_fsv2_gates/s1_rtl ... 136 lines
#     .claude/worktrees/txmux-localize/.../s1_rtl_f1536 (Jul-25) ... 1270 lines
#   => $KIT/s1_rtl IS the flashed generation. The Jul-25 netlist is NOT.
#
# CADENCE CONTRACT (HARNESS_AB.md, tag archive/pre-cleanup-2026-09-09) --
# getting this wrong yields 0 CRC-good and
# looks like a broken datapath:
#   Jul-25 archive generation ....... cadence 4
#   post-Jul-29 / flashed generation  cadence 2   <-- $KIT/s1_rtl, i.e. the default here
#
# Usage: build_replay_lock.sh [driver] [netlist_dir] [objdir_suffix]
#   driver        sim_byte_lock.cpp (default) | sim_byte_dip.cpp | ...
#   netlist_dir   default $KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback (the FLASHED lineage)
#   objdir_suffix default derived from the driver + netlist tag
set -e -o pipefail
R=$(cd "$(dirname "$0")" && pwd)
KIT=$(dirname "$R")
DRV=${1:-sim_byte_lock.cpp}
VD=${2:-$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback}
TAG=${3:-$(basename "$DRV" .cpp)_flashed}
export PATH=/usr/local/bin:/usr/bin:/bin

[ -f "$VD/TxRxComposite.v" ] || { echo "FATAL: no netlist at $VD" >&2; exit 1; }
[ -f "$R/$DRV" ] || { echo "FATAL: no driver $R/$DRV" >&2; exit 1; }
cd "$R"
OBJ=obj_${TAG}
rm -rf "$OBJ"
verilator -O2 -Wno-fatal --cc wrap_byte_lock.v -y "$VD" --exe "$DRV" \
  -Mdir "$OBJ" --top-module wrap_byte_lock
make -s -C "$OBJ" -f Vwrap_byte_lock.mk Vwrap_byte_lock
echo "BUILD_REPLAY_LOCK_DONE $R/$OBJ/Vwrap_byte_lock"
echo "  netlist : $VD"
echo "  driver  : $DRV"
echo "  CADENCE : use 2 for \$KIT/s1_rtl (flashed lineage), 4 for the Jul-25 worktree"
