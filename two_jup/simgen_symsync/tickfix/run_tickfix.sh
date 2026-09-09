#!/bin/bash
# run_tickfix.sh -- TICK-FIX A/B campaign (2026-08-13 staged task).
# 4 shards x ~200 frames of the 810-frame hunt_auto healthy capture, each run
# in 3 modes through sim_byte_tickfix (behavioral 1536-word platform-FIFO
# shadow at the netlist byte_rx output):
#   m0 = clean baseline (no injection)
#   m1 = paired wrap-beat swallow, UNGUARDED (positive control)
#   m2 = same schedule + skid-buffer guard
# Schedule: SUPER=6144 words (4 FIFO wraps = 32.17 frames), PAIROFF=1536 words
# (1 wrap = 8.04 frames), EATW=3 swallowed beats/hit, per-hit gate p=0.70.
# Same seed per shard across modes -> identical hit schedule for the A/B.
# Drive contract: cadence 4 = the Jul-25 netlist's NATIVE cadence per
# HARNESS_AB.md (the cadence-2 value there is the post-Jul-29/fsv2 contract;
# HARNESS_AB's own matrix shows Jul-25 at cadence 2 delivers 0 CRC-good).
# Detach-safe.
cd "$(dirname "$0")"
BIN=../../../jupiter_240k5_byte/rtl_sim/obj_byte_tickfix_f1536_jul25/Vwrap_byte_tickfix
CAP=../../r3cap/hunt_auto_20260731_211829/pair.iq
SPF=49332
SUPER=6144; PAIROFF=1536; START=700; EATW=3; HITP=700
for s in 0 200 400 600; do
  e=$((s+201)); [ $e -gt 809 ] && e=809
  w0=$((s-8)); [ $w0 -lt 0 ] && w0=0
  off=$((w0*SPF)); nfr=$((e-w0+1)); ns=$((nfr*SPF))
  tag=tf_${s}_${e}
  if [ ! -s $tag.iq ]; then
    python3 - "$CAP" $tag.iq $off $ns <<'EOF'
import sys, numpy as np
cap,out,off,ns = sys.argv[1],sys.argv[2],int(sys.argv[3]),int(sys.argv[4])
raw = np.memmap(cap, dtype=np.int16)
I = raw[2*off:2*(off+ns):2].astype(np.int32); Q = raw[2*off+1:2*(off+ns):2].astype(np.int32)
z = (I==0)&(Q==0)
if z.any(): I,Q = I[~z],Q[~z]
o = np.empty(2*I.size, np.int16); o[0::2]=np.clip(I,-32768,32767); o[1::2]=np.clip(Q,-32768,32767)
o.tofile(out); print(f"SLICE {out} off={off} ns={ns} zeros={int(z.sum())}")
EOF
  fi
  NS=$(( $(stat -c%s $tag.iq) / 4 ))
  SEED=$((0xB7000000 + s))
  for m in 0 1 2; do
    nice -n 10 $BIN $tag.iq $NS 0 4 8400 0 ${tag}_m${m} $m \
      $SUPER $PAIROFF $START $EATW $HITP $SEED > ${tag}_m${m}.stdout 2>&1 &
  done
done
wait
echo "TICKFIX_DONE $(date)" >> status.txt
