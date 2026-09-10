function res = evm_selftest()
%EVM_SELFTEST  Synthetic correctness gate for the EVM instrument (task C1).
%
%   Generates pi/4-Gray QPSK FRAMES (real preamble + random payload symbols,
%   from cfg.PreambleSymbols/cfg.FrameLenSym -- exercises the same frame-sync
%   + global-rotation-resolution code path evm_from_tap uses on real
%   captures), applies:
%     - a coarse constant phase offset (tests 90-deg ambiguity resolution --
%       residual after quadrant-snap is < 45 deg, as a locked carrier-sync
%       loop would leave)
%     - small carrier phase noise (loop jitter)
%     - complex AWGN at a KNOWN, MEASURED Es/N0 (added directly on the
%       symbol-rate samples -- no pulse shaping/matched filtering in this
%       test, so there is no processing gain to confound the EVM/SNR check;
%       see task brief + advisor note)
%   at two SNR points, and checks measured RMS EVM against the COMBINED
%   theory EVM% ~= sqrt((100/sqrt(SNR_lin))^2 + EVM_pn^2), where EVM_pn is
%   the injected phase-noise term (RMS phase noise in radians x 100,
%   small-angle approx). Comparing against pure-AWGN theory alone would be
%   contaminated by the phase-noise term also injected below, understating
%   the gate's real sensitivity; combining both terms lets the tolerance be
%   tightened to 5%.
%
%   Separately, the 4-fold quadrant-rotation-ambiguity resolver is swept
%   across all four quadrants (0/90/180/270 deg) and checked for an exact
%   match against res.globalRotDeg.
%
%   res.pass is true iff both SNR points and all four rotation-sweep points
%   pass. Numbers are printed and returned in res.

cfg = evm_config_240k();
rng(12345);

snrPointsDb = [15 22];
nFramesPerTest = 40;
phaseNoiseDegRms = 2.0;      % small loop-jitter proxy
% Exactly a multiple of 90 deg: tests that the 4-fold quadrant-ambiguity
% resolver correctly detects a non-zero rotation, WITHOUT leaving a residual
% (non-quadrant) constant phase offset that would inflate EVM independent of
% the AWGN under test -- a locked carrier-sync loop's residual is captured
% instead by phaseNoiseDegRms above, not by this term.
coarsePhaseOffsetDeg = 90;

res = struct('snrPointsDb', snrPointsDb, 'trials', struct([]));
allPass = true;

% Phase-noise contribution to EVM (small-angle): RMS phase error in radians
% x 100. Combined with the pure-AWGN term in quadrature below so the gate
% compares against the theory relationship it actually claims to validate.
phaseNoiseEvmPct = deg2rad(phaseNoiseDegRms) * 100;

for si = 1:numel(snrPointsDb)
    snrDb = snrPointsDb(si);
    snrLin = 10^(snrDb/10);
    awgnEvmPct = 100/sqrt(snrLin);
    theoryEvmPct = sqrt(awgnEvmPct^2 + phaseNoiseEvmPct^2);

    % ---- build nFramesPerTest frames: known preamble + random payload ----
    preSyms = cfg.PreambleSymbols(:); nPre = cfg.NPreambleSym;
    paySym  = cfg.PaySymPerFrame;     frameLen = cfg.FrameLenSym;
    ideal = cfg.IdealConstellation(:).';

    txSym = zeros(frameLen*nFramesPerTest, 1);
    for fIdx = 1:nFramesPerTest
        payIdx = randi(4, paySym, 1);
        pay = ideal(payIdx).';
        s0 = (fIdx-1)*frameLen;
        txSym(s0+1:s0+nPre) = preSyms;
        txSym(s0+nPre+1:s0+frameLen) = pay;
    end

    % ---- known impairments ----
    rxSym = txSym * exp(1i*deg2rad(coarsePhaseOffsetDeg));
    phaseNoise = deg2rad(phaseNoiseDegRms) * randn(size(rxSym));
    rxSym = rxSym .* exp(1i*phaseNoise);
    rxSym = awgn(rxSym, snrDb, 'measured');   % Es/N0 SNR, measured on symbol-rate samples directly

    % ---- run the instrument under test ----
    opts = struct('plot', false, 'label', sprintf('selftest_%ddB', snrDb));
    r = evm_from_tap(rxSym, cfg, 'symbols', opts);

    measEvmPct = r.rms_evm;
    pctErr = abs(measEvmPct - theoryEvmPct) / theoryEvmPct * 100;
    thisPass = pctErr <= 5;
    rotOk = (r.globalRotDeg == 90);  % nearest-quadrant snap of the 90 deg coarsePhaseOffsetDeg

    fprintf(['[evm_selftest] SNR=%2ddB: theory EVM(awgn+pn)=%.3f%% (awgn=%.3f%%, pn=%.3f%%)  measured RMS EVM=%.3f%%  ' ...
        '(err=%.1f%%, tol=5%%) -> %s | rotation resolved=%d deg (expect 90) -> %s | nFrames=%d\n'], ...
        snrDb, theoryEvmPct, awgnEvmPct, phaseNoiseEvmPct, measEvmPct, pctErr, ternary(thisPass,'PASS','FAIL'), ...
        r.globalRotDeg, ternary(rotOk,'PASS','FAIL'), r.nFrames);

    trial = struct('snrDb', snrDb, 'theoryEvmPct', theoryEvmPct, 'awgnEvmPct', awgnEvmPct, ...
        'phaseNoiseEvmPct', phaseNoiseEvmPct, 'measEvmPct', measEvmPct, ...
        'pctErr', pctErr, 'pass', thisPass, 'rotOk', rotOk, 'res', r);
    res.trials = [res.trials, trial]; %#ok<AGROW>
    allPass = allPass && thisPass && rotOk;
end

% ---- rotation-ambiguity sweep: all four quadrants (finding #3) ----
% Reuses a single moderate SNR/phase-noise operating point; the AWGN-theory
% relationship is already validated above, this loop isolates the 4-fold
% quadrant resolver itself.
rotSweepDeg = [0 90 180 270];
rotSweepSnrDb = 18;
res.rotSweep = struct([]);
for qi = 1:numel(rotSweepDeg)
    offsetDeg = rotSweepDeg(qi);

    preSyms  = cfg.PreambleSymbols(:); nPre = cfg.NPreambleSym;
    paySym   = cfg.PaySymPerFrame;     frameLen = cfg.FrameLenSym;
    ideal    = cfg.IdealConstellation(:).';

    txSym = zeros(frameLen*nFramesPerTest, 1);
    for fIdx = 1:nFramesPerTest
        payIdx = randi(4, paySym, 1);
        pay = ideal(payIdx).';
        s0 = (fIdx-1)*frameLen;
        txSym(s0+1:s0+nPre) = preSyms;
        txSym(s0+nPre+1:s0+frameLen) = pay;
    end

    rxSym = txSym * exp(1i*deg2rad(offsetDeg));
    phaseNoise = deg2rad(phaseNoiseDegRms) * randn(size(rxSym));
    rxSym = rxSym .* exp(1i*phaseNoise);
    rxSym = awgn(rxSym, rotSweepSnrDb, 'measured');

    opts = struct('plot', false, 'label', sprintf('selftest_rot_%ddeg', offsetDeg));
    r = evm_from_tap(rxSym, cfg, 'symbols', opts);

    rotOk = (r.globalRotDeg == offsetDeg);
    fprintf(['[evm_selftest] rotation sweep: applied=%3d deg  resolved=%3d deg -> %s | nFrames=%d\n'], ...
        offsetDeg, r.globalRotDeg, ternary(rotOk,'PASS','FAIL'), r.nFrames);

    rotTrial = struct('offsetDeg', offsetDeg, 'globalRotDeg', r.globalRotDeg, 'pass', rotOk);
    res.rotSweep = [res.rotSweep, rotTrial]; %#ok<AGROW>
    allPass = allPass && rotOk;
end

res.pass = allPass;
if allPass
    fprintf('[evm_selftest] SELFTEST_PASS -- EVM matches combined AWGN+phase-noise theory within 5%% at all SNR points, rotation ambiguity resolved correctly at all 4 quadrants\n');
else
    fprintf('[evm_selftest] SELFTEST_FAIL -- see per-point results above\n');
end

end

function s = ternary(cond, a, b)
if cond, s = a; else, s = b; end
end
