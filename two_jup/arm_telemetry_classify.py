#!/usr/bin/env python3
"""arm_telemetry_classify.py <armtel.log> [--fps 623]

Parse an arm_telemetry.sh log and classify every arm per the ARMCAUSE
deviation-first logic:

  C1 cal-settle      ROM fps ramps (early <50% of steady) and steady is good;
                     and/or degradation confined to FULL arms
  C2 LO-PLL          pll_status shows a needed LO Unlocked
  C3-slip            rstcs storm (>100 per ROM window)
  C3-margin          full ROM fps but PRBS errors at the operating delay point
  C4 CFO-dead-zone   ROM fps 30-60% of rate with cfc sign-flip dither
  C5 acq-wedge       ROM fps ~0 with rstcs calm; CS-reset-only probe recovers
  C6 grid/fabric     ROM clean + PRBS clean but byte crc high; deint ratio
                     (d0x120/d0x12C != 2.000) or 0x124 != 0x104 corroborates
  C8 host-pacing     byte dma_tx well below the paced rate
  GOOD               ROM >=90% rate, byte crc <=15%
"""
import re, sys, statistics

fps_nominal = 623.0
args = [a for a in sys.argv[1:]]
if "--fps" in args:
    i = args.index("--fps"); fps_nominal = float(args[i+1]); del args[i:i+2]
LOG = args[0]

def hx(s):
    v = int(s, 16) if s.startswith("0x") else int(s)
    return v
def s32(v):
    return v - (1 << 32) if v >= (1 << 31) else v

arms = {}          # i -> dict
def arm(i):
    return arms.setdefault(i, dict(type="?", win={}, cswin={}, snap={}, prbs={},
                                   byte={}, ssi={}))

pat_kv = re.compile(r'(\w+)=([\w.:+-]+)')
for line in open(LOG):
    line = line.rstrip("\n")
    m = re.match(r'@@ ARM (\d+) TYPE=(\w+)', line)
    if m: arm(int(m.group(1)))["type"] = m.group(2); continue
    m = re.match(r'@@ ARM (\d+) ssi(146|148): (.*)', line)
    if m: arm(int(m.group(1)))["ssi"][m.group(2)] = m.group(3); continue
    m = re.match(r'@@ (WIN|CSWIN) (\d+) ([AB]) (.*)', line)
    if m:
        kind, i, side, rest = m.group(1), int(m.group(2)), m.group(3), m.group(4)
        d = dict(pat_kv.findall(rest))
        if "pkts" not in d: continue
        tgt = arm(i)["win" if kind == "WIN" else "cswin"].setdefault(side, [])
        tgt.append(d); continue
    m = re.match(r'@@ SNAP (\d+) ([AB]) (\w+): (.*)', line)
    if m:
        arm(int(m.group(1)))["snap"].setdefault(m.group(2), {})[m.group(3)] = m.group(4)
        continue
    m = re.match(r'@@ PRBS (\d+) ([AB]) (\w+_prbs): (.*)', line)
    if m:
        arm(int(m.group(1)))["prbs"].setdefault(m.group(2), {})[m.group(3)] = m.group(4)
        continue
    m = re.match(r'@@ BYTE([01]) (\d+) ([AB]) (.*)', line)
    if m:
        d = dict(pat_kv.findall(m.group(4)))
        arm(int(m.group(2)))["byte"].setdefault(m.group(3), {})[m.group(1)] = d
        continue

def win_metrics(samples):
    """fps trajectory, steady fps, ramp flag, cfc signflips, rstcs delta."""
    if len(samples) < 3: return None
    t = [float(s["t"]) for s in samples]
    pk = [hx(s["pkts"]) for s in samples]
    fps = [(pk[j+1]-pk[j])/max(t[j+1]-t[j], 1e-3) for j in range(len(pk)-1)]
    steady = statistics.median(fps[len(fps)//2:])
    early = statistics.median(fps[:max(2, len(fps)//3)])
    cfc = [s32(hx(s["cfc"])) for s in samples]
    flips = sum(1 for j in range(len(cfc)-1)
                if cfc[j] != 0 and cfc[j+1] != 0 and (cfc[j] > 0) != (cfc[j+1] > 0))
    rst = hx(samples[-1]["rstcs"]) - hx(samples[0]["rstcs"])
    c120 = hx(samples[-1].get("c120","0x0")) - hx(samples[0].get("c120","0x0"))
    c124 = hx(samples[-1].get("c124","0x0")) - hx(samples[0].get("c124","0x0"))
    c12c = hx(samples[-1].get("c12C","0x0")) - hx(samples[0].get("c12C","0x0"))
    ratio = c120 / c12c if c12c else float("nan")
    biterr = hx(samples[-1]["biterr"]) - hx(samples[0]["biterr"])
    return dict(fps=fps, steady=steady, early=early, flips=flips, rst=rst,
                ratio=ratio, dframes=hx(samples[-1]["pkts"])-hx(samples[0]["pkts"]),
                d124=c124, biterr=biterr)

def prbs_errors(p):
    out = {}
    tx = p.get("tx0_prbs", "")
    m = re.search(r'dataError[^0-9]*(\d+)', tx)
    out["tx_err"] = int(m.group(1)) if m else None
    rx = p.get("rx0_prbs", "")
    out["rx_bad"] = ("PN-Error" in rx) or ("Out-of-Sync" in rx) or ("OOS" in rx)
    return out

def byte_metrics(b):
    if "0" not in b or "1" not in b: return None
    d0, d1 = b["0"], b["1"]
    dt = float(d1["t"]) - float(d0["t"])
    def dv(k): return (int(d1.get(k, 0)) - int(d0.get(k, 0)))
    # decoded frames = idle_rx + dma_rx_ok (idles dominate with no tun traffic)
    rx_ok = (dv("dma_rx_ok") + dv("idle_rx"))/dt
    crc = dv("crc_drop")/dt; tx = dv("dma_tx")/dt
    tot = rx_ok + crc
    return dict(rx_fps=rx_ok, crc_fps=crc, tx_fps=tx,
                crc_pct=100*crc/tot if tot else float("nan"), dt=dt)

rows = []
for i in sorted(arms):
    a = arms[i]
    for side in ("A", "B"):
        w = win_metrics(a["win"].get(side, []))
        if not w: continue
        snap = a["snap"].get(side, {})
        pll = snap.get("pll", "")
        pll_bad = bool(re.search(r'LO1: Unlocked|Clock: Unlocked', pll))
        pe = prbs_errors(a["prbs"].get(side, {}))
        bm = byte_metrics(a["byte"].get(side, {}))
        cs = win_metrics(a["cswin"].get(side, []))
        r = w["steady"]/fps_nominal
        verdict = "GOOD"
        if pll_bad: verdict = "C2 LO-PLL"
        elif w["rst"] > 100: verdict = "C3-slip (rstcs storm)"
        elif r < 0.10:
            verdict = ("C5 acq-wedge (CS-reset recovered)"
                       if cs and cs["steady"]/fps_nominal > 0.9
                       else "C5/C2 dead (CS-reset did NOT recover)")
        elif 0.30 <= r <= 0.60 and w["flips"] >= 3: verdict = "C4 CFO-dead-zone"
        elif 0.30 <= r <= 0.60: verdict = "C4? low-rate (few flips - inspect)"
        elif r < 0.90 and w["early"] < 0.5*w["steady"]: verdict = "C1 cal-settle (ramp)"
        elif r < 0.90: verdict = "DEGRADED-ROM (unclassified)"
        elif pe["tx_err"] not in (0, None) or pe["rx_bad"]: verdict = "C3-margin (PRBS err)"
        elif bm and bm["tx_fps"] < 0.75*fps_nominal: verdict = "C8 host-pacing"
        elif bm and bm["crc_pct"] > 15:
            verdict = "C6 grid/fabric" if (abs(w["ratio"]-2.0) > 0.01 or
                                            w["d124"] != w["dframes"]) \
                      else "C6-suspect (byte crc high, all else clean)"
        # the byte re-arm (0x000) re-rolls the acquisition lottery independently
        # of the ROM window: report a byte-phase-only degradation explicitly
        if bm and bm["rx_fps"] < 0.5*fps_nominal and bm["tx_fps"] > 0.75*fps_nominal:
            verdict += " |BYTE-reroll-degraded"
        rows.append((i, a["type"], side, r*100, w["early"], w["steady"], w["flips"],
                     w["rst"], pe["tx_err"], pe["rx_bad"],
                     bm["crc_pct"] if bm else float("nan"),
                     bm["rx_fps"] if bm else float("nan"), verdict))

hdr = ("arm type side rom% early_fps steady_fps cfc_flips drstcs prbs_tx "
       "prbs_rx_bad byte_crc% byte_rx_fps verdict").split()
print(("{:>3} {:>5} {:>4} {:>6} {:>9} {:>10} {:>9} {:>6} {:>7} {:>11} "
       "{:>9} {:>10}  {}").format(*hdr))
for r in rows:
    print(("{:>3} {:>5} {:>4} {:>6.1f} {:>9.1f} {:>10.1f} {:>9} {:>6} {:>7} "
           "{:>11} {:>9.1f} {:>10.1f}  {}").format(
        r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7],
        str(r[8]), str(r[9]), r[10], r[11], r[12]))

from collections import Counter
c = Counter(r[12].split()[0] for r in rows)
n = len(rows)
print("\nSummary ({} board-arms): ".format(n) +
      ", ".join("{} {}/{}".format(k, v, n) for k, v in c.most_common()))
full = [r for r in rows if r[1] == "FULL" and r[12] != "GOOD"]
rearm = [r for r in rows if r[1] == "REARM" and r[12] != "GOOD"]
print("Degraded on FULL arms: {}   on REARM-only: {}".format(len(full), len(rearm)))
print("(FULL-only degradation -> transceiver stage; both -> modem/acquisition stage)")
