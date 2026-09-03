#!/usr/bin/env python3
"""Four-part capture-path positive control at the LARGE operating point.

A new gate, not a revision of ddrcap_pc.py: 134 MB is a different operating
point and inherits nothing from the 1 MB result, and the tuple-based loader in
the original would not survive 16.7 M beats. Same four parts, numpy-backed.

Parts (identical in intent to ddrcap_pc.py):
  1 LIVENESS   not constant, and not a counter (the T1 ADC-ramp trap: ~all
               consecutive deltas equal is a ramp even when it WRAPS)
  2 SELECTOR   two different 0x10C values give different buffers
  3 CROSS-CHECK hard decisions reproduce DBGCAP's golden 0xBCF94856, allowing
               the §36 one-beat skew and the dataOutReg-zeroed first symbol
  4 MARKERS    demod-marker spacing matches a domain rate

Usage: ddrcap_pc_large.py <sel6.bin> <other.bin> [expected_spacing]
"""
import collections, sys
import numpy as np

GOLD = 0xBCF94856
MARK = 0x7FFF

def load(p):
    a = np.fromfile(p, dtype='<i2')
    a = a[: (len(a) // 4) * 4].reshape(-1, 4)
    return a

def p1(a):
    I = a[:, 0]
    if np.all(I == I[0]):
        return False, "constant"
    d = np.diff(I[:200000].astype(np.int32))
    vals, cnts = np.unique(d, return_counts=True)
    frac = cnts.max() / len(d)
    if frac >= 0.95:
        return False, f"ramp: {100*frac:.1f} % of deltas are {vals[cnts.argmax()]:+d} -- a counter, not our signal"
    return True, f"{len(np.unique(I[:200000]))} distinct I in 200k beats, delta spread {len(vals)}"

def p2(a, b):
    n = min(len(a), len(b), 200000)
    diff = int(np.count_nonzero(a[:n, 0] != b[:n, 0]))
    if diff == 0:
        return False, "two selectors produced identical buffers -- selector does nothing"
    return True, f"{diff}/{n} words differ between selectors"

def p3(a):
    m = np.flatnonzero(a[:, 2] == MARK)
    if len(m) < 2:
        return False, f"only {len(m)} demod markers"
    for mk in m[:8]:
        for off in (0, 1, 2):
            s = mk + off
            if s + 16 > len(a):
                continue
            I = a[s:s+16, 0]; Q = a[s:s+16, 1]
            sym = ((I < 0).astype(np.uint32) << 1) | (Q < 0).astype(np.uint32)
            w = 0
            for k in range(16):
                w |= int(sym[k]) << (30 - 2*k)
            if w == GOLD:
                return True, f"exact digest match at marker+{off} (all 16 symbols)"
            if (w & 0x3FFFFFFF) == (GOLD & 0x3FFFFFFF):
                return True, f"digest matches at marker+{off} on symbols 1-15 (dataOutReg-zeroed case, §36)"
    return False, f"no offset 0..2 at any of {min(8,len(m))} markers reproduces 0x{GOLD:08X}"

def p4(a, exp=None):
    m = np.flatnonzero(a[:, 2] == MARK)
    if len(m) < 3:
        return False, f"only {len(m)} demod markers"
    g = np.diff(m)
    vals, cnts = np.unique(g, return_counts=True)
    mode = int(vals[cnts.argmax()]); n = int(cnts.max())
    dom = {49349: 'sample', 12337: 'symbol', 12320: 'symbol', 1542: 'bit-word'}
    near = min(dom, key=lambda k: abs(k - mode))
    ok = abs(mode - near) / near < 0.02 and n >= 0.9 * len(g)
    msg = f"modal spacing {mode} ({n}/{len(g)} intervals) -> {dom[near]} domain"
    if exp:
        ok = ok and abs(mode - int(exp)) / int(exp) < 0.02
        msg += f"; expected {exp}"
    return ok, msg

if __name__ == '__main__':
    a = load(sys.argv[1]); b = load(sys.argv[2]) if len(sys.argv) > 2 else None
    exp = sys.argv[3] if len(sys.argv) > 3 else None
    print(f"buffer1 {len(a):,} beats" + (f"; buffer2 {len(b):,} beats" if b is not None else ""))
    res = [("1 LIVENESS", p1(a))]
    if b is not None:
        res.append(("2 SELECTOR", p2(a, b)))
    res += [("3 CROSS-CHECK", p3(a)), ("4 MARKERS", p4(a, exp))]
    bad = 0
    for nm, (ok, msg) in res:
        print(f"  [{'PASS' if ok else 'FAIL'}] {nm:14s} {msg}")
        bad += 0 if ok else 1
    print(f"\nDDRCAP_PC_LARGE {'ALL PASS -- large captures may be interpreted' if not bad else f'{bad} FAILED -- WITNESS-DEAD at this size'}")
    sys.exit(1 if bad else 0)
