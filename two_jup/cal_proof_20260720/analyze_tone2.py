#!/usr/bin/env python3
# Improved periodic-transient search on a CW tone. The BBDC insertion is a
# ~133us (256-sample) event every ~1.489s; block-MEAN decimation smears it, so
# we use per-block PEAK deviation from the pure tone (catches short glitches).
# Observables per 0.5ms block: (a) max |tracking error| (departure from the
# constant baseband tone), (b) max |d/dn phase| (phase jerk), (c) max |amp step|.
# Then test for a spectral line at the KNOWN tick rate 0.671 Hz (period 1.489s)
# and report SNR; compare BBDC on vs off.
import sys, numpy as np
FS = 1_920_000
TICK_HZ = 1/1.489

def load(p):
    d=np.fromfile(p,dtype="<i2").astype(np.float64); d=d[:(len(d)//2)*2].reshape(-1,2); return d[:,0]+1j*d[:,1]

def tone_f0(x):
    N=min(len(x),1<<20); X=np.fft.fft(x[:N]*np.hanning(N)); k=np.argmax(np.abs(X)); return np.fft.fftfreq(N,1/FS)[k]

def line_snr(sig, fs_dec, f_target):
    sig = sig-np.mean(sig); n=len(sig); w=np.hanning(n)
    S=np.abs(np.fft.rfft(sig*w)); fr=np.fft.rfftfreq(n,1/fs_dec)
    band=(fr>=0.3)&(fr<=3.0)
    ib=np.argmin(np.abs(fr-f_target))
    flo=np.median(S[band])+1e-12
    # strongest line in band + the value exactly at tick freq
    kk=np.argmax(S[band]); return fr[band][kk], S[band][kk]/flo, S[ib]/flo

def analyze(p):
    x=load(p); n=len(x); dur=n/FS; f0=tone_f0(x)
    base=x*np.exp(-1j*2*np.pi*f0*np.arange(n)/FS)      # tone -> ~DC baseband
    B=960; m=(n//B)*B; br=base[:m].reshape(-1,B)         # 0.5ms blocks
    tone=br.mean(1,keepdims=True)
    track_pk=np.abs(br-tone).max(1)                      # peak departure from pure tone
    amp=np.abs(br); amp_pk=(amp.max(1)-amp.min(1))       # intra-block amp swing
    ph=np.angle(br*np.conj(tone)); ph_pk=np.abs(ph).max(1)
    fs_dec=FS/B
    tot=np.sqrt(np.mean(np.abs(x)**2))
    print(f"== {p.split('/')[-1]} ==  dur={dur:.1f}s f0={f0/1e3:.1f}kHz rms={tot:.0f}  (tick={TICK_HZ:.3f}Hz/{1/TICK_HZ:.3f}s)")
    for lbl,sig in [("track_peak",track_pk),("amp_swing",amp_pk),("phase_peak",ph_pk)]:
        fpk,snr_pk,snr_tick=line_snr(sig,fs_dec,TICK_HZ)
        flag=""
        if snr_tick>5 and abs(fpk-TICK_HZ)<0.05: flag="  <== LINE AT TICK FREQ"
        elif snr_tick>5: flag=f"  (tick-bin SNR {snr_tick:.1f})"
        print(f"    {lbl:11s}: strongest {fpk:.3f}Hz SNR={snr_pk:.1f} | @tickfreq SNR={snr_tick:.1f}{flag}")

if __name__=="__main__":
    for p in sys.argv[1:]:
        try: analyze(p)
        except Exception as e: print(f"{p}: ERR {e}")
