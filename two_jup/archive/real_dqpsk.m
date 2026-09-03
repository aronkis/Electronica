function real_dqpsk(capfile)
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
C=commhdlQPSKTxRxParameters(); pre=C.preambleSymbols(:); nPre=numel(pre);
refpay=load('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt'); rp=refpay(:,1)+1j*refpay(:,2);
paySyms=numel(rp); frameLen=nPre+paySyms; sps=8; Rsym=240e3;
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end);Q=raw(2:2:end);n=min(numel(I),numel(Q));x=double(I(1:n))+1j*double(Q(1:n)); x=x(abs(x)>0); x=x/rms(abs(x));
h=rcosdesign(0.5,4,sps); mf=conv(x,h,'same');
ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
sy=ssy(mf); sy=sy(:)/rms(abs(sy))*rms(abs(pre));
N=2^floor(log2(numel(sy))); w=sy(1:N).^4; W=fftshift(abs(fft(w.*hann(N)))); fax=linspace(-Rsym/2,Rsym/2,N);
[~,k]=max(W); f4=fax(k)/4; sy=sy.*exp(-1j*2*pi*f4/Rsym*(0:numel(sy)-1).');   % full-range CFO
dps=pre(2:end).*conj(pre(1:end-1)); ds=sy(2:end).*conj(sy(1:end-1));
cc=abs(conv(ds,conj(flipud(dps)))); cc=cc/max(cc);
[pkv,pk]=findpeaks(cc,'MinPeakHeight',0.5,'MinPeakDistance',round(0.6*frameLen));
ps=pk-(nPre-2); keep=ps>=1 & ps+frameLen-1<=numel(sy); ps=ps(keep);
dg=rp(2:end).*conj(rp(1:end-1)); bg=pskdemod(dg,4,0,'gray');
bg_coh=pskdemod(rp,4,pi/4,'gray');
cs=[]; dser=[];
for i=1:numel(ps)
  fr=sy(ps(i):ps(i)+frameLen-1); pay=fr(nPre+1:end);
  Zc=sum(fr(1:nPre).*conj(pre)); p2=pay*conj(Zc)/abs(Zc);
  cs(end+1)=min(arrayfun(@(rr) mean(pskdemod(p2*exp(-1j*deg2rad(rr)),4,pi/4,'gray')~=bg_coh),[0 90 180 270]));
  d=pay(2:end).*conj(pay(1:end-1));
  dser(end+1)=min(arrayfun(@(rr) mean(pskdemod(d*exp(-1j*deg2rad(rr)),4,0,'gray')~=bg),[0 90 180 270]));
end
fprintf('%-22s frames=%d  COHERENT SER=%.3f   DIFFERENTIAL(DQPSK) SER=%.3f\n',regexprep(capfile,'.*/',''),numel(ps),median(cs),median(dser));
end
