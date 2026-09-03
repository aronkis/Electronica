import numpy as np, sys
pre=np.loadtxt('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_presym.txt',delimiter=','); pre=pre[:,0]+1j*pre[:,1]
pay=np.loadtxt('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt',delimiter=','); pay=pay[:,0]+1j*pay[:,1]
frame=np.concatenate([pre,pay])
def rrc(b,s,sp):
    t=np.arange(-s*sp,s*sp+1)/sp; h=np.zeros_like(t,float)
    for i,x in enumerate(t):
        if abs(x)<1e-9: h[i]=1-b+4*b/np.pi
        elif abs(abs(4*b*x)-1)<1e-9: h[i]=b/np.sqrt(2)*((1+2/np.pi)*np.sin(np.pi/(4*b))+(1-2/np.pi)*np.cos(np.pi/(4*b)))
        else: h[i]=(np.sin(np.pi*x*(1-b))+4*b*x*np.cos(np.pi*x*(1+b)))/(np.pi*x*(1-(4*b*x)**2))
    return h/np.sqrt((h**2).sum())
sps=8; h=rrc(0.5,4,sps)
up=np.zeros(len(frame)*sps,dtype=complex); up[::sps]=frame; refw=np.convolve(up,h,'same'); tpl=refw[:300*sps]
d=np.fromfile(sys.argv[1],dtype=np.int16); iq=(d[0::2].astype(float)+1j*d[1::2].astype(float))
if np.abs(iq).mean()<1: print(sys.argv[1],"ZEROS"); sys.exit()
x=(iq/np.maximum(np.abs(iq),1))**4; N=1<<18
sp=np.fft.fftshift(np.abs(np.fft.fft(x[:N]))); fr=np.fft.fftshift(np.fft.fftfreq(N,1/1.92e6)); cfo=fr[np.argmax(sp)]/4
iq=iq*np.exp(-1j*2*np.pi*cfo/1.92e6*np.arange(len(iq)))
y=np.convolve(iq,h,'same')
c=np.abs(np.correlate(y[:400000],tpl,'valid')); k0=int(np.argmax(c[:2*1133*sps]))
ng=nt=0; base=k0
while base+1133*sps<len(y):
    sym=y[base:base+1133*sps:sps][:1133]
    if len(sym)<1133: break
    z=sym.copy()
    for s0 in range(0,1133,50):
        bl=slice(s0,min(s0+50,1133)); z[bl]=sym[bl]*np.exp(-1j*np.angle(np.vdot(frame[bl],sym[bl])))
    zp=z[13:]
    e=min(np.mean((np.real(zp)>0)!=(np.real(pay)>0))+np.mean((np.imag(zp)>0)!=(np.imag(pay)>0)),
          np.mean((np.real(zp)>0)==(np.real(pay)>0))+np.mean((np.imag(zp)>0)==(np.imag(pay)>0)))/2
    nt+=1; ng+= (e<0.002); base+=1133*sps
print(f"{sys.argv[1].split('/')[-1]}: cfo={cfo:.0f}Hz {nt} frames {ng} golden ({100*ng/max(1,nt):.1f}%)")
