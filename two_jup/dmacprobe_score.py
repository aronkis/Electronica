#!/usr/bin/env python3
"""Score one dmacprobe point: in-dwell ok/lost/dup, lost-frame position within the M-slot transfer
(relative to the first scored seq), witness deltas (seam beats/user beats vs modem pin words)."""
import sys, re, collections
log, wit, nb, M, tag = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
L = open(log, errors='replace').read().splitlines()
summ = [l for l in L if l.startswith('seq: t=')]
def kv(l): return {k: v for k, v in re.findall(r'(\w+)=(-?[\d.e+]+)', l)}
base = kv(summ[nb]) if len(summ) > nb else {}
fin = [l for l in L if 'SEQRX frames_scored' in l]
v = kv(fin[-1]) if fin else (kv(summ[-1]) if summ else {})   # scorer may still be running: last periodic line
g = lambda d, k: float(d.get(k, 0))
ok, lost, dup = g(v,'ok')-g(base,'ok'), g(v,'lost')-g(base,'lost'), g(v,'dup')-g(base,'dup')
ev = [kv(l) for l in L if l.startswith('EVT ') and 'type=lost' in l]
# first seq scored after enable: first EVT/ok seq unknown -> use min lost seq's neighbourhood; the injector restarts
# at seq=1 on every enable, so transfer slot k of frame seq s is (s-1) % M when the first transfer syncs on seq 1.
pos = collections.Counter(); runs = collections.Counter()
for e in ev:
    s, n = int(float(e['seq'])), int(float(e['n']))
    if s >= 1: pos[(s-1) % M] += 1; runs[n] += 1
W = {}
for l in open(wit):
    m = re.match(r'WIT (\w+) beats=(\S+) user=(\S+) pins=(\S+)', l)
    if m: W[m.group(1)] = tuple(int(x, 16) if x.startswith('0x') else int(x) for x in m.groups()[1:])
d = lambda k: (W['post'][k]-W['pre'][k]) & 0xFFFFFFFF if 'pre' in W and 'post' in W else -1
tot = ok + lost
per = 100.0*lost/tot if tot else float('nan')
print(f"DMACPROBE_RESULT {tag} ok={ok:.0f} lost={lost:.0f} dup={dup:.0f} PER={per:.3f}% lost_events={len(ev)} (total ok={g(v,'ok'):.0f} lost={g(v,'lost'):.0f} junk={g(v,'junk'):.0f}; baseline line {nb}: ok={g(base,'ok'):.0f})")
print(f"  lost-slot-in-transfer histogram (slot=(seq-1)%M): {dict(sorted(pos.items()))}")
print(f"  lost-run-length histogram: {dict(sorted(runs.items()))}")
print(f"  witness deltas: seam_beats={d(0)} seam_user_beats={d(1)} modem_pin_words={d(2)} "
      f"(frames offered by user beats={d(1)}; seam beats/191={d(0)/191 if d(0)>=0 else -1:.1f})")
if ok and d(1) > 0: print(f"  landed/offered = {ok/d(1):.4f}  -> discarded frames = {d(1)-ok:.0f}")
