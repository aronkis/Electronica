#!/usr/bin/env python3
"""txlog_gaps.py <rep.txlog> [frame_us=803]

Analyze a QPSK_TXLOG ring dump (16-byte records: u64 t_mono_ns, u32 slot,
u16 inflight_before, u16 spins). Answers ONE question for the TX zero-fill /
wedge work: did the FEEDER's submit cadence break (gaps > frame period), and
if so with what periodicity -- or was the feed clean while the RX side saw
zeros/junk (=> fabric-side underrun)?

Gaps are measured submit-to-submit. A gap of G frame-periods means the air
had ~G-1 slots with no fresh frame IF the fabric drains one frame per period
and had <= max_inflight queued. inflight_before==0 at the submit AFTER a gap
means the fabric had fully drained -- underrun certain, not just possible.
"""
import struct, sys, statistics as st

REC = struct.Struct("<QIHH")

def main():
    path = sys.argv[1]
    frame_us = float(sys.argv[2]) if len(sys.argv) > 2 else 803.0
    raw = open(path, "rb").read()
    n = len(raw) // REC.size
    recs = [REC.unpack_from(raw, i * REC.size) for i in range(n)]
    if n < 2:
        print(f"{path}: only {n} records"); return
    t0 = recs[0][0]
    dur_s = (recs[-1][0] - t0) / 1e9
    print(f"{path}: {n} submits over {dur_s:.1f}s "
          f"({n/dur_s:.0f}/s vs air {1e6/frame_us:.0f}/s)")
    gaps = []
    for i in range(1, n):
        g_us = (recs[i][0] - recs[i-1][0]) / 1e3
        if g_us > 1.5 * frame_us:
            gaps.append((i, (recs[i-1][0]-t0)/1e9, g_us, recs[i][2], recs[i][3]))
    print(f"  gaps >1.5 frames: {len(gaps)}")
    for i, t_s, g_us, infl, spins in gaps[:40]:
        print(f"    t={t_s:8.3f}s gap={g_us/frame_us:6.1f} frames ({g_us/1000:7.2f} ms) "
              f"inflight_after={infl} spins={spins}")
    if len(gaps) > 40:
        print(f"    ... {len(gaps)-40} more")
    if len(gaps) >= 3:
        starts = [g[1] for g in gaps]
        deltas = [(b - a) for a, b in zip(starts, starts[1:])]
        print(f"  gap-to-gap spacing (s): min {min(deltas):.3f} "
              f"median {st.median(deltas):.3f} max {max(deltas):.3f}")
        fp = frame_us / 1e6
        frames = [d / fp for d in deltas]
        print(f"  spacing in frames: {['%.1f' % f for f in frames[:20]]}")
    # spin pressure: how often the feeder had to wait on tx_capacity at all
    spun = sum(1 for r in recs if r[3] > 0)
    print(f"  submits that spun for capacity: {spun}/{n} "
          f"max_spins={max(r[3] for r in recs)}")

if __name__ == "__main__":
    main()
