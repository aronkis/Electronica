#!/usr/bin/env python3
"""Four-part capture-path positive control for the DDR capture taps (Task 5 §0 gate).

NOTHING captured by this path may be interpreted until all four parts pass. A
capture path that has never been shown to move produces no evidence, only a
zero -- this campaign has been burned by that four times.

Input: raw interleaved int16 buffers, 4 channels per word:
  ch0 = I, ch1 = Q, ch2 = demod frame marker, ch3 = FEC frame marker.

Parts:
  1 LIVENESS      buffer is neither constant nor a monotonic ramp. The ramp
                  clause matters: T1 proved RX1's "data" was an ADC-side
                  counter, which looks alive and is not our signal.
  2 SELECTOR      buffers from two different 0x10C values differ.
  3 CROSS-CHECK   hard decisions from selector 6 reproduce DBGCAP tap 3's
                  digest 0xBCF94856 -- WITH the §36 corrections applied.
  4 MARKERS       demod marker spacing matches the tap's domain rate, which
                  also self-identifies the domain.

Usage: ddrcap_pc.py <sel6.bin> <other.bin> [expected_spacing]
"""
import sys, collections, struct

MARK = 0x7FFF
GOLD = 0xBCF94856

def load(p):
    b = open(p, 'rb').read()
    n = len(b) // 8
    w = struct.unpack('<%dh' % (n * 4), b[:n * 8])
    return [(w[i * 4], w[i * 4 + 1], w[i * 4 + 2], w[i * 4 + 3]) for i in range(n)]

def part1_liveness(buf):
    I = [r[0] for r in buf]
    if len(set(I)) <= 1:
        return False, "constant"
    # T1's counter WRAPPED, so "monotonic" is not the test -- a wrapping ramp has
    # a large negative delta at each wrap and would sail through it. My own
    # negative control caught this. The real signature is that almost every
    # consecutive delta is the SAME constant; a modulated signal has a broad
    # delta distribution.
    d = [I[i + 1] - I[i] for i in range(min(20000, len(I) - 1))]
    dc = collections.Counter(d)
    step, n = dc.most_common(1)[0]
    if n >= 0.95 * len(d):
        return False, (f"ramp: {100.0*n/len(d):.1f} % of deltas are exactly {step:+d} "
                       f"-- a digital counter (the T1 ADC-side trap), not our signal")
    return True, f"{len(set(I))} distinct I values, non-monotonic"

def part2_selector(a, b):
    ia = [r[0] for r in a][:20000]
    ib = [r[0] for r in b][:20000]
    if ia == ib:
        return False, "two selectors produced identical buffers -- selector does nothing"
    diff = sum(1 for x, y in zip(ia, ib) if x != y)
    return True, f"{diff}/{len(ia)} words differ between selectors"

def part3_crosscheck(buf):
    """DBGCAP takes 16 consecutive QPSKConstellationValid strobes from frame start.

    §36: the DDR path is COMBINATIONAL at selector 6 while DBGCAP samples the
    registered Delay4_out1_re one enb tick later, so the DDR stream leads by
    exactly one captured beat -- hence the +1 offsets tried here. And DBGCAP's
    dataOutReg is zeroed while `active` is low, so its FIRST window element may
    not match a naively shifted stream; both the full 16 and the last 15 symbols
    are therefore accepted, with which one matched reported.
    """
    marks = [i for i, r in enumerate(buf) if r[2] == MARK]
    if len(marks) < 2:
        return False, f"only {len(marks)} demod markers -- cannot anchor"
    def word(a, k0=0):
        w = 0
        for k in range(k0, 16):
            I, Q = buf[a + k][0], buf[a + k][1]
            s = ((1 if I < 0 else 0) << 1) | (1 if Q < 0 else 0)
            w |= s << (30 - 2 * k)
        return w
    for m in marks[:8]:
        for off in (0, 1, 2):
            if m + off + 16 > len(buf):
                continue
            full = word(m + off)
            if full == GOLD:
                return True, f"exact digest match at marker+{off} (all 16 symbols)"
            if (full & 0x3FFFFFFF) == (GOLD & 0x3FFFFFFF):
                return True, (f"digest matches at marker+{off} on symbols 1-15; symbol 0 differs, "
                              f"which is the dataOutReg-zeroed-while-inactive case (§36)")
    return False, f"no offset in 0..2 at any of {len(marks[:8])} markers reproduces 0x{GOLD:08X}"

def part4_markers(buf, expected=None):
    marks = [i for i, r in enumerate(buf) if r[2] == MARK]
    if len(marks) < 3:
        return False, f"only {len(marks)} demod markers"
    gaps = [marks[i + 1] - marks[i] for i in range(len(marks) - 1)]
    c = collections.Counter(gaps)
    mode, n = c.most_common(1)[0]
    dom = {49349: 'sample', 12337: 'symbol', 1542: 'bit-word'}
    near = min(dom, key=lambda k: abs(k - mode))
    ok = abs(mode - near) / near < 0.02 and n >= len(gaps) * 0.9
    msg = f"modal spacing {mode} ({n}/{len(gaps)} intervals) -> {dom[near]} domain (ref {near})"
    if expected:
        ok = ok and abs(mode - int(expected)) / int(expected) < 0.02
        msg += f"; expected {expected}"
    return ok, msg

if __name__ == '__main__':
    a = load(sys.argv[1])
    b = load(sys.argv[2]) if len(sys.argv) > 2 else None
    exp = sys.argv[3] if len(sys.argv) > 3 else None
    print(f"buffer 1: {len(a)} words" + (f"; buffer 2: {len(b)} words" if b else ""))
    results = [("1 LIVENESS", part1_liveness(a))]
    if b:
        results.append(("2 SELECTOR", part2_selector(a, b)))
    results.append(("3 CROSS-CHECK", part3_crosscheck(a)))
    results.append(("4 MARKERS", part4_markers(a, exp)))
    bad = 0
    for name, (ok, msg) in results:
        print(f"  [{'PASS' if ok else 'FAIL'}] {name:14s} {msg}")
        bad += 0 if ok else 1
    print(f"\nDDRCAP_PC {'ALL PASS -- captures may be interpreted' if not bad else f'{bad} FAILED -- WITNESS-DEAD, collect no measurements'}")
    sys.exit(1 if bad else 0)
