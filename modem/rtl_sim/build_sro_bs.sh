#!/bin/bash
# [sim] Task 46: build the SRO harness against the RXFIX_BS byte-seam census.
# Pre-registration RXFIX_BS1_SIM_GATE.md (tag archive/pre-cleanup-2026-09-09;
# committed with this file; its
# numbers were fixed before any leg ran and the file says so in its own text).
#
#   build_sro_bs.sh          -- build ALL THREE binaries from freshly made trees
#   build_sro_bs.sh bs       -- only the RXFIX_BS binary
#   build_sro_bs.sh base     -- only the drop-in baseline binary
#   build_sro_bs.sh gen      -- only the wrapper-transparency binary
#
# TWO BINARIES, ONE BASE TREE, ONE WRAPPER, ONE DRIVER.  That is what makes the
# identity legs a test of the RTL patch and of nothing else:
#
#   obj_byte_sro_bs_base   s1_rtl_bs_base  (s1_rtl + the v5 BRAM drop-in ByteRxFifo)
#                          wrap_byte_bs.v, NO define        -> BS taps compiled out
#   obj_byte_sro_bs        s1_rtl_bs       (the same tree + RXFIX_BS)
#                          wrap_byte_bs.v, +define+RXFIX_BS -> BS taps read
#
# and a THIRD, which tests the WRAPPER rather than the patch:
#
#   obj_byte_sro_bs_gen    s1_rtl_bs_gen   (s1_rtl VERBATIM -- the generated 64-deep
#                          ByteRxFifo, no drop-in, no RXFIX_BS), wrap_byte_bs.v, no
#                          define.  Its n_p000 leg must be BYTE-IDENTICAL to task 7's
#                          banked b_p000_frames.txt, which was produced by the SAME
#                          driver on the SAME RTL through wrap_byte_sro.v.  That is the
#                          only comparison that isolates this wrapper: the base/BS pair
#                          share it, so a non-transparent wrapper would cancel between
#                          them and leave the identity legs looking clean.
#
# WHY THE DROP-IN FIFO IS IN BOTH TREES.  RXFIX_BS taps ByteRxFifo's `push`/`pop`/
# `drop` wires, which exist only in the v5 BRAM drop-in
# (modem/rxfifo_bram/ByteRxFifo.v) -- the module EVERY build tree in this
# lineage carries (rxfifo_inject.sh).  The HDL-Coder-generated 64-deep module names
# none of them.  Building the sim gate on the generated module would mean gating a
# DIFFERENT tap expression from the one the build ships, so both trees get the drop-in
# and the injector refuses the generated form outright.  This does NOT close O1 (which
# ByteRxFifo is in the FLASHED image); nothing at a desk can.
set -e -o pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
KIT=/mnt/onetb/scratch/qpsk-jupiter-modem/modem
REPO=/mnt/onetb/scratch/qpsk-jupiter-modem
cd "$KIT/rtl_sim"
WHICH=${1:-both}
DEPTH=${DEPTH:-4096}

mk_tree () {   # mk_tree <dir> <apply_bs:0|1>
  local D=$1 BS=$2
  rm -rf "$D"
  cp -r "$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback" "$D"
  # the drop-in, at the shipped DEPTH by default
  local AW; AW=$(python3 -c "import math;print(int(math.log2($DEPTH)))")
  sed -e "s/^module ByteRxFifo #(parameter DEPTH = 4096, parameter AW = 12)/module ByteRxFifo #(parameter DEPTH = $DEPTH, parameter AW = $AW)/" \
      "$KIT/rxfifo_bram/ByteRxFifo.v" > "$D/ByteRxFifo.v"
  grep -q "BRAM drop-in v5" "$D/ByteRxFifo.v" || { echo "BUILD_SRO_BS_FAIL drop-in not installed in $D"; exit 1; }
  grep -q "parameter DEPTH = $DEPTH" "$D/ByteRxFifo.v" || { echo "BUILD_SRO_BS_FAIL depth not $DEPTH in $D"; exit 1; }
  if [ "$BS" = 1 ]; then
    python3 "$REPO/ops/skidfix/rxfix_inject.py" "$PWD/$D" BS --sim-tree | tail -1
    for f in ByteSerializer.v ByteRxFifo.v TxRxComposite.v; do
      grep -q RXFIX_BS "$D/$f" || { echo "BUILD_SRO_BS_FAIL $D/$f lacks RXFIX_BS"; exit 1; }
    done
    grep -q "module bs_seam_census" "$D/TxRxComposite.v" || \
      { echo "BUILD_SRO_BS_FAIL the census module is not in $D/TxRxComposite.v"; exit 1; }
  else
    for f in ByteSerializer.v ByteRxFifo.v TxRxComposite.v; do
      if grep -q RXFIX_BS "$D/$f"; then echo "BUILD_SRO_BS_FAIL baseline tree $D/$f carries RXFIX_BS"; exit 1; fi
    done
  fi
}

build () {     # build <objdir> <treedir> <define|->
  local O=$1 VD=$2 DEF=$3 L
  rm -rf "$O"
  local DEFARG=""; [ "$DEF" = "-" ] || DEFARG="+define+$DEF"
  verilator -O2 -Wno-fatal --cc wrap_byte_bs.v -y "$VD" -y "$KIT/rtl_sim" $DEFARG \
    --exe sim_sro.cpp -Mdir "$O" --top-module wrap_byte_sro > "${O}_verilate.log" 2>&1
  L="${O}_verilate.log"
  # --- wrapper provenance: SEVEN files declare `module wrap_byte_sro`.  The verilate
  # --- log must name THIS one and none of the other six.
  for w in wrap_byte_sro wrap_byte_sro3s wrap_byte_sro4 wrap_byte_sro4b wrap_byte_sro4d wrap_byte_sro4e; do
    if grep -qE "(^|[^_a-z])$w\.v" "$L"; then
      echo "BUILD_SRO_BS_FAIL $w.v was read"; exit 1; fi
  done
  grep -q 'wrap_byte_bs\.v' "$L" || { echo "BUILD_SRO_BS_FAIL wrap_byte_bs.v not in the verilate log"; exit 1; }
  grep -q "$VD/" "$L" || { echo "BUILD_SRO_BS_FAIL tree $VD is not in the verilate log"; exit 1; }
  # --- the OTHER tree must not have been read (s1_rtl_bs is a prefix of nothing here,
  # --- but s1_rtl_bs_base contains s1_rtl_bs, so the trailing slash is load-bearing)
  for other in s1_rtl_bs s1_rtl_bs_base s1_rtl_bs_gen; do
    [ "$other" = "$VD" ] && continue
    if grep -q "$other/" "$L"; then
      echo "BUILD_SRO_BS_FAIL tree $other was read into the $VD build"; exit 1; fi
  done
  make -s -j"$(nproc)" -C "$O" -f Vwrap_byte_sro.mk Vwrap_byte_sro > "${O}_make.log" 2>&1
  echo "BUILD_SRO_BS_OK $O $(md5sum "$O/Vwrap_byte_sro" | cut -d' ' -f1)"
}

if [ "$WHICH" = both ] || [ "$WHICH" = gen ]; then
  # VERBATIM s1_rtl: no drop-in, no BS.  mk_tree would install the drop-in, so this
  # tree is made here and the absence of both is asserted.
  rm -rf s1_rtl_bs_gen
  cp -r "$KIT/s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback" s1_rtl_bs_gen
  grep -q "BRAM drop-in" s1_rtl_bs_gen/ByteRxFifo.v && \
    { echo "BUILD_SRO_BS_FAIL s1_rtl_bs_gen must carry the GENERATED ByteRxFifo"; exit 1; }
  grep -q "reg \[63:0\] mem \[0:63\];" s1_rtl_bs_gen/ByteRxFifo.v || \
    { echo "BUILD_SRO_BS_FAIL s1_rtl_bs_gen ByteRxFifo is not the generated 64-deep module"; exit 1; }
  if grep -rq RXFIX_BS s1_rtl_bs_gen; then
    echo "BUILD_SRO_BS_FAIL s1_rtl_bs_gen carries RXFIX_BS"; exit 1; fi
  build obj_byte_sro_bs_gen s1_rtl_bs_gen -
fi
if [ "$WHICH" = both ] || [ "$WHICH" = base ]; then
  mk_tree s1_rtl_bs_base 0
  build obj_byte_sro_bs_base s1_rtl_bs_base -
fi
if [ "$WHICH" = both ] || [ "$WHICH" = bs ]; then
  mk_tree s1_rtl_bs 1
  build obj_byte_sro_bs s1_rtl_bs RXFIX_BS
fi
# bs2: the SAME tree and the SAME define, into a SEPARATE object dir, so the first
# run's binary is never overwritten.  It differs only in the wrapper's dump TRIGGER
# (a record every BS_PUSH_GRID pushes as well as on the clk grid) -- nothing inside
# the DUT, nothing the stall or the skip poke touches.  See the wrapper comment.
if [ "$WHICH" = bs2 ]; then
  test -d s1_rtl_bs || { echo "BUILD_SRO_BS_FAIL no s1_rtl_bs (run build_sro_bs.sh first)"; exit 1; }
  grep -q RXFIX_BS s1_rtl_bs/TxRxComposite.v || { echo "BUILD_SRO_BS_FAIL s1_rtl_bs lacks RXFIX_BS"; exit 1; }
  build obj_byte_sro_bs2 s1_rtl_bs RXFIX_BS
fi
B=$PWD/obj_byte_sro_bs/Vwrap_byte_sro
BB=$PWD/obj_byte_sro_bs_base/Vwrap_byte_sro
if [ -x "$B" ] && [ -x "$BB" ]; then
  M=$(md5sum "$B" | cut -d' ' -f1); MB=$(md5sum "$BB" | cut -d' ' -f1)
  [ "$M" != "$MB" ] || { echo "BUILD_SRO_BS_FAIL the two binaries are byte-identical"; exit 1; }
  echo "BUILD_SRO_BS_MD5 bs=$M base=$MB (differ: OK) depth=$DEPTH"
fi
echo "BUILD_SRO_BS_DONE"
