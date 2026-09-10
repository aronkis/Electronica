function res = evm_ideal_ref(capfile_or_iq, cfg, opts)
%EVM_IDEAL_REF  Float-chain EVM from a raw AGC-tap (mode 0) or rx-lpc capture.
%
%   res = evm_ideal_ref(capfile_or_iq, cfg, opts)
%
%   Front end (RRC matched filter -> Gardner symbol timing -> 4th-power+
%   preamble-refine CFO -> comm.CarrierSynchronizer -> preamble frame sync) is
%   REFACTORED/ADAPTED from k5_240/decode_ref_k5.m's proven float front end
%   (that file is NEVER modified -- this is an independent copy, parameterized
%   on cfg.Rsym/cfg.Sps/cfg.Beta/cfg.RrcSpan/cfg.PreambleSymbols instead of the
%   hardcoded 1.92e6/8/240e3 in the original). Bit-scoring is replaced by the
%   SAME EVM metric block evm_from_tap uses (evm/evm_metrics.m).
%
%   capfile_or_iq : path to an int16-interleaved I/Q capture (raw ADC-scale,
%                   e.g. two_jup/paired/*/pair.iq or a mode-0 rx2-lpc tap
%                   capture), OR a numeric complex vector of raw samples.
%   cfg           : struct from evm_config_240k().
%   opts:
%     .loopbw          (cfg.CSBnXTsamp) carrier-sync normalized loop bandwidth
%     .ssloopbw         ([])            symbol-sync normalized loop bandwidth
%                                        (empty -> comm.SymbolSynchronizer default)
%     .nocfo           (false) ablation: skip 4th-power/preamble CFO estimate
%     .nocarrier       (false) ablation: skip comm.CarrierSynchronizer tracking
%     .nopreamphase    (false) ablation: skip per-frame preamble derotation
%     .cfomax          (15e3)  coarse-CFO search half-range, Hz
%     .ncleanresolve   (24)    #cleanest frames used for global rotation vote
%     .k               (5)     tick-flag threshold: frame EVM > median+k*sigma
%     .plot            (false) produce plots
%     .label           ('')

if nargin < 3, opts = struct(); end
if ~isfield(opts,'loopbw'),        opts.loopbw = cfg.CSBnXTsamp; end
if ~isfield(opts,'ssloopbw'),      opts.ssloopbw = []; end
if ~isfield(opts,'nocfo'),         opts.nocfo = false; end
if ~isfield(opts,'nocarrier'),     opts.nocarrier = false; end
if ~isfield(opts,'nopreamphase'),  opts.nopreamphase = false; end
if ~isfield(opts,'cfomax'),        opts.cfomax = 15e3; end
if ~isfield(opts,'ncleanresolve'), opts.ncleanresolve = 24; end
if ~isfield(opts,'k'),             opts.k = 5; end
if ~isfield(opts,'plot'),          opts.plot = false; end
if ~isfield(opts,'label'),         opts.label = ''; end

res = struct('label', opts.label);

Rsym = cfg.Rsym; sps = cfg.Sps;
RRC = rcosdesign(cfg.Beta, cfg.RrcSpan, sps);
preSyms = cfg.PreambleSymbols(:); nPre = cfg.NPreambleSym; frameLenSym = cfg.FrameLenSym;

% ---- 1. load ----------------------------------------------------------
if ischar(capfile_or_iq) || isstring(capfile_or_iq)
    fname = char(capfile_or_iq);
    fid = fopen(fname,'r');
    assert(fid > 0, 'evm_ideal_ref:openFailed', 'cannot open %s', fname);
    raw = fread(fid, Inf, 'int16'); fclose(fid);
    I = raw(1:2:end); Q = raw(2:2:end); nn = min(numel(I), numel(Q));
    iq = double(I(1:nn)) + 1i*double(Q(1:nn));
    res.srcfile = fname;
else
    iq = double(capfile_or_iq(:));
    res.srcfile = '';
end
iq = iq(abs(iq) > 0);
assert(~isempty(iq), 'evm_ideal_ref:empty', 'no nonzero samples in capture');
iq = iq / (max(abs(iq)) + eps);
res.nRawSamples = numel(iq);
fprintf('[evm_ideal_ref] %s: %d complex samples (~%.0f frames)\n', ...
    res.label, numel(iq), numel(iq)/sps/frameLenSym);

% ---- 2. front end: timing, CFO, carrier sync (parameterized copy of decode_ref_k5.m) ----
x = iq(:) / rms(abs(iq));
mf = conv(x, RRC, 'same');

ssArgs = {'TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps};
if ~isempty(opts.ssloopbw)
    ssArgs = [ssArgs, {'NormalizedLoopBandwidth', opts.ssloopbw}]; %#ok<AGROW>
end
ssy = comm.SymbolSynchronizer(ssArgs{:});
sy = ssy(mf); sy = sy(:) / rms(abs(sy));
sym0 = sy * rms(abs(preSyms));

if opts.nocfo
    fCoarse = 0;
    res.cfoBreakdown = struct('fourthPower',0,'preambleRefine',0);
else
    f4 = local_fourthPowerCFO(sym0, Rsym, opts.cfomax);
    if abs(f4) > 0.9*opts.cfomax
        warning('evm_ideal_ref:cfoEdge', ...
            '4th-power CFO %.0f Hz is at the +-%.0f Hz mask edge -- raise opts.cfomax', f4, opts.cfomax);
    end
    sym1 = sym0 .* exp(-1i*2*pi*f4/Rsym*(0:numel(sym0)-1).');
    [psAll, ~] = local_framePeaks(sym1, preSyms, nPre, frameLenSym);
    fRef = local_coarseCFO(sym1, psAll, preSyms, nPre, Rsym);
    if abs(fRef) > 5e3
        fprintf('[evm_ideal_ref] preamble-refine %.0f Hz IMPLAUSIBLE -> ignored\n', fRef);
        fRef = 0;
    end
    fCoarse = f4 + fRef;
    res.cfoBreakdown = struct('fourthPower',f4,'preambleRefine',fRef);
    fprintf('[evm_ideal_ref] CFO breakdown: 4th-power=%.0f Hz + preamble-refine=%.0f Hz (search +-%.0f Hz)\n', ...
        f4, fRef, opts.cfomax);
end
symCFO = sym0 .* exp(-1i*2*pi*fCoarse/Rsym*(0:numel(sym0)-1).');

if opts.nocarrier
    symC = symCFO(:) / rms(abs(symCFO)) * rms(abs(preSyms));
else
    csy = comm.CarrierSynchronizer('Modulation','QPSK','SamplesPerSymbol',1, ...
        'DampingFactor',1/sqrt(2),'NormalizedLoopBandwidth',opts.loopbw);
    symC = csy(symCFO); symC = symC(:) / rms(abs(symC)) * rms(abs(preSyms));
end
res.coarseCFO = fCoarse;

[ps0, ~] = local_framePeaks(symC, preSyms, nPre, frameLenSym);
ps0 = local_refineStarts(symC, ps0, preSyms, nPre, 8);
nF = numel(ps0);
fprintf('[evm_ideal_ref] coarse CFO=%.0f Hz ; framed %d candidates\n', fCoarse, nF);

% ---- 3. per-frame preamble derotation (constant phase) ----------------
frS0 = []; frPreCorr = []; frPayD = {};
for kk = 1:nF
    s0 = ps0(kk);
    if s0 < 1 || s0+frameLenSym-1 > numel(symC), continue; end
    fr = symC(s0:s0+frameLenSym-1); pre = fr(1:nPre);
    preCorr = abs(sum(pre .* conj(preSyms))) / (sum(abs(preSyms)) + eps);
    Zc = sum(pre .* conj(preSyms));
    r0 = 1;
    if ~opts.nopreamphase && abs(Zc) > 0, r0 = conj(Zc)/abs(Zc); end
    fr = fr * r0;
    frS0(end+1) = s0; %#ok<AGROW>
    frPreCorr(end+1) = preCorr; %#ok<AGROW>
    frPayD{end+1} = fr; %#ok<AGROW>
end
nF = numel(frS0);
assert(nF > 0, 'evm_ideal_ref:noFrames', 'no decodable frames found');

% ---- 4. GLOBAL rotation resolution from the cleanest frames -----------
[~, ord] = sort(frPreCorr, 'descend');
useIdx = ord(1:min(opts.ncleanresolve, nF));
rotDeg = zeros(1,nF);
for kk = 1:nF
    pre = frPayD{kk}(1:nPre);
    Zc = sum(pre .* conj(preSyms));
    rotDeg(kk) = mod(round(angle(Zc)/(pi/2))*90, 360);
end
candRot = rotDeg(useIdx);
u = unique(candRot);
cnts = arrayfun(@(v) sum(candRot == v), u);
[~, bi] = max(cnts);
globalRotDeg = u(bi);
res.globalRotDeg = globalRotDeg;
res.rotVotes = struct('candidates',u,'counts',cnts);
fprintf('[evm_ideal_ref] GLOBAL rotation: %d deg (resolved on %d cleanest frames)\n', globalRotDeg, numel(useIdx));

% ---- 5. build the full derotated symbol stream + per-frame indices ----
allSym = []; frameIdxRanges = zeros(nF,2);
for kk = 1:nF
    fr = frPayD{kk} * exp(-1i*deg2rad(globalRotDeg));
    startIdx = numel(allSym) + 1;
    allSym = [allSym; fr(:)]; %#ok<AGROW>
    frameIdxRanges(kk,:) = [startIdx, startIdx+frameLenSym-1];
end
res.nFrames = nF;

% ---- 6. EVM metrics (shared core) --------------------------------------
mAll = evm_metrics(allSym, cfg);
res.rms_evm   = mAll.rms_evm;
res.peak_evm  = mAll.peak_evm;
res.p95_evm   = mAll.p95;
res.p99_evm   = mAll.p99;
res.mag_evm   = mAll.mag_evm;
res.phase_evm = mAll.phase_evm;
res.evm_inst  = mAll.evm_inst;
res.phase_err = mAll.phase_err;
res.t = (0:numel(allSym)-1).' / Rsym;

frameEVM = nan(nF,1);
preIdxAll = zeros(0,1); payIdxAll = zeros(0,1);
for kk = 1:nF
    idxAll = (frameIdxRanges(kk,1):frameIdxRanges(kk,2)).';
    mF = evm_metrics(allSym(idxAll), cfg);
    frameEVM(kk) = mF.rms_evm;
    preIdxAll = [preIdxAll; idxAll(1:nPre)];       %#ok<AGROW>
    payIdxAll = [payIdxAll; idxAll(nPre+1:end)];   %#ok<AGROW>
end
res.frameEVM = frameEVM;
valid = ~isnan(frameEVM);
med = median(frameEVM(valid)); sig = std(frameEVM(valid));
flagged = valid & (frameEVM > med + opts.k*sig);
res.flaggedFrames = find(flagged);
res.evm_all_frames = sqrt(mean(frameEVM(valid).^2));
if any(valid & ~flagged)
    res.evm_excised = sqrt(mean(frameEVM(valid & ~flagged).^2));
else
    res.evm_excised = res.evm_all_frames;
end
mPre = evm_metrics(allSym(preIdxAll), cfg);
mPay = evm_metrics(allSym(payIdxAll), cfg);
res.preamble_evm = mPre.rms_evm;
res.payload_evm  = mPay.rms_evm;

if numel(res.phase_err) >= 32
    [pxx, f] = pwelch(res.phase_err, [], [], [], Rsym);
    res.psd_f = f; res.psd_pxx = pxx;
else
    res.psd_f = []; res.psd_pxx = [];
end

% ---- 7. plots -----------------------------------------------------------
res.figs = [];
if opts.plot
    figs = gobjects(0);
    fh = figure('Name', sprintf('EVM (ideal ref) constellation: %s', res.label));
    plot(real(allSym), imag(allSym), '.', 'MarkerSize', 2); hold on;
    plot(real(cfg.IdealConstellation), imag(cfg.IdealConstellation), 'r*', 'MarkerSize', 12);
    axis equal; grid on; xlabel('I'); ylabel('Q');
    title(sprintf('Constellation (RMS EVM=%.2f%%)', res.rms_evm));
    figs(end+1) = fh;

    fh = figure('Name', 'EVM vs time (ideal ref)');
    plot(res.t, res.evm_inst); grid on; xlabel('time (s)'); ylabel('EVM %');
    title('Per-symbol EVM'); figs(end+1) = fh;

    fh = figure('Name', 'Per-frame EVM trace (ideal ref)');
    plot(res.frameEVM, 'o-'); hold on;
    if ~isempty(res.flaggedFrames)
        plot(res.flaggedFrames, res.frameEVM(res.flaggedFrames), 'rx', 'MarkerSize', 10, 'LineWidth', 2);
    end
    grid on; xlabel('frame #'); ylabel('frame RMS EVM %');
    title(sprintf('Per-frame EVM (flagged=%d/%d)', numel(res.flaggedFrames), nF));
    figs(end+1) = fh;

    if ~isempty(res.psd_f)
        fh = figure('Name', 'Phase-error PSD (ideal ref)');
        plot(res.psd_f, 10*log10(res.psd_pxx)); hold on;
        xline(cfg.CarrierLoopBWHz, 'r--', sprintf('loop BW %.0f Hz', cfg.CarrierLoopBWHz));
        grid on; xlabel('Hz'); ylabel('dB/Hz'); title('Carrier phase-error PSD'); figs(end+1) = fh;
    end
    res.figs = figs;
end

fprintf(['[evm_ideal_ref] %s: nFrames=%d globalRot=%d deg  RMS EVM=%.2f%%  peak=%.2f%%  ' ...
    'p95=%.2f%%  p99=%.2f%%  magEVM=%.2f%%  phaseEVM=%.2f%%\n'], res.label, nF, globalRotDeg, ...
    res.rms_evm, res.peak_evm, res.p95_evm, res.p99_evm, res.mag_evm, res.phase_evm);
fprintf('[evm_ideal_ref] preamble EVM=%.2f%%  payload EVM=%.2f%%  all-frames EVM=%.2f%%  tick-excised EVM=%.2f%% (flagged %d frames)\n', ...
    res.preamble_evm, res.payload_evm, res.evm_all_frames, res.evm_excised, numel(res.flaggedFrames));

end

% ============================ helpers (parameterized copies; decode_ref_k5.m untouched) ====
function [ps0, pkv] = local_framePeaks(sym, preSyms, nPre, frameLenSym)
sym = sym(:);
dps = preSyms(2:end) .* conj(preSyms(1:end-1));
dsy = sym(2:end) .* conj(sym(1:end-1));
ccd = abs(conv(dsy, conj(flipud(dps))));
ccd = ccd / (max(ccd) + eps);
[pkv, pk] = findpeaks(ccd, 'MinPeakHeight', 0.4, 'MinPeakDistance', round(0.6*frameLenSym));
ps0 = pk - (nPre - 2);
keep = ps0 >= 1 & ps0 + frameLenSym - 1 <= numel(sym);
ps0 = ps0(keep); pkv = pkv(keep);
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
