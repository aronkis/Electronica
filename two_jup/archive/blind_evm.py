#!/usr/bin/env python3
# blind_evm.py -- reference-free QPSK constellation / EVM on a raw int16 I/Q capture.
# Python companion to two_jup/blind_evm.m (MATLAB down). Front-end matches
# k5_240/soak_decode_k5.m: RRC rcosdesign(0.5,4,8), 8 sps, Fs=1.92 MHz, Rsym=240 ksym,
# 4th-power coarse CFO, then block-wise 4th-power phase de-rotation for the intrinsic EVM.
#
# Reports:
#   CFO_Hz            coarse 4th-power carrier offset
#   EVM_static  %     single whole-capture phase (shows CFO spin / gross rotation)
#   EVM_tracked %     block-derotated (residual CFO/drift removed) = intrinsic spread
#   class             CLEAN / CFO-DRIFT / STRUCTURED / THERMAL  (discriminator)
# Saves <prefix>_const.png (tracked scatter) if matplotlib present, else <prefix>_syms.npy.
import sys, numpy as np

def rrc(beta, span, sps):
    N = span*sps
    t = np.arange(-N/2, N/2+1)/sps
    h = np.empty_like(t)
    for i, ti in enumerate(t):
        if abs(ti) < 1e-9:
            h[i] = 1 - beta + 4*beta/np.pi
        elif abs(abs(ti) - 1/(4*beta)) < 1e-9:
            h[i] = (beta/np.sqrt(2))*((1+2/np.pi)*np.sin(np.pi/(4*beta)) +
                                       (1-2/np.pi)*np.cos(np.pi/(4*beta)))
        else:
            num = np.sin(np.pi*ti*(1-beta)) + 4*beta*ti*np.cos(np.pi*ti*(1+beta))
            den = np.pi*ti*(1-(4*beta*ti)**2)
            h[i] = num/den
    return h/np.sqrt(np.sum(h**2))

def fourth_power_cfo(x, fs, fmax):
    # coarse CFO from the 4th-power spectral peak (QPSK), restricted to |f|<fmax
    N = 1 << int(np.floor(np.log2(min(len(x), 1 << 18))))  # power of 2 <= len(x)
    w = x[:N]**4
    W = np.abs(np.fft.fftshift(np.fft.fft(w*np.hanning(N))))
    f = np.fft.fftshift(np.fft.fftfreq(N, d=1/fs))
    W[np.abs(f) >= fmax] = 0
    return f[np.argmax(W)]/4.0

def evm_to_qpsk(s):
    # grid-agnostic: normalize to unit avg power (ideal radius 1), estimate the
    # constellation's own rotation th0 from the 4th-power moment, snap each symbol
    # to the nearest ideal point at th0 + k*90deg. Works for axis- or 45deg-aligned QPSK.
    s = s/np.sqrt(np.mean(np.abs(s)**2))
    th0 = np.angle(np.mean(s**4))/4
    k = np.round((np.angle(s) - th0)/(np.pi/2))
    ideal = np.exp(1j*(th0 + k*(np.pi/2)))
    return np.sqrt(np.mean(np.abs(s-ideal)**2))*100.0, s, ideal

def main(path, prefix):
    sps, Fs, Rsym = 8, 1.92e6, 240e3
    raw = np.fromfile(path, dtype=np.int16).astype(float)
    I, Q = raw[0::2], raw[1::2]
    n = min(len(I), len(Q))
    x = I[:n] + 1j*Q[:n]
    x = x[np.abs(x) > 0]
    rms_adc = np.sqrt(np.mean(np.abs(x)**2))
    x = x/ (np.max(np.abs(x))+1e-12)
    mf = np.convolve(x, rrc(0.5, 4, sps), 'same')
    # coarse CFO on the oversampled stream, remove it (wide range: 4*cfo up to Rsym -> cfo<=60 kHz)
    cfo = fourth_power_cfo(mf, Fs, Rsym)
    t = np.arange(len(mf))
    mf = mf*np.exp(-1j*2*np.pi*cfo/Fs*t)
    # symbol timing: max-output-energy sampling phase
    best_ph, best_e = 0, -1
    for ph in range(sps):
        e = np.mean(np.abs(mf[ph::sps])**2)
        if e > best_e: best_e, best_ph = e, ph
    sym = mf[best_ph::sps]
    sym = sym/np.sqrt(np.mean(np.abs(sym)**2))
    # EVM static (one global 4th-power phase align)
    phi0 = np.angle(np.mean(sym**4))/4
    evm_static, _, _ = evm_to_qpsk(sym*np.exp(-1j*phi0))
    # EVM tracked: block-wise 4th-power de-rotation (removes residual CFO/drift)
    B = 64
    st = sym.copy()
    for i in range(0, len(st), B):
        blk = st[i:i+B]
        if len(blk) < 8: continue
        phi = np.angle(np.mean(blk**4))/4
        st[i:i+B] = blk*np.exp(-1j*phi)
    evm_tracked, sn, _ = evm_to_qpsk(st)
    # 4th-power coherence: ~1 = coherent 4-blob QPSK, ~0 = uniform-phase ring (large CFO / fast phase noise)
    C4 = np.abs(np.mean(sym**4))/(np.mean(np.abs(sym)**4)+1e-12)
    ratio = evm_static/max(evm_tracked, 1e-9)
    if C4 < 0.35:
        cls = "RING / CFO-limited (uniform phase -> gross carrier offset; carrier/RF fix, NOT decoder)"
    elif evm_tracked < 12:
        cls = "CLEAN (tight 4-blob -> a floor here would be the BOX/decoder, not the signal)"
    elif ratio > 1.8:
        cls = "CFO-DRIFT (static>>tracked -> removable residual carrier)"
    else:
        cls = f"SPREAD (blobs present but wide EVM={evm_tracked:.0f}% -> marginal SNR / thermal-ish)"
    print(f"{path.split('/')[-1]}: nsym={len(sym)} rms_adc={rms_adc:.0f} CFO={cfo:.0f}Hz C4={C4:.2f} "
          f"EVM_static={evm_static:.1f}% EVM_tracked={evm_tracked:.1f}%  -> {cls}")
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(1, 2, figsize=(10, 5))
        for a, (d, ti) in zip(ax, [(sym*np.exp(-1j*phi0), f'static EVM={evm_static:.1f}%'),
                                    (sn, f'tracked EVM={evm_tracked:.1f}%')]):
            m = min(4000, len(d))
            a.plot(d[:m].real, d[:m].imag, '.', ms=1, alpha=0.3)
            a.set_title(ti); a.set_aspect('equal'); a.grid(True, alpha=0.3)
            a.set_xlim(-2.2, 2.2); a.set_ylim(-2.2, 2.2)
        fig.suptitle(f"{path.split('/')[-1]}  CFO={cfo:.0f}Hz  {cls.split('(')[0].strip()}")
        fig.tight_layout(); fig.savefig(prefix+'_const.png', dpi=90)
        print(f"  saved {prefix}_const.png")
    except Exception as e:
        np.save(prefix+'_syms.npy', sn)
        print(f"  (no matplotlib: {e}); saved {prefix}_syms.npy")

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
