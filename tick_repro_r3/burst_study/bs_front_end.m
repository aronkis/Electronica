function res = bs_front_end(iq, cfg, opts)
%BS_FRONT_END  Float R3 receiver front end returning PER-FRAME sync/EVM detail.
%
%   res = bs_front_end(iq, cfg, opts)
%
%   Burst-study copy of the evm/evm_ideal_ref.m front end (RRC matched filter
%   -> comm.SymbolSynchronizer (Gardner) -> 4th-power + preamble-refine CFO ->
%   comm.CarrierSynchronizer -> differential-Barker frame detection), extended
%   to RETURN the quantities evm_ideal_ref keeps internal:
%     .ps        detected+refined frame starts (post-sync symbol domain)
%     .preCorr   normalized preamble correlation per detected frame (0..1)
%     .frameEVM  per-frame RMS EVM %% (per-frame preamble derotation, so the
%                metric is rotation-ambiguity-free like evm_ideal_ref)
%     .nSym      total recovered symbols
%     .coarseCFO coarse CFO estimate (Hz)
%     .paySym    int8 [nF x PaySymPerFrame] per-frame hard-decision payload
%                symbol indices (0..3), after per-frame preamble derotation --
%                the CRC-equivalent scoring input: comparing these against the
%                baseline run's paySym detects DISPLACED-but-valid payload
%                content that hard-decision EVM is blind to (a slipped frame's
%                symbols still sit on constellation points, so EVM stays low,
%                but the delivered bits are wrong and the hardware CRC fails).
%
%   evm_ideal_ref.m is NOT modified; this is an independent parameterized copy
%   (per the repo convention -- see evm_ideal_ref's own header re decode_ref_k5).
%
%   iq   : complex column vector of raw samples (already segmented; NOT a file)
%   cfg  : evm_config_1536k()
%   opts : .loopbw (cfg.CSBnXTsamp), .ssloopbw ([] = comm default), .cfomax (15e3)

if nargin < 3, opts = struct(); end
if ~isfield(opts,'loopbw'),   opts.loopbw = cfg.CSBnXTsamp; end
if ~isfield(opts,'ssloopbw'), opts.ssloopbw = []; end
if ~isfield(opts,'cfomax'),   opts.cfomax = 15e3; end

Rsym = cfg.Rsym; sps = cfg.Sps;
RRC = rcosdesign(cfg.Beta, cfg.RrcSpan, sps);
preSyms = cfg.PreambleSymbols(:); nPre = cfg.NPreambleSym;
frameLenSym = cfg.FrameLenSym;

iq = double(iq(:));
iq = iq / (max(abs(iq)) + eps);

% ---- matched filter + Gardner symbol timing (same as evm_ideal_ref) ------
x = iq / rms(abs(iq));
mf = conv(x, RRC, 'same');
ssArgs = {'TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps};
if ~isempty(opts.ssloopbw)
    ssArgs = [ssArgs, {'NormalizedLoopBandwidth', opts.ssloopbw}];
end
ssy = comm.SymbolSynchronizer(ssArgs{:});
sy = ssy(mf); sy = sy(:) / rms(abs(sy));
sym0 = sy * rms(abs(preSyms));

% ---- coarse CFO: 4th power + preamble refine ------------------------------
f4 = local_fourthPowerCFO(sym0, Rsym, opts.cfomax);
sym1 = sym0 .* exp(-1i*2*pi*f4/Rsym*(0:numel(sym0)-1).');
psAll = local_framePeaks(sym1, preSyms, nPre, frameLenSym);
fRef = local_coarseCFO(sym1, psAll, preSyms, nPre, Rsym);
if abs(fRef) > 5e3, fRef = 0; end
fCoarse = f4 + fRef;
symCFO = sym0 .* exp(-1i*2*pi*fCoarse/Rsym*(0:numel(sym0)-1).');

% ---- carrier tracking -----------------------------------------------------
csy = comm.CarrierSynchronizer('Modulation','QPSK','SamplesPerSymbol',1, ...
    'DampingFactor',1/sqrt(2),'NormalizedLoopBandwidth',opts.loopbw);
symC = csy(symCFO); symC = symC(:) / rms(abs(symC)) * rms(abs(preSyms));

% ---- frame detection + refine (identical mechanics) -----------------------
ps0 = local_framePeaks(symC, preSyms, nPre, frameLenSym);
ps0 = local_refineStarts(symC, ps0, preSyms, nPre, 8);

% ---- per-frame preamble corr + EVM (per-frame derotation) -----------------
nF0 = numel(ps0); nPay = frameLenSym - nPre;
ideal = cfg.IdealConstellation(:).';
ps = zeros(nF0,1); preCorr = zeros(nF0,1); frameEVM = zeros(nF0,1); n = 0;
paySym = zeros(nF0, nPay, 'int8');
for kk = 1:nF0
    s0 = ps0(kk);
    if s0 < 1 || s0+frameLenSym-1 > numel(symC), continue; end
    fr = symC(s0:s0+frameLenSym-1);
    pre = fr(1:nPre);
    Zc = sum(pre .* conj(preSyms));
    pc = abs(Zc) / (sum(abs(preSyms)) + eps);
    if abs(Zc) > 0, fr = fr * (conj(Zc)/abs(Zc)); end
    mF = evm_metrics(fr, cfg);
    n = n + 1;
    ps(n) = s0; preCorr(n) = pc; frameEVM(n) = mF.rms_evm;
    pay = fr(nPre+1:end);
    [~, di] = min(abs(pay - ideal).^2, [], 2);   % hard decision 1..4
    paySym(n,:) = int8(di.' - 1);
end
res = struct('ps', ps(1:n), 'preCorr', preCorr(1:n), 'frameEVM', frameEVM(1:n), ...
    'nSym', numel(symC), 'coarseCFO', fCoarse, 'nFrames', n, ...
    'paySym', paySym(1:n,:));
% ADDITIVE (2026-08-11): return the post-carrier-sync symbol stream as well, so a
% caller can examine WITHIN a frame -- e.g. sub-block EVM to tell a carrier
% transient (spread / ramped) from a localised corruption burst. Every pre-existing
% field is unchanged, so existing callers are unaffected.
res.symC = symC;
end

% ===== helpers: verbatim parameterized copies from evm_ideal_ref.m =========
function ps0 = local_framePeaks(sym, preSyms, nPre, frameLenSym)
sym = sym(:);
dps = preSyms(2:end) .* conj(preSyms(1:end-1));
dsy = sym(2:end) .* conj(sym(1:end-1));
ccd = abs(conv(dsy, conj(flipud(dps))));
ccd = ccd / (max(ccd) + eps);
[~, pk] = findpeaks(ccd, 'MinPeakHeight', 0.4, 'MinPeakDistance', round(0.6*frameLenSym));
ps0 = pk - (nPre - 2);
ps0 = ps0(ps0 >= 1 & ps0 + frameLenSym - 1 <= numel(sym));
end

function f = local_fourthPowerCFO(sym, Rsym, cfomax)
s = sym(:); s = s ./ (abs(s) + eps);
N = min(2^18, numel(s)); w = s(1:N).^4;
W = fftshift(abs(fft(w .* hann(N)))); fax = linspace(-Rsym/2, Rsym/2, N);
mask = abs(fax) <= 4*cfomax; W(~mask) = 0;
[~, k] = max(W); f = fax(k)/4;
end

function f = local_coarseCFO(sym, ps0, preSyms, nPre, Rsym)
fs = [];
for ii = 1:numel(ps0)
    s0 = ps0(ii); if s0+nPre-1 > numel(sym), continue; end
    z = sym(s0:s0+nPre-1) .* conj(preSyms);
    dz = z(2:end) .* conj(z(1:end-1));
    fs(end+1) = angle(mean(dz))/(2*pi)*Rsym; %#ok<AGROW>
end
if isempty(fs), f = 0; else, f = median(fs); end
end

function ps2 = local_refineStarts(symC, starts, preSyms, nPre, win)
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
