function determine_source(capfile)
% DATA-AIDED impairment decomposition using the KNOWN golden symbols.
% residual_k = rx_k * conj(golden_k)/|golden_k|^2  = per-symbol complex channel.
% Decompose: mean gain/phase, CFO (linear phase), residual phase noise (correlated?),
% amplitude noise (AWGN?), spurs (FFT of residual), and a LS linear-FIR channel fit.
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
C=commhdlQPSKTxRxParameters(); pre=C.preambleSymbols(:); nPre=numel(pre);
refpay=load('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt'); refpay=refpay(:,1)+1j*refpay(:,2);
paySyms=numel(refpay); frameLenSym=nPre+paySyms; sps=8; Rsym=240e3; gold=[pre;refpay];
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); n=min(numel(I),numel(Q)); x=double(I(1:n))+1j*double(Q(1:n));
x=x(abs(x)>0); x=x/rms(abs(x));
h=rcosdesign(0.5,4,sps); mf=conv(x,h,'same');
ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
sy=ssy(mf); sy=sy(:)/rms(abs(sy))*rms(abs(pre));
N=2^floor(log2(numel(sy))); w=sy(1:N).^4; W=fftshift(abs(fft(w.*hann(N)))); fax=linspace(-Rsym/2,Rsym/2,N);
mask=abs(fax)<8e3; W(~mask)=0; [~,k]=max(W); f4=fax(k)/4; sy=sy.*exp(-1j*2*pi*f4/Rsym*(0:numel(sy)-1).');
dps=pre(2:end).*conj(pre(1:end-1)); dsy=sy(2:end).*conj(sy(1:end-1));
cc=abs(conv(dsy,conj(flipud(dps)))); cc=cc/max(cc);
[pkv,pk]=findpeaks(cc,'MinPeakHeight',0.5,'MinPeakDistance',round(0.6*frameLenSym));
ps0=pk-(nPre-2); keep=ps0>=1 & ps0+frameLenSym-1<=numel(sy); ps0=ps0(keep); pkv=pkv(keep);
[~,bi]=max(pkv); s0=ps0(bi); fr=sy(s0:s0+frameLenSym-1);
% coarse phase align to golden frame (whole-frame)
r0=sum(fr.*conj(gold))/sum(abs(gold).^2); fr=fr/r0;
res = fr.*conj(gold)./max(abs(gold).^2,1e-6);   % per-symbol complex channel (data-aided)
% --- decompose ---
ph=unwrap(angle(res)); kk=(1:numel(res)).';
p=polyfit(kk,ph,1); cfo_hz=p(1)/(2*pi)*Rsym; phlin=polyval(p,kk); phres=ph-phlin;
amp=abs(res);
fprintf('\n=== %s ===  frames=%d bestcorr=%.2f coarseCFO=%.0fHz\n',capfile,numel(ps0),max(pkv),f4);
fprintf('[MAG]  mean|res|=%.2f  amplitude CV=%.1f%%  -> Es/N0~%.1f dB (if AWGN)\n', mean(amp),100*std(amp)/mean(amp), -20*log10(std(amp)/mean(amp)));
fprintf('[CFO]  residual linear freq = %.0f Hz (removable by carrier loop)\n', cfo_hz);
fprintf('[PHASE] after CFO: std=%.1f deg, per-symbol STEP std=%.1f deg\n', rad2deg(std(phres)), rad2deg(std(diff(phres))));
% correlated vs white: autocorrelation of the phase-step at lag1
d=diff(phres); ac1=sum(d(1:end-1).*d(2:end))/sum(d.^2);
fprintf('[PHASE] step autocorr(lag1)=%.2f  (~-0.5 white/AWGN ; ~0..+ correlated=phase-noise/drift)\n', ac1);
% spectral: FFT of residual (spurs / a beating tone?)
M=2^nextpow2(numel(res)); R=fftshift(abs(fft((res-mean(res)).*hann(numel(res)),M)));
fa=linspace(-Rsym/2,Rsym/2,M); [pkr,ir]=max(R);
fprintf('[SPUR] residual dominant tone @ %.0f Hz, %.1f dB over median (>>0 = a discrete beating spur)\n', fa(ir), 20*log10(pkr/median(R)));
% linear FIR channel fit at sps: does a static channel explain it?
Lh=7; A=zeros(numel(fr),Lh); for t=1:Lh, A(:,t)=[zeros(t-1,1); gold(1:end-t+1)]; end
hh=A\fr; eqres=fr-A*hh; fprintf('[LINchan] %d-tap LS fit residual EVM=%.1f%% (low=static linear channel/ISI; high=time-varying/nonlinear)\n', Lh, 100*rms(eqres)/rms(fr));
save(['/tmp/src_' regexprep(capfile,'.*/','') '.mat'],'res','phres','amp','cfo_hz');
end
