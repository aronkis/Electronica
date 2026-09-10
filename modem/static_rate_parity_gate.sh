#!/bin/bash
# static_rate_parity_gate.sh <candidate_build_dir> [reference_build_dir]
#
# Static rate-parity gate (N3 2026-08-13, born from RECONCILE_FSV2.md): assert
# that a candidate build's generated fabric carries EXACTLY the reference
# lineage's rate structure -- the check that would have caught any scheduler/
# rail regression (halved rail, new ce, flipped ingest cadence contract) before
# a 3h bitgen and a flash cycle. Reference default = the banked e49c011b
# lineage build (jupiter_byte_lean_build).
#
# Checks (all against hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback):
#   1. Timing controller (TxRxCompo_ip_src_TxRxComposite_tc.v) byte-identical
#      modulo the "// Created:" timestamp line.
#   2. Composite header rail table (base rate + every "ce_out_N <sample time>"
#      line) identical; candidate may only ADD output rows whose ce/period pair
#      already exists in the reference table (witness ports on existing rails).
#   3. Block design system.bd identical after json-normalization, modulo
#      ip_revision and the absolute mem_init path.
# Exit 0 = RATE_PARITY_PASS; nonzero prints the offending diff.
set -u
CAND=${1:?usage: static_rate_parity_gate.sh <candidate_build_dir> [reference_build_dir]}
REF=${2:-$(cd "$(dirname "$0")/.." && pwd)/jupiter_byte_lean_build}
SUB=hdl_prj_jupiter_composite/hdlsrc/commhdlQPSKTxRxLoopback
CT="$CAND/$SUB/TxRxCompo_ip_src_TxRxComposite_tc.v"
RT="$REF/$SUB/TxRxCompo_ip_src_TxRxComposite_tc.v"
CC="$CAND/$SUB/TxRxCompo_ip_src_TxRxComposite.v"
RC="$REF/$SUB/TxRxCompo_ip_src_TxRxComposite.v"
fail(){ echo "RATE_PARITY_FAIL $*"; exit 1; }
for f in "$CT" "$RT" "$CC" "$RC"; do [ -f "$f" ] || fail "missing $f"; done

# --- 1. timing controller parity (modulo Created timestamp) ---
if ! diff <(grep -v '^// Created:' "$RT") <(grep -v '^// Created:' "$CT") >/dev/null; then
  echo "--- timing controller diff (ref vs cand):"
  diff <(grep -v '^// Created:' "$RT") <(grep -v '^// Created:' "$CT") | head -40
  fail "timing controller differs -- rail structure changed"
fi
echo "  [1/3] timing controller byte-identical (modulo timestamp)"

# --- 2. rail table parity ---
rails(){ awk '/^\/\/ Clock Enable  Sample Time/{f=1} f&&/^\/\/ ce_out/{print $2,$3} f&&/^\/\/ Output Signal/{exit}' "$1"; }
base(){ grep -m1 '^// Model base rate:' "$1"; }
[ "$(base "$RC")" = "$(base "$CC")" ] || fail "model base rate differs: ref='$(base "$RC")' cand='$(base "$CC")'"
if ! diff <(rails "$RC") <(rails "$CC") >/dev/null; then
  echo "--- rail (ce) table diff:"; diff <(rails "$RC") <(rails "$CC")
  fail "clock-enable rail set differs"
fi
# every candidate output row's (ce, period) pair must exist in the reference table
outtab(){ awk '/^\/\/ Output Signal/{f=1;next} f&&/^\/\/ [a-z]/{print $2,$3,$4} f&&/^\/\/ --/{c++} c>=2{exit}' "$1"; }
while read -r sig ce per; do
  grep -q "^$ce $per\$" <(rails "$RC") || fail "output $sig on unknown rail: $ce $per"
done < <(outtab "$CC")
# no reference output may have MOVED rails
while read -r sig ce per; do
  cl=$(outtab "$CC" | awk -v s="$sig" '$1==s{print $2,$3}')
  [ -z "$cl" ] && fail "reference output $sig missing from candidate"
  [ "$cl" = "$ce $per" ] || fail "output $sig moved rails: ref '$ce $per' cand '$cl'"
done < <(outtab "$RC")
echo "  [2/3] rail table + per-port rail assignment parity OK"

# --- 3. BD parity (modulo ip_revision + absolute paths) ---
CB="$CAND/hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.srcs/sources_1/bd/system/system.bd"
RB="$REF/hdl_prj_jupiter_composite/vivado_ip_prj/vivado_prj.srcs/sources_1/bd/system/system.bd"
if [ -f "$CB" ] && [ -f "$RB" ]; then
  norm(){ python3 -c "import json,sys,re
d=json.dumps(json.load(open(sys.argv[1])),indent=1,sort_keys=True)
d=re.sub(r'\"ip_revision\": \"[0-9]+\"','\"ip_revision\": \"X\"',d)
d=re.sub(r'/mnt/[^\"]*/(jupiter_byte_[a-z0-9_]+)/','/BUILD/',d)
print(d)" "$1"; }
  if ! diff <(norm "$RB") <(norm "$CB") >/dev/null; then
    echo "--- BD diff:"; diff <(norm "$RB") <(norm "$CB") | head -40
    fail "block design differs beyond ip_revision/paths"
  fi
  echo "  [3/3] system.bd parity OK"
else
  echo "  [3/3] BD parity SKIPPED (bd not present yet in one side)"
fi
echo "RATE_PARITY_PASS cand=$CAND ref=$REF"
