#!/bin/bash
# run_highamp.sh -- amplitude bracket for the kill argument: 156 Hz timing
# dither at 1.0 and 3.0 samples peak (spec sweep 0.01-0.3 showed no
# dither-caused failures; find where the loop actually breaks and check the
# structure of the failures there). Detach-safe.
cd "$(dirname "$0")"
for a in 1.0 3.0; do
  tag=t_f156_a${a}
  ( [ -s $tag.iq ] || python3 ../../jupiter_240k5_byte/rtl_sim/iq_dither.py \
      ../r3cap/evm_swap_A/pair.iq $tag.iq --type timing --cadence_hz 156 --amp $a \
      > $tag.gen.log 2>&1
    nice -n 10 ./simlock $tag.iq 8000000 0 4 8400 0 $tag 1 > $tag.stdout 2>&1 ) &
done
wait
echo "HIGHAMP_DONE $(date)" >> sweep.status
