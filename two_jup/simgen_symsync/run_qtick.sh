#!/bin/bash
# run_qtick.sh -- QUICK-LOOK (2026-08-13): gated byte-plane tick, 8 shards of
# ~100 frames (8-frame warmup) from the 810-frame hunt_auto healthy capture.
# Tick: period 8.04 frames (1586517.12 clk), gate p=0.35, eat 3 words at the
# ByteSerializer output. Detach-safe.
cd "$(dirname "$0")"
CAP=../r3cap/hunt_auto_20260731_211829/pair.iq
SPF=49332
TICK=1586517120     # milli-clk
P=350
EATW=3
for s in 0 100 200 300 400 500 600 700; do
  e=$((s+99)); [ $e -gt 809 ] && e=809
  w0=$((s-8)); [ $w0 -lt 0 ] && w0=0
  off=$((w0*SPF)); nfr=$((e-w0+1)); ns=$((nfr*SPF))
  tag=q_${s}_${e}
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
  SEED=$((0xA5000000 + s))
  nice -n 10 ../../jupiter_240k5_byte/rtl_sim/obj_byte_qtick_f1536_jul25/Vwrap_byte_lock \
    $tag.iq $NS 0 4 8400 0 $tag $TICK $P $SEED $EATW > $tag.stdout 2>&1 &
done
wait
echo "QTICK_DONE $(date)" >> sweep.status
