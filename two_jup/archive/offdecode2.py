import numpy as np, sys
pre=np.loadtxt('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_presym.txt',delimiter=','); pre=pre[:,0]+1j*pre[:,1]
sps=8; fs=1.92e6; frameLen=1133
def rrc(beta,span,sps):
    N=span*sps; t=(np.arange(N+1)-N/2)/sps; h=np.zeros_like(t)
    for i,ti in enumerate(t):
        if abs(ti)<1e-8: h[i]=1-beta+4*beta/np.pi
        elif beta>0 and abs(abs(ti)-1/(4*beta))<1e-8: h[i]=(beta/np.sqrt(2))*((1+2/np.pi)*np.sin(np.pi/(4*beta))+(1-2/np.pi)*np.cos(np.pi/(4*beta)))
        else: h[i]=(np.sin(np.pi*ti*(1-beta))+4*beta*ti*np.cos(np.pi*ti*(1+beta)))/(np.pi*ti*(1-(4*beta*ti)**2))
    return h/np.sqrt(np.sum(h**2))
h=rrc(0.5,4,sps)
d=np.fromfile(sys.argv[1],dtype=np.int16); I=d[0::2].astype(float); Q=d[1::2].astype(float); n=min(len(I),len(Q)); x=I[:n]+1j*Q[:n]
x=x-np.mean(x); x=x/np.sqrt(np.mean(np.abs(x)**2)); mf=np.convolve(x,h,'same')
N=1<<int(np.floor(np.log2(len(mf)))); w=mf[:N]**4
W=np.abs(np.fft.fftshift(np.fft.fft(w*np.hanning(N)))); fax=np.linspace(-fs/2,fs/2,N); f4=fax[np.argmax(W)]/4
mfc=mf*np.exp(-1j*2*np.pi*f4/fs*np.arange(len(mf)))
dpre=pre[1:]*np.conj(pre[:-1])       # differential preamble (CFO-robust)
best=(0,0,None)
for ph in range(sps):
    sym=mfc[ph::sps]
    dsym=sym[1:]*np.conj(sym[:-1])
    c=np.abs(np.correlate(dsym,dpre,'valid'))/ (np.sqrt(np.mean(np.abs(dsym)**2))*len(dpre)+1e-9)
    r=c.max()/(np.median(c)+1e-9)
    if r>best[0]: best=(r,ph,c)
r,ph,c=best
# count frames: peaks above 0.5*max spaced ~frameLen apart
thr=0.5*c.max(); pk=[i for i in range(1,len(c)-1) if c[i]>thr and c[i]>=c[i-1] and c[i]>c[i+1]]
# keep peaks ~frameLen apart
frames=0; last=-9999
for i in sorted(pk):
    if i-last>0.6*frameLen: frames+=1; last=i
print(f"{sys.argv[1].split('/')[-1]}: CFO={f4:+.0f}Hz diffBarker peak/median={r:.1f} phase={ph} frames~{frames} (expect ~{len(mfc[ph::sps])//frameLen})")
