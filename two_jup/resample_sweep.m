function resample_sweep(capfile)
% Test the sample-rate-offset hypothesis: resample the raw IQ by (1+ppm), then decode.
% If a specific ppm makes the payload SER->0, the two clocks have that rate offset and
% correcting it (resample / rate-tracking timing) is the fix.
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
C=commhdlQPSKTxRxParameters(); pre=C.preambleSymbols(:); nPre=numel(pre);
refpay=load('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt'); refpay=refpay(:,1)+1j*refpay(:,2);
paySyms=numel(refpay); frameLenSym=nPre+paySyms; sps=8; Rsym=240e3; demref=pskdemod(refpay,4,pi/4,'gray');
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); nn=min(numel(I),numel(Q)); iq0=double(I(1:nn))+1j*double(Q(1:nn));
iq0=iq0(abs(iq0)>0); iq0=iq0/rms(abs(iq0));
h=rcosdesign(0.5,4,sps);
fprintf('\n=== resample sweep on %s ===\n',capfile);
for ppm=[-2000 -1000 -500 -200 -100 -50 0 50 100 200 500 1000 2000]
  r=1+ppm*1e-6;
  % resample by ratio r via interpolation
  t=(0:numel(iq0)-1); tq=(0:1/r:t(end)); iq=interp1(t,iq0,tq,'linear').';
  mf=conv(iq,h,'same');
  ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
  sy=ssy(mf); sy=sy(:)/rms(abs(sy))*rms(abs(pre));
  M=2^floor(log2(numel(sy))); w=sy(1:M).^4; W=fftshift(abs(fft(w.*hann(M)))); fax=linspace(-Rsym/2,Rsym/2,M);
  W(abs(fax)>=5e3)=0; [~,k]=max(W); f4=fax(k)/4; sy=sy.*exp(-1j*2*pi*f4/Rsym*(0:numel(sy)-1).');
  dps=pre(2:end).*conj(pre(1:end-1)); dsy=sy(2:end).*conj(sy(1:end-1));
  cc=abs(conv(dsy,conj(flipud(dps)))); cc=cc/max(cc);
  [pkv,pk]=findpeaks(cc,'MinPeakHeight',0.5,'MinPeakDistance',round(0.6*frameLenSym));
  ps0=pk-(nPre-2); keep=ps0>=1 & ps0+frameLenSym-1<=numel(sy); ps0=ps0(keep); pkv=pkv(keep);
  if isempty(ps0), fprintf('  %+6d ppm: no frames\n',ppm); continue; end
  sers=zeros(numel(ps0),1);
  for fi=1:numel(ps0)
    fr=sy(ps0(fi):ps0(fi)+frameLenSym-1); Zc=sum(fr(1:nPre).*conj(pre)); pay=fr(nPre+1:end)*conj(Zc)/abs(Zc);
    best=Inf; for rr=[0 90 180 270], for sw=0:1
      pp=pay*exp(-1j*deg2rad(rr)); if sw,pp=conj(pp);end
      d=mean(pskdemod(pp,4,pi/4,'gray')~=demref); if d<best,best=d;end
    end,end
    sers(fi)=best;
  end
  fprintf('  %+6d ppm: frames=%d  median payload SER=%.3f  best=%.3f\n',ppm,numel(ps0),median(sers),min(sers));
end
fprintf('(a clear SER dip at some ppm = sample-rate offset confirmed; flat high = not rate offset)\n');
end
