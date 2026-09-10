#!/bin/bash
# run_region.sh -- replay a frame region of the R3 hunt tap through the
# FIXED-POINT f1536 netlist byte receiver (perframe_f1536, linked against the
# preserved obj_byte_iq_f1536 archive), chunked with warm-up overlap so the
# chunks run in parallel. Geometry: f1536 SPF=49332 samples/frame, cadence=4
# clks/sample (16 clk/sym, sps=4 -- calibrated from the S1B f1536 gate run).
#
# usage: run_region.sh F0 F1 ROT [JOBS] [WARM]
#   F0/F1 : first/last capture frame index (inclusive), frame = 49332 samples
#   ROT   : sample-level quadrant rotation (0/90/180/270) from the pilot sweep
#   JOBS  : parallel sims (default 4); WARM: warm-up frames per chunk (default 8)
set -eu
cd "$(dirname "$0")"
CAP=${CAP:-../../../two_jup/r3cap/hunt_auto_20260731_211829/pair.iq}
SPF=49332
F0=${1:?F0} F1=${2:?F1} ROT=${3:?ROT} JOBS=${4:-4} WARM=${5:-8}
CHUNK=${CHUNK:-70}          # payload frames per chunk
RSTCS_END=${RSTCS_END:-8400}
VP=${VP:-0}

n=0
for ((s=F0; s<=F1; s+=CHUNK)); do
  e=$((s+CHUNK-1)); [ $e -gt $F1 ] && e=$F1
  w0=$((s-WARM)); [ $w0 -lt 0 ] && w0=0
  off=$((w0*SPF)); nfr=$((e-w0+1)); ns=$((nfr*SPF))
  tag=chunk_${s}_${e}_r${ROT}
  # PROVENANCE GUARD (defect #8, 2026-08-11). This reuse test used to be the whole
  # check: if $tag.iq existed it was kept, whatever capture it came from. CAP is an
  # env override, so a later run against a DIFFERENT capture wrote same-named chunk
  # files into this directory, and aggregate.py merged them silently. The symptom was
  # a -2590 decoded-seq jump with every frame still CRC-good -- a decode fault cannot
  # produce valid CRCs on a different seq run, which is what exposed it. Three chunks
  # were foreign; they are quarantined in foreign_notpair/.
  # Now every slice carries a .prov sidecar (capture path + md5 + offset + count), and
  # a slice whose provenance does not match is REGENERATED rather than reused.
  CAPMD5=${CAPMD5:-$(md5sum "$CAP" | cut -d' ' -f1)}
  WANT="$CAP $CAPMD5 off=$off ns=$ns rot=$ROT"
  if [ -s $tag.iq ] && [ "$(cat $tag.prov 2>/dev/null)" != "$WANT" ]; then
    echo "PROVENANCE MISMATCH on $tag.iq -- regenerating"
    echo "  have: $(cat $tag.prov 2>/dev/null || echo '(no .prov -- predates the guard)')"
    echo "  want: $WANT"
    rm -f $tag.iq
  fi
  if [ ! -s $tag.iq ]; then
    python3 - "$CAP" $tag.iq $off $ns $ROT <<'EOF'
import sys, numpy as np
cap, out, off, ns, rot = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
raw = np.memmap(cap, dtype=np.int16)
I = raw[2*off:2*(off+ns):2].astype(np.int32); Q = raw[2*off+1:2*(off+ns):2].astype(np.int32)
z = (I==0)&(Q==0)
if z.any(): I,Q = I[~z],Q[~z]
if rot==90: I,Q = -Q,I
elif rot==180: I,Q = -I,-Q
elif rot==270: I,Q = Q,-I
o = np.empty(2*I.size, np.int16); o[0::2]=np.clip(I,-32768,32767); o[1::2]=np.clip(Q,-32768,32767)
o.tofile(out)
print(f"SLICE {out} off={off} ns={ns} zeros={int(z.sum())} rot={rot}")
EOF
    echo "$WANT" > $tag.prov
  fi
  NS=$(( $(stat -c%s $tag.iq) / 4 ))
  ( nice -n 15 ./perframe_f1536 $tag.iq $NS $VP 4 $RSTCS_END 0 $tag > $tag.log 2>&1 \
      && echo "DONE $tag" || echo "FAIL $tag" ) &
  n=$((n+1)); [ $((n % JOBS)) -eq 0 ] && wait
done
wait
echo "REGION_RUNS_COMPLETE F0=$F0 F1=$F1 rot=$ROT"
