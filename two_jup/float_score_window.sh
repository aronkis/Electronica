#!/bin/bash
# float_score_window.sh CAPTURE.bin START COUNT OUTDIR -- float column for one sample-domain window.
set -eu
D=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$D/.." && pwd)
CAP=$1; START=$2; COUNT=$3; OUT=$4; mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)   # absolute -- matlab -batch below does its own cd('$ROOT/k5_240')
python3 "$D/ddr_to_iq.py" "$CAP" "$OUT/window.iq" --start "$START" --count "$COUNT"
/mnt/onetb/MATLAB/R2025b/bin/matlab -batch "cd('$ROOT/k5_240'); float_tap_window('$OUT/window.iq','$OUT/float.csv')" 2>&1 | tee "$OUT/float.log" | grep -E "FLOAT_WINDOW|Error"
