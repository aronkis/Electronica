#!/bin/bash
# build_replay_v3.sh -- build the byte-plane harness against the netlist BIT-MATCHED TO
# THE FLASHED IMAGE fe5bd8a4fe19 (see docs/evidence/NETLIST_PROVENANCE.md).
#
# Every build_*.sh in this directory defaults to $KIT/s1_rtl, a DIFFERENT generation from
# the flashed image. And wrap_byte_lock.v is stale -- it references Loop_Filter_stateP/I
# hierarchical paths that exist only in the retired Jul-25 netlist, so it will not
# compile here. Use wrap_byte_bf2.v + sim_byte_ce.cpp: the pair the v3 pre-flash gate
# used against this exact netlist.
#
# Drive cadence for this netlist is 2 (NOT the Jul-25 archive's 4).
#
# wrap_byte_bf2.v / --top-module wrap_byte_ce is HARDCODED, not a parameter: it is the
# only wrapper proven to build against this netlist generation (wrap_byte_lock.v does
# not -- see the "Harness trap" section of docs/evidence/NETLIST_PROVENANCE.md). A driver that
# needs a different wrapper needs a different script, not a flag on this one.
set -e -u -o pipefail
# PATH is deliberately minimized to avoid the ~/.local/bin toolchain-shadow footgun on
# these hosts (an `as` on that PATH silently hijacks the assembler otherwise). Set
# PATH_PREFIX to prepend a directory (e.g. a non-standard verilator install) ahead of the
# sanitised PATH: PATH_PREFIX=/opt/verilator/bin build_replay_v3.sh ...
# Sanitised before ANY other command runs (including dirname/basename below) so a hostile
# or merely unusual caller PATH can't affect this script at all before the check fires.
export PATH="${PATH_PREFIX:+$PATH_PREFIX:}/usr/local/bin:/usr/bin:/bin"
command -v verilator >/dev/null 2>&1 || {
  echo "FATAL: verilator not found on the sanitised PATH ($PATH)." >&2
  echo "       PATH is deliberately minimal here to avoid the ~/.local/bin toolchain-shadow" >&2
  echo "       footgun. If verilator lives elsewhere, prepend its dir explicitly, e.g.:" >&2
  echo "         PATH_PREFIX=/opt/verilator/bin $0 $*" >&2
  exit 1; }

R=$(cd "$(dirname "$0")" && pwd)
V3=$R/s1_rtl_beatfix3/hdlsrc/commhdlQPSKTxRxLoopback
DRV=${1:-sim_byte_ce.cpp}
OBJ=${2:-obj_$(basename "$DRV" .cpp)_v3}

[ -f "$V3/TxRxComposite.v" ] || {
  echo "FATAL: v3 netlist missing at $V3 -- re-read docs/evidence/NETLIST_PROVENANCE.md" >&2
  exit 1; }

case "$OBJ" in
  /*|*..*) echo "FATAL: objdir must be a simple relative name under rtl_sim, got '$OBJ'" >&2; exit 1;;
esac

cd "$R"
rm -rf "$OBJ"
verilator -O2 -Wno-fatal --public-flat-rw -CFLAGS "-O2 -DHAVE_FLAT_RW -DHAVE_BF2" \
  --cc wrap_byte_bf2.v -y "$V3" --exe "$DRV" -Mdir "$OBJ" --top-module wrap_byte_ce
make -s -C "$OBJ" -f Vwrap_byte_ce.mk Vwrap_byte_ce
echo "BUILD_REPLAY_V3_DONE driver=$DRV cadence=2 bin=$R/$OBJ/Vwrap_byte_ce"
echo "  netlist : $V3"
