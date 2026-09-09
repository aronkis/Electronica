#!/usr/bin/env python3
"""revrom_analyze.py -- discriminate the reverse-link fault source from a
ROM/BIST soak (reverse_rom_soak.sh). ROM bypasses the byte/DMA/host plane, so:
  - BIST errors present -> PHY/modem/interface; adc_forensic (0x15C) then splits
    modem-loop vs axi_adrv9001 SSI delivery.
  - BIST clean over the soak -> the fault needs the byte/DMA path -> DMA/byte-plane.
adc_forensic 0x15C = [levelLog:31..24 | maxBurst:23..16 | maxGap:15..8 | validDuty:7..0].
"""
import re, sys
import numpy as np

GOLDEN = 0x04922282

def load(path):
    rows = []
    for ln in open(path):
        m = re.search(r"t=([\d.]+).*pkts=0x([0-9a-fA-F]+).*biterr=0x([0-9a-fA-F]+).*cap=0x([0-9a-fA-F]+).*rstcs=0x([0-9a-fA-F]+).*cfc=0x([0-9a-fA-F]+).*fx=0x([0-9a-fA-F]+)", ln)
        if m:
            rows.append([float(m.group(1))] + [int(m.group(i),16) for i in range(2,8)])
    a = np.array(rows, dtype=np.float64)
    return a

def sx21(u):
    u = int(u) & 0x1FFFFF
    return u-(1<<21) if u >= (1<<20) else u

def main(path):
    a = load(path)
    if a.shape[0] < 10:
        print("revrom: too few samples"); return 1
    t = a[:,0]-a[0,0]; pk=a[:,1]; be=a[:,2].astype(np.int64); cap=a[:,3].astype(np.int64)
    rst=a[:,4]; cfc=a[:,5]; fx=a[:,6].astype(np.int64)
    dur=t[-1]
    dbe=np.diff(be); dbe[dbe<0]=0
    dpk=np.diff(pk); dpk[dpk<0]=0
    # adc_forensic decode
    validDuty = fx & 0xFF; maxGap=(fx>>8)&0xFF; maxBurst=(fx>>16)&0xFF; levelLog=(fx>>24)&0xFF
    capgold = np.mean(cap==GOLDEN)
    # error episodes = samples where BIST bit_errors grew
    ev = np.flatnonzero(dbe>0)
    print(f"revrom: {a.shape[0]} samples over {dur:.0f}s")
    print(f"  packets advanced: {int(pk[-1]-pk[0])} ({dpk.mean()*10:.0f}/s)  rstcs total: {int(rst[-1]-rst[0])}")
    print(f"  cap_out golden: {capgold*100:.1f}% of samples")
    print(f"  BIST bit_errors: grew {int(be[-1]-be[0])}; growth events={ev.size}")
    print(f"  adc_forensic: maxGap median={np.median(maxGap):.0f} max={maxGap.max():.0f} | "
          f"maxBurst median={np.median(maxBurst):.0f} | levelLog median={np.median(levelLog):.0f} "
          f"| validDuty median={np.median(validDuty):.0f}")
    # cfc dither
    cfcs = np.array([sx21(v) for v in cfc])
    print(f"  cfc(0x154): median={np.median(cfcs):.0f} std={np.std(cfcs):.0f} range=[{cfcs.min():.0f},{cfcs.max():.0f}]")

    # ---- verdict ----
    wedged = (be[-1]-be[0]) > 100 or capgold < 0.9
    gap_glitch = maxGap.max() > 2
    cfc_dither = np.std(cfcs) > 200
    print("\n== SOURCE DISCRIMINATION ==")
    if not wedged:
        print("VERDICT: reverse ROM/BIST stayed CLEAN (cap golden, no BIST error growth)")
        print("  -> the reverse fault does NOT appear without the byte/DMA path")
        print("  -> DMA / BYTE-PLANE is implicated (not PHY/interface).")
    else:
        print("VERDICT: reverse ROM/BIST WEDGES (BIST errors / cap non-golden) -> PHY/modem/interface")
        if gap_glitch:
            print(f"  adc_forensic maxGap={maxGap.max():.0f} (>2) -> axi_adrv9001 SSI VALID-CADENCE GLITCH")
            print("  -> the axi_adrv9001 interface delivery is the source.")
        elif cfc_dither:
            print(f"  adc clean (maxGap<=2) but cfc dither std={np.std(cfcs):.0f} -> MODEM CARRIER LOOP")
        else:
            print("  adc clean + cfc stable -> modem timing/decode loop (not SSI, not carrier)")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv)>1 else "revrom.log"))
