function sound_channel(capfile,varargin)
% sound_channel — frame-synchronous LS channel extraction against the KNOWN golden waveform.
% For each detected golden frame in the capture, LS-fit an L-tap FIR h such that
% y ≈ conv(x_golden, h). Reports the delay profile, per-frame residual EVM (how much a
% static linear channel explains), and frame-to-frame h variation (time selectivity).
% Handles: capture 2x-duplication (dec2), wide-range CFO (±50 kHz), 4-quadrant phase.
L = 65;                 % channel taps at sps=8 (±4 symbols)
fs = 1.92e6;
% --- known golden frame (9064 samples @ sps=8) ---
g = fopen('/mnt/onetb/scratch/qpsk_variants/two_jup/golden_tx.iq'); raw = fread(g,Inf,'int16'); fclose(g);
xg = double(raw(1:2:end)) + 1j*double(raw(2:2:end));
FR = 9064; xf = xg(1:FR); xf = xf/rms(abs(xf));
% --- capture (dec2 to the golden domain) ---
fid = fopen(capfile); raw = fread(fid,Inf,'int16'); fclose(fid);
I = raw(1:2:end); Q = raw(2:2:end); n = min(numel(I),numel(Q));
y = double(I(1:n)) + 1j*double(Q(1:n)); y = y(1:2:end);       % dec2
y = y(abs(y)>0); y = y - mean(y); y = y/rms(abs(y));
% --- wide-range CFO (4th power, ±50 kHz) ---
N = 2^floor(log2(min(numel(y),2^18))); w = y(1:N).^4;
W = fftshift(abs(fft(w.*hann(N)))); fax = linspace(-fs/2,fs/2,N);
mask = abs(fax) < 200e3; W(~mask) = 0; [~,k] = max(W); cfo = fax(k)/4;
y = y .* exp(-1j*2*pi*cfo/fs*(0:numel(y)-1).');
fprintf('[snd] %s: %d samp, CFO=%+.0f Hz\n', capfile, numel(y), cfo);
% --- frame sync: FFT correlation with the golden frame ---
M = numel(y); C = ifft( fft(y,2^nextpow2(M)) .* conj(fft([xf; zeros(2^nextpow2(M)-FR,1)])) );
C = abs(C(1:M-FR)); thr = 0.5*max(C);
% peaks at least 0.8*FR apart
pk = []; i = 1;
while i <= numel(C)
  if C(i) > thr
    [~,j] = max(C(i:min(i+FR-1,numel(C)))); pk(end+1) = i+j-1; %#ok<AGROW>
    i = i + j + round(0.8*FR);
  else, i = i + 1; end
end
fprintf('[snd] %d frame hits (spacing med=%.1f, expect %d)\n', numel(pk), median(diff(pk)), FR);
if numel(pk) < 3, fprintf('[snd] TOO FEW FRAMES - correlation failed\n'); return; end
% --- per-frame LS channel fit ---
half = floor((L-1)/2);
X = zeros(FR-L+1, L);
for t = 1:L, X(:,t) = xf(L-t+1 : FR-t+1); end   % convolution matrix (valid region)
Hs = []; evms = []; evms_h1 = []; evms_h2 = [];
XtXi = pinv(X'*X) * X';                          % precompute LS operator
for q = 1:min(numel(pk),40)
  s = pk(q) - half; if s < 1 || s+FR-1 > numel(y), continue; end
  yy = y(s:s+FR-1); yv = yy(L:FR);               % align to the 'valid' rows of X
  if numel(yv) ~= size(X,1), continue; end
  h = XtXi * yv;
  r = yv - X*h; ev = norm(r)/norm(yv);
  % intra-frame split fits (time variation inside a frame)
  m2 = floor(size(X,1)/2);
  h1 = pinv(X(1:m2,:)'*X(1:m2,:))*(X(1:m2,:)'*yv(1:m2));   e1 = norm(yv(1:m2)-X(1:m2,:)*h1)/norm(yv(1:m2));
  h2 = pinv(X(m2+1:end,:)'*X(m2+1:end,:))*(X(m2+1:end,:)'*yv(m2+1:end)); e2 = norm(yv(m2+1:end)-X(m2+1:end,:)*h2)/norm(yv(m2+1:end));
  Hs = [Hs, h]; evms(end+1) = ev; evms_h1(end+1) = e1; evms_h2(end+1) = e2; %#ok<AGROW>
end
nf = size(Hs,2);
if nf < 2, fprintf('[snd] not enough clean fits\n'); return; end
% --- reports ---
Hm = mean(abs(Hs),2); Hm = Hm/max(Hm);
[~,pkt] = max(Hm);
fprintf('[snd] frames fit=%d  FULL-frame LS residual EVM: med=%.1f%% (static linear channel explains 1-EVM)\n', nf, 100*median(evms));
fprintf('[snd] HALF-frame residual EVM: med=%.1f%% / %.1f%% (much lower than full => channel varies WITHIN a frame)\n', 100*median(evms_h1), 100*median(evms_h2));
fprintf('[snd] delay profile (dB rel main tap @%d):\n', pkt-1);
for t = 1:L
  d = 20*log10(Hm(t)+1e-6);
  if d > -25, fprintf('    tap %+3d (%.2f sym): %6.1f dB\n', t-pkt, (t-pkt)/8, d); end
end
% frame-to-frame variation of h (normalized)
dh = vecnorm(diff(Hs,1,2)) ./ vecnorm(Hs(:,1:end-1));
% dominant-tap phase trajectory across frames
ph = angle(Hs(pkt,:)); dph = rad2deg(angle(exp(1j*diff(ph))));
fprintf('[snd] h frame-to-frame change: med=%.1f%%  | main-tap phase step: med=%.1f deg/frame (frame=4.72ms)\n', 100*median(dh), median(abs(dph)));
fprintf('[snd] main-tap |gain| CV across frames: %.1f%%\n', 100*std(abs(Hs(pkt,:)))/mean(abs(Hs(pkt,:))));
end
