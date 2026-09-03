#!/usr/bin/env python3
"""Analyze a stage_poll CSV: detect 119.75s beat bursts (via bit_errors_out
delta rate) and localize the corruption stage.

Two independent localizers:
 (A) COUNTER rate-conservation (alias-immune): per-second delta of the
     non-saturating stage counters (cnt_frame_start/cnt_vit_reset/cnt_bist_start)
     baseline vs in-burst. First chain-order stage whose rate deviates = injection.
 (B) CAP checksum bisection: cap_in -> cap_deint -> cap_out are windowed
     checksums at FEC input / deinterleaver / decoder output. Under the repeating
     ROM source each is a constant golden between bursts (cap_out golden=0x04922282).
     First cap to leave its golden during a burst names the stage.
"""
import sys, csv, statistics

MASK = 0xFFFFFFFF
SAT  = 0xFFFFFFFF

def d32(a, b):
    return (b - a) & MASK

def load(path):
    rows = []
    with open(path) as f:
        r = csv.DictReader(f)
        for row in r:
            try:
                t = int(row['t_ms'])
            except (KeyError, ValueError):
                continue
            rec = {'t_ms': t}
            for k, v in row.items():
                if k == 't_ms':
                    continue
                try:
                    rec[k] = int(v, 16)
                except (ValueError, TypeError):
                    rec[k] = None
            rows.append(rec)
    return rows

def main():
    path = sys.argv[1]
    rows = load(path)
    if len(rows) < 5:
        print("STAGEPOLL_ANALYZE: too few samples (%d)" % len(rows)); return
    dur_s = (rows[-1]['t_ms'] - rows[0]['t_ms']) / 1000.0
    print("samples=%d span=%.1fs rate=%.1f Hz" % (len(rows), dur_s, len(rows)/max(dur_s,1e-9)))

    # burst detection: aggregate bit_errors_out (0x108) into 1-second buckets
    # (per-100ms-sample deltas are too noisy; 1s buckets give a clean floor).
    be = 'bit_errors_out'
    sec = {}
    for r in rows:
        if r.get(be) is None: continue
        sec.setdefault(r['t_ms'] // 1000, []).append(r[be])
    secs = sorted(sec)
    rate = {}
    prev = None
    for s in secs:
        v = sec[s][-1]
        if prev is not None:
            rate[s] = d32(prev, v)   # errors in this 1s window
        prev = v
    rlist = [rate[s] for s in sorted(rate)]
    floor = statistics.median(rlist) if rlist else 0.0
    THRESH = max(500.0, floor * 5)
    print("err/s floor(median)=%.0f  max=%.0f  burst threshold=%.0f/s"
          % (floor, max(rlist) if rlist else 0, THRESH))

    bursts = []  # (start_ms, end_ms, size_errors)
    inb = False; st = None; sm = 0; last = None
    for s in sorted(rate):
        if rate[s] > THRESH:
            if not inb: st = s; sm = 0; inb = True
            sm += rate[s]; last = s
        elif inb:
            bursts.append((st*1000, last*1000, sm)); inb = False
    if inb:
        bursts.append((st*1000, last*1000, sm))
    # report as (start,end,peak-compat) triples; peak slot carries size
    print("BURSTS detected: %d" % len(bursts))
    for (s, e, sz) in bursts:
        print("  burst t=%.0f..%.0fs dur=%.0fs size=%d errors"
              % (s/1000.0, e/1000.0, (e-s)/1000.0 + 1, sz))
    THRESH = THRESH  # kept for downstream windows below

    # index helper
    def sample_at(tms):
        best = min(rows, key=lambda x: abs(x['t_ms'] - tms))
        return best

    # baseline window = first 5s that is quiet
    def in_any_burst(tms):
        return any(s <= tms <= e for (s, e, _) in bursts)

    CAPS = ['cap_in', 'cap_deint', 'cap_out', 'cap_cad']
    print("\n-- CAP golden (mode over all quiet, non-burst samples) --")
    base_cap = {}
    for c in CAPS:
        allq = [r[c] for r in rows if r.get(c) is not None and not in_any_burst(r['t_ms'])]
        golden = max(set(allq), key=allq.count) if allq else None
        base_cap[c] = golden
        print("   %-9s golden=0x%08X" % (c, golden) if golden is not None else "   %-9s golden=None" % c)

    # CAP divergence inside bursts
    print("\n-- CAP divergence during bursts (stage bisection) --")
    for (s, e, pk) in bursts:
        seen = {c: set() for c in CAPS}
        for r in rows:
            if s <= r['t_ms'] <= e:
                for c in CAPS:
                    if r.get(c) is not None:
                        seen[c].add(r[c])
        print("  burst @%.0fs:" % (s/1000.0))
        for c in CAPS:
            g = base_cap[c]
            dev = sorted(v for v in seen[c] if v != g)
            if dev:
                print("     %-9s DIVERGES: %s (golden 0x%08X)"
                      % (c, ", ".join("0x%08X" % v for v in dev[:6]), g if g is not None else 0))
            else:
                print("     %-9s stays golden" % c)

    # COUNTER rate-conservation (non-saturating counters only)
    CNT = ['count_out','packets_out','cnt_frame_start','cnt_vit_reset',
           'cnt_bist_start','cnt_descr_in','cnt_deint_valid','cnt_dec_bits']
    print("\n-- COUNTER rate-conservation (delta/s baseline vs in-burst) --")
    def window_rate(name, t0, t1):
        seg = [r for r in rows if t0 <= r['t_ms'] <= t1 and r.get(name) is not None]
        if len(seg) < 2: return None
        if seg[0][name] == SAT or seg[-1][name] == SAT: return 'SAT'
        dt = (seg[-1]['t_ms'] - seg[0]['t_ms'])/1000.0
        if dt <= 0: return None
        return d32(seg[0][name], seg[-1][name]) / dt
    # baseline = first quiet 20s
    bt0, bt1 = rows[0]['t_ms'], rows[0]['t_ms']+20000
    for name in CNT:
        br = window_rate(name, bt0, bt1)
        parts = []
        for (s,e,pk) in bursts:
            wr = window_rate(name, s, e)
            parts.append("burst@%.0fs=%s" % (s/1000.0, ("SAT" if wr=='SAT' else ("%.0f/s"%wr) if isinstance(wr,float) else "?")))
        bstr = ("SAT" if br=='SAT' else ("%.0f/s"%br) if isinstance(br,float) else "?")
        print("   %-16s baseline=%-9s %s" % (name, bstr, "  ".join(parts)))

    print("\nSTAGEPOLL_ANALYZE_DONE")

if __name__ == '__main__':
    main()
