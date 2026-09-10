#!/bin/bash
# rxloop_launch.sh -- [sim] Task 8d leg launcher.  One transient user unit per
# leg (systemd-run --user, never a harness background task).  Every leg runs the
# SAME TGEN configuration (gap 150000, fill 1516, seq from 1) so the underlying
# TX byte stream is bit-identical across legs and only the impairment differs.
#   ./rxloop_launch.sh <nepochs> <max_minutes> [leg ...]
set -u
R=$(cd "$(dirname "$0")" && pwd)
BIN=$R/obj_rxloop/Vwrap_byte_rxloop
OUT=$R/rxloop_runs
GAP=150000; FILL=1516; SEED=20260904
NEP=${1:-1200}; MAXMIN=${2:-88}; shift 2 || true
mkdir -p "$OUT"
# tag|esn0|cfo_Hz
LEGS="clean_c2k|none|2000
esn15_c2k|15|2000
esn10_c2k|10|2000
esn15_c0|15|0
esn15_c3k|15|3000
esn07_c2k|7|2000"
for L in $LEGS; do
  TAG=${L%%|*}; REST=${L#*|}; ESN=${REST%%|*}; CFO=${REST#*|}
  if [ $# -gt 0 ]; then case " $* " in *" $TAG "*) ;; *) continue;; esac; fi
  UNIT=rxloop-$TAG
  systemctl --user reset-failed "$UNIT" 2>/dev/null
  systemd-run --user --collect --unit="$UNIT" --working-directory="$R" \
    -p StandardOutput=append:"$OUT/$TAG.log" -p StandardError=append:"$OUT/$TAG.log" \
    "$BIN" "$NEP" "$OUT/$TAG" "$ESN" "$CFO" "$SEED" "$GAP" "$FILL" "$MAXMIN" \
    && echo "LAUNCHED $TAG esn0=$ESN cfo=$CFO nepochs=$NEP maxmin=$MAXMIN"
done
