#!/usr/bin/env python3
import numpy as np, matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt, re, glob, sys
FS=1_920_000; SP=scratch="/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/99c1d537-a8f8-481c-b665-21aeee224f33/scratchpad/"
pA=sorted(glob.glob(SP+"phaseA_2026*/"))[-1]; pB=sorted(glob.glob(SP+"phaseB_2026*/"))[-1]
def load(p):
    d=np.fromfile(p,dtype="<i2").astype(float); d=d[:(len(d)//2)*2].reshape(-1,2); return d[:,0]+1j*d[:,1]
def movsum(a,w): c=np.cumsum(np.concatenate([[0],a])); return c[w:]-c[:-w]

fig,ax=plt.subplots(2,2,figsize=(13,9))
fig.suptitle("Burst disruption on Jupiter unit 148 = ADRV9002 BBDC rejection tracking-cal artifact\n"
             "(device-side calibration, not fabric; a sample-delivery INDEX event, not data corruption)  —  2026-07-20",fontweight="bold")

# P1: witnessed burst
t=[];lost=[];ber=[]
for ln in open(SP+"witness_acc.log"):
    m=re.search(r"t=(\d+)s.*lost=(\d+).*BER=([\d.eE+-]+)",ln)
    if m: t.append(int(m[1]));lost.append(int(m[2]));ber.append(float(m[3]))
t=np.array(t);lost=np.array(lost)
a=ax[0,0]; a.plot(t,np.gradient(lost,t),"o-",color="crimson",label="lost frames/s")
a.set_title("① The burst is REAL & LIVE on 148 (forward QPSK link)")
a.set_xlabel("time (s)");a.set_ylabel("lost frames / s",color="crimson");a.tick_params(axis='y',labelcolor="crimson")
a2=a.twinx();a2.plot(t,ber,"s--",color="navy",alpha=.6,label="BER");a2.set_ylabel("forward BER",color="navy")
a.text(.5,.05,f"~5e-4 aggregate BER (incl. thin-margin non-tick loss); reverse/clean 146 ~2e-6",transform=a.transAxes,ha="center",fontsize=8.5,style="italic")

# P2: BBDC active — DC on vs off (from phaseA tap)
dcON =abs(np.mean(load(pA+"tap_bbdcON.bin")))
dcOFF=abs(np.mean(load(pA+"tap_bbdcOFF.bin")))
a=ax[0,1];a.bar(["BBDC tracking\nON","BBDC tracking\nOFF"],[dcON,dcOFF],color=["seagreen","darkorange"])
a.set_title("② The BBDC calibration IS active & correcting on 148")
a.set_ylabel("|residual DC| at AGC-out tap (LSB)")
for i,v in enumerate([dcON,dcOFF]): a.text(i,v,f"{v:.1f}",ha="center",va="bottom",fontweight="bold")
a.text(.5,.8,f"{dcOFF/dcON:.0f}× DC when the cal is disabled\n→ the cal is doing real work",transform=a.transAxes,ha="center",fontsize=9,style="italic")

# P3: data-domain BLIND — lag-256 coherence, real tick vs synthetic repeat
def coh(x,LAG=256,W=256):
    y=x[LAG:]*np.conj(x[:-LAG]); pw=np.abs(x[LAG:])**2
    return np.abs(movsum(y,W))/(movsum(pw,W)+1e-9)
def blockmax(c,bw):  # preserve 256-wide coherence peaks
    m=(len(c)//bw)*bw; return c[:m].reshape(-1,bw).max(1)
BW=int(0.02*FS)
xr=load(pA+"tap_bbdcON.bin"); cr=blockmax(coh(xr),BW); tr=np.arange(len(cr))*BW/FS
# synthetic reference with true 256-repeats every 1.489s
np.random.seed(1);s=np.repeat(np.exp(1j*(np.pi/4+np.pi/2*np.random.randint(0,4,12*240000))),8)
xi=list(s);pos=int(0.7*FS)
while pos<len(s)-512: xi[pos:pos]=list(s[pos-256:pos]);pos+=int(1.489*FS)
xi=np.array(xi)[:len(s)];cs=blockmax(coh(xi),BW);ts=np.arange(len(cs))*BW/FS
a=ax[1,0]
a.plot(ts,cs,"o-",ms=3,color="gray",lw=.8,label="synthetic: TRUE 256-sample repeats @1.489s → coh→1.0")
a.plot(tr,cr,"o-",ms=3,color="crimson",lw=.8,label="REAL 148 AGC-out tap (metronomic tick ~8/12s)")
a.axhline(1.0,ls=":",color="gray");a.set_ylim(0,1.15)
a.text(0.72,1.02,"← true repeats",color="gray",fontsize=8)
a.set_title("③ The burst is NOT in the delivered IQ data (tap is blind)")
a.set_xlabel("time (s)");a.set_ylabel("lag-256 coherence")
a.legend(fontsize=8,loc="upper right")
a.text(.5,.06,"tick is metronomic/LO-driven at 0.67/s → ~8 events MUST fall in 12 s (SNR-independent),\nyet NO coherent 256-repeat appears → a sample-delivery INDEX jump, invisible to any IQ snoop",
       transform=a.transAxes,ha="center",fontsize=8.5,style="italic")

# P4: tone null at tick freq
xt=load(pB+"tone_bbdcON.bin");n=len(xt)
N=1<<20;X=np.fft.fft(xt[:N]*np.hanning(N));f0=np.fft.fftfreq(N,1/FS)[np.argmax(np.abs(X))]
base=xt*np.exp(-1j*2*np.pi*f0*np.arange(n)/FS);B=960;m=(n//B)*B;br=base[:m].reshape(-1,B)
te=np.abs(br-br.mean(1,keepdims=True)).max(1);te=te-te.mean()
S=np.abs(np.fft.rfft(te*np.hanning(len(te))));fr=np.fft.rfftfreq(len(te),B/FS)
a=ax[1,1];band=(fr>=0.2)&(fr<=3.0)
a.semilogy(fr[band],S[band],color="teal",lw=.9)
a.axvline(1/1.489,color="crimson",ls="--",label="tick rate 0.672 Hz (1.489 s)")
a.set_title("④ Tones attempted — cannot image this fault (negative 'if possible')")
a.set_xlabel("frequency (Hz)");a.set_ylabel("tone tracking-error spectrum")
a.legend(fontsize=8)
a.text(.5,.06,"a tone can't lock the modem (no tick witness) AND the cal was abnormal here\n(tap |DC|=195 tracking-ON vs 0.83 on QPSK) → NO signal-domain conclusion is drawn",
       transform=a.transAxes,ha="center",fontsize=8.5,style="italic")

plt.tight_layout(rect=[0,0,1,0.95])
out=SP+"tick_calibration_proof.png";plt.savefig(out,dpi=115);print("wrote",out)
print(f"DC contrast: ON={dcON:.2f} OFF={dcOFF:.2f}  tone f0={f0/1e3:.1f}kHz")
