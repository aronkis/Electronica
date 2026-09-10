#!/bin/bash
# measure_ber.sh <ip> <nreads> -- rapid BIST reads; aggregate BER by summing positive counter deltas
# (robust to datapath resets). Reports golden_frac, lock-loss events, BER. Jupiter base 0x9D000000.
set -u
WRAP=$(cd "$(dirname "$0")" && pwd)/anyssh.sh
IP=${1:?ip}; N=${2:-600}
$WRAP $IP 'for i in $(seq 1 '"$N"'); do echo "$(busybox devmem 0x9D000104 32) $(busybox devmem 0x9D000108 32) $(busybox devmem 0x9D000144 32)"; done' 2>/dev/null | \
python3 -c '
import sys
def h(x):
    try: return int(x,16)
    except: return None
P=[];E=[];G=[]
for ln in sys.stdin:
    a=ln.split()
    if len(a)==3 and h(a[0]) is not None and h(a[1]) is not None:
        P.append(h(a[0])); E.append(h(a[1])); G.append(1 if a[2].strip().lower()=="0x04922282" else 0)
tp=te=0
for i in range(1,len(P)):
    dp=P[i]-P[i-1]; de=E[i]-E[i-1]
    if dp>0: tp+=dp
    if de>0: te+=de
ber=100*te/(tp*120) if tp>0 else -1
gf=sum(G)/len(G) if G else 0
print(f"ip='"$IP"' golden_frac={gf:.3f} packets={tp} errors={te} BER={ber:.5f}% bits={tp*120}")
'
