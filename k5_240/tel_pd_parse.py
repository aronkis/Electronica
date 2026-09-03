#!/usr/bin/env python3
"""tel_pd_parse.py -- parse the P1C/P1D Preamble-Detector telemetry stream.

Two formats, auto-detected by S0 tag:
  0xD = P1C: 8-word snapshot/symbol; S1=corr; S7={0xA5,symCtr24}; flags
        instantaneous (pulses alias to 0 at the strobe beat).
  0xE = P1D: 7-word snapshot/symbol (loss-free: >=1 idle beat slack, idle
        emits 0x00000000); S1={dI,dQ}; S6={0xA5,beat3,symCtr21}; the
        done/newPk/thrEx/sync/vPop flags are STICKY over the symbol.

Usage:
  tel_pd_parse.py records <tap.iq> <out.npz>     all symbol records
  tel_pd_parse.py drive   <tap.iq> <out.txt> <sym0> <nsym>
      emit dataIn I/Q per symbol for the PD netlist mirror
"""
import sys, struct
import numpy as np

def words_of(path):
    d = open(path, 'rb').read()
    n = len(d) // 4
    v = np.frombuffer(d[:4*n], dtype='<i2').astype(np.int64)
    return ((v[0::2] & 0xFFFF) << 16) | (v[1::2] & 0xFFFF)

def parse(path):
    w = words_of(path).astype(np.uint64)
    tag = (w >> np.uint64(28)) & np.uint64(0xF)
    nD = int((tag == 0xD).sum()); nE = int((tag == 0xE).sum())
    v2 = nE > nD
    t0 = 0xE if v2 else 0xD
    nslots = 7 if v2 else 8
    starts = np.where(tag == t0)[0]
    recs = []
    for i, s in enumerate(starts):
        end = starts[i+1] if i+1 < len(starts) else len(w)
        r = w[s:min(s+nslots, end)]
        if len(r) < nslots - 1:
            continue
        s0 = int(r[0])
        rec = dict(
            tRef=(s0 >> 17) & 0x7FF, tOff=(s0 >> 6) & 0x7FF,
            done=s0 & 1, newPk=(s0 >> 1) & 1, succ=(s0 >> 2) & 1,
            thrEx=(s0 >> 3) & 1, sync=(s0 >> 4) & 1, armed=(s0 >> 5) & 1,
            streamword=int(s))
        if v2:
            rec.update(
                dI=np.int16((int(r[1]) >> 16) & 0xFFFF), dQ=np.int16(int(r[1]) & 0xFFFF),
                taRef=(int(r[2]) >> 21) & 0x7FF, accOff=(int(r[2]) >> 10) & 0x7FF,
                fifoEnt=(int(r[2]) >> 1) & 0x1FF, vPop=int(r[2]) & 1,
                tRefLong=int(r[3]), runMax=int(r[4]),
                heldTs=int(r[5]) if len(r) > 5 else 0,
                corr=0)
            if len(r) > 6 and ((int(r[6]) >> 24) & 0xFF) == 0xA5:
                rec['beat'] = (int(r[6]) >> 21) & 0x7
                rec['symCtr'] = int(r[6]) & 0x1FFFFF
            else:
                rec['beat'] = -1; rec['symCtr'] = -1
        else:
            rec.update(
                corr=int(r[1]),
                taRef=(int(r[2]) >> 21) & 0x7FF, accOff=(int(r[2]) >> 10) & 0x7FF,
                fifoEnt=(int(r[2]) >> 1) & 0x1FF, vPop=int(r[2]) & 1,
                dI=np.int16((int(r[3]) >> 16) & 0xFFFF), dQ=np.int16(int(r[3]) & 0xFFFF),
                tRefLong=int(r[4]),
                runMax=int(r[5]) if len(r) > 5 else 0,
                heldTs=int(r[6]) if len(r) > 6 else 0,
                beat=-1,
                symCtr=(int(r[7]) & 0xFFFFFF) if len(r) > 7 and ((int(r[7]) >> 24) & 0xFF) == 0xA5 else -1)
        recs.append(rec)
    # reconstruct clipped symbol counters by increment
    wrap = 0x200000 if v2 else 0x1000000
    last = -1
    for rec in recs:
        if rec['symCtr'] < 0 and last >= 0:
            rec['symCtr'] = (last + 1) % wrap
        last = rec['symCtr']
    sys.stderr.write(f'format={"P1D/0xE" if v2 else "P1C/0xD"} ({nslots} slots)\n')
    return recs

def main():
    mode, path = sys.argv[1], sys.argv[2]
    recs = parse(path)
    sys.stderr.write(f'{len(recs)} symbol records\n')
    if mode == 'records':
        keys = list(recs[0].keys())
        arrs = {k: np.array([r[k] for r in recs]) for k in keys}
        np.savez(sys.argv[3], **arrs)
        sys.stderr.write(f'saved -> {sys.argv[3]}\n')
    elif mode == 'drive':
        out, sym0, nsym = sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
        with open(out, 'w') as f:
            for r in recs:
                if sym0 <= r['symCtr'] < sym0 + nsym:
                    f.write(f"{int(r['dI'])} {int(r['dQ'])}\n")
        sys.stderr.write(f'drive file -> {out}\n')

if __name__ == '__main__':
    main()
