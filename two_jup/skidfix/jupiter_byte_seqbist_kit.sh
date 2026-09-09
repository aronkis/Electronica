#!/bin/bash
# jupiter_byte_seqbist_kit.sh <148|146>
#
# Derives a SEQ-BIST build kit (T1 / T4 of plan happy-bubbling-owl) from an
# existing TXFIX-F3 kit, modelled on jupiter_byte_txfix_kit.sh:
#
#   148 -> SRC jupiter_byte_txfixF3_build       KIT jupiter_byte_seqbist_build
#          (lineage 148: BD already has traffic_gen / rx_checker / tx_checker /
#          tx_starve / cnt_mux16 / sel_slice / the three 0x9D4x GPIOs)
#   146 -> SRC jupiter_byte_txfixF3vendh_build  KIT jupiter_byte_seqbist146_build
#          (lineage vendh: BD has NONE of that chain; the patch adds it)
#
# Steps: copy (same rsync excludes as jupiter_byte_txfix_kit.sh) -> install the
# three Task-1 RTL files from jupiter_240k5_byte/rtl_sim/ into the kit root ->
# run two_jup/skidfix/patch_seqbist_tcl.py on the kit's build_txfix.tcl -> widen
# build_txfix.sh's kit-name guard -> verify -> write SEQBIST_VARIANT.
#
# NEVER runs Vivado.  The copied build_txfix.tcl keeps its IMPL_STRATEGY hook
# and its routed-WNS gate (TXFIX_ROUTED_WNS / TXFIX_ROUTED_TIMING_FAIL); the
# patcher refuses to run on a build tcl that lacks either.
#
# The kit's TXFIX_VARIANT file is carried over BYTE FOR BYTE from the source kit
# (build_txfix.sh reads line 1 as VARIANT, and the vendh template's
# TXFIX_IPSHARED_VERIFY exits 1 on an unknown variant).  SEQBIST_VARIANT is a
# NEW marker file alongside it.
#
# build_txfix.sh guards on `case "$KIT" in jupiter_byte_txfix*_build)`, which the
# seqbist kit names do not match, so the installed copy's guard is widened to
# accept jupiter_byte_seqbist*_build too (idempotent sed, verified after).
# REMOTE_DIR and the systemd unit name are both derived from the kit basename,
# so the two seqbist kits build in independent remote dirs and are still caught
# by build_txfix.sh's own `txfix-build-*` concurrency preflight.
#
# Usage:  two_jup/skidfix/jupiter_byte_seqbist_kit.sh <148|146>
# Env:    REPO (default: the repo this script lives in)
set -u

BOARD="${1:-}"
case "$BOARD" in
  148) SRC_KIT="jupiter_byte_txfixF3_build";      KIT_NAME="jupiter_byte_seqbist_build";    LINEAGE="148"   ;;
  146) SRC_KIT="jupiter_byte_txfixF3vendh_build"; KIT_NAME="jupiter_byte_seqbist146_build"; LINEAGE="vendh" ;;
  *) echo "SEQBIST_KIT_BAD_BOARD '$BOARD' -- usage: jupiter_byte_seqbist_kit.sh <148|146>"; exit 1 ;;
esac

HERE=$(cd "$(dirname "$0")" && pwd)
REPO="${REPO:-$(cd "$HERE/../.." && pwd)}"
SRC="$REPO/$SRC_KIT"
KIT="$REPO/$KIT_NAME"
PATCHER="$HERE/patch_seqbist_tcl.py"
RTL_SRC="${RTL_SRC:-$REPO/jupiter_240k5_byte/rtl_sim}"
RTL_FILES="qpsk_traffic_gen_v2.v rx_seq_checker.v cnt_mux32.v"
# rx_seq_checker WITH_CRC default baked into the kit's build tcl (0 drops the
# CRC32 datapath -- the routed-WNS/utilisation escape hatch).  The build driver
# can still override it per run with env SEQBIST_WITH_CRC without re-patching.
WITH_CRC="${SEQBIST_WITH_CRC:-1}"
case "$WITH_CRC" in 0|1) ;; *) echo "SEQBIST_KIT_BAD_WITH_CRC '$WITH_CRC' (want 0 or 1)"; exit 1 ;; esac

if [ ! -d "$SRC" ]; then echo "SEQBIST_KIT_NO_SRC $SRC"; exit 1; fi
if [ ! -f "$PATCHER" ]; then echo "SEQBIST_KIT_NO_PATCHER $PATCHER"; exit 1; fi
if [ ! -f "$SRC/build_txfix.tcl" ] || [ ! -f "$SRC/build_txfix.sh" ]; then
  echo "SEQBIST_KIT_NO_BUILD_TCL $SRC/build_txfix.{tcl,sh} -- source kit was not made by jupiter_byte_txfix_kit.sh"; exit 1
fi
if [ ! -f "$SRC/TXFIX_VARIANT" ]; then echo "SEQBIST_KIT_NO_TXFIX_VARIANT $SRC/TXFIX_VARIANT"; exit 1; fi

# --- fail LOUDLY if Task 1's RTL is not landed yet ---------------------------
MISSING=""
for f in $RTL_FILES; do
  [ -f "$RTL_SRC/$f" ] || MISSING="$MISSING $f"
done
if [ -n "$MISSING" ]; then
  echo "SEQBIST_KIT_NO_RTL missing in $RTL_SRC:$MISSING (Task 1 / T0a not landed yet)"; exit 1
fi

if [ -f "$KIT/SEQBIST_VARIANT" ]; then
  echo "SEQBIST_KIT_REFUSE_ALREADY_TAGGED $KIT already has SEQBIST_VARIANT: $(tr '\n' ' ' < "$KIT/SEQBIST_VARIANT")"
  exit 1
fi
if [ -e "$KIT" ]; then
  echo "SEQBIST_KIT_REFUSE_EXISTS $KIT exists with no SEQBIST_VARIANT marker -- remove or bank it manually first"
  exit 1
fi

echo "SEQBIST_KIT copy start $(date -Is) $SRC -> $KIT (lineage=$LINEAGE)"
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
if [ $RC -ne 0 ]; then echo "SEQBIST_KIT_COPY_FAILED rc=$RC"; exit 1; fi
echo "SEQBIST_KIT copy done $(date -Is)"

# --- install the Task-1 RTL at the kit root (where build_txfix.tcl add_files
# --- them via [file dirname [info script]], the same idiom as timing_gate.tcl)
for f in $RTL_FILES; do
  cp "$RTL_SRC/$f" "$KIT/$f" || { echo "SEQBIST_KIT_RTL_COPY_FAILED $f"; exit 1; }
  echo "SEQBIST_KIT rtl $f md5=$(md5sum "$KIT/$f" | awk '{print $1}')"
done

# --- BD patch ----------------------------------------------------------------
echo "SEQBIST_KIT patch start $(date -Is) lineage=$LINEAGE with_crc=$WITH_CRC"
python3 "$PATCHER" "$KIT" --lineage "$LINEAGE" --with-crc "$WITH_CRC"
RC=$?
if [ $RC -ne 0 ]; then echo "SEQBIST_KIT_PATCH_FAILED rc=$RC"; exit 1; fi

# --- widen build_txfix.sh's kit-name guard (idempotent) ----------------------
if ! grep -q 'jupiter_byte_seqbist\*_build' "$KIT/build_txfix.sh"; then
  sed -i 's|^  jupiter_byte_txfix\*_build) ;;|  jupiter_byte_txfix*_build\|jupiter_byte_seqbist*_build) ;;|' "$KIT/build_txfix.sh"
fi
if ! grep -q 'jupiter_byte_seqbist\*_build' "$KIT/build_txfix.sh"; then
  echo "SEQBIST_KIT_GUARD_FAILED could not widen the kit-name case guard in $KIT/build_txfix.sh"; exit 1
fi
echo "SEQBIST_KIT guard widened: $(grep -n 'seqbist\*_build' "$KIT/build_txfix.sh" | head -1)"

# --- independent re-verification (do not just trust the patcher's printout) ---
FAIL=0
grep -q 'SEQBIST_PATCH_V1'            "$KIT/build_txfix.tcl" || { echo "SEQBIST_KIT_VERIFY_FAILED no marker"; FAIL=1; }
grep -q "SEQBIST_WIRE_OK lineage=$LINEAGE" "$KIT/build_txfix.tcl" || { echo "SEQBIST_KIT_VERIFY_FAILED no lineage tail"; FAIL=1; }
grep -q 'IMPL_STRATEGY'               "$KIT/build_txfix.tcl" || { echo "SEQBIST_KIT_VERIFY_FAILED IMPL_STRATEGY hook lost"; FAIL=1; }
grep -q 'TXFIX_ROUTED_TIMING_FAIL'    "$KIT/build_txfix.tcl" || { echo "SEQBIST_KIT_VERIFY_FAILED routed-WNS gate lost"; FAIL=1; }
grep -q "set _sb_with_crc $WITH_CRC" "$KIT/build_txfix.tcl" || { echo "SEQBIST_KIT_VERIFY_FAILED WITH_CRC default not baked in"; FAIL=1; }
grep -q 'CONFIG.WITH_CRC'             "$KIT/build_txfix.tcl" || { echo "SEQBIST_KIT_VERIFY_FAILED no CONFIG.WITH_CRC"; FAIL=1; }
grep -q 'cnt_mux32'                   "$KIT/build_txfix.tcl" || { echo "SEQBIST_KIT_VERIFY_FAILED no cnt_mux32"; FAIL=1; }
grep -q 'rx_seq_checker'              "$KIT/build_txfix.tcl" || { echo "SEQBIST_KIT_VERIFY_FAILED no rx_seq_checker"; FAIL=1; }
grep -q 'qpsk_traffic_gen_v2'         "$KIT/build_txfix.tcl" || { echo "SEQBIST_KIT_VERIFY_FAILED no qpsk_traffic_gen_v2"; FAIL=1; }
cmp -s "$SRC/TXFIX_VARIANT" "$KIT/TXFIX_VARIANT" || { echo "SEQBIST_KIT_VERIFY_FAILED TXFIX_VARIANT not carried over byte for byte"; FAIL=1; }
if [ "$LINEAGE" = "vendh" ]; then
  grep -q '0x9D400000' "$KIT/build_txfix.tcl" || { echo "SEQBIST_KIT_VERIFY_FAILED vendh: no tgen_ctrl_gpio address"; FAIL=1; }
  grep -q '0x9D410000' "$KIT/build_txfix.tcl" || { echo "SEQBIST_KIT_VERIFY_FAILED vendh: no tgen_rx_ctrl_gpio address"; FAIL=1; }
  grep -q '0x9D450000' "$KIT/build_txfix.tcl" || { echo "SEQBIST_KIT_VERIFY_FAILED vendh: no tgen_rx_wit_gpio address"; FAIL=1; }
  grep -q 'TXFIX_VENDH_IMPL_STRATEGY_REFUSED' "$KIT/build_txfix.tcl" || { echo "SEQBIST_KIT_VERIFY_FAILED vendh guard lost"; FAIL=1; }
fi
if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "SEQBIST_KIT_VERIFY_OK"

PATCH_COMMIT=$(cd "$REPO" && git log -1 --format=%H -- two_jup/skidfix/patch_seqbist_tcl.py 2>/dev/null)
[ -z "$PATCH_COMMIT" ] && PATCH_COMMIT="UNCOMMITTED"
RTL_MD5=$(cd "$KIT" && md5sum $RTL_FILES | awk '{printf "%s=%s ", $2, $1}')
# line 1 = lineage (148|vendh), line 2 = patcher commit, line 3 = source kit,
# line 4 = the three RTL md5s.  TXFIX_VARIANT is untouched next to it.
{ echo "$LINEAGE"; echo "$PATCH_COMMIT"; echo "SRC_KIT=$SRC_KIT"; echo "RTL: $RTL_MD5"; echo "WITH_CRC=$WITH_CRC"; } > "$KIT/SEQBIST_VARIANT"
echo "SEQBIST_KIT_DONE board=$BOARD lineage=$LINEAGE kit=$KIT src_kit=$SRC_KIT patcher_commit=$PATCH_COMMIT"
if [ "$LINEAGE" = "vendh" ]; then
  echo "SEQBIST_KIT_NOTE 146/vendh: build with IMPL_STRATEGY UNSET -- the vendh build tcl exits 1 on IMPL_STRATEGY=explore"
else
  echo "SEQBIST_KIT_NOTE 148: build with IMPL_STRATEGY=explore (plan T1)"
fi
