#!/bin/bash
# run_sweep.sh -- STAGE-2 coarse sweep: wait for dithered IQ files, then run all
# points through the Jul-25 lock-instrumented netlist in parallel. Detach-safe.
cd "$(dirname "$0")"
while [ "$(ls t_*.iq 2>/dev/null | wc -l)" -lt 9 ]; do sleep 5; done
echo "ALL_IQ_READY $(date)" >> sweep.status
for f in 130 156 180; do
  for a in 0.05 0.15 0.30; do
    tag=t_f${f}_a${a}
    if [ ! -s ${tag}_res.txt ]; then
      nice -n 10 ./simlock $tag.iq 8000000 0 4 8400 0 $tag 1 > $tag.stdout 2>&1 &
    fi
  done
done
wait
echo "SWEEP_SIMS_DONE $(date)" >> sweep.status
