#!/bin/bash
# jupiter_byte_txfix_fetch.sh <kit>
#
# Fetches a finished TXFIX build's BOOT.BIN from hdl-dev-2, banks it into
# boot_known_good/ under this repo's naming convention, and appends its row
# to boot_known_good/README.md and boot_known_good/MD5SUMS.
#
# <kit> is a local kit dir basename, e.g. jupiter_byte_txfixF3_build. Reads
# <kit>/TXFIX_VARIANT (written by jupiter_byte_txfix_kit.sh) for the variant
# tag; REMOTE_DIR/BOOT.BIN path matches build_txfix.tcl's bootgen output
# (<REMOTE_DIR>/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN).
#
# BOARD (env, default 148) selects the bank naming and the README table the new
# row lands in: BOOT.BIN.$BOARD.$TAG.$MD5_12.  TXFIX_TAG (env, default
# txfix<VARIANT>) overrides the tag -- needed for lineage-qualified builds such as
# txfixF3vendh (the 146 / TMR-vendh lineage), where the variant alone would collide
# with the 148 ddrcap2-lineage image of the same variant letter.  For BOARD=146 the
# row is INSERTED after the last existing BOOT.BIN.146.* row (the 146 table is at the
# top of README.md); for BOARD=148 it is appended at the end of the file, exactly as
# before -- that is where the 148 rows have accumulated.
#
# Does NOT flash anything and never touches the board (10.0.0.148/146). The
# README row is stamped "BUILT, NOT flashed, sim gate pending" -- the silicon
# lane (Task 8/T3) is the only place that later edits it to "flashed"/
# "verified".
#
# NOT run automatically by anything in this repo; invoked by hand (or by the
# Vivado-lane task) only after build_txfix.sh's remote unit has printed
# TXFIX_BUILD_DONE in the remote log.
set -u
KIT="${1:?usage: jupiter_byte_txfix_fetch.sh <kit-dir-name-or-path>}"
HERE=$(cd "$(dirname "$0")" && pwd)
KIT_BASENAME=$(basename "$KIT")
KIT_LOCAL="$HERE/$KIT_BASENAME"
REMOTE_HOST=hdl-dev-2
REMOTE_DIR_EXPANDED="/home/tcollins/qpsk-builds/$KIT_BASENAME"
REMOTE_BOOT="$REMOTE_DIR_EXPANDED/hdl_prj_jupiter_composite/vivado_ip_prj/boot/BOOT.BIN"
BANK="$HERE/boot_known_good"
README="$BANK/README.md"
MD5SUMS="$BANK/MD5SUMS"

if [ ! -d "$KIT_LOCAL" ]; then echo "TXFIX_FETCH_NO_KIT $KIT_LOCAL"; exit 1; fi
if [ ! -f "$KIT_LOCAL/TXFIX_VARIANT" ]; then
  echo "TXFIX_FETCH_NO_VARIANT_MARKER $KIT_LOCAL/TXFIX_VARIANT missing"; exit 1
fi
VARIANT=$(head -1 "$KIT_LOCAL/TXFIX_VARIANT")
case "$VARIANT" in F1|F2|F3) ;; *) echo "TXFIX_FETCH_BAD_VARIANT '$VARIANT'"; exit 1 ;; esac
BOARD="${BOARD:-148}"
case "$BOARD" in 146|148) ;; *) echo "TXFIX_FETCH_BAD_BOARD '$BOARD' (want 146|148)"; exit 1 ;; esac
TAG="${TXFIX_TAG:-txfix${VARIANT}}"
case "$TAG" in *[!A-Za-z0-9]*) echo "TXFIX_FETCH_BAD_TAG '$TAG' (alphanumeric only -- it becomes part of the bank filename)"; exit 1 ;; esac
# line 3 of TXFIX_VARIANT (written since 2026-09-03) records the source kit; older
# kits have only two lines, in which case the historical ddrcap2 wording is right.
SRC_KIT_LINE=$(sed -n '3p' "$KIT_LOCAL/TXFIX_VARIANT")
case "$SRC_KIT_LINE" in
  SRC_KIT=*) SRC_KIT_DESC="source kit ${SRC_KIT_LINE#SRC_KIT=}" ;;
  *)         SRC_KIT_DESC="jupiter_byte_ddrcap2_build (DDRCAP-v2 instrument unchanged)" ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
LOCAL_TMP="$WORK/BOOT.BIN"

echo "TXFIX_FETCH scp start $(date -Is) $REMOTE_HOST:$REMOTE_BOOT"
scp -p "$REMOTE_HOST:$REMOTE_BOOT" "$LOCAL_TMP"
RC=$?
if [ $RC -ne 0 ]; then echo "TXFIX_FETCH_SCP_FAILED rc=$RC"; exit 1; fi
echo "TXFIX_FETCH scp done $(date -Is)"

MD5_FULL=$(md5sum "$LOCAL_TMP" | awk '{print $1}')
MD5_12=${MD5_FULL:0:12}
DEST_NAME="BOOT.BIN.${BOARD}.${TAG}.${MD5_12}"
DEST="$BANK/$DEST_NAME"

# NOTE (2026-09-03): an already-banked BOOT.BIN must NOT short-circuit the README /
# MD5SUMS / md5sum -c steps below.  This script copies the image BEFORE it appends
# those rows, so a failure in the row step (e.g. the 146 table not being found) leaves
# a banked file with no README row and no MD5SUMS line -- and the old `exit 0` here
# made the obvious retry a silent no-op that never fixed it.  The row and MD5SUMS
# appends are both idempotent (they grep for $DEST_NAME first), so falling through is
# safe and makes a re-run the correct repair.
if [ -e "$DEST" ]; then
  EXIST_MD5=$(md5sum "$DEST" | awk '{print $1}')
  if [ "$EXIST_MD5" = "$MD5_FULL" ]; then
    echo "TXFIX_FETCH_ALREADY_BANKED $DEST (md5 matches -- continuing to the README/MD5SUMS/verify steps)"
  else
    echo "TXFIX_FETCH_REFUSE_COLLISION $DEST exists with a DIFFERENT md5 ($EXIST_MD5 != $MD5_FULL) -- refusing to overwrite"
    exit 1
  fi
else
  cp "$LOCAL_TMP" "$DEST"
  echo "TXFIX_FETCH banked $DEST md5=$MD5_FULL"
fi

# --- README.md row: follow the existing table format (see the
#     BOOT.BIN.148.ddrcap2.638b36de3493 row for the pattern) ---
ROW="| \`$DEST_NAME\` | \`$MD5_12\` | TXFIX $VARIANT: fix build from $SRC_KIT_DESC via txfix_inject.py, fetched from hdl-dev-2 kit $KIT_BASENAME. **BUILT, NOT flashed, sim gate pending.** |"
if grep -qF "$DEST_NAME" "$README"; then
  echo "TXFIX_FETCH_README_ROW_ALREADY_PRESENT (skipping append)"
elif [ "$BOARD" = "146" ]; then
  # the 146 table is at the top of README.md -- insert after its last row rather than
  # appending to the end of the file, where the row would land in the 148 material.
  LASTROW=$(grep -n '^| `BOOT.BIN.146\.' "$README" | tail -1 | cut -d: -f1)
  if [ -z "$LASTROW" ]; then echo "TXFIX_FETCH_README_NO_146_TABLE (refusing to guess a location)"; exit 1; fi
  awk -v n="$LASTROW" -v row="$ROW" 'NR==n{print; print row; next} {print}' "$README" > "$README.new" \
    && mv "$README.new" "$README"
  echo "TXFIX_FETCH readme row inserted after line $LASTROW: $ROW"
else
  printf '%s\n' "$ROW" >> "$README"
  echo "TXFIX_FETCH readme row appended: $ROW"
fi

# --- MD5SUMS line (bare filename, matches how `md5sum -c` is run from
#     inside boot_known_good/) ---
MD5_LINE="$MD5_FULL  $DEST_NAME"
if grep -qF "$DEST_NAME" "$MD5SUMS"; then
  echo "TXFIX_FETCH_MD5SUMS_LINE_ALREADY_PRESENT (skipping append)"
else
  printf '%s\n' "$MD5_LINE" >> "$MD5SUMS"
  echo "TXFIX_FETCH md5sums line appended: $MD5_LINE"
fi

echo "TXFIX_FETCH verify start $(date -Is)"
VERIFY_OUT=$(cd "$BANK" && grep -F "$DEST_NAME" MD5SUMS | md5sum -c - 2>&1)
VRC=$?
echo "$VERIFY_OUT"
if [ $VRC -ne 0 ]; then echo "TXFIX_FETCH_VERIFY_FAILED"; exit 1; fi
echo "TXFIX_FETCH_DONE variant=$VARIANT dest=$DEST_NAME md5=$MD5_FULL"
