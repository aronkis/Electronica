function res = evm_from_tap(iqfile_or_vector, cfg, mode, opts)
%EVM_FROM_TAP  Hardware-loop EVM instrument for the on-chip debug tap (AXI 0x10C).
%
%   res = evm_from_tap(iqfile_or_vector, cfg, mode, opts)
%
%   iqfile_or_vector : path to a raw int16-interleaved I/Q capture file (as
%                      produced by tap_smoke.sh / capture_evm.sh's
%                      "axi-adrv9002-rx2-lpc voltage0_i voltage0_q" reads), OR
%                      a numeric complex vector already in engineering units
%                      (see opts.alreadySymbolRate).
%   cfg              : struct from evm_config_240k() (or a sibling rate cfg) --
%                      NOTHING here hardcodes 1.92e6/8/240e3, all rate/tap
%                      constants come from cfg.
%   mode             : tap mode number (cfg.TapModes.*, e.g. 0/1/2/3/5), OR
%                      the string 'symbols'/'sym' meaning iqfile_or_vector is
%                      ALREADY 1-sample/symbol data (used by evm_selftest.m).
%   opts (all optional):
%     .plot               (false) produce constellation/EVM/PSD plots
%     .k                  (5)     tick-flag threshold: frame EVM > median+k*sigma
%     .ncleanresolve      (24)    #cleanest frames used for global rotation vote
%     .label              ('')    free-text label, propagated to res.label
%     .alreadySymbolRate  (false) skip hold-detection/decimation entirely
%     .skipFrameSync      (false) skip preamble search + ambiguity resolution
%                                 (only for controlled synthetic tests where
%                                 the caller does not want frame-sync noise
%                                 in the correctness check)
%
%   Known risk (recorded, task C1 brief): the tap modes are HELD at rail rate
%   with debugValid folded into sample alignment -- there is no explicit valid
%   channel in the captured stream (see evm_config_240k.m for the empirical
%   verification: mode 3 collapses to ~1 sample/symbol via consecutive-
%   duplicate detection, but modes 1/2 empirically collapse to ~2
%   samples/symbol, not cfg.Sps). This function DETECTS the hold factor from
%   the data (median duplicate-run length) rather than assuming cfg.Sps, and
%   always reports what it detected in res.decimation so a wrong assumption
%   is visible in the output rather than silently baked into the EVM number.

if nargin < 4, opts = struct(); end
if ~isfield(opts,'plot'),              opts.plot = false; end
if ~isfield(opts,'k'),                 opts.k = 5; end
if ~isfield(opts,'ncleanresolve'),     opts.ncleanresolve = 24; end
if ~isfield(opts,'label'),             opts.label = ''; end
if ~isfield(opts,'alreadySymbolRate'), opts.alreadySymbolRate = false; end
if ~isfield(opts,'skipFrameSync'),     opts.skipFrameSync = false; end

res = struct();
res.mode  = mode;
res.label = opts.label;

% ---- 1. load ----------------------------------------------------------
if ischar(iqfile_or_vector) || isstring(iqfile_or_vector)
    fname = char(iqfile_or_vector);
    fid = fopen(fname,'r');
    assert(fid > 0, 'evm_from_tap:openFailed', 'cannot open %s', fname);
    raw = fread(fid, Inf, 'int16'); fclose(fid);
    I = raw(1:2:end); Q = raw(2:2:end); nn = min(numel(I), numel(Q));
    rawIQ = (double(I(1:nn)) + 1i*double(Q(1:nn))) / cfg.TapScale;
    res.srcfile = fname;
else
    rawIQ = double(iqfile_or_vector(:));
    res.srcfile = '';
end
res.nRawSamples = numel(rawIQ);
assert(res.nRawSamples > 0, 'evm_from_tap:empty', 'no samples loaded');

% ---- 2. mode / hold-factor recovery -----------------------------------
isSymbolMode = opts.alreadySymbolRate || (ischar(mode) && any(strcmpi(mode, {'symbols','sym'})));
if isSymbolMode
    sym = rawIQ;
    res.decimation = struct('method','none (pre-supplied symbol-rate)', ...
        'holdRunSamples',1, 'detectedRateHz',cfg.Rsym, 'finalSymRateHz',cfg.Rsym, ...
        'confidence','n/a', 'heldOrStrobed','n/a (pre-supplied)');
else
    modeNum = mode;
    if res.nRawSamples < 2
        same = false;
    else
        same = (rawIQ(2:end) == rawIQ(1:end-1));
    end
    dupFrac = mean(same);
    if dupFrac < 0.05
        % Continuous / not held (e.g. AGC-out mode 0): no debugValid-derived
        % symbol boundary is recoverable from duplicate detection. Best-effort
        % naive stride decimation by cfg.Sps -- LOW CONFIDENCE, flagged.
        sym = rawIQ(1:cfg.Sps:end);
        res.decimation = struct( ...
            'method','continuous (dup_frac<0.05): naive stride decimate by cfg.Sps', ...
            'holdRunSamples',1, 'detectedRateHz',cfg.Fs, 'finalSymRateHz',cfg.Fs/cfg.Sps, ...
            'confidence','low -- mode appears un-held/continuous; no timing recovery applied. Use evm_ideal_ref for a proper matched-filter+Gardner front end on this mode.', ...
            'heldOrStrobed','continuous (not held)', 'dupFrac',dupFrac);
        warning('evm_from_tap:continuousMode', ...
            'mode %s: dup_frac=%.3f (<0.05) looks continuous/un-held; naive stride-decimate by Sps used (low confidence)', ...
            num2str(modeNum), dupFrac);
    else
        % Held stream: collapse consecutive-duplicate runs (take the LAST
        % sample of each run -- the most-settled value before the next update).
        edges = find(~same);
        runStarts = [1; edges+1]; %#ok<NASGU>
        runEnds   = [edges; numel(rawIQ)];
        collapsed = rawIQ(runEnds);
        runLens   = diff([0; runEnds]);
        medRun = median(runLens);
        detectedRateHz = cfg.Fs / medRun;
        ratioToRsym = detectedRateHz / cfg.Rsym;
        extraFactor = max(1, round(ratioToRsym));
        if abs(ratioToRsym - extraFactor) > 0.15
            conf = sprintf(['low -- detected collapsed rate %.0f Hz is not close to an ' ...
                'integer multiple of Rsym (%.0f Hz), ratio=%.3f'], detectedRateHz, cfg.Rsym, ratioToRsym);
        elseif extraFactor == 1
            conf = 'high -- collapsed rate matches Rsym directly (1 sample/symbol hold)';
        else
            conf = sprintf(['medium -- collapsed rate is %dx Rsym; extra decimate-by-%d ' ...
                'applied (keeps every %d-th collapsed sample)'], extraFactor, extraFactor, extraFactor);
        end
        sym = collapsed(extraFactor:extraFactor:end);
        res.decimation = struct( ...
            'method','duplicate-run collapse (take last sample of each held run)', ...
            'holdRunSamples',medRun, 'runLenStd',std(runLens), ...
            'detectedRateHz',detectedRateHz, 'ratioToRsym',ratioToRsym, ...
            'extraDecimateFactor',extraFactor, 'finalSymRateHz',detectedRateHz/extraFactor, ...
            'confidence',conf, ...
            'heldOrStrobed','held (debugValid-gated; recovered via consecutive-duplicate detection -- no explicit valid channel in the captured stream, see evm_config_240k.m)', ...
            'dupFrac',dupFrac);
        fprintf(['[evm_from_tap] mode %s: dup_frac=%.3f medianRun=%.1f (std=%.2f) -> ' ...
            'detected %.0f Hz (%.2fx Rsym); %s\n'], num2str(modeNum), dupFrac, medRun, ...
            std(runLens), detectedRateHz, ratioToRsym, conf);
    end
end
sym = sym(:);
res.nSymbols = numel(sym);

% ---- 3. frame sync (differential correlation vs known preamble; rotation-invariant) ----
preSyms  = cfg.PreambleSymbols(:);
nPre     = cfg.NPreambleSym;
frameLen = cfg.FrameLenSym;

globalRotDeg = 0;
res.nFrames = 0;
res.frameStarts = [];
if ~opts.skipFrameSync && numel(sym) >= frameLen
    [starts, ~] = local_framePeaks(sym, preSyms, nPre, frameLen);
    starts = local_refineStarts(sym, starts, preSyms, nPre, 4);
    res.nFrames = numel(starts);
    res.frameStarts = starts;
    if ~isempty(starts)
        rotDeg = zeros(numel(starts),1); mag = zeros(numel(starts),1);
        for kk = 1:numel(starts)
            s0 = starts(kk);
            pre = sym(s0:s0+nPre-1);
            Zc = sum(pre .* conj(preSyms));
            mag(kk) = abs(Zc);
            rotDeg(kk) = mod(round(angle(Zc)/(pi/2))*90, 360);
        end
        [~, ord] = sort(mag, 'descend');
        useIdx = ord(1:min(opts.ncleanresolve, numel(ord)));
        candRot = rotDeg(useIdx);
        u = unique(candRot);
        cnts = arrayfun(@(v) sum(candRot == v), u);
        [~, bi] = max(cnts);
        globalRotDeg = u(bi);
        res.rotVotes = struct('candidates',u, 'counts',cnts);
    end
end
res.globalRotDeg = globalRotDeg;
symDerot = sym * exp(-1i*deg2rad(globalRotDeg));

% ---- 4. full-signal EVM (shared metric core) --------------------------
mAll = evm_metrics(symDerot, cfg);
res.rms_evm   = mAll.rms_evm;
res.peak_evm  = mAll.peak_evm;
res.p95_evm   = mAll.p95;
res.p99_evm   = mAll.p99;
res.mag_evm   = mAll.mag_evm;
res.phase_evm = mAll.phase_evm;
res.evm_inst  = mAll.evm_inst;
res.phase_err = mAll.phase_err;

% NOTE: res.decimation.detectedRateHz is the pre-extra-decimation HELD-UPDATE
% rate (a diagnostic value); the actual sample rate of `sym`/`symDerot` after
% all decimation is res.decimation.finalSymRateHz -- use THAT for the time
% axis and the phase-error PSD, or both are stretched by extraDecimateFactor
% (or by cfg.Sps, in the continuous-mode fallback).
symRateHz = res.decimation.finalSymRateHz;
res.t = (0:numel(symDerot)-1).' / symRateHz;

% ---- 5. per-frame EVM, tick-flagging, preamble/payload split ----------
if res.nFrames > 0
    nF = res.nFrames;
    frameEVM = nan(nF,1);
    preIdxAll = zeros(0,1); payIdxAll = zeros(0,1);
    for kk = 1:nF
        s0 = res.frameStarts(kk);
        if s0 < 1 || s0+frameLen-1 > numel(symDerot), continue; end
        idxAll = (s0:s0+frameLen-1).';
        mF = evm_metrics(symDerot(idxAll), cfg);
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
    if ~isempty(preIdxAll)
        mPre = evm_metrics(symDerot(preIdxAll), cfg);
        res.preamble_evm = mPre.rms_evm;
    else
        res.preamble_evm = NaN;
    end
    if ~isempty(payIdxAll)
        mPay = evm_metrics(symDerot(payIdxAll), cfg);
        res.payload_evm = mPay.rms_evm;
    else
        res.payload_evm = NaN;
    end
else
    res.frameEVM = [];
    res.flaggedFrames = [];
    res.evm_all_frames = res.rms_evm;
    res.evm_excised = res.rms_evm;
    res.preamble_evm = NaN;
    res.payload_evm = NaN;
end

% ---- 6. phase-error PSD -------------------------------------------------
if numel(res.phase_err) >= 32
    [pxx, f] = pwelch(res.phase_err, [], [], [], symRateHz);
    res.psd_f = f; res.psd_pxx = pxx;
else
    res.psd_f = []; res.psd_pxx = [];
end

% ---- 7. plots ------------------------------------------------------------
res.figs = [];
if opts.plot
    figs = gobjects(0);

    fh = figure('Name', sprintf('EVM constellation: %s mode %s', res.label, num2str(mode)));
    plot(real(symDerot), imag(symDerot), '.', 'MarkerSize', 2); hold on;
    plot(real(cfg.IdealConstellation), imag(cfg.IdealConstellation), 'r*', 'MarkerSize', 12);
    axis equal; grid on; xlabel('I'); ylabel('Q');
    title(sprintf('Constellation (RMS EVM=%.2f%%)', res.rms_evm));
    figs(end+1) = fh;

    fh = figure('Name', 'EVM vs time');
    plot(res.t, res.evm_inst); grid on; xlabel('time (s)'); ylabel('EVM %');
    title(sprintf('Per-symbol EVM (mode %s)', num2str(mode)));
    figs(end+1) = fh;

    if ~isempty(res.frameEVM)
        fh = figure('Name', 'Per-frame EVM trace');
        plot(res.frameEVM, 'o-'); hold on;
        if ~isempty(res.flaggedFrames)
            plot(res.flaggedFrames, res.frameEVM(res.flaggedFrames), 'rx', 'MarkerSize', 10, 'LineWidth', 2);
        end
        grid on; xlabel('frame #'); ylabel('frame RMS EVM %');
        title(sprintf('Per-frame EVM (flagged=%d/%d, k=%.1f)', numel(res.flaggedFrames), res.nFrames, opts.k));
        figs(end+1) = fh;
    end

    if ~isempty(res.psd_f)
        fh = figure('Name', 'Phase-error PSD');
        plot(res.psd_f, 10*log10(res.psd_pxx)); hold on;
        xline(cfg.CarrierLoopBWHz, 'r--', sprintf('loop BW %.0f Hz', cfg.CarrierLoopBWHz));
        grid on; xlabel('Hz'); ylabel('dB/Hz');
        title('Carrier phase-error PSD');
        figs(end+1) = fh;
    end
    res.figs = figs;
end

% ---- 8. summary ----------------------------------------------------------
fprintf(['[evm_from_tap] %s mode %s: nSym=%d nFrames=%d globalRot=%d deg  ' ...
    'RMS EVM=%.2f%%  peak=%.2f%%  p95=%.2f%%  p99=%.2f%%  magEVM=%.2f%%  phaseEVM=%.2f%%\n'], ...
    res.label, num2str(mode), res.nSymbols, res.nFrames, res.globalRotDeg, ...
    res.rms_evm, res.peak_evm, res.p95_evm, res.p99_evm, res.mag_evm, res.phase_evm);
if res.nFrames > 0
    fprintf('[evm_from_tap] preamble EVM=%.2f%%  payload EVM=%.2f%%  all-frames EVM=%.2f%%  tick-excised EVM=%.2f%% (flagged %d frames)\n', ...
        res.preamble_evm, res.payload_evm, res.evm_all_frames, res.evm_excised, numel(res.flaggedFrames));
end

end

% ============================ helpers ====================================
function [ps0, pkv] = local_framePeaks(sym, preSyms, nPre, frameLenSym)
% Rotation-invariant preamble-frame search via differential correlation
% (adapted from k5_240/decode_ref_k5.m's framePeaks; parameterized here on
% nPre/frameLenSym so it is rate/frame-length agnostic -- decode_ref_k5.m
% itself is NOT modified).
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
