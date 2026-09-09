function test_eq(capfile)
% Does an adaptive equalizer recover the payload? If yes -> ISI/frequency-selective channel
% is the root cause and an Rx equalizer is the fix. Trains a linear + DFE equalizer on the
% known frame (preamble + ref payload), reports payload SER before/after.
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
C=commhdlQPSKTxRxParameters(); pre=C.preambleSymbols(:); nPre=numel(pre);
refpay=load('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt'); refpay=refpay(:,1)+1j*refpay(:,2);
paySyms=numel(refpay); frameLenSym=nPre+paySyms; sps=8; Rsym=240e3; demref=pskdemod(refpay,4,pi/4,'gray');
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); nn=min(numel(I),numel(Q)); iq=double(I(1:nn))+1j*double(Q(1:nn));
iq=iq(abs(iq)>0); iq=iq/rms(abs(iq)); h=rcosdesign(0.5,4,sps); mf=conv(iq,h,'same');
ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
sy=ssy(mf); sy=sy(:)/rms(abs(sy))*rms(abs(pre));
M=2^floor(log2(numel(sy))); w=sy(1:M).^4; W=fftshift(abs(fft(w.*hann(M)))); fax=linspace(-Rsym/2,Rsym/2,M);
W(abs(fax)>=5e3)=0; [~,k]=max(W); f4=fax(k)/4; sy=sy.*exp(-1j*2*pi*f4/Rsym*(0:numel(sy)-1).');
dps=pre(2:end).*conj(pre(1:end-1)); dsy=sy(2:end).*conj(sy(1:end-1));
cc=abs(conv(dsy,conj(flipud(dps)))); cc=cc/max(cc);
[pkv,pk]=findpeaks(cc,'MinPeakHeight',0.5,'MinPeakDistance',round(0.6*frameLenSym));
ps0=pk-(nPre-2); keep=ps0>=1 & ps0+frameLenSym-1<=numel(sy); ps0=ps0(keep); pkv=pkv(keep);
[~,bi]=max(pkv); s0=ps0(bi); fr=sy(s0:s0+frameLenSym-1);
Zc=sum(fr(1:nPre).*conj(pre)); fr=fr*conj(Zc)/abs(Zc);   % constant derotate
% known reference for the whole frame (preamble + payload)
reffull=[pre; refpay];
% baseline SER (payload)
pay0=fr(nPre+1:end); ser0=mean(pskdemod(pay0,4,pi/4,'gray')~=demref);
fprintf('\n=== %s ===  baseline payload SER=%.3f\n',capfile,ser0);
% --- Linear equalizer (LMS), trained on the full known frame ---
for ntaps=[5 11 21 31]
  eq=comm.LinearEqualizer('Algorithm','LMS','NumTaps',ntaps,'StepSize',0.01, ...
       'ReferenceTap',ceil(ntaps/2),'Constellation',unique(refpay));
  y=eq(fr, reffull);              % train on full frame (data-aided)
  pay=y(nPre+1:end);
  ser=mean(pskdemod(pay,4,pi/4,'gray')~=demref);
  fprintf('  LinearEq %2d taps: payload SER=%.3f\n', ntaps, ser);
end
% --- DFE ---
try
  dfe=comm.DecisionFeedbackEqualizer('Algorithm','LMS','NumForwardTaps',15,'NumFeedbackTaps',10, ...
       'StepSize',0.01,'ReferenceTap',8,'Constellation',unique(refpay));
  y=dfe(fr,reffull); pay=y(nPre+1:end);
  fprintf('  DFE 15/10: payload SER=%.3f\n', mean(pskdemod(pay,4,pi/4,'gray')~=demref));
catch e; fprintf('  DFE err: %s\n',e.message); end
fprintf('(SER->~0 with an equalizer => ISI/frequency-selective channel confirmed; equalizer is the fix)\n');
end
