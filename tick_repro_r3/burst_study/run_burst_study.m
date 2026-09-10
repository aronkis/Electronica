function run_burst_study()
%RUN_BURST_STUDY  STAGE A': recovery length vs sample-slip size at R3 (f1536).
%
%   Splices single sample INSERTIONS and DELETIONS of {4,32,64,128,256,512}
%   samples (1..128 symbols at sps=4) into a segment of the REAL R3 reverse
%   capture two_jup/r3cap/hunt_auto_20260731_211829/pair.iq (genuine link IQ,
%   float-decodes clean), runs each through the float receiver
%   (bs_front_end = evm_ideal_ref front-end copy), and measures how many
%   frames after the injection are missed (no preamble sync at cadence -- the
%   hardware CRC-hard-fail analog) or EVM-degraded before recovery.
%
%   Bonus rows: 2-sample (half-symbol) slips -- the only non-integer-symbol
%   case, maximally disturbs Gardner timing phase.
%
%   Writes burst_study_results.mat + prints a markdown table (captured by the
%   caller into RESULTS.md).

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
addpath(here);
addpath(fullfile(repo, 'evm'));

cfg = evm_config_1536k();
frameLenSym = cfg.FrameLenSym; sps = cfg.Sps;

capfile = fullfile(repo,'two_jup','r3cap','hunt_auto_20260731_211829','pair.iq');
Nseg = 10e6;                       % 10 M samples @61.44 MSPS = 162 ms, ~202 frames
fid = fopen(capfile,'r'); assert(fid>0);
raw = fread(fid, 2*Nseg, 'int16'); fclose(fid);
x = double(raw(1:2:end)) + 1i*double(raw(2:2:end));
i0 = find(abs(x) > 0, 1); x = x(i0:end);
fprintf('[seg] %d samples (~%.0f frames), %d interior zeros, lead-skip %d\n', ...
    numel(x), numel(x)/sps/frameLenSym, sum(abs(x)==0), i0-1);

% ---- baseline ------------------------------------------------------------
t0 = tic; base = bs_front_end(x, cfg); tb = toc(t0);
baseMed = median(base.frameEVM); baseSig = std(base.frameEVM);
% spacing sanity: all detected frames at 12333-symbol cadence?
gaps = round(diff(base.ps)/frameLenSym) - 1;
fprintf('[base] %d frames CFO=%.0fHz EVM med=%.2f%% sig=%.2f%% missedslots=%d (%.0fs)\n', ...
    base.nFrames, base.coarseCFO, baseMed, baseSig, sum(gaps), tb);

evmThr = max(baseMed + 5*baseSig, 1.5*baseMed);
pcThr  = 0.5;
fprintf('[thr] degraded if frameEVM > %.2f%% or preCorr < %.2f\n', evmThr, pcThr);

% ---- injection point: mid-frame, ~frame 50 of the baseline ---------------
j0 = min(50, base.nFrames - 120);
injSymBase = base.ps(j0) + round(frameLenSym/2);   % mid-frame, symbol domain
n0 = round(injSymBase * sps);                       % approx raw-sample offset
fprintf('[inj] baseline frame %d mid-frame -> symbol ~%d, raw sample n0=%d (%.1f frames from end: %d)\n', ...
    j0, injSymBase, n0, (numel(x)-n0)/(sps*frameLenSym), base.nFrames - j0);

% ---- the run matrix ------------------------------------------------------
sizes = [2 4 32 64 128 256 512];   % 2 = bonus half-symbol row
kinds = {'insert','delete'};
rows = struct('kind',{},'N',{},'nsym',{},'score',{},'cfo',{},'nF',{});

for si = 1:numel(sizes)
    for ki = 1:numel(kinds)
        N = sizes(si); kind = kinds{ki};
        y = bs_perturb(x, n0, N, kind);
        t0 = tic; r = bs_front_end(y, cfg); tr = toc(t0);
        sc = bs_score(r, base, injSymBase, frameLenSym, evmThr, pcThr);
        r = rmfield(r, 'paySym');    % keep the .mat small
        rows(end+1) = struct('kind',kind,'N',N,'nsym',N/sps,'score',sc, ...
            'cfo',r.coarseCFO,'nF',r.nFrames); %#ok<AGROW>
        fprintf(['[run] %-6s %4d samp (%5.1f sym): missed=%d degraded=%d crcfail=%d ' ...
            'recover=%d peakEVM=%.1f%% ser=[%s] (%.0fs)\n'], ...
            kind, N, N/sps, sc.framesMissed, sc.framesDegraded, sc.framesCRCFail, ...
            sc.framesToRecover, sc.peakEVM, strtrim(sprintf('%.3f ', sc.serTrail)), tr);
    end
end

baseSlim = rmfield(base, 'paySym');
save(fullfile(here,'burst_study_results.mat'), 'rows', 'baseSlim', 'baseMed', ...
    'baseSig', 'evmThr', 'pcThr', 'n0', 'injSymBase', 'j0', '-v7.3');

% ---- markdown table ------------------------------------------------------
fprintf('\n== TABLE ==\n');
fprintf(['| Slip | Samples | Symbols | Frames missed (sync) | Frames degraded (EVM) | ' ...
    'Frames CRC-fail (payload mismatch) | Frames to recover | Peak frame EVM |\n']);
fprintf('|---|---|---|---|---|---|---|---|\n');
for i = 1:numel(rows)
    r = rows(i); sc = r.score;
    fprintf('| %s | %d | %.1f | %d | %d | %d | **%d** | %.1f%% |\n', ...
        r.kind, r.N, r.nsym, sc.framesMissed, sc.framesDegraded, ...
        sc.framesCRCFail, sc.framesToRecover, sc.peakEVM);
end
fprintf('== END TABLE ==\n');
end
