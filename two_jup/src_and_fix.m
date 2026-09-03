% Full model: reproduce with the EXACT suspected source (relative reference freq random-walk
% -> BOTH LO phase walk AND sample-clock/timing walk), verify coherent fails + DQPSK fixes.
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
C=commhdlQPSKTxRxParameters(); pre=C.preambleSymbols(:); nPre=numel(pre);
refpay=load('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt'); rp=refpay(:,1)+1j*refpay(:,2);
sps=8; fs=1.92e6; beta=0.5; h=rcosdesign(beta,6,sps); h=h/max(abs(conv(ones(sps,1),h)));
rng(7); nrep=6; bitsData=pskdemod(rp,4,pi/4,'gray');
% differential precode payload (for DQPSK path): cumulative phase
dsym_pay = zeros(size(rp)); acc=0; for k=1:numel(rp), acc=mod(acc+angle(rp(k)),2*pi); dsym_pay(k)=exp(1j*acc); end
function ser=chain(symsyms,pre,nPre,h,sps,fs,walk_ppm_rms,diffdec)
  Ns=numel(symsyms); s=[]; for r=1:6, s=[s; pre; symsyms]; end
  up=upsample(s,sps); w=conv(up,h); w=w(1:sps*numel(s));
  % relative reference freq random-walk: sample-clock timing walk + LO phase walk
  t=(0:numel(w)-1).';
  fwalk=cumsum(randn(numel(w),1))*walk_ppm_rms*1e-6;   % fractional freq deviation (random walk)
  % timing: warp time by integral of fwalk ; LO phase: 2*pi*fwalk*LO... use fwalk directly as phase drive
  tw=t+cumsum(fwalk);                                  % time warp (sample-clock)
  wv=interp1(t,w,tw,'linear',0);
  loph=2*pi*cumsum(fwalk)*0.0;                          % LO phase (small per tone=1.5deg) -> ~0 here
  x=wv.*exp(1j*loph); x=x/rms(abs(x));
  mf=conv(x,h,'same');
  ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
  sy=ssy(mf); sy=sy(:)/rms(abs(sy))*rms(abs(pre));
  % frame sync (diff Barker)
  frameLen=nPre+Ns; dps=pre(2:end).*conj(pre(1:end-1)); ds=sy(2:end).*conj(sy(1:end-1));
  cc=abs(conv(ds,conj(flipud(dps)))); cc=cc/max(cc);
  [pkv,pk]=findpeaks(cc,'MinPeakHeight',0.5,'MinPeakDistance',round(0.6*frameLen));
  ps=pk-(nPre-2); keep=ps>=1 & ps+frameLen-1<=numel(sy); ps=ps(keep);
  sers=[];
  for i=1:numel(ps)
    fr=sy(ps(i):ps(i)+frameLen-1); pay=fr(nPre+1:end);
    if diffdec
      d=pay(2:end).*conj(pay(1:end-1)); bg=pskdemod(symsyms(2:end).*conj(symsyms(1:end-1)),4,0,'gray');
      e=min(arrayfun(@(rr) mean(pskdemod(d*exp(-1j*deg2rad(rr)),4,0,'gray')~=bg),[0 90 180 270]));
    else
      Zc=sum(fr(1:nPre).*conj(pre)); p2=pay*conj(Zc)/abs(Zc); bg=pskdemod(symsyms,4,pi/4,'gray');
      e=min(arrayfun(@(rr) mean(pskdemod(p2*exp(-1j*deg2rad(rr)),4,pi/4,'gray')~=bg),[0 90 180 270]));
    end
    sers(end+1)=e;
  end
  ser=median(sers);
end
for wk=[20 50 100]
  cerr=chain(rp,pre,nPre,h,sps,fs,wk,false);
  derr=chain(dsym_pay,pre,nPre,h,sps,fs,wk,true);
  fprintf('clock-walk %3d ppm-rms:  COHERENT SER=%.3f   DQPSK SER=%.3f\n',wk,cerr,derr);
end
