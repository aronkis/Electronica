import numpy as np, sys
f,delta,fs,label=sys.argv[1],float(sys.argv[2]),float(sys.argv[3]),sys.argv[4]
d=np.fromfile(f,dtype=np.int16); I=d[0::2].astype(float); Q=d[1::2].astype(float)
n=min(len(I),len(Q)); x=I[:n]+1j*Q[:n]
sat=np.mean(np.abs(np.concatenate([x.real,x.imag]))>32000)
N=1<<int(np.floor(np.log2(len(x)))); w=np.hanning(N)
X=np.abs(np.fft.fftshift(np.fft.fft(x[:N]*w))); faxis=np.linspace(-fs/2,fs/2,N)
ki=np.argmax(X); pk=X[ki]; fpeak=faxis[ki]
noise=np.median(X[X<pk/10])+1e-9; snr=20*np.log10(pk/noise)
cfo=fpeak-delta
# channel PASS = strong clean tone at expected |offset| within a generous CFO budget (+-30kHz)
ok = snr>25 and sat<0.001 and abs(abs(fpeak)-abs(delta))<30e3
print(f"[{label}] fs={fs/1e6:.3f}MHz expect={delta:+.0f} meas={fpeak:+.0f} impliedCFO={cfo:+.0f}Hz SNR={snr:.1f}dB sat={100*sat:.3f}% -> {'PASS' if ok else 'FAIL'}")
