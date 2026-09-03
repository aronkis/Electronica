function sym_analysis(capfile)
% Extract one good frame's payload symbols from a capture, compare to ref_paysym,
% and characterize the failure: symbol-error rate + per-symbol phase drift across the
% frame (spiral=phase noise the carrier loop can't hold; blob=SNR; match=bit-domain).
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
C=commhdlQPSKTxRxParameters(); pre=C.preambleSymbols(:); nPre=numel(pre);
refpay=load('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt'); refpay=refpay(:,1)+1j*refpay(:,2);
paySyms=numel(refpay); frameLenSym=nPre+paySyms; sps=8; Fs=1.92e6; Rsym=240e3;
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); nn=min(numel(I),numel(Q)); iq=double(I(1:nn))+1j*double(Q(1:nn));
iq=iq(abs(iq)>0); iq=iq/rms(abs(iq));
h=rcosdesign(0.5,4,sps); mf=conv(iq,h,'same');
% timing recovery + coarse CFO (like soak_decode)
ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
sy=ssy(mf); sy=sy(:)/rms(abs(sy))*rms(abs(pre));
N=2^floor(log2(numel(sy))); w=sy(1:N).^4; W=fftshift(abs(fft(w.*hann(N)))); fax=linspace(-Rsym/2,Rsym/2,N);
mask=abs(fax)<5e3; W(~mask)=0; [~,k]=max(W); f4=fax(k)/4;
sy=sy.*exp(-1j*2*pi*f4/Rsym*(0:numel(sy)-1).');
% carrier sync
csy=comm.CarrierSynchronizer('Modulation','QPSK','SamplesPerSymbol',1,'DampingFactor',1/sqrt(2),'NormalizedLoopBandwidth',0.01);
symC=csy(sy); symC=symC(:)/rms(abs(symC))*rms(abs(pre));
% frame sync: differential Barker peak
dps=pre(2:end).*conj(pre(1:end-1)); dsy=symC(2:end).*conj(symC(1:end-1));
cc=abs(conv(dsy,conj(flipud(dps)))); cc=cc/max(cc);
[pkv,pk]=findpeaks(cc,'MinPeakHeight',0.5,'MinPeakDistance',round(0.6*frameLenSym));
ps0=pk-(nPre-2); keep=ps0>=1 & ps0+frameLenSym-1<=numel(symC); ps0=ps0(keep); pkv=pkv(keep);
[~,bi]=max(pkv); s0=ps0(bi);   % best frame
fr=symC(s0:s0+frameLenSym-1); prc=fr(1:nPre); payr=fr(nPre+1:end);
% preamble-derotate (constant phase)
Zc=sum(prc.*conj(pre)); r0=conj(Zc)/abs(Zc); payr=payr*r0;
% resolve the 4-fold QPSK ambiguity against ref (pick rotation minimizing symbol error)
bests=Inf; bestp=payr;
for rr=[0 90 180 270]
  p=payr*exp(-1j*deg2rad(rr));
  % also allow conj (I/Q swap)
  for sw=0:1
    pp=p; if sw, pp=conj(pp); end
    e=mean(sign(round(angle(pp.*conj(refpay))/(pi/2)))~=0); % crude
    d=mean(abs(pskdemod(pp,4,pi/4,'gray')-pskdemod(refpay,4,pi/4,'gray'))>0);
    if d<bests, bests=d; bestp=pp; end
  end
end
% symbol error rate vs ref
ser=mean(pskdemod(bestp,4,pi/4,'gray')~=pskdemod(refpay,4,pi/4,'gray'));
% phase drift across payload: angle of rx.*conj(ref) (should be ~const if link ok)
resid=bestp.*conj(refpay); resid=resid/rms(abs(resid));
phdrift=unwrap(angle(resid));
fprintf('\n=== %s ===\n', capfile);
fprintf('frames found=%d, best preamble corr=%.2f, coarseCFO=%.0f Hz\n', numel(ps0), max(pkv), f4);
fprintf('PAYLOAD symbol-error-rate vs ref_paysym = %.3f  (0=perfect symbols, 0.75=random)\n', ser);
fprintf('phase drift across %d payload symbols: total=%.0f deg, std=%.0f deg\n', paySyms, rad2deg(phdrift(end)-phdrift(1)), rad2deg(std(phdrift)));
fprintf('constellation |resid| spread (EVM proxy) = %.1f%%\n', 100*std(abs(resid)));
fprintf('DIAGNOSIS: ');
if ser<0.05, fprintf('SYMBOLS MATCH -> link fine, bit-domain issue\n');
elseif abs(rad2deg(phdrift(end)-phdrift(1)))>180 || rad2deg(std(phdrift))>40, fprintf('PHASE SPIRAL -> LO phase noise carrier loop cannot hold\n');
else, fprintf('DIFFUSE/RANDOM -> SNR/EVM or structural\n'); end
end
