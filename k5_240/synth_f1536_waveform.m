function [wf, cfg] = synth_f1536_waveform(nFrames, opts)
%SYNTH_F1536_WAVEFORM  Clean f1536 baseband at sps=4 with KNOWN content.
%
% Used by the G1/G2/G3 gates. opts.esn0_db (default Inf = noiseless);
% opts.flipIdx = payload-bit indices to flip in EVERY frame (G3 planted fault).
% The reference returned by f1536_ref_bits() is NOT modified -- the fault is
% planted in the transmitted waveform only, so the scorer must find it.
if nargin < 2, opts = struct(); end
allowedFields = {'esn0_db','flipIdx'};
extra = setdiff(fieldnames(opts), allowedFields);
assert(isempty(extra), 'synth_f1536_waveform: unrecognized opts field(s): %s', ...
    strjoin(extra, ', '));
if ~isfield(opts,'esn0_db'), opts.esn0_db = Inf; end
if ~isfield(opts,'flipIdx'), opts.flipIdx = []; end

here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..', 'evm'));
cfg = evm_config_1536k();
R   = f1536_ref_bits();

bits = R.payload;
if ~isempty(opts.flipIdx)
    bits(opts.flipIdx) = 1 - bits(opts.flipIdx);
end

% bit pairs -> pi/4-Gray QPSK. Index = 2*b(1) + b(2); the ABSOLUTE mapping does
% not need to match the DUT, because the scorer resolves rotation and I/Q swap
% globally (see float_baseline_f1536.m). What matters is that it is CONSISTENT.
pairs = reshape(bits, 2, []).';
idx   = 2*pairs(:,1) + pairs(:,2);
paySym = cfg.IdealConstellation(idx+1).';
assert(numel(paySym) == cfg.PaySymPerFrame);

oneFrame = [cfg.PreambleSymbols(:); paySym];
assert(numel(oneFrame) == cfg.FrameLenSym);
% NOTE: all nFrames repeats carry IDENTICAL payload data -- only the AWGN
% draw (if any) differs frame to frame. So "N frames" is N noise draws of a
% single data realization, not N independent data realizations; any
% denominator quoted downstream from multi-frame stats must carry this caveat.
sym = repmat(oneFrame, nFrames, 1);

% upsample + sqrt-RRC pulse shape at sps=4
up = upsample(sym, cfg.Sps);
rrc = rcosdesign(cfg.Beta, cfg.RrcSpan, cfg.Sps);
wf  = conv(up, rrc, 'same');

if isfinite(opts.esn0_db)
    % Es/N0 convention: Es is energy per SYMBOL, i.e. per-sample signal power
    % times Sps. Noise is complex AWGN at sample rate. Measured from the actual
    % post-RRC waveform rather than from the pre-upsample constellation, because
    % upsampling and pulse shaping change the power by Sps and by the RRC gain.
    Ps     = mean(abs(wf).^2);
    esn0   = 10^(opts.esn0_db/10);
    sigma2 = Ps * cfg.Sps / esn0;
    n = sqrt(sigma2/2) * (randn(size(wf)) + 1i*randn(size(wf)));
    wf = wf + n;
end
wf = wf(:);
end
