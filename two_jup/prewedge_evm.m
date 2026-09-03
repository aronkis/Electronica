function prewedge_evm(iqfile, reglog, anchorfile)
%PREWEDGE_EVM  EVM in sliding windows across a capture that spans the pre-wedge rise.
%
%   Answers one question: as biterr climbs (5.3 s before the wedge, while cfc, rstcs,
%   maxGap and agc_level all stay nominal), does the CONSTELLATION degrade?
%     EVM rises with biterr -> signal quality (TX-side or channel)
%     EVM flat while biterr rises -> demodulator/slicer, i.e. fixed point
%
%   The comparison is WITHIN one capture -- a clean stretch and a degrading stretch of
%   the same run, same gain, same LO -- so no cross-run normalisation is involved. That
%   matters here: cross-run comparison on this rig has been wrong repeatedly.

here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..', 'evm'));
addpath(fullfile(here, '..', 'tick_repro_r3', 'burst_study'));
cfg = evm_config_1536k();

fid = fopen(iqfile, 'rb');
if fid < 0, error('cannot open %s', iqfile); end
raw = fread(fid, Inf, 'int16=>double');
fclose(fid);
iq = complex(raw(1:2:end), raw(2:2:end));
fs = 61.44e6;
fprintf('IQ: %d samples (%.3f s)\n', numel(iq), numel(iq)/fs);

% --- biterr timeline from the register log -----------------------------------------
txt = fileread(reglog);
tk  = regexp(txt, 't=([\d.]+) cap=0x([0-9a-fA-F]+) cfc=0x([0-9a-fA-F]+) biterr=0x([0-9a-fA-F]+)', 'tokens');
if isempty(tk)
    warning('no register samples parsed; EVM reported without biterr alignment');
    tr = []; ber = [];
else
    tr  = cellfun(@(c) str2double(c{1}), tk);
    ber = cellfun(@(c) hex2dec(c{4}),    tk);
    tr  = tr - tr(1);
    dber = [0; diff(ber(:))];
    firstbad = find(dber > 0, 1);
    if isempty(firstbad)
        fprintf('biterr never advanced during the register window\n');
    else
        fprintf('biterr first advances at t=%.2f s (of %.2f s logged)\n', tr(firstbad), tr(end));
    end
end

% --- EVM in sliding windows ---------------------------------------------------------
win = round(0.10 * fs);                 % 100 ms windows ~ 124 frames each
nw  = floor(numel(iq) / win);
fprintf('\n%6s %10s %10s %10s\n', 'win', 't_start', 'rms_evm', 'nFrames');
ev = nan(nw,1); tw = nan(nw,1);
for k = 1:nw
    seg = iq((k-1)*win + (1:win));
    tw(k) = (k-1)*win/fs;
    try
        r = bs_front_end(seg, cfg, struct());
        if isempty(r.frameEVM), continue; end
        % A window that syncs only a handful of frames has a MEANINGLESS EVM: rep 3
        % window 6 reported 59.52%% off nFrames=2 against 124 elsewhere, which reads as
        % an RF excursion and is actually a sync failure. Require most of the expected
        % frame count before trusting the number.
        expF = win / (cfg.Sps * 12333);
        if numel(r.frameEVM) < 0.5 * expF
            fprintf('%6d %9.3fs   (only %d frames synced of ~%.0f -- window rejected)\n', ...
                    k, tw(k), numel(r.frameEVM), expF);
            continue;
        end
        ev(k) = median(r.frameEVM);
        fprintf('%6d %9.3fs %9.2f%% %10d\n', k, tw(k), ev(k), numel(r.frameEVM));
    catch e
        fprintf('%6d %9.3fs   (front end failed: %s)\n', k, tw(k), e.message);
    end
end

ok = ~isnan(ev);
if nnz(ok) >= 3
    fprintf('\nEVM across capture: first=%.2f%%  last=%.2f%%  min=%.2f%%  max=%.2f%%\n', ...
            ev(find(ok,1)), ev(find(ok,1,'last')), min(ev(ok)), max(ev(ok)));
    % split at the biterr onset if we have it, else halves
    if ~isempty(tr) && exist('firstbad','var') && ~isempty(firstbad)
        tsplit = tr(firstbad);
    else
        tsplit = tw(round(nw/2));
    end
    a = ok & (tw <  tsplit);
    b = ok & (tw >= tsplit);
    if nnz(a) >= 2 && nnz(b) >= 2
        fprintf('\nSPLIT AT t=%.2fs (biterr onset):\n', tsplit);
        fprintf('  clean stretch : n=%d  median EVM %.2f%%\n', nnz(a), median(ev(a)));
        fprintf('  degrading     : n=%d  median EVM %.2f%%\n', nnz(b), median(ev(b)));
        d = median(ev(b)) - median(ev(a));
        fprintf('  delta = %+.2f pp\n', d);
        if d > 1.0
            fprintf('\n  >>> EVM RISES with biterr -> SIGNAL QUALITY (TX-side or channel)\n');
        elseif abs(d) <= 1.0
            fprintf('\n  >>> EVM FLAT while biterr rises -> DEMOD/SLICER (fixed point),\n');
            fprintf('      NOT signal quality. The samples stay clean; the bits do not.\n');
        else
            fprintf('\n  >>> EVM FELL while biterr rose -- unexpected; inspect before concluding\n');
        end
    else
        fprintf('\n  (not enough windows either side of the split to compare)\n');
    end
else
    fprintf('\ntoo few usable EVM windows (%d) -- front end may not be syncing\n', nnz(ok));
end
end
