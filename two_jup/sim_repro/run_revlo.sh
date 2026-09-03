#!/bin/bash
# H-5a: reverse LO operating-point sweep (the lever that halved forward), one 68 s reverse
# leg per point, same capture/scoring discipline (capture_r3.sh B, accept_analyze). Runs
# only after the flash+A/B chain has finished (rig mutex). No retries.
S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
. sim_repro/riglock.sh
while [ ! -f $S/flash_ab_chain.done ] || [ -e "$RIG_LOCK" ]; do sleep 300; done
rig_lock reverse_lo_sweep; trap rig_unlock EXIT
for pt in default 1899980000 1900020000 1900040000; do
  if [ "$pt" = default ]; then E=""; else E="LO_B_RX=$pt"; fi
  env $E GATE_DIR=B ./capture_r3.sh B -d 68 -k -o r3cap/revlo_${pt}_$(date +%Y%m%d_%H%M%S) > $S/revlo_$pt.log 2>&1
  d=$(ls -d r3cap/revlo_${pt}_* | tail -1); echo "REVLO $pt $(grep -a -m1 'LO' $d/qpsk_tun.log | cut -c1-60) $(python3 accept_analyze.py $d/frames.bin 2>&1 | grep -E 'PER=|UNUSABLE' | head -1)" >> $S/revlo.txt
done
echo done > $S/revlo.done
