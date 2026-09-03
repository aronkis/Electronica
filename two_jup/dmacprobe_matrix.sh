#!/bin/bash
# dmacprobe_matrix.sh -- the deterministic DMAC-boundary matrix on 148 (probe image). Sequential,
# one dmacprobe_run.sh per point, RIG_LOCK held by the caller (RIGLOCK_PARENT=1) or taken here.
set -u
D=$(cd "$(dirname "$0")" && pwd); cd "$D"
. sim_repro/riglock.sh 2>/dev/null || true
[ "${RIGLOCK_PARENT:-0}" = 1 ] || { rig_lock dmacprobe_matrix || exit 2; trap rig_unlock EXIT; }
export RIGLOCK_PARENT=1 DUR=${DUR:-60}
RES=$D/DMACPROBE_MATRIX_$(date +%Y%m%d_%H%M%S).txt
run(){ echo "### $*" | tee -a "$RES"; env "$@" bash dmacprobe_run.sh 2>&1 | grep -E "DMACPROBE_RESULT|lost-slot|lost-run|witness|landed/offered|MASK_ON|DMACPROBE_ABORT|DMACPROBE_DONE" | tee -a "$RES"; }
# 1 bursty control (08-18 zero-loss regime)      2 continuous, queued, M16 (prediction: 1 lost/boundary, slot 0)
run RXQ=1 M=16 WORDGAP=0   GAP=200000 MASK=0
run RXQ=1 M=16 WORDGAP=535 GAP=545    MASK=0
# 3 continuous, queued, M32 (prediction: half)   4 continuous, reset-per-transfer, M16 (prediction: more)
run RXQ=1 M=32 WORDGAP=535 GAP=545    MASK=0
run RXQ=0 M=16 WORDGAP=535 GAP=545    MASK=0
# 5 Option E: queued + tuser masked after first transfer (prediction: zero loss)
run RXQ=1 M=16 WORDGAP=535 GAP=545    MASK=1
# 6 mask under reset-per-transfer (prediction: delivery stops after the mask -- every re-arm waits for tuser)
run RXQ=0 M=16 WORDGAP=535 GAP=545    MASK=1
echo "DMACPROBE_MATRIX_DONE $RES" | tee -a "$RES"
