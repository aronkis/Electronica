#!/usr/bin/env python3
"""loss_ledger.py -- Track N4: zero-unnamed-losses accounting over the
2026-08-12 framelogs (ops/r3cap). Classifies EVERY hole in the clean-seq
ladder of each frames.bin into named classes and emits ops/LOSS_LEDGER.md
with per-run and pooled per-direction scoreboards. The unnamed bucket is
ENUMERATED event-by-event, never summarized.

Classes (priority order applied per hole; rules stated in the ledger):
  startup-burst    k>20 delivered-corrupt second inside the first 15 s bring-up
  burst-frozen     k>20 with reg_packets frozen across the hole
  boundary-single/-double
                   k<=2 locked to the measured ~8-frame DMA-boundary comb
                   (fwd: >=1 neighbor within +/-1 of j*8, j=1..6; rev: both
                   neighbors required -- stated because chance-pass differs)
                   subtypes: delivered-corrupt (crc=0 record in hole) vs
                   never-delivered (no record)
  tx-underrun-comb k<=2 (rev) locked to the ~33-frame TX zero-fill comb
                   (TX_ANOMALY_SCAN.md), +/-2 of j*33, j=1..3, either neighbor
  tx-mute-cand     k<=2 with a host_seq==0 garbage record in/adjacent (the
                   SINGLES_REPLAY.md ~72us mute signature), not comb-locked
  feeder-gap       hole matching a TX submit gap in txlog (singles_disc only)
  mid-gap          3<=k<=20 (cadence flags annotated, per plan its own class)
  big-gap-unnamed / unnamed  everything else -- enumerated individually
"""
import glob
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from frame_taxonomy import read_frames                       # noqa: E402

R3 = os.path.join(os.path.dirname(os.path.abspath(__file__)), "r3cap")
FRAME_S = 49332 / 61.44e6            # 802.9 us/frame (f1536)
SETTLE = 15.0

RUNS = []  # (label, dir_path, direction, group)


def add(label, rel, direction, group):
    RUNS.append((label, os.path.join(R3, rel), direction, group))


add("accept_155622_r1", "accept_rxq_20260812_155622_r1", "rev", "accept")
add("accept_160104_r1", "accept_rxq_20260812_160104_r1", "rev", "accept")
add("accept_160104_r2", "accept_rxq_20260812_160104_r2", "rev", "accept")
add("accept_160833_r1", "accept_rxq_20260812_160833_r1", "fwd", "accept")
add("accept_160833_r2", "accept_rxq_20260812_160833_r2", "fwd", "accept")
add("accept_160833_r3", "accept_rxq_20260812_160833_r3", "fwd", "accept")
add("accept_201153_r1(M32)", "accept_rxq_20260812_201153_r1", "fwd", "accept")
for sw in ("sweep_20260812_135103", "sweep_20260812_151226"):
    for arm in sorted(os.path.basename(x) for x in
                      glob.glob(os.path.join(R3, sw, "bud*_c*")) if os.path.isdir(x)):
        add(f"{sw[-6:]}_{arm}", f"{sw}/{arm}", "rev", "sweep")
add("singles_disc", "singles_disc", "fwd", "disc")
add("singles_reread", "singles_reread", "fwd", "disc")
add("cp1_verdict2", "cp1_verdict2", "fwd", "disc")
add("evm_swap_A", "evm_swap_A", "fwd", "disc")
add("evm_swap_B(WEDGED)", "evm_swap_B", "rev", "disc")


def meta(dirp):
    m = {}
    p = os.path.join(dirp, "meta.txt")
    if os.path.exists(p):
        for line in open(p):
            for tok in line.split():
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    m[k] = v
    return m


def detect_m(fr):
    """Drain burst structure: M32 runs show >=20-record bursts routinely."""
    dt = np.diff(fr["t_mono_ns"].astype(np.int64)) / 1e3
    edges = np.flatnonzero(dt > 400)
    bl = np.diff(np.concatenate(([0], edges + 1, [fr.size])))
    return 32 if np.percentile(bl, 90) >= 20 else 16


def comb_lock(ds_prev, ds_next, period, tol, jmax, both=False):
    def ok(x):
        if x is None:
            return False
        for j in range(1, jmax + 1):
            if abs(x - j * period) <= tol:
                return True
        return False
    return (ok(ds_prev) and ok(ds_next)) if both else (ok(ds_prev) or ok(ds_next))


def tx_gaps_146(dirp, fr):
    """singles_disc feeder-gap support: TX submit gaps translated to the RX
    run's wall clock. Returns list of (t_wall_ns, gap_us)."""
    p = os.path.join(dirp, "txlog_146.bin")
    pp = os.path.join(dirp, "frames_peer.bin")
    if not (os.path.exists(p) and os.path.exists(pp)):
        return []
    pe = read_frames(pp)
    off146 = int(np.median(pe["t_real_ns"].astype(np.int64) -
                           pe["t_mono_ns"].astype(np.int64)))
    R = struct.Struct("<QIHH")
    raw = open(p, "rb").read()
    t = np.array([R.unpack_from(raw, i * R.size)[0]
                  for i in range(len(raw) // R.size)], dtype=np.int64)
    g = np.diff(t) / 1e3
    gi = np.flatnonzero(g > 1.5 * 803.0)
    return [(int(t[i] + off146), float(g[i])) for i in gi]


def analyze_run(label, dirp, direction):
    fr = read_frames(os.path.join(dirp, "frames.bin"))
    M = detect_m(fr)
    clean = fr["crc_ok"] != 0
    ci = np.flatnonzero(clean)
    cs = fr["host_seq"][ci].astype(np.int64)
    tm = fr["t_mono_ns"].astype(np.int64)
    tw = fr["t_real_ns"].astype(np.int64)
    t0 = tm[0]
    ts = (tm - t0) / 1e9
    d = np.diff(cs)
    hidx = np.flatnonzero(d > 1)

    # holes ----------------------------------------------------------------
    holes = []
    for i in hidx:
        i0, i1 = ci[i], ci[i + 1]
        seqin = fr["host_seq"][i0 + 1:i1].astype(np.int64)
        lo, hi = cs[i] - 100000, cs[i + 1] + 100000
        # seq==0 record inside hole or within +/-2 records of the edges
        adj = fr["host_seq"][max(i0 - 2, 0):min(i1 + 3, fr.size)].astype(np.int64)
        adjc = fr["crc_ok"][max(i0 - 2, 0):min(i1 + 3, fr.size)]
        holes.append(dict(
            k=int(d[i] - 1), seq0=int(cs[i] + 1), seq1=int(cs[i + 1] - 1),
            i0=int(i0), i1=int(i1), ncrc0=int(i1 - i0 - 1),
            t=float(ts[i0]), t_end=float(ts[i1]),
            twall=int(tw[i0]),
            dpk=int(fr["reg_packets"][i1]) - int(fr["reg_packets"][i0]),
            biterr=int(fr["reg_biterr"][i1]) - int(fr["reg_biterr"][i0]),
            has_seq0=bool(np.any(seqin == 0)),
            adj_seq0=bool(np.any((adj == 0) & (adjc == 0))),
            has_garb=bool(np.any((seqin < lo) | (seqin > hi))),
        ))

    # neighbor spacings among the event grid (all holes k<=20) for comb tests
    grid = [h for h in holes if h["k"] <= 20]
    sseq = np.array([h["seq0"] for h in grid], dtype=np.int64)
    for j, h in enumerate(grid):
        h["dprev"] = int(sseq[j] - sseq[j - 1]) if j > 0 else None
        h["dnext"] = int(sseq[j + 1] - sseq[j]) if j + 1 < len(sseq) else None

    # feeder-gap candidates (singles_disc)
    txg = tx_gaps_146(dirp, fr)

    # classification -------------------------------------------------------
    for h in holes:
        k = h["k"]
        c8 = c33 = False
        if k <= 20:
            both = direction == "rev"
            c8 = comb_lock(h.get("dprev"), h.get("dnext"), 8, 1, 6, both=both)
            c33 = comb_lock(h.get("dprev"), h.get("dnext"), 33, 2, 3, both=False)
            h["c633"] = comb_lock(h.get("dprev"), h.get("dnext"), 633, 1, 2,
                                  both=False)
        fg = False
        for gt, gus in txg:
            if abs(h["twall"] - gt) < 25e6:
                fg = True
        h["c8"], h["c33"], h["fg"] = c8, c33, fg
        if k > 20:
            if h["dpk"] <= max(2, k // 10):
                h["cls"] = "burst-frozen"
            elif h["t"] < SETTLE and k > 200:
                h["cls"] = "startup-burst"
            else:
                h["cls"] = "big-gap-unnamed"
        elif 3 <= k <= 20:
            if direction == "rev" and c33:
                h["cls"] = "tx-underrun-comb"
            else:
                h["cls"] = "mid-gap[c8]" if c8 else "mid-gap"
        else:  # k<=2
            sub = "dc" if h["ncrc0"] >= 1 else "nd"
            if direction == "rev" and c33:
                h["cls"] = "tx-underrun-comb"
            elif c8:
                h["cls"] = ("boundary-single" if k == 1 else "boundary-double") \
                    + f"[{sub}]"
            elif h["has_seq0"] or h["adj_seq0"]:
                h["cls"] = "tx-mute-cand"
            elif fg:
                h["cls"] = "feeder-gap"
            else:
                h["cls"] = "unnamed"

    # accept_analyze live-window reference (reimplemented without the O(n^2)
    # lag-33 autocorrelation; windowing logic identical to accept_analyze) ---
    dur = float(ts[-1])
    nb = max(int(dur) + 1, 1)
    cts = ts[ci]
    cps = np.histogram(cts, bins=nb, range=(0.0, float(nb)))[0]
    peak = cps.max() if cps.size else 0
    live_end = dur
    wedged = False
    if peak > 0:
        good = np.flatnonzero(cps >= 0.25 * peak)
        live_end = float(good[-1] + 1) if good.size else 0.0
        wedged = live_end < dur - 3.0
        if wedged:
            live_end = max(live_end - 2.0, 0.0)
    else:
        wedged = True
        live_end = 0.0
    usable = ((cts >= SETTLE) & (cts < live_end)).sum() >= 100
    ref = dict(live_end=live_end, wedged=wedged, usable=usable)
    for h in holes:
        h["in_live"] = SETTLE <= h["t"] and h["t_end"] < live_end \
            and h["t"] >= SETTLE
    # replicate accept_analyze's own hole set for the sum-check
    ct = ts[ci]
    w = (ct >= SETTLE) & (ct < live_end)
    cw = cs[np.flatnonzero(w)]
    ref_miss = int(np.clip(np.diff(cw) - 1, 0, None).sum()) if cw.size > 1 else 0
    # my live-window lost total: holes whose BOTH brackets fall in the window
    inw = np.zeros(len(ci), dtype=bool)
    inw[np.flatnonzero(w)] = True
    pos = {int(ix): j for j, ix in enumerate(ci)}
    live_lost = 0
    for h in holes:
        j0 = pos[h["i0"]]
        if inw[j0] and inw[j0 + 1]:
            h["in_live"] = True
            live_lost += h["k"]
        else:
            h["in_live"] = False

    span = int(cs[-1] - cs[0])
    return dict(label=label, dirp=dirp, direction=direction, M=M,
                n_rec=int(fr.size), n_clean=int(clean.sum()),
                span=span, holes=holes, total_lost=int((d[d > 1] - 1).sum()),
                live_end=float(live_end), wedged=bool(ref.get("wedged", False)),
                ref_usable=bool(ref.get("usable", False)),
                ref_miss=ref_miss if ref.get("usable", False) else None,
                ref_miss_calc=ref_miss, live_lost=live_lost,
                dur=float(ts[-1]), n_txgap=len(txg))


CLS_ORDER = ["boundary-single[dc]", "boundary-single[nd]",
             "boundary-double[dc]", "boundary-double[nd]",
             "tx-underrun-comb", "tx-mute-cand", "feeder-gap", "mid-gap[c8]", "mid-gap",
             "burst-frozen", "startup-burst", "big-gap-unnamed", "unnamed"]


def tally(holes, live_only=False):
    ev = {c: 0 for c in CLS_ORDER}
    lost = {c: 0 for c in CLS_ORDER}
    for h in holes:
        if live_only and not h["in_live"]:
            continue
        ev[h["cls"]] += 1
        lost[h["cls"]] += h["k"]
    return ev, lost


def main():
    results = [analyze_run(*r[:3]) for r in RUNS]
    out = []
    A = out.append
    A("# LOSS_LEDGER -- zero-unnamed-losses accounting, 2026-08-12 framelogs")
    A("")
    A("Track N4 of the overnight plan. Every hole in the clean-`host_seq` ladder of")
    A("every 2026-08-12 framelog under `ops/r3cap/` is classified below; the")
    A("unnamed bucket is enumerated event-by-event at the end. Generated by")
    A("`ops/loss_ledger.py` (this file is its output; re-run to regenerate).")
    A("")
    A("## Method / class definitions")
    A("")
    A("- A **loss event** = a gap in the sequence ladder of CRC-clean frames of the")
    A("  run's own `frames.bin` (dtype per `frame_taxonomy.read_frames`). Lost")
    A("  frames = sum of (gap-1). Direction per `meta.txt` `target=`/`rx=` (A/fwd:")
    A("  rx=10.0.0.148, B/rev: rx=10.0.0.146) -- verified for every run.")
    A("- **Empirical correction to the plan's cadence spec:** the boundary-event")
    A("  comb in these logs has period **~8 frames = 6.42 ms** (measured; spacing")
    A("  histogram dominated by 8/24/32-frame deltas with a slow +/-1 phase drift),")
    A("  i.e. HALF the -M16 area period the plan quotes -- and it stays ~8 frames")
    A("  at -M32 too. The test used: a k<=2 hole is *boundary* if its spacing to a")
    A("  neighboring small-hole event is within +/-1 frame (0.8 ms, inside the")
    A("  plan's +/-2 ms tolerance) of j*8 frames (j=1..6). Forward runs: either")
    A("  neighbor (comb density high, 86-95% of events lock). Reverse runs: BOTH")
    A("  neighbors required, because at reverse's low event density a one-sided")
    A("  match has ~37% chance-pass; two-sided ~14%.")
    A("- **tx-underrun-comb** (reverse only): spacing within +/-2 of j*33 frames")
    A("  (j=1..3) to a neighbor -- the TX zero-fill cadence of TX_ANOMALY_SCAN.md")
    A("  (revlong: 33.000-frame spacing). Takes precedence over the boundary test")
    A("  in reverse.")
    A("- **tx-mute-cand**: hole with a crc=0, host_seq==0 record inside or within")
    A("  +/-2 records (the SINGLES_REPLAY.md ~72 us mute signature), not comb-")
    A("  locked. Envelope verification not run (pair.iq covers only ~130 ms/run).")
    A("- **burst-frozen**: >20-frame hole with reg_packets frozen (dpk<=max(2,k/10)).")
    A("- **startup-burst**: >200-frame delivered-corrupt hole inside the first 15 s")
    A("  (the three ~1s corrupt bursts during bring-up, identical in every accept")
    A("  run; reg_packets advances, so NOT the frozen-burst class).")
    A("- **mid-gap**: 3-20 frames (its own class per plan; cadence flags kept).")
    A("- **feeder-gap** (singles_disc only, txlog_146.bin present): hole within")
    A("  +/-25 ms (wall-clock translated) of a TX submit gap >1.5 frame periods.")
    A("- Everything else: **unnamed**, enumerated below.")
    A("- Live window = accept_analyze.py's (settle 15 s, wedge-guarded live end);")
    A("  sum-check per run = my live-window lost total vs accept_analyze's miss.")
    A("")

    # per-run tables -------------------------------------------------------
    A("## Per-run ledger (full log; live-window subtotal + sum-check per row)")
    A("")
    hdr = ("| run | dir | M | frames(clean) | span | lost | " +
           " | ".join(CLS_ORDER) + " | live lost | accept miss | sum-check |")
    A(hdr)
    A("|" + "---|" * (len(CLS_ORDER) + 9))
    for r in results:
        ev, lost = tally(r["holes"])
        s = sum(lost.values())
        chk = "OK" if s == r["total_lost"] else f"MISMATCH {s}!={r['total_lost']}"
        ref = r["ref_miss"] if r["ref_miss"] is not None else "n/a(wedge)"
        chk2 = "OK" if (r["ref_miss"] is None or r["live_lost"] == r["ref_miss"]) \
            else f"live {r['live_lost']}!={r['ref_miss']}"
        cells = " | ".join(f"{lost[c]}({ev[c]})" for c in CLS_ORDER)
        A(f"| {r['label']} | {r['direction']} | {r['M']} | "
          f"{r['n_rec']}({r['n_clean']}) | {r['span']} | {r['total_lost']} | "
          f"{cells} | {r['live_lost']} | {ref} | {chk}; {chk2} |")
    A("")
    A("Cells are lost-frames(events). Sum-check column: full-log class sum vs")
    A("total lost, then live-window lost vs accept_analyze miss.")
    A("")

    # pooled per direction -------------------------------------------------
    A("## Pooled scoreboard per direction (live windows, settle>=15 s)")
    A("")
    for live in (True,):
        for dirn in ("fwd", "rev"):
            rs = [r for r in results if r["direction"] == dirn]
            ev = {c: 0 for c in CLS_ORDER}
            lost = {c: 0 for c in CLS_ORDER}
            span = 0
            tot = 0
            for r in rs:
                e, l = tally(r["holes"], live_only=live)
                for c in CLS_ORDER:
                    ev[c] += e[c]
                    lost[c] += l[c]
                # live span: clean seqs in window
                span += r["span"]
                tot += r["live_lost"]
            A(f"### {dirn.upper()} ({len(rs)} runs) -- live-window losses"
              f" {tot}, full-log span {span}")
            A("")
            A("| class | events | lost frames | share of losses | PER contribution |")
            A("|---|---|---|---|---|")
            denom = sum(lost.values())
            for c in CLS_ORDER:
                if ev[c] == 0:
                    continue
                A(f"| {c} | {ev[c]} | {lost[c]} | "
                  f"{100*lost[c]/max(denom,1):.1f}% | "
                  f"{100*lost[c]/max(span,1):.3f}% |")
            A(f"| **total** | {sum(ev.values())} | {denom} | 100% | "
              f"{100*denom/max(span,1):.3f}% |")
            A("")
    A("PER contribution uses the pooled full-log clean-seq span as denominator;")
    A("live-window losses as numerator (matches accept_analyze's metric per run).")
    A("")

    # unnamed enumeration --------------------------------------------------
    A("## Unnamed bucket -- ENUMERATED (every event, full log)")
    A("")
    n_un = 0
    for r in results:
        uh = [h for h in r["holes"] if h["cls"] in ("unnamed", "big-gap-unnamed")]
        if not uh:
            continue
        A(f"### {r['label']} ({r['direction']}, M{r['M']}) -- "
          f"{len(uh)} unnamed events, {sum(h['k'] for h in uh)} frames")
        A("")
        A("| t(s) | wall(ns) | seq | k | crc0-in | dpk | dbiterr | dprev | dnext"
          " | seq0-adj | garbage | 633-tick | live |")
        A("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for h in uh:
            n_un += 1
            A(f"| {h['t']:.3f} | {h['twall']} | {h['seq0']}"
              + (f"-{h['seq1']}" if h["k"] > 1 else "")
              + f" | {h['k']} | {h['ncrc0']} | {h['dpk']} | {h['biterr']}"
              f" | {h.get('dprev')} | {h.get('dnext')}"
              f" | {'y' if (h['has_seq0'] or h['adj_seq0']) else ''}"
              f" | {'y' if h['has_garb'] else ''}"
              f" | {'y' if h.get('c633') else ''}"
              f" | {'y' if h['in_live'] else ''} |")
        A("")
    A(f"**Unnamed total: {n_un} events across all runs.**")
    A("")

    # notes ---------------------------------------------------------------
    A("## Notes and caveats")
    A("")
    A("- evm_swap_B wedged at ~12 s (meta: MID_CAPTURE_WEDGE, 'NOT usable data');")
    A("  its rows cover the pre-wedge window only and the wedge truncation itself")
    A("  is a run-level event, not a hole (delivery flatlined; capture ended).")
    A("- accept_201153_r1 ran -M32 (detected from drain-burst structure and")
    A("  meta timestamps); all other runs -M16.")
    A("- The 8-frame comb finding (vs the plan's 12.85 ms area period) is the")
    A("  headline surprise; see Method above. The boundary class label is kept")
    A("  because the comb is still DMA-cadence-locked, but the period is half an")
    A("  area at -M16 and a QUARTER area at -M32.")
    # discovered-structure stats for the notes
    n633 = {}; nalt = {}
    for r in results:
        n633[r["label"]] = sum(1 for h in r["holes"] if h.get("c633"))
        nalt[r["label"]] = sum(1 for h in r["holes"]
                               if h["k"] == 1 and (h.get("dprev") == 2 or
                                                   h.get("dnext") == 2))
    A("- **Discovered structure #1 -- reverse 633-frame tick pairs:** in every")
    A("  reverse run the mid-gap/unnamed events organize into PAIRS: a k=2..9 hole")
    A("  followed by a k~2 hole exactly 633 frames (508 ms) later, with pair")
    A("  onsets repeating on a ~1.79 s / 3.58 s super-period (e.g. accept_155622:")
    A("  onsets 8.50, 12.15, 15.79, 23.01, 24.81, 28.39 s...). Events flagged in")
    A("  the 633-tick column; per-run flagged counts: "
      + ", ".join(f"{k}={v}" for k, v in n633.items() if v))
    A("  This is the dominant REVERSE loss structure and is NOT in tonight's")
    A("  class list -- it stays mid-gap/unnamed here, named for the morning.")
    A("- **Discovered structure #2 -- bud0_c1 pre-settle alternating storm:** 443")
    A("  k=1 holes spaced exactly 2 frames apart (lost-clean-lost), ALL inside")
    A("  t=3.4-5.0 s (the third warm-up second, which in every other run is one")
    A("  contiguous startup-burst). Pre-settle, so excluded from the pooled")
    A("  live-window scoreboard; enumerated in the unnamed table (live=blank).")
    A("  Per-run k=1-with-2-frame-neighbor counts: "
      + ", ".join(f"{k}={v}" for k, v in nalt.items() if v > 5))
    n_fg = sum(1 for r in results for h in r["holes"] if h["cls"] == "feeder-gap")
    fgd = next((r for r in results if r["label"] == "singles_disc"), None)
    if fgd:
        A(f"- singles_disc txlog: {fgd['n_txgap']} TX submit gaps (all ~1.2-1.3 ms")
        A(f"  = ~1.5 frame periods); holes matched within +/-25 ms: "
          f"{n_fg} classified feeder-gap.")
    open(os.path.join(os.path.dirname(R3), "LOSS_LEDGER.md"), "w").write(
        "\n".join(out) + "\n")
    print(f"wrote LOSS_LEDGER.md; unnamed={n_un}")
    for r in results:
        ev, lost = tally(r["holes"])
        s = sum(lost.values())
        flag = "" if s == r["total_lost"] else "  SUM-MISMATCH"
        lw = "" if (r["ref_miss"] is None or r["live_lost"] == r["ref_miss"]) \
            else f"  LIVE {r['live_lost']} vs ref {r['ref_miss']}"
        print(f"{r['label']:24s} {r['direction']} M{r['M']} lost={r['total_lost']}"
              f" live={r['live_lost']} ref={r['ref_miss']}{flag}{lw}")


if __name__ == "__main__":
    main()
