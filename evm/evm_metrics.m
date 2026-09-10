function m = evm_metrics(y, cfg, opts)
%EVM_METRICS  Shared EVM metric core, used by both evm_from_tap and
%   evm_ideal_ref so the two instruments report numbers computed the same way.
%
%   m = evm_metrics(y, cfg) takes a column vector of 1-sample/symbol complex
%   values y (any phase/gain normalization is fine -- this function hard-
%   decides and normalizes internally) and returns a struct with:
%     .yhat        ideal pi/4-Gray QPSK point nearest each y (hard decision)
%     .evm_inst    per-symbol EVM %, normalized to cfg.RefRMS
%     .rms_evm     RMS EVM %
%     .peak_evm    peak (max) EVM %
%     .p95, .p99   95th / 99th percentile EVM %
%     .mag_evm     magnitude-error EVM % : rms(|y|-|yhat|) / RefRMS * 100
%     .phase_evm   phase-error EVM %     : rms(angle(y.*conj(yhat))) * 100
%                  (radians-as-percent, per task-C1 brief formula, verbatim)
%     .phase_err   per-symbol phase error (rad), angle(y.*conj(yhat))
%     .mag_err     per-symbol magnitude error, |y|-|yhat|
%
%   opts.gainNorm (default true): rescale y so mean(|y|) == cfg.RefRMS before
%   hard-decision / EVM, matching typical EVM-instrument AGC-normalization
%   convention (removes a global amplitude scale ambiguity that is not a
%   modulation-quality impairment).

if nargin < 3, opts = struct(); end
if ~isfield(opts,'gainNorm'), opts.gainNorm = true; end

y = y(:);
if isempty(y)
    m = struct('yhat',[],'evm_inst',[],'rms_evm',NaN,'peak_evm',NaN,'p95',NaN,'p99',NaN, ...
        'mag_evm',NaN,'phase_evm',NaN,'phase_err',[],'mag_err',[]);
    return;
end

if opts.gainNorm
    g = mean(abs(y));
    if g > 0, y = y * (cfg.RefRMS / g); end
end

% hard decision to nearest pi/4-Gray point (cfg.IdealConstellation)
ideal = cfg.IdealConstellation(:).';
d2 = abs(y - ideal).^2;              % Nsym x 4
[~, idx] = min(d2, [], 2);
yhat = ideal(idx).';

e = y - yhat;
evm_inst = 100 * abs(e) / cfg.RefRMS;

mag_err   = abs(y) - abs(yhat);
phase_err = angle(y .* conj(yhat));

m.yhat      = yhat;
m.evm_inst  = evm_inst;
m.rms_evm   = sqrt(mean(evm_inst.^2));
m.peak_evm  = max(evm_inst);
m.p95       = prctile_local(evm_inst, 95);
m.p99       = prctile_local(evm_inst, 99);
m.mag_evm   = 100 * sqrt(mean(mag_err.^2)) / cfg.RefRMS;
m.phase_evm = 100 * sqrt(mean(phase_err.^2));
m.phase_err = phase_err;
m.mag_err   = mag_err;

end

function p = prctile_local(x, q)
% Percentile without requiring Statistics Toolbox's prctile in all
% environments -- simple linear-interpolation order-statistic estimator.
x = sort(x(:));
n = numel(x);
if n == 0, p = NaN; return; end
if n == 1, p = x(1); return; end
r = (q/100) * (n-1) + 1;
lo = floor(r); hi = ceil(r);
if lo < 1, lo = 1; end
if hi > n, hi = n; end
frac = r - lo;
p = x(lo) + frac * (x(hi) - x(lo));
end
