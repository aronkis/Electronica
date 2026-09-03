function k300_float_probe(iqfile, k0, k1, outcsv)
%K300_FLOAT_PROBE  Float front end over a frame window, to answer ONE question
%   about k=300: are the SAMPLES bad there, or are the samples fine and the
%   fixed-point receiver is what fails?
%
%   k300_float_probe(iqfile, k0, k1, outcsv)
%
% WHY THIS AND NOT THE HYBRID LADDER. The ladder (k5_240/hybrid_ladder_k5.m)
% needs per-stage fixed-point taps from a tap-instrumented netlist
% (wrap_byte_taps.v exposes agc/rrc/ss/cfc/cs/pd/pa/con/dem/fec). Only a 240k
% tap build exists (obj_byte_taps). The f1536 netlist survives ONLY as a
% compiled archive (obj_byte_f1536/Vwrap_byte__ALL.a, Jul 25) whose wrapper
% exposes byte_rx_* and the counters -- no stage taps -- and the current
% generated HDL is k5 geometry (2240 payload bits / 1120 symbols, verified;
% f1536 is 24640/12333). So stage-level localisation at R3 needs an f1536 HDL
% regeneration + tap Verilate first. This probe is what can be answered TODAY.
%
% WHAT IT CAN AND CANNOT CONCLUDE.
%   CAN: whether frame k=300's samples are anomalous (EVM / preamble
%        correlation / detected-cadence) relative to its neighbours.
%   CANNOT: which fixed-point stage diverges. That is the ladder's job and it
%        is blocked. Do not report this as a stage localisation.
%
% Reading:
%   k=300 EVM/preCorr in family with neighbours  -> samples are FINE, so the
%        netlist's CRC failure on them is a FIXED-POINT/implementation failure.
%        That is the result that justifies building the f1536 tap netlist.
%   k=300 EVM elevated / preCorr collapsed       -> the samples are disturbed
%        there; the netlist is failing on genuinely bad input and there may be
%        no implementation bug to find at this frame.

if nargin < 4, outcsv = ''; end
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..', 'evm'));
addpath(fullfile(here, '..', 'tick_repro_r3', 'burst_study'));

cfg = evm_config_1536k();
SPF = 49332;                       % f1536 samples per frame (12333 sym x sps4)

% Read [k0, k1] inclusive, plus a frame of lead-in so the front end can acquire
% before the window of interest starts.
lead = 2;
kstart = max(k0 - lead, 0);
off    = kstart * SPF;
nsamp  = (k1 - kstart + 1) * SPF;

fprintf('=== k300_float_probe: %s  frames %d..%d (read from k=%d) ===\n', ...
        iqfile, k0, k1, kstart);
fid = fopen(iqfile, 'rb');
if fid < 0, error('cannot open %s', iqfile); end
fseek(fid, 2 * 2 * off, 'bof');                 % int16 I,Q -> 4 bytes/sample
raw = fread(fid, 2 * nsamp, 'int16=>double');
fclose(fid);
iq = complex(raw(1:2:end), raw(2:2:end));
fprintf('loaded %d complex samples (%.3f s)\n', numel(iq), numel(iq) / cfg.Fs);

res = bs_front_end(iq, cfg, struct());
ps  = res.ps(:); ev = res.frameEVM(:); pc = res.preCorr(:);
fprintf('front end detected %d frames\n', numel(ps));

% Map each detected frame start back to an absolute capture-frame index.
kabs = kstart + round((ps - ps(1)) / 12333);
% anchor: the first detected frame corresponds to kstart (+/- acquisition slip)

fprintf('\n  k      EVM%%    preCorr\n');
rows = [];
for i = 1:numel(kabs)
    k = kabs(i);
    if k < k0 || k > k1, continue; end
    mark = '';
    if k == 300 || k == 330, mark = '   <== netlist CRC FAIL here'; end
    fprintf('  %-5d  %6.2f  %7.3f%s\n', k, ev(i), pc(i), mark);
    rows(end+1, :) = [k, ev(i), pc(i)]; %#ok<AGROW>
end

if isempty(rows), error('no frames landed in the requested window'); end

% Compare the frames of interest against the rest of the window. Threshold is
% fixed BEFORE looking: >1.0 pp of EVM is the same "signal quality changed" bar
% this campaign used for the pre-wedge EVM work, so the call is not tuned to
% whatever this data happens to show.
EVM_PP = 1.0;
for kk = [300 330]
    idx = rows(:,1) == kk;
    if ~any(idx), fprintf('\n  k=%d not detected in this window\n', kk); continue; end
    other = rows(rows(:,1) ~= kk, :);
    dEVM  = rows(idx,2) - median(other(:,2));
    dPC   = rows(idx,3) - median(other(:,3));
    fprintf('\n  k=%d: EVM %.2f%% vs neighbour median %.2f%% (delta %+.2f pp)\n', ...
            kk, rows(idx,2), median(other(:,2)), dEVM);
    fprintf('        preCorr %.3f vs %.3f (delta %+.3f)\n', ...
            rows(idx,3), median(other(:,3)), dPC);
    % DIRECTION MATTERS. The first version tested |dEVM| and so read k=300's
    % BELOW-baseline EVM (3.39%% vs 5.06%%) as "disturbed". It is not: a frame whose
    % EVM is better than its neighbours is not a damaged frame. What is actually
    % anomalous is the +16 pp SPIKE on the FOLLOWING frame (k=301: 21.19%%), which
    % is the signature of a sample-domain discontinuity at the k/k+1 boundary --
    % the front end absorbs it into the next frame's estimate.
    nxt = rows(rows(:,1) == kk+1, :);
    if ~isempty(nxt) && nxt(2) - median(other(:,2)) > 5*EVM_PP
        fprintf('        >>> BOUNDARY DISCONTINUITY: next frame k=%d EVM %.2f%% (%+.1f pp).\n', ...
                kk+1, nxt(2), nxt(2) - median(other(:,2)));
        fprintf('            A sample insertion/deletion at the k=%d/%d boundary, NOT a\n', kk, kk+1);
        fprintf('            fixed-point arithmetic fault. The hybrid ladder is the wrong\n');
        fprintf('            instrument for this frame -- localise the splice instead.\n');
    elseif dEVM > EVM_PP
        fprintf('        >>> SAMPLES DEGRADED at this frame (+%.2f pp) -- bad input, not\n', dEVM);
        fprintf('            necessarily an implementation bug.\n');
    else
        fprintf('        >>> SAMPLES ARE FINE here (dEVM %+.2f pp). The netlist fails CRC on\n', dEVM);
        fprintf('            clean samples -> FIXED-POINT/implementation failure.\n');
    end
end

if ~isempty(outcsv)
    f = fopen(outcsv, 'w'); fprintf(f, 'k,evm_pct,precorr\n');
    fprintf(f, '%d,%.4f,%.4f\n', rows.');
    fclose(f); fprintf('\nwrote %s\n', outcsv);
end
end
