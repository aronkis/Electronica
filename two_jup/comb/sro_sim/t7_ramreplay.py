#!/usr/bin/env python3
"""[sim] Task 7 controller probe: replay the Rate_Handle ring RAM from a per-enb-beat
window (sim_sro ramwin) and test WHICH model reproduces the emitted word, and whether
the emitted word is the ring content from the PREVIOUS LAP.

Models tried, all of the SimpleDualPortRAM_generic shape (registered read):
  RBW  read-before-write  : dout(n+1) = ram_before_write(n)[rd_addr(n)]
  RAW  read-after-write   : dout(n+1) = ram_after_write(n)[rd_addr(n)]
Then, at each validated pop, report the LAP DISTANCE of the emitted word: how many
pushes ago the word at that address was written.
"""
import sys, collections
f = sys.argv[1] if len(sys.argv) > 1 else 't7_ram_m10.txt'
ev = collections.defaultdict(list)
for ln in open(f):
    if ln.startswith('#'): continue
    a = [int(x) for x in ln.strip().split(',')]
    ev[a[0]].append(a)
C = dict(ev=0, rel=1, sidx=2, beat=3, inI=4, inQ=5, wr=6, rd=7, vp=8, vq=9,
         occ=10, pe=11, pf=12, oI=13, oQ=14, vo=15, tr=16)
for e in sorted(ev):
    rows = ev[e]
    for model in ('RBW', 'RAW'):
        ram = {}; wcnt = {}; npush = 0; dout = None; mism = 0; tot = 0; lapd = []
        for r in rows:
            if dout is not None and r[C['vo']]:
                tot += 1
                if dout[0] != (r[C['oI']], r[C['oQ']]): mism += 1
                else: lapd.append(npush - dout[1])
            pre = ram.get(r[C['rd']])
            if r[C['vp']]:
                npush += 1
                ram[r[C['wr']]] = ((r[C['inI']], r[C['inQ']]), npush)
            post = ram.get(r[C['rd']])
            nd = pre if model == 'RBW' else post
            if nd is not None: dout = nd
        if tot:
            cl = collections.Counter(lapd)
            print(f"event {e} [{model}]: validOut beats={tot} mismatch={mism} "
                  f"lap distance (pushes ago) = {dict(sorted(cl.items())[:6])}")
    r0 = [r for r in rows if r[C['pe']]]
    if r0:
        r = r0[0]
        print(f"   popEmpty at sidx={r[C['sidx']]} tref={r[C['tr']]} occ={r[C['occ']]} "
              f"wr={r[C['wr']]} rd={r[C['rd']]}")
    occs = collections.Counter(r[C['occ']] for r in rows)
    ptrd = collections.Counter((r[C['wr']] - r[C['rd']]) % 32 for r in rows)
    print(f"   occupancy histogram in window: {dict(sorted(occs.items()))}")
    print(f"   (wr-rd) mod 32 histogram:     {dict(sorted(ptrd.items()))}")
