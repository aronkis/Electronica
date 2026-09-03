function evenodd(capfile)
% Test the "every-other DAC sample corrupt" (bad i1/q1 2nd sample) hypothesis.
% de-interleave even/odd complex samples; blind EVM on each half + spectrum for Nyquist energy.
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end);Q=raw(2:2:end);n=min(numel(I),numel(Q));x=double(I(1:n))+1j*double(Q(1:n)); x=x(abs(x)>0); x=x/rms(abs(x));
% spectrum: look for energy near +/- fs/2 (alternating-sample garbage shows as Nyquist content)
N=2^floor(log2(numel(x))); X=fftshift(abs(fft(x(1:N).*hann(N)))); f=linspace(-0.5,0.5,N);
band=@(lo,hi) 20*log10(rms(X(f>=lo & f<hi))+1e-9);
fprintf('%-20s  spectrum: center[-.1,.1]=%.1f  mid[.2,.35]=%.1f  NYQ[.4,.5]=%.1f dB\n', regexprep(capfile,'.*/',''), band(-0.1,0.1), band(0.2,0.35), band(0.4,0.5));
% even/odd blind EVM (each half is at fs/2, sps=4 for a 15.36MHz cap of 1.92Msym)
ev=x(1:2:end); od=x(2:2:end);
for tag={'even(i0/q0)',ev; 'odd(i1/q1)',od}, s=tag{2}; 
  h=rcosdesign(0.5,4,4); mf=conv(s,h,'same');
  ss=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',4); sy=ss(mf); sy=sy/rms(abs(sy));
  M=2^floor(log2(numel(sy))); w=sy(1:M).^4; W=fftshift(abs(fft(w.*hann(M)))); fa=linspace(-1.92e6/2,1.92e6/2,M);
  [~,k]=max(W); f4=fa(k)/4; sy=sy.*exp(-1j*2*pi*f4/1.92e6*(0:numel(sy)-1).');
  cs=comm.CarrierSynchronizer('Modulation','QPSK','SamplesPerSymbol',1,'NormalizedLoopBandwidth',0.02); z=cs(sy); z=z(end/4:end); z=z/rms(abs(z));
  ref=exp(1j*(pi/4+pi/2*round((angle(z)-pi/4)/(pi/2)))); evm=rms(z-ref)/rms(ref);
  fprintf('   %-12s blind EVM=%.1f%%\n', tag{1}, 100*evm);
end
end
