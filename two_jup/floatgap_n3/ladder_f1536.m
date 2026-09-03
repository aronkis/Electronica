function res = ladder_f1536(prefix, iqfile, offFrames, nFrames)
% ladder_f1536 -- hybrid fixed/float EVM ladder at R3 (f1536 geometry).
%
% Port of the k5_240/hybrid_ladder_k5.m METHOD to EVM terms: each rung decodes
% a FIXED-POINT stage tap stream (sim_byte_taps / wrap_byte_taps on the f1536
% netlist) with the FLOAT remainder of the chain (bs_front_end mechanics), and
% scores per-frame RMS EVM with per-frame preamble derotation (evm_metrics).
% Rung k EVM minus rung k-1 EVM (in quadrature) attributes margin to the stage
% whose fixed implementation was added at rung k.
%
% Empirical tap rates (measured from the Jul25 f1536 netlist dumps, NOT assumed):
%   agc : 8 lines/symbol (4 sps input logged 2x per sample, mostly duplicate pairs)
%   rrc : 8 lines/symbol GENUINE (the netlist RRC is a 2x-interpolating polyphase)
%   ss/cfc/cs/pa : 1 line/symbol
%   con : 1/symbol, payload-only (12320/frame), delivered frames only
%
% prefix    : tap file prefix (expects <prefix>_agc.txt ... <prefix>_con.txt)
% iqfile    : raw int16 IQ capture the taps were generated from
% offFrames : window start offset in frames (same as the tap run)
% nFrames   : window length in frames

here = fileparts(mfilename('fullpath'));
repo = fullfile(here,'..','..');
addpath(fullfile(repo,'evm'));
cfg  = evm_config_1536k();
Rsym = cfg.Rsym; preSyms = cfg.PreambleSymbols(:); nPre = cfg.NPreambleSym;
frameLenSym = cfg.FrameLenSym; paySyms = cfg.PaySymPerFrame;
WARM = 5; cfoMax = 15e3; loopBW = cfg.CSBnXTsamp;

% ---- rung 0: full float on the identical raw IQ window --------------------
SPF = frameLenSym*cfg.Sps;
f = fopen(iqfile,'rb'); fseek(f, offFrames*SPF*4, 'bof');
d = fread(f, 2*nFrames*SPF, 'int16'); fclose(f);
iq = complex(d(1:2:end), d(2:2:end));
symC = float_chain(iq/ (max(abs(iq))+eps), 4, true, true, true, cfg, loopBW, cfoMax);
res = struct('rung',{},'nF',{},'medEVM',{},'meanEVM',{},'p90',{});
res(end+1) = scoreEVM('float', symC, cfg, WARM);

cfgs = { ...
  'agc', 8, true,  true,  true ; ...
  'rrc', 8, false, true,  true ; ...
  'ss',  1, false, true,  true ; ...
  'cfc', 1, false, false, true ; ...
  'cs',  1, false, false, false; ...
  'pa',  1, false, false, false};

for r = 1:size(cfgs,1)
  rg = cfgs{r,1};
  fn = sprintf('%s_%s.txt', prefix, rg);
  if ~exist(fn,'file'), fprintf('[%-5s] SKIP (no file)\n', rg); continue; end
  M = readmatrix(fn);
  if isempty(M), fprintf('[%-5s] EMPTY\n', rg); continue; end
  z = complex(M(:,1), M(:,2));
  % trim the flush tail (valid latched high after input ends -> repeated value)
  z = trim_flush(z);
  symC = float_chain(z/(max(abs(z))+eps), cfgs{r,2}, cfgs{r,3}, cfgs{r,4}, cfgs{r,5}, cfg, loopBW, cfoMax);
  res(end+1) = scoreEVM(rg, symC, cfg, WARM); %#ok<AGROW>
end

% con: payload-only framed stream, delivered frames only
fn = sprintf('%s_con.txt', prefix);
if exist(fn,'file')
  M = readmatrix(fn);
  if ~isempty(M) && size(M,1) >= paySyms
    z = complex(M(:,1), M(:,2));
    nF = floor(numel(z)/paySyms);
    ev = zeros(nF,1);
    for k = 1:nF
      m = evm_metrics(z((k-1)*paySyms+1 : k*paySyms), cfg);
      ev(k) = m.rms_evm;
    end
    ev2 = ev(min(WARM,nF-1)+1:end);
    fprintf('[con  ] nF=%-3d medEVM=%6.3f meanEVM=%6.3f p90=%6.3f\n', nF, median(ev2), mean(ev2), prctile(ev2,90));
    res(end+1) = struct('rung','con','nF',nF,'medEVM',median(ev2),'meanEVM',mean(ev2),'p90',prctile(ev2,90));
  end
end
save([prefix '_ladder_f1536.mat'], 'res');
end

% =========================================================================
function s = scoreEVM(name, symC, cfg, WARM)
preSyms = cfg.PreambleSymbols(:); nPre = cfg.NPreambleSym; frameLenSym = cfg.FrameLenSym;
ps0 = framePeaks(symC, preSyms, nPre, frameLenSym);
ps0 = refineStarts(symC, ps0, preSyms, nPre, 8);
ev = [];
for kk = 1:numel(ps0)
  s0 = ps0(kk);
  if s0 < 1 || s0+frameLenSym-1 > numel(symC), continue; end
  fr = symC(s0:s0+frameLenSym-1);
  pre = fr(1:nPre); Zc = sum(pre .* conj(preSyms));
  if abs(Zc) > 0, fr = fr * (conj(Zc)/abs(Zc)); end
  m = evm_metrics(fr, cfg);
  ev(end+1) = m.rms_evm; %#ok<AGROW>
end
nF = numel(ev);
if nF == 0
  fprintf('[%-5s] NO FRAMES\n', name);
  s = struct('rung',name,'nF',0,'medEVM',NaN,'meanEVM',NaN,'p90',NaN);
  return;
end
ev2 = ev(min(WARM,nF-1)+1:end);
fprintf('[%-5s] nF=%-3d medEVM=%6.3f meanEVM=%6.3f p90=%6.3f\n', name, nF, median(ev2), mean(ev2), prctile(ev2,90));
s = struct('rung',name,'nF',nF,'medEVM',median(ev2),'meanEVM',mean(ev2),'p90',prctile(ev2,90));
end

function symC = float_chain(x, sps, useMF, useCFO, usePLL, cfg, loopBW, cfoMax)
Rsym = cfg.Rsym; preSyms = cfg.PreambleSymbols(:); nPre = cfg.NPreambleSym;
frameLenSym = cfg.FrameLenSym;
x = x(:) / (rms(abs(x))+eps);
if useMF, x = conv(x, rcosdesign(cfg.Beta, cfg.RrcSpan, sps), 'same'); end
if sps > 1
  ssy = comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
  sy = ssy(x);
else
  sy = x;
end
sy = sy(:) / (rms(abs(sy))+eps); sym0 = sy * rms(abs(preSyms));
if useCFO
  f4 = fourthPowerCFO(sym0, Rsym, cfoMax);
  sym1 = sym0 .* exp(-1i*2*pi*f4/Rsym*(0:numel(sym0)-1).');
  psAll = framePeaks(sym1, preSyms, nPre, frameLenSym);
  fRef = coarseCFO(sym1, psAll, preSyms, nPre, Rsym);
  if abs(fRef) > 5e3, fRef = 0; end
  fC = f4 + fRef;
else
  fC = 0;
end
symCFO = sym0 .* exp(-1i*2*pi*fC/Rsym*(0:numel(sym0)-1).');
if usePLL
  csy = comm.CarrierSynchronizer('Modulation','QPSK','SamplesPerSymbol',1, ...
    'DampingFactor',1/sqrt(2),'NormalizedLoopBandwidth',loopBW);
  symC = csy(symCFO);
else
  symC = symCFO;
end
symC = symC(:) / (rms(abs(symC))+eps) * rms(abs(preSyms));
end

function z = trim_flush(z)
% remove the trailing run of a single repeated value (flush-latched output)
n = numel(z); if n < 10, return; end
k = n;
while k > 1 && z(k-1) == z(n), k = k - 1; end
if n - k > 100, z = z(1:k); end
end

% ---- helpers verbatim (parameterized) from bs_front_end / hybrid_ladder ----
function ps0 = framePeaks(sym, preSyms, nPre, frameLenSym)
sym = sym(:);
dps = preSyms(2:end) .* conj(preSyms(1:end-1));
dsy = sym(2:end) .* conj(sym(1:end-1));
ccd = abs(conv(dsy, conj(flipud(dps))));
ccd = ccd / (max(ccd) + eps);
[~, pk] = findpeaks(ccd, 'MinPeakHeight', 0.4, 'MinPeakDistance', round(0.6*frameLenSym));
ps0 = pk - (nPre - 2);
ps0 = ps0(ps0 >= 1 & ps0 + frameLenSym - 1 <= numel(sym));
end

function f = fourthPowerCFO(sym, Rsym, cfomax)
s = sym(:); s = s ./ (abs(s) + eps);
N = min(2^18, numel(s)); w = s(1:N).^4;
W = fftshift(abs(fft(w .* hann(N)))); fax = linspace(-Rsym/2, Rsym/2, N);
mask = abs(fax) <= 4*cfomax; W(~mask) = 0;
[~, k] = max(W); f = fax(k)/4;
end

function f = coarseCFO(sym, ps0, preSyms, nPre, Rsym)
fs = [];
for ii = 1:numel(ps0)
  s0 = ps0(ii); if s0+nPre-1 > numel(sym), continue; end
  z = sym(s0:s0+nPre-1) .* conj(preSyms);
  dz = z(2:end) .* conj(z(1:end-1));
  fs(end+1) = angle(mean(dz))/(2*pi)*Rsym; %#ok<AGROW>
end
if isempty(fs), f = 0; else, f = median(fs); end
end

function ps2 = refineStarts(symC, starts, preSyms, nPre, win)
ps2 = starts(:);
for i = 1:numel(ps2)
  best = -1; bb = ps2(i);
  for o = -win:win
    s = ps2(i) + o;
    if s < 1 || s+nPre-1 > numel(symC), continue; end
    v = abs(sum(symC(s:s+nPre-1) .* conj(preSyms)));
    if v > best, best = v; bb = s; end
  end
  ps2(i) = bb;
end
ps2 = unique(ps2);
end
