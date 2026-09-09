#!/bin/bash
# txfix_witness_go.sh -- VAR env: sel6 DDRCAP-v2 witness on the CURRENT arm (no arm inside).
# Real path: ddrcap2_capture.sh 6 <VAR> (512 MB, credited on golden pre/post capTAP AND a
# full-size capture -- bytes=536870912 in the capture meta; a short read is NOT credited), then
# sel6_stall_geometry.py <bin> <json> (stall-run count) and ddrcap2_pc.py <bin> --sel 6 (Tier-2),
# printing WITNESS_<VAR> stalls=<n> tier2=<PASS|FAIL> credited=<yes|no>.
#
# DRY=1 makes zero board contact: it never calls ddrcap2_capture.sh (that script has no DRY
# guard of its own -- it always ssh's). Instead it exercises the scoring path on two local
# positive/negative controls and prints one WITNESS_<VAR> line per control:
#   1. an existing local sel6 capture (two_jup/beatcap/20260902_185552_sel6/mid.bin) as the
#      POSITIVE control -- must show a non-zero stall count (measured on this repo's copy:
#      stalls=6; the plan text's "stalls=4" figure is stale, see task report).
#   2. a freshly generated synthetic all-quiet .bin (1,048,576 records of one fixed repeating
#      hard-decision symbol with periodic demod-mark frame boundaries every 12,320 records,
#      no transitions anywhere) as the NEGATIVE control -- must show stalls=0. Tier-2 is
#      expected to FAIL on this synthetic stream (it is not real modulated IQ), which is fine:
#      DRY only proves the stall counter's zero/nonzero discrimination, not Tier-2 on synthetic
#      data.
set -u
D=$(cd "$(dirname "$0")" && pwd); VAR=${VAR:?}; DRY=${DRY:-0}
OUT=${OUT:-$D/txfixwit/$(date +%Y%m%d_%H%M%S)_$VAR}; mkdir -p "$OUT"
log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }

score(){ # $1=bin $2=json $3=label -> prints STALLS=<n> TIER2=<PASS|FAIL>, sets globals
  local bin=$1 json=$2 label=$3
  python3 "$D/sel6_stall_geometry.py" "$bin" "$json" > "$OUT/${label}_geometry.log" 2>&1
  STALLS=$(python3 -c "import json;print(len(json.load(open('$json'))['stalls']))")
  python3 "$D/ddrcap2_pc.py" "$bin" --sel 6 > "$OUT/${label}_tier2.log" 2>&1
  if [ $? -eq 0 ]; then TIER2=PASS; else TIER2=FAIL; fi
}

if [ "$DRY" = 1 ]; then
  log "[dry] no ddrcap2_capture.sh call (no board contact); scoring two local controls instead"

  # --- positive control: existing local capture ---
  POSBIN="$D/beatcap/20260902_185552_sel6/mid.bin"
  POSMETA="$D/beatcap/20260902_185552_sel6/meta.txt"
  if [ ! -f "$POSBIN" ]; then log "FATAL: positive-control capture missing: $POSBIN"; exit 1; fi
  score "$POSBIN" "$OUT/pos_stalls.json" pos
  PCREDIT=$(grep '^mid ' "$POSMETA" | sed -n 's/.*credit=\([a-z]*\).*/\1/p')
  [ -z "$PCREDIT" ] && PCREDIT=no
  log "  positive control ($POSBIN)"
  echo "WITNESS_$VAR stalls=$STALLS tier2=$TIER2 credited=$PCREDIT"

  # --- negative control: synthetic all-quiet capture ---
  QBIN="$OUT/quiet_synthetic.bin"
  python3 - "$QBIN" <<'PYEOF'
import sys
import numpy as np
N = 1048576      # 1M records
FRAME = 12320    # sel6 demod-marker frame length (offset map's declared frame length)
a = np.zeros((N, 4), dtype='<i2')
a[:, 0] = -100   # I: fixed sign -> one constant hard-decision symbol, never transitions
a[:, 1] = 100    # Q: fixed sign
idx = np.arange(N)
mark = (idx % FRAME == 0)
ch2 = np.zeros(N, dtype='<u2')
ch2[mark] |= (1 << 15)   # mark_demod bit, periodic frame boundaries
a[:, 2] = ch2.astype('<i2')
a[:, 3] = 0
a.tofile(sys.argv[1])
PYEOF
  score "$QBIN" "$OUT/quiet_stalls.json" quiet
  log "  synthetic all-quiet control ($QBIN, $(stat -c %s "$QBIN") bytes)"
  echo "WITNESS_$VAR stalls=$STALLS tier2=$TIER2 credited=yes"
else
  CAPOUT="$OUT/cap"; mkdir -p "$CAPOUT"
  OUT="$CAPOUT" SZ=134217728 bash "$D/ddrcap2_capture.sh" 6 "$VAR" > "$OUT/run.log.capture" 2>&1 || true
  cat "$OUT/run.log.capture" >> "$OUT/run.log" 2>/dev/null
  # ddrcap2_capture.sh writes straight into the OUT we hand it: $CAPOUT/$VAR.bin and
  # $CAPOUT/meta.txt -- it does NOT make a timestamped subdir (that only happens when OUT is
  # unset and it defaults to ddrcap2_pc/<ts>). The recursive find below is therefore a no-op
  # in this call path; it is left in place so an older layout still resolves.
  BIN=$(find "$CAPOUT" -name "$VAR.bin" -newer "$CAPOUT" 2>/dev/null | head -1)
  [ -z "$BIN" ] && BIN=$(find "$CAPOUT" -name "$VAR.bin" | head -1)
  [ -z "$BIN" ] && { log "FATAL: no capture .bin produced"; exit 1; }
  # Credit rule (BOTH halves required): pre/post capTAP golden AND a full-size capture.
  # meta.txt line format: "<VAR> sel=6 bytes=<n> pre=0x... post=0x..." (ddrcap2_capture.sh:16).
  # A short read still produces a scorable .bin, and stalls=0 on a truncated capture is not
  # evidence of anything -- so bytes must be the full 536,870,912 (SZ=134217728 samples x 4 B).
  WANT_BYTES=536870912
  GOT_BYTES=$(sed -n "s/.* bytes=\([0-9][0-9]*\).*/\1/p" "$CAPOUT/meta.txt" 2>/dev/null | tail -1)
  [ -z "$GOT_BYTES" ] && GOT_BYTES=0
  if grep -q "WARN: post capTAP not golden" "$OUT/run.log.capture"; then
    CREDITED=no
  elif [ "$GOT_BYTES" != "$WANT_BYTES" ]; then
    CREDITED=no
    log "  NOT credited: capture is $GOT_BYTES bytes, want $WANT_BYTES (short read)"
  else
    CREDITED=yes
  fi
  JSON="$OUT/${VAR}_stalls.json"
  score "$BIN" "$JSON" "$VAR"
  echo "WITNESS_$VAR stalls=$STALLS tier2=$TIER2 credited=$CREDITED"
fi
