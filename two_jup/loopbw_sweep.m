function loopbw_sweep(capfile)
% Sweep the carrier-sync loop bandwidth on a real capture: does a faster loop track the
% LO phase noise (payload symbol-error-rate -> 0)? Decides whether a wider-loop modem
% change fixes it, or the phase noise is untrackable (need a cleaner LO).
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
C=commhdlQPSKTxRxParameters(); pre=C.preambleSymbols(:); nPre=numel(pre);
refpay=load('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt'); refpay=refpay(:,1)+1j*refpay(:,2);
paySyms=numel(refpay); frameLenSym=nPre+paySyms; sps=8; Rsym=240e3;
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); nn=min(numel(I),numel(Q)); iq=double(I(1:nn))+1j*double(Q(1:nn));
iq=iq(abs(iq)>0); iq=iq/rms(abs(iq));
h=rcosdesign(0.5,4,sps); mf=conv(iq,h,'same');
ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
sy0=ssy(mf); sy0=sy0(:)/rms(abs(sy0))*rms(abs(pre));
N=2^floor(log2(numel(sy0))); w=sy0(1:N).^4; W=fftshift(abs(fft(w.*hann(N)))); fax=linspace(-Rsym/2,Rsym/2,N);
mask=abs(fax)<5e3; W(~mask)=0; [~,k]=max(W); f4=fax(k)/4;
sy0=sy0.*exp(-1j*2*pi*f4/Rsym*(0:numel(sy0)-1).');
fprintf('\n=== loop-BW sweep on %s (coarseCFO=%.0f Hz) ===\n',capfile,f4);
for bw=[0.01 0.02 0.05 0.10 0.20 0.40]
  csy=comm.CarrierSynchronizer('Modulation','QPSK','SamplesPerSymbol',1,'DampingFactor',1/sqrt(2),'NormalizedLoopBandwidth',bw);
  symC=csy(sy0); symC=symC(:)/rms(abs(symC))*rms(abs(pre));
  dps=pre(2:end).*conj(pre(1:end-1)); dsy=symC(2:end).*conj(symC(1:end-1));
  cc=abs(conv(dsy,conj(flipud(dps)))); cc=cc/max(cc);
  [pkv,pk]=findpeaks(cc,'MinPeakHeight',0.5,'MinPeakDistance',round(0.6*frameLenSym));
  ps0=pk-(nPre-2); keep=ps0>=1 & ps0+frameLenSym-1<=numel(symC); ps0=ps0(keep); pkv=pkv(keep);
  if isempty(ps0), fprintf('  BW=%.2f : no frames\n',bw); continue; end
  sers=zeros(numel(ps0),1);
  for fi=1:numel(ps0)
    fr=symC(ps0(fi):ps0(fi)+frameLenSym-1); prc=fr(1:nPre); payr=fr(nPre+1:end);
    Zc=sum(prc.*conj(pre)); payr=payr*conj(Zc)/abs(Zc);
    best=Inf;
    for rr=[0 90 180 270], for sw=0:1
      pp=payr*exp(-1j*deg2rad(rr)); if sw, pp=conj(pp); end
      d=mean(pskdemod(pp,4,pi/4,'gray')~=pskdemod(refpay,4,pi/4,'gray')); if d<best,best=d; end
    end, end
    sers(fi)=best;
  end
  fprintf('  BW=%.2f : frames=%d  median payload SER=%.3f  best=%.3f\n', bw, numel(ps0), median(sers), min(sers));
end
fprintf('(SER->0 at some BW = wider carrier loop FIXES it; stays high = phase noise untrackable)\n');
end
