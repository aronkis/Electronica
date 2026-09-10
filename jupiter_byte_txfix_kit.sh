#!/bin/bash
# jupiter_byte_txfix_kit.sh <VARIANT>   (VARIANT = F1|F2|F3)
#
# Makes a TXFIX build kit: $KIT_NAME/ (default jupiter_byte_txfix<VARIANT>_build)
# = a copy of $SRC_KIT (default jupiter_byte_ddrcap2_build -- the DDRCAP-v2
# instrument stays unchanged, sel6 witness must keep working) with the
# fix-variant RTL patches injected into
# every loose .v mirror under hdl_prj_jupiter_composite/ (ipcore/
# TxRxCompo_ip_v1_0/hdl/, hdlsrc/commhdlQPSKTxRxLoopback/, and
# vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0/hdl/) and the two
# TxRxCompo_ip_v1_0.zip members (which live at different paths under the
# composite tree).
#
# Exclusions on the copy mirror build_ddrcap.sh's rsync (never carry heavy/
# derived Vivado state or a stale BOOT.BIN/LAUNCHED marker into a new kit):
#   vivado_prj.runs/{synth_1,impl_1}, vivado_prj.cache, vivado_prj.sim,
#   vivado_prj.hw, *.log *.jou *.str, boot/BOOT.BIN, LAUNCHED
#
# After the copy, build_txfix.sh/.tcl (this repo's generic templates, see
# two_jup/skidfix/txfix_build.{sh,tcl}.tmpl) are installed into the kit,
# replacing the ddrcap2-specific build_ddrcap.sh/.tcl -- REMOTE_DIR in
# build_txfix.sh is derived from the kit's own basename, so it never collides
# with another kit's remote build dir. timing_gate.tcl is carried over
# unmodified from the ddrcap2 kit.
#
# Then two_jup/skidfix/txfix_inject.py <kit>/hdl_prj_jupiter_composite
# <VARIANT> patches the netlist (contract: prints
# "TXFIX_INJECT variant=... zips=2 zips_verified=2", nonzero on failure).
# This script independently re-verifies (marker grep in loose .v + unzip -p
# of both zip members) before writing <kit>/TXFIX_VARIANT.
#
# Refuses to run on a kit dir that already carries a TXFIX_VARIANT marker,
# and refuses to overwrite an existing kit dir that lacks one (ambiguous
# state -- remove or bank it manually first).
#
# ---------------------------------------------------------------------------
# SOURCE-KIT GENERALISATION (2026-09-03, 146 fix-flash prep).  146 is NOT on the
# ddrcap2 lineage: it runs the TMR/vendh image ec414d2df8bc, whose RTL kit is
# jupiter_byte_tmr146_build.  Four env knobs make this script lineage-agnostic;
# every default reproduces the previous behaviour byte for byte:
#
#   SRC_KIT   source kit dir name    (default jupiter_byte_ddrcap2_build)
#   KIT_NAME  output kit dir name    (default jupiter_byte_txfix<VARIANT>_build)
#   TCL_TMPL  build tcl template     (default two_jup/skidfix/txfix_build.tcl.tmpl)
#   TMR_ATTR  1 = run the source kit's tmr_attr_inject.sh AFTER injection and
#             require TMR_ATTR_OK (default 0 = skip, as before).  The TMR
#             (* dont_touch *) annotations on the triplicated Delay14 regs are
#             load-bearing on the 146 lineage (see tmr_attr_inject.sh's header):
#             the injector rewrites the two TxRxCompo_ip_v1_0.zip archives, so
#             re-running the idempotent annotator is the cheap proof they
#             survived the rewrite in every copy AND in both zips.
#
# The rsync exclude list also drops vivado_prj.runs/v_*/ -- the tmr146 project
# carries nine placement-variant impl runs (v_aslh..v_wldbp, several GB of
# routed DCPs) that are audit artefacts of the 2026-08-25 copy_run study and are
# useless to a from-scratch re-synth.  ddrcap2 has no such runs, so the default
# kit is unaffected.
# ---------------------------------------------------------------------------
set -u
VARIANT="${1:-}"
case "$VARIANT" in
  F1|F2|F3) ;;
  *) echo "TXFIX_KIT_BAD_VARIANT '$VARIANT' -- usage: jupiter_byte_txfix_kit.sh <F1|F2|F3>"; exit 1 ;;
esac

HERE=$(cd "$(dirname "$0")" && pwd)
SRC_KIT="${SRC_KIT:-jupiter_byte_ddrcap2_build}"
KIT_NAME="${KIT_NAME:-jupiter_byte_txfix${VARIANT}_build}"
TCL_TMPL="${TCL_TMPL:-two_jup/skidfix/txfix_build.tcl.tmpl}"
TMR_ATTR="${TMR_ATTR:-0}"
SRC="$HERE/$SRC_KIT"
KIT="$HERE/$KIT_NAME"
INJECTOR="$HERE/two_jup/skidfix/txfix_inject.py"
TMPL_SH="$HERE/two_jup/skidfix/txfix_build.sh.tmpl"
TMPL_TCL="$HERE/$TCL_TMPL"
TMPL_README="$HERE/two_jup/skidfix/txfix_kit_readme.md.tmpl"

# build_txfix.sh only accepts kits named jupiter_byte_txfix*_build (it derives the
# remote build dir from the kit basename); refuse early rather than at build time.
case "$KIT_NAME" in
  jupiter_byte_txfix*_build) ;;
  *) echo "TXFIX_KIT_BAD_NAME '$KIT_NAME' (build_txfix.sh requires jupiter_byte_txfix<...>_build)"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then echo "TXFIX_KIT_NO_SRC $SRC"; exit 1; fi
if [ ! -f "$INJECTOR" ]; then echo "TXFIX_KIT_NO_INJECTOR $INJECTOR (Task 2 not landed yet)"; exit 1; fi
if [ ! -f "$TMPL_SH" ] || [ ! -f "$TMPL_TCL" ]; then echo "TXFIX_KIT_NO_TEMPLATE $TMPL_SH / $TMPL_TCL"; exit 1; fi
if [ ! -f "$TMPL_README" ]; then echo "TXFIX_KIT_NO_TEMPLATE $TMPL_README"; exit 1; fi

if [ -f "$KIT/TXFIX_VARIANT" ]; then
  echo "TXFIX_KIT_REFUSE_ALREADY_TAGGED $KIT already has TXFIX_VARIANT: $(cat "$KIT/TXFIX_VARIANT" | tr '\n' ' ')"
  exit 1
fi
if [ -e "$KIT" ]; then
  echo "TXFIX_KIT_REFUSE_EXISTS $KIT exists with no TXFIX_VARIANT marker -- remove or bank it manually before rerunning"
  exit 1
fi

echo "TXFIX_KIT copy start $(date -Is) $SRC -> $KIT"
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
if [ $RC -ne 0 ]; then echo "TXFIX_KIT_COPY_FAILED rc=$RC"; exit 1; fi
echo "TXFIX_KIT copy done $(date -Is)"

cp "$TMPL_SH" "$KIT/build_txfix.sh"
chmod +x "$KIT/build_txfix.sh"
cp "$TMPL_TCL" "$KIT/build_txfix.tcl"
sed "s/@VARIANT@/$VARIANT/g" "$TMPL_README" > "$KIT/README.md"
echo "TXFIX_KIT installed build_txfix.sh + build_txfix.tcl + README.md (templates: $TMPL_SH, $TMPL_TCL, $TMPL_README)"

# Injector recurses (os.walk) over the whole tree it's given, patching every
# loose-.v copy it finds by basename (incl. the TxRxCompo_ip_src_ prefixed
# names used inside the Vivado IP kit, at all 3 locations they're mirrored:
# ipcore/TxRxCompo_ip_v1_0/hdl/, hdlsrc/commhdlQPSKTxRxLoopback/, and
# vivado_ip_prj/ipcore/TxRxCompo_ip_v1_0/hdl/) plus the two
# TxRxCompo_ip_v1_0.zip members (which live at DIFFERENT paths under the
# composite tree, not both under ipcore/) -- so it must be pointed at the
# whole composite tree, exactly as the plan specifies.
COMPOSITE="$KIT/hdl_prj_jupiter_composite"
if [ ! -d "$COMPOSITE" ]; then echo "TXFIX_KIT_NO_COMPOSITE $COMPOSITE"; exit 1; fi

echo "TXFIX_KIT inject start $(date -Is) variant=$VARIANT dir=$COMPOSITE"
python3 "$INJECTOR" "$COMPOSITE" "$VARIANT"
RC=$?
if [ $RC -ne 0 ]; then echo "TXFIX_KIT_INJECT_FAILED rc=$RC"; exit 1; fi
echo "TXFIX_KIT inject done $(date -Is)"

# --- optional TMR re-annotation gate (TMR_ATTR=1; 146/vendh lineage) ---------
if [ "$TMR_ATTR" = "1" ]; then
  TMRI="$KIT/tmr_attr_inject.sh"
  if [ ! -f "$TMRI" ]; then
    echo "TXFIX_KIT_NO_TMR_INJECT $TMRI (TMR_ATTR=1 but the source kit carries no annotator)"
    exit 1
  fi
  echo "TXFIX_KIT tmr_attr start $(date -Is) (idempotent re-annotate + hard verify after the zip rewrite)"
  TMR_OUT=$(bash "$TMRI" "$KIT" 2>&1); TMR_RC=$?
  echo "$TMR_OUT"
  if [ $TMR_RC -ne 0 ] || ! echo "$TMR_OUT" | grep -q '^TMR_ATTR_OK'; then
    echo "TXFIX_KIT_TMR_FAILED rc=$TMR_RC (no TMR_ATTR_OK)"; exit 1
  fi
  echo "TXFIX_KIT tmr_attr done $(date -Is)"
fi

# --- independent re-verification (do not just trust the injector's own printout) ---
MARKER="TXFIX_${VARIANT}"
LOOSE_HITS=$(grep -rl "$MARKER" "$COMPOSITE" --include='*.v' 2>/dev/null | wc -l)
if [ "$LOOSE_HITS" -lt 1 ]; then
  echo "TXFIX_KIT_VERIFY_FAILED no loose .v under $COMPOSITE contains marker $MARKER"
  exit 1
fi
echo "TXFIX_KIT_VERIFY loose_v_hits=$LOOSE_HITS marker=$MARKER"

ZIP_COUNT=0
ZIP_OK=0
while IFS= read -r Z; do
  [ -z "$Z" ] && continue
  ZIP_COUNT=$((ZIP_COUNT+1))
  if unzip -p "$Z" 2>/dev/null | strings | grep -q "$MARKER"; then
    ZIP_OK=$((ZIP_OK+1))
    echo "TXFIX_KIT_VERIFY zip_ok $Z"
  else
    echo "TXFIX_KIT_VERIFY zip_missing_marker $Z"
  fi
done < <(find "$COMPOSITE" -iname 'TxRxCompo_ip_v1_0.zip')

echo "TXFIX_KIT_VERIFY zips=$ZIP_COUNT zips_with_marker=$ZIP_OK"
if [ "$ZIP_COUNT" -ne 2 ] || [ "$ZIP_OK" -ne 2 ]; then
  echo "TXFIX_KIT_VERIFY_FAILED expected exactly 2 zip members carrying $MARKER, got zips=$ZIP_COUNT with_marker=$ZIP_OK"
  exit 1
fi

INJ_COMMIT=$(cd "$HERE" && git log -1 --format=%H -- two_jup/skidfix/txfix_inject.py 2>/dev/null)
if [ -z "$INJ_COMMIT" ]; then INJ_COMMIT="UNCOMMITTED"; fi
# line 1 = variant (build_txfix.sh reads it with head -1 -- do not reorder),
# line 2 = injector commit, line 3 = source-kit provenance.
{ echo "$VARIANT"; echo "$INJ_COMMIT"; echo "SRC_KIT=$SRC_KIT"; } > "$KIT/TXFIX_VARIANT"
echo "TXFIX_KIT_DONE variant=$VARIANT kit=$KIT src_kit=$SRC_KIT injector_commit=$INJ_COMMIT"
