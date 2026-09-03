function phase_traj(capfile)
% Modulation-removed phase trajectory across the payload (artifact-free: does NOT need ref
% symbols). QPSK: sym^4 removes the data -> residual carrier phase phi=(angle(sym^4)-pi)/4.
% Smooth ramp=freq offset; smooth curve=freq drift; noisy=phase noise/SNR. Also checks
% timing (Gardner error proxy) and per-symbol amplitude (SNR).
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
C=commhdlQPSKTxRxParameters(); pre=C.preambleSymbols(:); nPre=numel(pre);
refpay=load('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt'); refpay=refpay(:,1)+1j*refpay(:,2);
paySyms=numel(refpay); frameLenSym=nPre+paySyms; sps=8; Rsym=240e3;
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); nn=min(numel(I),numel(Q)); iq=double(I(1:nn))+1j*double(Q(1:nn));
iq=iq(abs(iq)>0); iq=iq/rms(abs(iq));
h=rcosdesign(0.5,4,sps); mf=conv(iq,h,'same');
ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
sy=ssy(mf); sy=sy(:)/rms(abs(sy))*rms(abs(pre));
N=2^floor(log2(numel(sy))); w=sy(1:N).^4; W=fftshift(abs(fft(w.*hann(N)))); fax=linspace(-Rsym/2,Rsym/2,N);
mask=abs(fax)<5e3; W(~mask)=0; [~,k]=max(W); f4=fax(k)/4;
sy=sy.*exp(-1j*2*pi*f4/Rsym*(0:numel(sy)-1).');
% frame sync (differential Barker)
dps=pre(2:end).*conj(pre(1:end-1)); dsy=sy(2:end).*conj(sy(1:end-1));
cc=abs(conv(dsy,conj(flipud(dps)))); cc=cc/max(cc);
[pkv,pk]=findpeaks(cc,'MinPeakHeight',0.5,'MinPeakDistance',round(0.6*frameLenSym));
ps0=pk-(nPre-2); keep=ps0>=1 & ps0+frameLenSym-1<=numel(sy); ps0=ps0(keep); pkv=pkv(keep);
[~,bi]=max(pkv); s0=ps0(bi);
fr=sy(s0:s0+frameLenSym-1); pay=fr(nPre+1:end);
% modulation-removed residual phase (no ref needed)
phi=(unwrap(angle(pay.^4))-pi)/4;      % rad, residual carrier phase per payload symbol
% detrend: remove best linear (=residual freq) to expose the NON-linear (drift/noise) part
n=(1:paySyms).'; p=polyfit(n,phi,1); lin=polyval(p,n); resid=phi-lin;
resid_freq_hz = p(1)/(2*pi)*Rsym;      % residual linear freq the loop would remove
amp=abs(pay);
fprintf('\n=== %s ===\n',capfile);
fprintf('best preamble corr=%.2f  coarseCFO=%.0fHz\n',max(pkv),f4);
fprintf('MOD-REMOVED residual phase over %d payload symbols:\n',paySyms);
fprintf('  linear part (residual freq) = %.0f Hz  (a carrier loop removes this)\n',resid_freq_hz);
fprintf('  NON-linear part: std=%.1f deg  peak-to-peak=%.0f deg\n',rad2deg(std(resid)),rad2deg(max(resid)-min(resid)));
fprintf('  per-symbol phase-step std (after detrend)=%.1f deg\n',rad2deg(std(diff(resid))));
fprintf('  amplitude CV (SNR proxy)=%.1f%%\n',100*std(amp)/mean(amp));
% verdict
sstep=rad2deg(std(diff(resid)));
if rad2deg(std(resid))<10, fprintf('VERDICT: phase CLEAN after removing a %.0fHz residual -> trackable (loop/CFO fix)\n',resid_freq_hz);
elseif sstep<8, fprintf('VERDICT: smooth phase DRIFT (not per-symbol noise) -> faster/2nd-order tracking or shorter frames\n');
else, fprintf('VERDICT: fast per-symbol phase noise (step std %.1f deg) -> LO phase noise; needs cleaner LO config or pilot-per-symbol\n',sstep); end
end
