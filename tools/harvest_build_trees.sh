#!/bin/bash
# harvest_build_trees.sh -- tar the hand-written scripts out of every untracked
# jupiter_byte_*_build / _gates tree before the tree is deleted.
#
# WHY: some scripts the shipped images were built with (build_txfix.sh,
# build_final.sh, rxfix_*.m) were generated INTO the build trees and never
# tracked. The archive tag cannot hold them. This keeps them, small, outside the
# repo, so sub-project 2 can trace the chain.
#
# A non-zero exit status means at least one tarball came out empty (0 files) --
# do NOT delete the source trees until that is investigated; re-run after
# fixing rather than deleting on faith.
#
# Usage: tools/harvest_build_trees.sh <dest_dir>
set -euo pipefail
DEST=${1:?dest dir}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$DEST"
cd "$ROOT"
n=0
empty=0
for t in jupiter_byte_*_build jupiter_byte_*_gates; do
  [ -d "$t" ] || continue
  find "$t" \( -path "*/hdl_prj*" -o -path "*/slprj" -o -path "*/ipcore" -o -path "*/.Xil" -o -path "*/vivado_prj*" -o -path "*/.runs" \) -prune -o \
       -type f \( -name "*.sh" -o -name "*.py" -o -name "*.tcl" -o -name "*.m" -o -name "*.xdc" -o -name "*.tmpl" -o -name "*.toml" -o -name "*.md" -o -name "*.txt" -o -name "*.log" -o -name "*.status" \) -size -4M -print0 \
    | tar --null -czf "$DEST/$t.tar.gz" -T -
  n=$((n+1))
  count=$(tar tzf "$DEST/$t.tar.gz" | wc -l)
  echo "harvested $t -> $DEST/$t.tar.gz ($count files)"
  if [ "$count" -eq 0 ]; then
    echo "HARVEST_EMPTY $t" >&2
    empty=$((empty+1))
  fi
done
echo "HARVEST_DONE trees=$n empty=$empty"
if [ "$empty" -gt 0 ]; then
  exit 1
fi
