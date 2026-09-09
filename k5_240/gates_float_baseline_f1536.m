function gates_float_baseline_f1536()
%GATES_FLOAT_BASELINE_F1536  G1/G2/G3 -- run before any air number is believed.
pass = true;

here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..', 'evm'));
cfg = evm_config_1536k();
oneCyclePerFrameHz = cfg.Rsym/cfg.FrameLenSym;   % ~1245 Hz at f1536

% ---- G1: synthetic positive control -- clean waveform must be bit-perfect ----
r = float_baseline_f1536(synth_f1536_waveform(4));
g1 = (r.bitErrors == 0) && (r.nFrames >= 3) && r.hypStable;
fprintf('G1 positive control : frames=%d bitErrors=%d hypStable=%d -> %s\n', ...
        r.nFrames, r.bitErrors, r.hypStable, tf(g1));
pass = pass && g1;

% ---- G1b: zero-CFO sanity check -- synth_f1536_waveform() has NO frequency
% offset by construction (it does not even accept a CFO-injection opts field),
% so the coarse CFO actually applied by the front end should be small compared
% to one preamble-correlation cycle per frame (Rsym/frameLenSym). Added
% 2026-08-24 after this exact check caught the front end fabricating a
% ~2.7 kHz "correction" (2+ cycles of phase drift per frame) on a genuinely
% zero-CFO waveform -- see task-3-report.md. If the estimator is inventing an
% offset, no air CFO number from this receiver can be trusted, so this check
% is permanent, not a one-off diagnostic.
g1b = abs(r.cfoAppliedHz) < oneCyclePerFrameHz;
fprintf('G1b zero-CFO sanity : cfoApplied=%.0f Hz  bound=%.0f Hz (1 cycle/frame) -> %s\n', ...
        r.cfoAppliedHz, oneCyclePerFrameHz, tf(g1b));
pass = pass && g1b;

% ---- G2: AWGN ladder -- BER must FALL MONOTONICALLY as Es/N0 rises, be high
% at low Es/N0, and reach 0 when clean. A mis-scaled decoder fails this even
% though it "runs": its BER is flat or noise-independent.
% Extended 2026-08-24 (Task 1) to [0 3 6 8 9 10 12] to locate the validated-
% SNR floor for the A3 verdict. See task-1-report.md for the full diagnosis:
%  - errPosProfile at 9 dB is FLAT across all 10 deciles, not tail-heavy ->
%    the brief's leading suspect (single per-frame preamble derotation
%    drifting across 12320 payload symbols) is REFUTED.
%  - loopbw sweep (0.001-0.05) at 9 dB stayed flat at ~0.499 chance ber ->
%    also refuted as the driver.
%  - ROOT CAUSE (found via the SAME named suspect, precorrthresh): with the
%    old 0.5 threshold, spurious frame-sync candidates (this synthetic
%    waveform repeats identical payload data every frame, raising off-lattice
%    self-correlation sidelobes) land in the 2-frame mapping-calibration set
%    and corrupt the GLOBAL quadrant->label mapping for the whole capture,
%    which is what actually produces the chance-level (~0.499) bit-error
%    plateau -- NOT a smooth noise-driven BER curve. Fixed by raising the
%    default precorrthresh to 0.8 (see float_baseline_f1536.m); this is now
%    baked into the receiver's default, not a gate-side workaround.
% rng seeded here (not in the receiver -- synth_f1536_waveform has no seed
% parameter and is out of scope to modify) so FLOOR_DB is reproducible run to
% run; a 7-seed sweep (documented in task-1-report.md) is the basis for the
% VALIDATED_ESN0_FLOOR_DB constant, which is set to the seed-ROBUST value,
% not necessarily this single run's printed FLOOR_DB.
rng(2026, 'twister');
esn0 = [0 3 6 8 9 10 12];
ber  = nan(size(esn0));
nFr  = zeros(size(esn0));
for k = 1:numel(esn0)
    try
        rk = float_baseline_f1536(synth_f1536_waveform(6, struct('esn0_db', esn0(k))));
        ber(k) = rk.ber;
        nFr(k) = rk.nFrames;
    catch err
        % Fix round 1 (2026-08-24, code review): filter on identifier. Only
        % the receiver's OWN "no candidate passed the preCorr gate" signal
        % (raised at float_baseline_f1536.m:316 and :429, both under this one
        % identifier) is a genuine link failure to be scored as ber=1 (not
        % silently skipped, so the ladder still records a data point instead
        % of a gap). Any OTHER exception -- an index error, a dimension
        % mismatch, a typo introduced next month -- is a real bug and must
        % CRASH, not get laundered into a plausible-looking ber=1 sample.
        % This is this project's signature failure mode (instruments quietly
        % converting bugs into data), and this catch block was exactly the
        % kind of unfiltered catch that does it.
        if strcmp(err.identifier, 'float_baseline_f1536:noDecodableFrames')
            % No candidate frame passed the preamble-correlation gate at
            % all -- total link failure at this Es/N0. NOTE: scoring this as
            % ber=1 is a CONVENTION, not evidence the receiver is somehow
            % "worse" at a higher Es/N0 than a lower one where it happened
            % to lock onto one bad frame and score e.g. ber=0.49 -- both are
            % total link failures; ranking "locked-but-wrong" above
            % "never-locked" is an artifact of this convention, and is the
            % documented cause of any apparent non-monotonicity below the
            % validated floor (see task-1-report.md).
            ber(k) = 1;
            nFr(k) = 0;
            fprintf('G2 ladder Es/N0=%2d dB : NO DECODABLE FRAMES (%s) -> ber scored as 1\n', esn0(k), err.identifier);
        else
            rethrow(err);
        end
    end
    fprintf('G2 ladder Es/N0=%2d dB : ber=%.3e  nFrames=%d\n', esn0(k), ber(k), nFr(k));
end
g2 = all(diff(ber) <= 1e-12) && ber(1) > ber(end) && ber(end) < 1e-4;
fprintf('G2 AWGN ladder      : monotonic-decreasing=%d  span %.3e -> %.3e -> %s\n', ...
        all(diff(ber) <= 1e-12), ber(1), ber(end), tf(g2));
pass = pass && g2;

% ---- FLOOR: lowest rung with zero bit errors AND nFrames>=3 (G1's own bar
% -- a "0 bit errors" reading on 1-2 surviving frames is a survivor-biased
% sample, not a floor measurement; see task-1-report.md) ----
eligible = find(ber == 0 & nFr >= 3);
if isempty(eligible)
    floorDb = NaN;
else
    floorDb = esn0(min(eligible));
end
fprintf('FLOOR_DB=%g\n', floorDb);
fprintf('  (this is the single-seeded-run reading; the authoritative, cross-seed-validated number is VALIDATED_ESN0_FLOOR_DB in float_baseline_f1536.m -- see task-1-report.md)\n');

% ---- G3: planted fault -- flip 2000 known coded bits per frame; the scorer
% must report a NONZERO error count, and the clean leg must still be zero.
% Magnitude history (measured 2026-08-24, see task-3-report.md): 37 and even
% 600 evenly-spread single-bit flips out of CODED=24592 coded bits are BOTH
% fully corrected by the K=5 rate-1/2 Viterbi decoder (0 residual info-bit
% errors) -- that is the code doing its job, not the scorer failing to look.
% Failure (i.e. errors surviving decode) was only observed past ~1200 flips.
% 2000 is comfortably past that measured threshold.
R = f1536_ref_bits();
flip = round(linspace(100, R.CODED-100, 2000));
rf = float_baseline_f1536(synth_f1536_waveform(4, struct('flipIdx', flip)));
rc = float_baseline_f1536(synth_f1536_waveform(4));
g3 = (rf.bitErrors > 0) && (rc.bitErrors == 0);
fprintf('G3 planted fault    : planted=%d faulted-run errors=%d clean-run errors=%d -> %s\n', ...
        numel(flip), rf.bitErrors, rc.bitErrors, tf(g3));
pass = pass && g3;

fprintf('%s\n', ternary(pass, 'GATES_PASS', 'GATES_FAIL'));
end

function s = tf(b),        if b, s='PASS'; else, s='FAIL'; end, end
function s = ternary(c,a,b), if c, s=a; else, s=b; end, end
