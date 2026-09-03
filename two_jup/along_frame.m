function along_frame(capfile)
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
C=commhdlQPSKTxRxParameters(); pre=C.preambleSymbols(:); nPre=numel(pre);
rp=load('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt'); rp=rp(:,1)+1j*rp(:,2);
gold=[pre;rp]; paySyms=numel(rp); frameLen=nPre+paySyms; sps=8; Rsym=240e3;
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end);Q=raw(2:2:end);n=min(numel(I),numel(Q));x=double(I(1:n))+1j*double(Q(1:n)); x=x(abs(x)>0); x=x/rms(abs(x));
h=rcosdesign(0.5,4,sps); mf=conv(x,h,'same');
ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
sy=ssy(mf); sy=sy(:)/rms(abs(sy))*rms(abs(pre));
N=2^floor(log2(numel(sy))); w=sy(1:N).^4; W=fftshift(abs(fft(w.*hann(N)))); fax=linspace(-Rsym/2,Rsym/2,N);
[~,k]=max(W); f4=fax(k)/4; sy=sy.*exp(-1j*2*pi*f4/Rsym*(0:numel(sy)-1).');
dps=pre(2:end).*conj(pre(1:end-1)); ds=sy(2:end).*conj(sy(1:end-1));
cc=abs(conv(ds,conj(flipud(dps)))); cc=cc/max(cc);
[pkv,pk]=findpeaks(cc,'MinPeakHeight',0.5,'MinPeakDistance',round(0.6*frameLen));
ps=pk-(nPre-2); keep=ps>=1 & ps+frameLen-1<=numel(sy); ps=ps(keep); pkv=pkv(keep);
[~,bi]=max(pkv); s0=ps(bi); fr=sy(s0:s0+frameLen-1);
r0=sum(fr(1:nPre).*conj(pre))/sum(abs(pre).^2); fr=fr/r0;    % align via preamble
resphase=rad2deg(angle(fr.*conj(gold)));                     % per-symbol phase error (data-aided)
resamp=abs(fr)./abs(gold);
% report windowed stats along the frame
fprintf('\n=== %s : per-symbol error along frame (data-aided vs golden) ===\n',regexprep(capfile,'.*/',''));
edges=[1 14 114 314 614 1133];
for w=1:numel(edges)-1
  seg=edges(w):edges(w+1)-1; lab=sprintf('sym %4d-%4d',edges(w),edges(w+1)-1);
  fprintf('  %s : phase-err std=%6.1f deg  |mean phase|=%6.1f  amp mean=%.2f cv=%.0f%%\n',lab,std(resphase(seg)),abs(mean(resphase(seg))),mean(resamp(seg)),100*std(resamp(seg))/mean(resamp(seg)));
end
% is the preamble itself clean? (sym 1-13)
fprintf('  PREAMBLE(1-13) phase-err std=%.1f deg (small=preamble clean, payload corrupts)\n',std(resphase(1:nPre)));
