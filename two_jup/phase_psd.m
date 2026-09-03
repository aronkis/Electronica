function phase_psd(capfile)
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
C=commhdlQPSKTxRxParameters(); pre=C.preambleSymbols(:); sps=8; Rsym=240e3;
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end);Q=raw(2:2:end);n=min(numel(I),numel(Q));x=double(I(1:n))+1j*double(Q(1:n)); x=x(abs(x)>0); x=x/rms(abs(x));
h=rcosdesign(0.5,4,sps); mf=conv(x,h,'same');
ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
sy=ssy(mf); sy=sy(:);
% mod-removed carrier phase via 4th power
z=sy.^4; ph=unwrap(angle(z))/4; kk=(1:numel(ph)).';
p=polyfit(kk,ph,1); phr=ph-polyval(p,kk);          % remove CFO
stepstd=rad2deg(std(diff(phr)));
% PSD of residual phase (per-symbol)
M=2^nextpow2(numel(phr)); Pf=abs(fft((phr-mean(phr)).*hann(numel(phr)),M)).^2; Pf=Pf(1:M/2);
fq=(0:M/2-1)/M*Rsym;                                % Hz (symbol-rate sampled)
[pk,ip]=max(Pf(2:end)); ip=ip+1;
% slope of PSD in log-log (random walk ~ -2 ; white ~ 0)
lo=find(fq>200 & fq<20e3); sl=polyfit(log10(fq(lo)),log10(Pf(lo)+1e-9),1);
fprintf('%-40s stepstd=%5.1fdeg  PSD peak@%6.0fHz(%4.0fdB over med)  loglog-slope=%+.1f\n',...
  regexprep(capfile,'.*/',''), stepstd, fq(ip), 10*log10(pk/median(Pf)), sl(1));
end
