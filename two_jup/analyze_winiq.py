#!/usr/bin/env python3
"""Compare demodulator soft constellation IN a held-corruption window vs a golden
GAP (rx2-lpc debug tap, interleaved little-endian int16 I,Q). Discriminates:
  TIGHT+correct clusters in-window  -> digital demapper/Serializer fault (after tap)
  ROTATED clusters                  -> carrier-phase slip
  SPREAD blob / displaced           -> symbol-timing (Gardner) slip
"""
import sys, numpy as np

def load(path):
    raw = np.fromfile(path, dtype='<i2')
    if len(raw) < 4: return None
    iq = raw[:len(raw)//2*2].reshape(-1, 2).astype(np.float64)
    return iq[:,0] + 1j*iq[:,1]

def characterize(z, tag):
    # drop near-zero (idle) samples
    mag = np.abs(z)
    m = mag > (0.15*np.median(mag[mag>0]) if np.any(mag>0) else 0)
    z = z[m]
    if len(z) < 100:
        print(f"  {tag}: too few active samples ({len(z)})"); return
    rms = np.sqrt(np.mean(np.abs(z)**2))
    # fold into first quadrant to estimate cluster tightness independent of which quadrant
    ang = np.angle(z)
    # 4-fold symmetry: map angle to nearest of +/-45,135 and measure residual
    q = np.round((ang - np.pi/4)/(np.pi/2))
    ideal = np.pi/4 + q*(np.pi/2)
    ang_err = np.angle(np.exp(1j*(ang-ideal)))  # residual angle error per symbol
    amp = np.abs(z)
    # EVM-ish: distance to nearest ideal QPSK point at radius = median amp
    R = np.median(amp)
    ideal_pts = R*np.exp(1j*ideal)
    evm = np.sqrt(np.mean(np.abs(z-ideal_pts)**2))/R*100
    # rotation: mean residual angle (systematic rotation away from 45-deg grid)
    rot = np.degrees(np.mean(ang_err))
    spread_deg = np.degrees(np.std(ang_err))
    amp_cv = np.std(amp)/np.mean(amp)
    # quadrant balance
    quad = np.round((ang % (2*np.pi))/(np.pi/2)).astype(int) % 4
    counts = [int(np.sum(quad==k)) for k in range(4)]
    print(f"  {tag}: N={len(z)} R={R:.0f} EVM={evm:.1f}% rot={rot:+.1f}deg angspread={spread_deg:.1f}deg ampCV={amp_cv:.2f} quad={counts}")
    return dict(evm=evm, rot=rot, spread=spread_deg, ampcv=amp_cv)

def main():
    import glob, os
    d = sys.argv[1]
    files = sorted(glob.glob(os.path.join(d,'*.bin')))
    print("files:", [os.path.basename(f) for f in files])
    res={}
    for f in files:
        z=load(f)
        if z is None: print(f"  {os.path.basename(f)}: empty"); continue
        res[os.path.basename(f)]=characterize(z, os.path.basename(f))
    print("\nVERDICT GUIDE: inwin EVM~=gap & rot~0 & spread small -> DIGITAL (after tap);")
    print("  inwin rot far from 0 -> CARRIER; inwin EVM/spread/ampCV >> gap -> TIMING.")

if __name__=='__main__': main()
