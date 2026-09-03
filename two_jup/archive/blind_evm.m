function blind_evm(capfile)
% Reference-FREE constellation EVM: are the symbols clean QPSK (contract mismatch)
% or a diffuse blob (real corruption)? Never uses ref_paysym.
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
sps=8; Rsym=240e3;
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end);Q=raw(2:2:end);n=min(numel(I),numel(Q));x=double(I(1:n))+1j*double(Q(1:n)); x=x(abs(x)>0); x=x/rms(abs(x));
h=rcosdesign(0.5,4,sps); mf=conv(x,h,'same');
ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
sy=ssy(mf); sy=sy(:)/rms(abs(sy));
% 4th-power CFO removal (data-independent)
N=2^floor(log2(numel(sy))); w=sy(1:N).^4; W=fftshift(abs(fft(w.*hann(N)))); fax=linspace(-Rsym/2,Rsym/2,N);
[~,k]=max(W); f4=fax(k)/4; sy=sy.*exp(-1j*2*pi*f4/Rsym*(0:numel(sy)-1).');
% carrier sync (blind, decision-directed) to lock the residual phase
csy=comm.CarrierSynchronizer('Modulation','QPSK','SamplesPerSymbol',1,'DampingFactor',1/sqrt(2),'NormalizedLoopBandwidth',0.02);
s=csy(sy); s=s(numel(s)/4:end);  % drop transient
s=s/rms(abs(s));
% nearest QPSK point (pi/4 grid), EVM = rms(err)/rms(ref)
ref=exp(1j*(pi/4+pi/2*round((angle(s)-pi/4)/(pi/2))));
evm=rms(s-ref)/rms(ref);
% also: are the 4 clusters distinct? (spread of the de-rotated symbols)
d=s.*conj(ref);   % should cluster near +1 if clean
fprintf('%-22s  BLIND EVM = %.1f%%   (<~20%%=clean QPSK/contract-mismatch ; >~40%%=corrupted)  in-phase mean=%.2f std=%.2f\n', regexprep(capfile,'.*/',''), 100*evm, mean(real(d)), std(real(d)));
end
