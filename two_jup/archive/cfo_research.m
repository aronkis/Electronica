function cfo_research()
% cfo_research  Compare carrier-robust QPSK coarse-CFO estimators against a strong
% CW LO-leakage carrier at band center (reproduces the two-Jupiter la146 failure).
%
% Signal model (baseband, post Rx-LO): r = (s + A)*exp(j2*pi*f0*n) + w
%   s = RRC-shaped QPSK (240 ksym, sps=8, beta=0.5), framed w/ 13-sym Barker preamble
%   A = complex CW carrier (Tx LO leakage), |A| set by carrier-to-signal ratio (dBc)
%   f0 = CFO to estimate; w = AWGN
% Methods compared (all candidates for the HDL Rx Coarse_Frequency_Estimator):
%   M1 blind 4th-power FFT (CURRENT method)
%   M2 DC-notch (remove CW) then 4th-power   -- but carrier sits at f0, not DC...
%   M3 adaptive CW cancel (estimate strongest CW line, subtract) then 4th-power
%   M4 preamble data-aided (differential over the known 13-sym Barker) -- carrier-robust
%   M5 preamble + M3 (cancel CW, then preamble-aided)
rng(1);
sps=8; Rsym=240e3; Fs=sps*Rsym; beta=0.5; span=4;
h=rcosdesign(beta,span,sps); h=h/sqrt(sum(h.^2));
C=commhdlQPSKTxRxParameters(); pre=C.preambleSymbols(:); nPre=numel(pre);
paySyms=1120; frameLenSym=nPre+paySyms;   % 1133
nFrames=6;

% --- build one long framed QPSK symbol stream ---
symsAll=[];
for k=1:nFrames
  pay=exp(1j*(pi/4+pi/2*randi([0 3],paySyms,1)));   % random QPSK payload
  symsAll=[symsAll; pre; pay]; %#ok<AGROW>
end
% pulse shape
up=upsample(symsAll,sps); s=conv(up,h,'same'); s=s/sqrt(mean(abs(s).^2));

f0_true = 0;                       % true CFO ~0 (matches nulled la146)
n=(0:numel(s)-1).';
methods = {'M1 blind4th','M2 dcNotch4th','M3 cancelCW4th','M4 preambleDA','M5 cancel+preDA'};
dBc_list = [-20 -10 -6 -3 0 3];    % carrier-to-signal ratio (0 dBc ~ la146)
snr_db = 15;

fprintf('\n=== CFO estimation error (Hz) vs carrier level ; true f0=%.0f Hz, SNR=%d dB ===\n',f0_true,snr_db);
fprintf('%-16s','carrier dBc:'); fprintf('%8.0f',dBc_list); fprintf('\n');
err=zeros(numel(methods),numel(dBc_list));
for mi=1:numel(methods)
  for di=1:numel(dBc_list)
    A = 10^(dBc_list(di)/20)*exp(1j*2*pi*rand);   % CW carrier, phase random
    r = (s + A).*exp(1j*2*pi*f0_true/Fs*n);
    r = awgn(r, snr_db, 'measured');
    fhat = estimate_cfo(r, methods{mi}, Fs, h, sps, pre, frameLenSym);
    err(mi,di) = fhat - f0_true;
  end
end
for mi=1:numel(methods)
  fprintf('%-16s',methods{mi}); fprintf('%8.0f',err(mi,:)); fprintf('\n');
end
fprintf('\n(good = |err| small across all dBc; robust method should hold near 0 even at 0 dBc)\n');
save('/mnt/onetb/scratch/qpsk_variants/two_jup/cfo_research.mat','methods','dBc_list','err','snr_db');
end

function fhat = estimate_cfo(r, method, Fs, h, sps, pre, frameLenSym)
switch method
  case 'M1 blind4th'
    fhat = fourth_power(r, Fs);
  case 'M2 dcNotch4th'
    r2 = r - mean(r);                    % remove DC (weak: carrier is at f0 not DC pre-tune)
    fhat = fourth_power(r2, Fs);
  case 'M3 cancelCW4th'
    r2 = cancel_cw(r, Fs);
    fhat = fourth_power(r2, Fs);
  case 'M4 preambleDA'
    fhat = preamble_da(r, h, sps, pre, frameLenSym, Fs);
  case 'M5 cancel+preDA'
    r2 = cancel_cw(r, Fs);
    fhat = preamble_da(r2, h, sps, pre, frameLenSym, Fs);
end
end

function f = fourth_power(r, Fs)
N=2^floor(log2(numel(r))); w=r(1:N).^4;
W=fftshift(abs(fft(w.*hann(N)))); fax=linspace(-Fs/2,Fs/2,N);
mask=abs(fax)<Fs/8; W(~mask)=0;                 % constrain (like the golden decoder)
[~,k]=max(W); f=fax(k)/4;
end

function r2 = cancel_cw(r, Fs)
% estimate the single strongest CW line (narrow) and subtract it
N=2^floor(log2(numel(r))); R=fftshift(fft(r(1:N).*hann(N))); fax=linspace(-Fs/2,Fs/2,N);
[~,k]=max(abs(R)); fcw=fax(k);
% LS-fit complex amplitude of a tone at fcw over full length, subtract
n=(0:numel(r)-1).'; e=exp(1j*2*pi*fcw/Fs*n); a=(e'*r)/(e'*e); r2=r-a*e;
end

function f = preamble_da(r, h, sps, pre, frameLenSym, Fs)
% matched filter, symbol-rate decimate (best phase), correlate to Barker, then estimate
% CFO from the phase slope across the detected preamble (data-aided, CW-robust because the
% preamble is a known spread sequence and we use differential of matched preamble product).
mf=conv(r,h,'same'); nPre=numel(pre);
dpre=pre(2:end).*conj(pre(1:end-1));
best=struct('r',0,'ph',0,'idx',0);
for ph=1:sps
  sym=mf(ph:sps:end); sym=sym/sqrt(mean(abs(sym).^2))*sqrt(mean(abs(pre).^2));
  dsym=sym(2:end).*conj(sym(1:end-1));
  c=abs(conv(dsym,conj(flipud(dpre)),'valid'));
  [pk,ix]=max(c);
  if pk>best.r, best=struct('r',pk,'ph',ph,'idx',ix); end
end
sym=mf(best.ph:sps:end); s0=best.idx;
if s0<1||s0+nPre-1>numel(sym), f=0; return; end
p=sym(s0:s0+nPre-1);
% remove known preamble modulation -> residual carrier phase ramp = CFO
z=p.*conj(pre);
dz=z(2:end).*conj(z(1:end-1));
f = angle(mean(dz))/(2*pi) * (Fs/sps);          % per-symbol phase step -> Hz
end
