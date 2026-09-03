function test_phasetrack(capfile)
% Does IDEAL phase tracking recover the payload? If yes -> pilots/phase-tracking is the fix.
% Also test realistic PILOT-AIDED tracking (pilot every P symbols, linear interp) vs pilot spacing.
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
C=commhdlQPSKTxRxParameters(); pre=C.preambleSymbols(:); nPre=numel(pre);
refpay=load('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt'); refpay=refpay(:,1)+1j*refpay(:,2);
paySyms=numel(refpay); frameLenSym=nPre+paySyms; sps=8; Rsym=240e3;
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); nn=min(numel(I),numel(Q)); iq=double(I(1:nn))+1j*double(Q(1:nn));
iq=iq(abs(iq)>0); iq=iq/rms(abs(iq)); h=rcosdesign(0.5,4,sps); mf=conv(iq,h,'same');
ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
sy=ssy(mf); sy=sy(:)/rms(abs(sy))*rms(abs(pre));
N=2^floor(log2(numel(sy))); w=sy(1:N).^4; W=fftshift(abs(fft(w.*hann(N)))); fax=linspace(-Rsym/2,Rsym/2,N);
mask=abs(fax)<5e3; W(~mask)=0; [~,k]=max(W); f4=fax(k)/4; sy=sy.*exp(-1j*2*pi*f4/Rsym*(0:numel(sy)-1).');
dps=pre(2:end).*conj(pre(1:end-1)); dsy=sy(2:end).*conj(sy(1:end-1));
cc=abs(conv(dsy,conj(flipud(dps)))); cc=cc/max(cc);
[pkv,pk]=findpeaks(cc,'MinPeakHeight',0.5,'MinPeakDistance',round(0.6*frameLenSym));
ps0=pk-(nPre-2); keep=ps0>=1 & ps0+frameLenSym-1<=numel(sy); ps0=ps0(keep); pkv=pkv(keep);
[~,bi]=max(pkv); s0=ps0(bi); fr=sy(s0:s0+frameLenSym-1); pay=fr(nPre+1:end);
Zc=sum(fr(1:nPre).*conj(pre)); pay=pay*conj(Zc)/abs(Zc);   % constant preamble derotate
demref=pskdemod(refpay,4,pi/4,'gray');
ser=@(p) mean(pskdemod(p,4,pi/4,'gray')~=demref);
fprintf('\n=== %s ===\n',capfile);
fprintf('baseline (const phase) payload SER = %.3f\n', ser(pay));
% IDEAL: use the true symbols to get per-symbol phase, remove it (genie phase tracking)
phi_true = angle(pay.*conj(refpay));
pay_ideal = pay.*exp(-1j*phi_true);
fprintf('GENIE ideal phase-track SER = %.3f  (0 => phase is the WHOLE problem -> pilots fix it)\n', ser(pay_ideal));
% amplitude-only check: if genie fixes phase but SER still high -> amplitude/AWGN remains
% PILOT-AIDED: every P-th payload symbol is a known pilot; estimate phase there, linear-interp
for P=[8 16 32 64]
  idx=1:P:paySyms; ph_pilot=angle(pay(idx).*conj(refpay(idx)));  % phase at pilots (known)
  ph_pilot=unwrap(ph_pilot);
  ph_interp=interp1(idx, ph_pilot, 1:paySyms, 'linear','extrap').';
  pay_pa=pay.*exp(-1j*ph_interp);
  % exclude pilot positions from data SER (they'd be overhead)
  datamask=true(paySyms,1); datamask(idx)=false;
  fprintf('  pilot every %2d syms (%.1f%% overhead): data SER = %.3f\n', P, 100/P, ...
      mean(pskdemod(pay_pa(datamask),4,pi/4,'gray')~=demref(datamask)));
end
fprintf('(if pilot-aided SER -> ~0 at reasonable spacing, a pilot-tracking modem fixes the phase-noise link)\n');
end
