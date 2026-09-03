function float_oracle_r3(iqfile, nsamp, outcsv)
%FLOAT_ORACLE_R3  Float receiver as an ORACLE over banked R3 field captures.
%
%   float_oracle_r3(iqfile, nsamp, outcsv)
%
% PURPOSE. Separate "channel/algorithm limited" from "implementation limited" on
% real field I/Q. The float front end is the algorithmic ceiling: whatever it
% cannot recover is a property of the SAMPLES (channel, LO, SNR), not of any
% implementation. Whatever it recovers but the hardware lost is implementation
% gap -- and the point of this campaign is that the gap need not be fixed-point
% arithmetic; on R3 the evidence says it is host-side transport.
%
% WHAT THIS MEASURES, precisely, and what it does NOT.
%   MEASURES: front-end frame recovery on the captured samples --
%     * frames detected vs expected at the 12333-symbol cadence (sync misses),
%     * per-frame RMS EVM and preamble correlation,
%     * the fraction of frames that are DEGRADED by EVM / preamble-corr.
%   DOES NOT measure a full-chain float FER: that needs deinterleave + Viterbi +
%   byte-pack + the frame CRC, which exists for 240k (k5_240/decode_ref_k5.m)
%   but is not ported to f1536 geometry. These captures carry live qpsk_perf
%   traffic (arbitrary payload), so bs_score's baseline-comparison CRC proxy
%   does not apply either -- it needs a known reference stream.
%
%   So the number produced here is an UPPER BOUND on the algorithmic ceiling:
%   if the front end recovers every frame cleanly, full-chain float FER can only
%   be <= that, and the algorithmic ceiling is ~0. If the front end already
%   fails frames, that failure rate is a floor on what any receiver can do with
%   these samples.
%
% Report a bound as a bound. Do not call it an FER.

if nargin < 2 || isempty(nsamp), nsamp = 8e6; end     % ~160 frames, tractable
if nargin < 3, outcsv = ''; end

here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..', 'evm'));
addpath(fullfile(here, '..', 'tick_repro_r3', 'burst_study'));

cfg = evm_config_1536k();
sps = cfg.Sps;
frameLenSym = 12333;                                  % f1536 geometry

fprintf('=== float_oracle_r3: %s (first %g samples) ===\n', iqfile, nsamp);

% int16 interleaved I,Q, raw ADC scale
fid = fopen(iqfile, 'rb');
if fid < 0, error('cannot open %s', iqfile); end
raw = fread(fid, 2*nsamp, 'int16=>double');
fclose(fid);
iq = complex(raw(1:2:end), raw(2:2:end));
fprintf('loaded %d complex samples (%.2f s at 61.44 MSPS)\n', numel(iq), numel(iq)/61.44e6);

opts = struct();
res = bs_front_end(iq, cfg, opts);

nF   = numel(res.ps);
% expected frames from the recovered symbol span, not from the sample count:
% sync loss at the head/tail should not be charged as a missed frame
span = (max(res.ps) - min(res.ps));
nExp = floor(span / frameLenSym) + 1;

% cadence gaps: a detected-start sequence that skips an expected slot
d = diff(res.ps(:));
gaps = sum(round(d / frameLenSym) - 1);

ev = res.frameEVM(:);
pc = res.preCorr(:);
evmThr = 25;      % %, generous: the population sits ~13-14%
pcThr  = 0.5;
degraded = sum(ev > evmThr | pc < pcThr);

fprintf('\n--- FRONT-END RECOVERY (algorithmic ceiling bound) ---\n');
fprintf('frames detected      : %d\n', nF);
fprintf('frames expected      : %d (from %d-symbol span)\n', nExp, span);
fprintf('cadence gaps (missed): %d\n', gaps);
fprintf('degraded (EVM>%.0f%% or preCorr<%.2f): %d\n', evmThr, pcThr, degraded);
fprintf('EVM  median %.2f%%  p95 %.2f%%  max %.2f%%\n', ...
        median(ev), prctile(ev, 95), max(ev));
fprintf('preCorr median %.3f  min %.3f\n', median(pc), min(pc));
badFrac = 100 * (gaps + degraded) / max(nExp, 1);
fprintf('\nFRONT-END FAILURE BOUND: %.4f%%  (%d of %d)\n', badFrac, gaps + degraded, nExp);
fprintf('  -> algorithmic ceiling is AT MOST this; a full-chain float decode\n');
fprintf('     (deint+Viterbi+CRC) could only find MORE frames recoverable.\n');

if ~isempty(outcsv)
    fid = fopen(outcsv, 'a');
    if fid > 0
        [~, nm] = fileparts(iqfile);
        fprintf(fid, '%s,%d,%d,%d,%d,%.4f,%.3f,%.3f,%.4f\n', nm, nF, nExp, gaps, ...
                degraded, median(ev), prctile(ev,95), median(pc), badFrac);
        fclose(fid);
    end
end
end
