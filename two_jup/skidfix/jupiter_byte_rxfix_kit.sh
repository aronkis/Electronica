#!/bin/bash
# jupiter_byte_rxfix_kit.sh <148>
#
# Derives an RXFIX build kit from the SEQ-BIST kit that produced the flashed 148
# image a1ff3c876d91, modelled on jupiter_byte_seqbist_kit.sh:
#
#   148 -> SRC jupiter_byte_seqbist_build
#     RXFIX_VARIANTS='W1'      (default, Task 9)  KIT jupiter_byte_rxfixw1_build
#     RXFIX_VARIANTS='W1 R4B'  (Task 13)          KIT jupiter_byte_rxfixr4b_build
#     RXFIX_VARIANTS='W1 R4D R1' (Task 22)        KIT jupiter_byte_rxfixr4dr1_build
#
# The default is UNCHANGED from Task 9: with no RXFIX_VARIANTS in the environment
# this script does exactly what it did for the flashed W1 image 2728dab3979a.
#
# W1 + R4D + R1 (Task 22, the 146 FULL-side candidate).  R4D is R4B plus the extra
# pop on the FULL side; R1 makes the Preamble_Detector realignment FIFO's pop
# OCCUPANCY-indexed instead of enb-tick-indexed, which is what stops that FIFO
# deleting the extra (Task 20's S1 gate: +10 ppm loss 0.00 %, rh_push_on_full 0,
# pdOcc pinned at 12,333).  R1 touches ONE file, Preamble_Detector.v, which is in
# NEITHER W1's nor R4D's set, so the three compose textually with no shared anchor.
# R1's two anchors are plain text that names no module -- `wire Delay10_out1;` and
# `assign Delay10_out1 = Delay10_reg[49331];` (kit line 334) -- so unlike R3S/R4 it
# needs no `_PFX` tolerance to reach the kit's prefixed modules, and a kit-shaped
# test pins that rather than assuming it.
#
# W1 + R4B (Task 13).  R4B (Task 12b) is the silicon-ready steering fix: a
# structural 13-slot skip window opened by End_Generator's pcEnd, a registered
# decision, lock = 8 pcEnd pulses, no pre-fill.  Its five core files are a SUBSET
# of W1's eight RTL files, and its witness word rides W1's read path as a NINTH
# read word at byte 0x234 -- so the two variants patch the SAME twelve files and
# W1 MUST be applied FIRST (R4B's addr_decoder hunk wraps W1's own `data_read`
# assign; the other order fails loudly -- rxfix_inject.py header, tests 118/119).
#
# W1 is applied ON TOP OF the SEQ-BIST tree, so the rx_seq_checker judge, the
# cnt_mux32 read-out and the three 0x9D4x GPIOs all stay in the image; the BD is
# NOT touched again (the SEQ-BIST tcl patch is inherited byte for byte in the
# copy).  W1 itself is a pure netlist patch inside the TxRxCompo_ip IP: eight new
# AXI-lite READ words plus the logic that feeds them.  It adds no IP top-level
# port, so component.xml and the BD are unchanged -- verified: ddrcap_* ARE in
# component.xml (DDRCAP did add top-level ports), beatfix_viol_count is NOT
# (AXI-lite read registers are IP-internal), and W1 follows the second pattern.
#
# Steps: assert the injector is committed -> refuse if already tagged -> copy
# (same rsync excludes as the seqbist kit) -> run two_jup/skidfix/rxfix_inject.py
# <kit> <variant> for each variant in RXFIX_VARIANTS, in order -> independently
# re-verify EVERY marker in all three loose mirrors and both zip members ->
# widen build_txfix.sh's kit-name guard -> write RXFIX_VARIANT.
#
# NEVER runs Vivado.  The copied build_txfix.tcl keeps its IMPL_STRATEGY hook and
# its routed-WNS gate (TXFIX_ROUTED_WNS / TXFIX_ROUTED_TIMING_FAIL); this script
# refuses to run on a build tcl that lacks either.  TXFIX_VARIANT and
# SEQBIST_VARIANT are carried over byte for byte; RXFIX_VARIANT is a NEW marker.
#
# Usage:  two_jup/skidfix/jupiter_byte_rxfix_kit.sh 148
# Env:    REPO (default: the repo this script lives in)
set -u

BOARD="${1:-}"
VARIANTS="${RXFIX_VARIANTS:-W1}"
case "$VARIANTS" in
  "W1")     KIT_SUFFIX="w1";  READ_WORDS="0x214,0x218,0x21C,0x220,0x224,0x228,0x22C,0x230" ;;
  "W1 R4B") KIT_SUFFIX="r4b"; READ_WORDS="0x214,0x218,0x21C,0x220,0x224,0x228,0x22C,0x230,0x234" ;;
  "W1 R4D R1") KIT_SUFFIX="r4dr1"; READ_WORDS="0x214,0x218,0x21C,0x220,0x224,0x228,0x22C,0x230,0x234,0x238" ;;
  *) echo "RXFIX_KIT_BAD_VARIANTS '$VARIANTS' -- supported: 'W1' (default), 'W1 R4B' or 'W1 R4D R1'"; exit 1 ;;
esac
case "$BOARD" in
  148) SRC_KIT="jupiter_byte_seqbist_build"; KIT_NAME="jupiter_byte_rxfix${KIT_SUFFIX}_build"; LINEAGE="148" ;;
  146) echo "RXFIX_KIT_REFUSE_146 Task 9 is 148-only (no 146 build, no flash)"; exit 1 ;;
  *)   echo "RXFIX_KIT_BAD_BOARD '$BOARD' -- usage: jupiter_byte_rxfix_kit.sh 148"; exit 1 ;;
esac

HERE=$(cd "$(dirname "$0")" && pwd)
REPO="${REPO:-$(cd "$HERE/../.." && pwd)}"
SRC="$REPO/$SRC_KIT"
KIT="$REPO/$KIT_NAME"
INJECT="$HERE/rxfix_inject.py"

if [ ! -d "$SRC" ]; then echo "RXFIX_KIT_NO_SRC $SRC"; exit 1; fi
if [ ! -f "$INJECT" ]; then echo "RXFIX_KIT_NO_INJECTOR $INJECT"; exit 1; fi
if [ ! -f "$SRC/build_txfix.tcl" ] || [ ! -f "$SRC/build_txfix.sh" ]; then
  echo "RXFIX_KIT_NO_BUILD_TCL $SRC/build_txfix.{tcl,sh} -- source kit was not made by jupiter_byte_seqbist_kit.sh"; exit 1
fi
for m in TXFIX_VARIANT SEQBIST_VARIANT; do
  [ -f "$SRC/$m" ] || { echo "RXFIX_KIT_NO_$m $SRC/$m"; exit 1; }
done
grep -q 'rx_seq_checker' "$SRC/build_txfix.tcl" || { echo "RXFIX_KIT_NO_CHECKER $SRC/build_txfix.tcl has no rx_seq_checker -- wrong source kit"; exit 1; }

# --- injector provenance, asserted BEFORE anything is copied -----------------
# Task 9's kit recorded injector_commit=b5c39a10 while the code it actually ran
# became 2c661e6: `git log -1 -- <file>` returns the last commit that TOUCHED the
# file, which is the wrong answer whenever the file is dirty, and Task 10 had to
# correct the flashed image's provenance after the fact.  Refuse to build a kit
# from an uncommitted injector, and record the md5 of the bytes actually run.
INJ_DIRTY=$(cd "$REPO" && git status --porcelain -- two_jup/skidfix/rxfix_inject.py 2>/dev/null)
if [ -n "$INJ_DIRTY" ]; then
  echo "RXFIX_KIT_REFUSE_DIRTY_INJECTOR two_jup/skidfix/rxfix_inject.py has uncommitted changes ($INJ_DIRTY) -- commit it first so the kit's provenance is true"; exit 1
fi
INJ_COMMIT=$(cd "$REPO" && git log -1 --format=%H -- two_jup/skidfix/rxfix_inject.py 2>/dev/null)
[ -n "$INJ_COMMIT" ] || { echo "RXFIX_KIT_NO_INJECTOR_COMMIT could not resolve the injector's git commit"; exit 1; }
INJ_MD5=$(md5sum "$INJECT" | awk '{print $1}')
echo "RXFIX_KIT injector commit=$INJ_COMMIT md5=$INJ_MD5 variants='$VARIANTS'"

if [ -f "$KIT/RXFIX_VARIANT" ]; then
  echo "RXFIX_KIT_REFUSE_ALREADY_TAGGED $KIT already has RXFIX_VARIANT: $(tr '\n' ' ' < "$KIT/RXFIX_VARIANT")"; exit 1
fi
if [ -e "$KIT" ]; then
  echo "RXFIX_KIT_REFUSE_EXISTS $KIT exists with no RXFIX_VARIANT marker -- remove or bank it manually first"; exit 1
fi

echo "RXFIX_KIT copy start $(date -Is) $SRC -> $KIT (lineage=$LINEAGE)"
mkdir -p "$KIT"
rsync -a \
  --exclude 'vivado_prj.runs/synth_1/' \
  --exclude 'vivado_prj.runs/impl_1/' \
  --exclude 'vivado_prj.runs/v_*/' \
  --exclude 'vivado_prj.cache/' \
  --exclude 'vivado_prj.sim/' \
  --exclude 'vivado_prj.hw/' \
  --exclude '*.log' --exclude '*.jou' --exclude '*.str' \
  --exclude 'boot/BOOT.BIN' \
  --exclude 'LAUNCHED' \
  "$SRC"/ "$KIT"/
RC=$?
if [ $RC -ne 0 ]; then echo "RXFIX_KIT_COPY_FAILED rc=$RC"; exit 1; fi
echo "RXFIX_KIT copy done $(date -Is)"

for V in $VARIANTS; do
  echo "RXFIX_KIT inject start $(date -Is) variant=$V"
  INJ_OUT=$(python3 "$INJECT" "$KIT" "$V" 2>&1)
  RC=$?
  echo "$INJ_OUT"
  if [ $RC -ne 0 ]; then echo "RXFIX_KIT_INJECT_FAILED variant=$V rc=$RC"; exit 1; fi
  # R4B's witness chain (QPSK_Rx .. TxRxCompo_ip) is patched ONLY where RXFIX_W1
  # is already present, and rxfix_inject.main() returns 0 either way -- it just
  # prints `skipped=[...] r4b_witness=off`.  A kit that had lost one W1 mirror
  # would therefore build cleanly with NO ninth word, so gate on that status line.
  case "$V" in R4B|R4D|R4E)
    VL=$(echo "$V" | tr 'A-Z' 'a-z')
    echo "$INJ_OUT" | grep -q "${VL}_witness=on" || { echo "RXFIX_KIT_INJECT_FAILED $V witness chain OFF (RXFIX_W1 missing from a mirror) -- the witness read words would not exist"; exit 1; }
    if echo "$INJ_OUT" | grep -q 'skipped='; then echo "RXFIX_KIT_INJECT_FAILED $V skipped one or more files"; exit 1; fi
    ;;
  esac
done

# --- independent re-verification (do not just trust the injector's printout) ---
FAIL=0
# W1 and R4B patch the SAME twelve files (R4B's five core files are a subset of
# W1's eight RTL files; its witness chain is the other three plus the four IP
# wrappers), so one loop over the marker list covers both variants.  NB the marker
# RXFIX_R4 is a PREFIX of RXFIX_R4B -- only the exact strings built here are ever
# grepped for, and the R3/R3S/R4 exclusion is left to the injector's own _has().
W1_SRC_FILES="Validate_Input_Push_Pop_block FIFO_block Rate_Handle Symbol_Synchronizer Frequency_and_Time_Synchronizer QPSK_Rx Receiver TxRxComposite"
W1_IP_FILES="TxRxCompo_ip_dut TxRxCompo_ip_axi_lite TxRxCompo_ip_addr_decoder TxRxCompo_ip"
# Per-variant file sets.  W1, R4B and R4D all patch the same twelve files; R1
# patches exactly ONE, Preamble_Detector.v, which is in neither of the other sets.
src_files_for(){ case "$1" in R1) echo "Preamble_Detector" ;; *) echo "$W1_SRC_FILES" ;; esac; }
ip_files_for(){  case "$1" in R1) echo "" ;;                  *) echo "$W1_IP_FILES"  ;; esac; }
for V in $VARIANTS; do
  M="RXFIX_$V"
  for f in $(src_files_for "$V"); do
    N=$(grep -rl "$M" --include="TxRxCompo_ip_src_$f.v" "$KIT" | wc -l)
    [ "$N" = 3 ] || { echo "RXFIX_KIT_VERIFY_FAILED $M $f marked in $N loose copies (want 3)"; FAIL=1; }
  done
  for f in $(ip_files_for "$V"); do
    N=$(grep -rl "$M" --include="$f.v" "$KIT" | wc -l)
    [ "$N" = 3 ] || { echo "RXFIX_KIT_VERIFY_FAILED $M $f marked in $N loose copies (want 3)"; FAIL=1; }
  done
done
NZ=0
for z in $(find "$KIT" -name TxRxCompo_ip_v1_0.zip); do
  NZ=$((NZ+1))
  for V in $VARIANTS; do
  python3 - "$z" "RXFIX_$V" "$(src_files_for "$V")" "$(ip_files_for "$V")" <<'PY' || FAIL=1
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1]); marker = sys.argv[2].encode()
want = ['TxRxCompo_ip_src_' + f + '.v' for f in sys.argv[3].split()] + \
       [f + '.v' for f in sys.argv[4].split()]
import os
have = {os.path.basename(i.filename): i.filename for i in z.infolist()}
bad = [w for w in want if w not in have or marker not in z.read(have[w])]
print(('RXFIX_KIT_ZIP_OK ' if not bad else 'RXFIX_KIT_ZIP_FAIL ') + sys.argv[2] + ' ' + sys.argv[1] +
      ('' if not bad else ' missing=' + ','.join(bad)))
sys.exit(1 if bad else 0)
PY
  done
done
[ "$NZ" = 2 ] || { echo "RXFIX_KIT_VERIFY_FAILED found $NZ TxRxCompo_ip_v1_0.zip (want 2)"; FAIL=1; }
# the SEQ-BIST judge and the build gates must survive the copy untouched
grep -q 'SEQBIST_PATCH_V1'         "$KIT/build_txfix.tcl" || { echo "RXFIX_KIT_VERIFY_FAILED seqbist BD patch lost"; FAIL=1; }
grep -q 'rx_seq_checker'           "$KIT/build_txfix.tcl" || { echo "RXFIX_KIT_VERIFY_FAILED rx_seq_checker lost"; FAIL=1; }
grep -q 'cnt_mux32'                "$KIT/build_txfix.tcl" || { echo "RXFIX_KIT_VERIFY_FAILED cnt_mux32 lost"; FAIL=1; }
grep -q 'IMPL_STRATEGY'            "$KIT/build_txfix.tcl" || { echo "RXFIX_KIT_VERIFY_FAILED IMPL_STRATEGY hook lost"; FAIL=1; }
grep -q 'TXFIX_ROUTED_TIMING_FAIL' "$KIT/build_txfix.tcl" || { echo "RXFIX_KIT_VERIFY_FAILED routed-WNS gate lost"; FAIL=1; }
cmp -s "$SRC/TXFIX_VARIANT"   "$KIT/TXFIX_VARIANT"   || { echo "RXFIX_KIT_VERIFY_FAILED TXFIX_VARIANT not carried over byte for byte"; FAIL=1; }
cmp -s "$SRC/SEQBIST_VARIANT" "$KIT/SEQBIST_VARIANT" || { echo "RXFIX_KIT_VERIFY_FAILED SEQBIST_VARIANT not carried over byte for byte"; FAIL=1; }
# W1 must not have touched the DBGCAP/TXCAP addresses or the write-only registers
grep -q 'read_reg_beatfix_viol_count' "$KIT/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/TxRxCompo_ip_addr_decoder.v" \
  || { echo "RXFIX_KIT_VERIFY_FAILED 0x20C decode disturbed"; FAIL=1; }
grep -q "decode_sel_fixctl_1_1 = addr_write == 14'b00000010000010" "$KIT/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/TxRxCompo_ip_addr_decoder.v" \
  || { echo "RXFIX_KIT_VERIFY_FAILED fixctl (0x208) write decode disturbed"; FAIL=1; }
# W1's eight read words 0x85..0x8C must survive whatever else was applied on top
DEC="$KIT/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/TxRxCompo_ip_addr_decoder.v"
grep -q "assign w1_hit = (address_select_level1 >= 8'h85)" "$DEC" \
  || { echo "RXFIX_KIT_VERIFY_FAILED W1's eight-word decode (0x85..0x8C) disturbed"; FAIL=1; }
case " $VARIANTS " in *" R4D "*)
  # R4D's witness is TWO words: 0x234 (word 0x8D, R4B's layout) and 0x238 (0x8E,
  # {16'b0, extras[15:0]}) -- the FULL side's counter.
  grep -q "assign r4d_hit = (address_select_level1 == 8'h8D) ||" "$DEC" \
    || { echo "RXFIX_KIT_VERIFY_FAILED R4D word 0x234 (0x8D) not decoded"; FAIL=1; }
  grep -q "(address_select_level1 == 8'h8E);" "$DEC" \
    || { echo "RXFIX_KIT_VERIFY_FAILED R4D word 0x238 (0x8E) not decoded"; FAIL=1; }
  grep -q "assign data_read = (r4d_hit ? r4d_reg\[address_select_level1\[0\]\] :" "$DEC" \
    || { echo "RXFIX_KIT_VERIFY_FAILED R4D witness words not wired into data_read"; FAIL=1; }
  RH="$KIT/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/TxRxCompo_ip_src_Rate_Handle.v"
  grep -q "r4d_do_extra" "$RH" \
    || { echo "RXFIX_KIT_VERIFY_FAILED R4D extra-pop path missing from Rate_Handle"; FAIL=1; }
  ;;
esac
case " $VARIANTS " in *" R1 "*)
  # R1: the realignment FIFO's pop becomes OCCUPANCY-indexed.  Assert BOTH the new
  # lines and the DISAPPEARANCE of the tick-indexed one it replaces -- a patch that
  # added its lines without removing the old pop would be silently inert.
  PD="$KIT/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/TxRxCompo_ip_src_Preamble_Detector.v"
  grep -q "assign Delay10_full = FIFO_numEntries == 14'd12333;" "$PD" \
    || { echo "RXFIX_KIT_VERIFY_FAILED R1 occupancy compare missing from Preamble_Detector"; FAIL=1; }
  grep -q "assign Delay10_out1 = Delay8_out1 & Delay10_full;" "$PD" \
    || { echo "RXFIX_KIT_VERIFY_FAILED R1 occupancy-indexed pop missing from Preamble_Detector"; FAIL=1; }
  if grep -q "assign Delay10_out1 = Delay10_reg\[49331\];" "$PD"; then
    echo "RXFIX_KIT_VERIFY_FAILED R1 left the tick-indexed pop in place (patch inert)"; FAIL=1
  fi
  ;;
esac
case " $VARIANTS " in *" R4B "*)
  # the ninth word at byte 0x234 = word 0x8D, ahead of W1's mux in data_read
  grep -q "assign r4b_hit = (address_select_level1 == 8'h8D);" "$DEC" \
    || { echo "RXFIX_KIT_VERIFY_FAILED ninth read word 0x234 (word 0x8D) not decoded"; FAIL=1; }
  grep -q "assign data_read = (r4b_hit ? r4b_reg :" "$DEC" \
    || { echo "RXFIX_KIT_VERIFY_FAILED ninth word not wired into data_read"; FAIL=1; }
  # the steered pop and the witness word themselves, in the kit's own Rate_Handle
  RH="$KIT/hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback/TxRxCompo_ip_src_Rate_Handle.v"
  grep -q "assign r4bWit = {r4b_locked, r4b_skips, r4b_opens};" "$RH" \
    || { echo "RXFIX_KIT_VERIFY_FAILED R4B witness word missing from Rate_Handle"; FAIL=1; }
  grep -q "r4b_pop_nom & ( ~r4b_skip_en)" "$RH" \
    || { echo "RXFIX_KIT_VERIFY_FAILED R4B steered pop expression missing from Rate_Handle"; FAIL=1; }
  ;;
esac

# --- widen build_txfix.sh's kit-name guard (idempotent) ----------------------
if ! grep -q 'jupiter_byte_rxfix\*_build' "$KIT/build_txfix.sh"; then
  sed -i 's|^  jupiter_byte_txfix\*_build\|jupiter_byte_seqbist\*_build) ;;|  jupiter_byte_txfix*_build\|jupiter_byte_seqbist*_build\|jupiter_byte_rxfix*_build) ;;|' "$KIT/build_txfix.sh"
fi
if ! grep -q 'jupiter_byte_rxfix\*_build' "$KIT/build_txfix.sh"; then
  echo "RXFIX_KIT_GUARD_FAILED could not widen the kit-name case guard in $KIT/build_txfix.sh"; FAIL=1
else
  echo "RXFIX_KIT guard widened: $(grep -n 'rxfix\*_build' "$KIT/build_txfix.sh" | head -1)"
fi

if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "RXFIX_KIT_VERIFY_OK"

{ echo "$VARIANTS"; echo "$INJ_COMMIT"; echo "INJECTOR_MD5=$INJ_MD5";
  echo "SRC_KIT=$SRC_KIT"; echo "LINEAGE=$LINEAGE";
  echo "READ_WORDS=$READ_WORDS"; echo "FREEZE=fixctl bit 4 (write 0x208)"; } > "$KIT/RXFIX_VARIANT"
echo "RXFIX_KIT_DONE board=$BOARD kit=$KIT src_kit=$SRC_KIT variants='$VARIANTS' injector_commit=$INJ_COMMIT injector_md5=$INJ_MD5"
echo "RXFIX_KIT_NOTE 148: build with IMPL_STRATEGY=explore; routed WNS < 0 => report, DO NOT bank as flashable"
