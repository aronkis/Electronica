function s = bs_score(res, base, injSym, frameLenSym, evmThr, pcThr)
%BS_SCORE  Frame-domain recovery scoring after a mid-stream disturbance.
%
%   s = bs_score(res, base, injSym, frameLenSym, evmThr, pcThr)
%
%   res      : bs_front_end() result for the PERTURBED stream
%   base     : bs_front_end() result for the CLEAN baseline (same segment);
%              its per-frame hard-decision payload is the CRC ground truth
%   injSym   : approximate post-sync symbol index of the disturbance
%   evmThr   : frame RMS EVM %% above which a frame counts DEGRADED
%   pcThr    : preamble-corr below which a frame counts sync-failed
%
%   Three per-frame failure tests, walked from the frame containing the
%   disturbance until 3 consecutive clean, gap-free frames are seen:
%     - MISSED   : no preamble detection at the expected 12333-symbol cadence
%                  (gap in detected starts);
%     - DEGRADED : detected but frameEVM > evmThr or preCorr < pcThr;
%     - CRC-FAIL : detected but the hard-decision payload DIFFERS from the
%                  baseline run's same-ordinal frame (symbol mismatch rate
%                  > 1e-3). This is the hardware-CRC-equivalent test: a frame
%                  whose content is displaced by a slip still shows clean EVM
%                  (valid QPSK points) but delivers wrong bits. Frame ordinals
%                  align because the splice is mid-frame (no preamble is
%                  created or destroyed) and the pre-splice stream is
%                  identical.
%
%   s.framesToRecover = bad slots (any test) before recovery -- the burst
%   length a hardware CRC counter would have seen.

ps = res.ps(:); ev = res.frameEVM(:); pc = res.preCorr(:);
j = find(ps <= injSym, 1, 'last');
if isempty(j), j = 1; end

% per-frame CRC-equivalent: payload symbol mismatch rate vs baseline ordinal
nCmp = min(res.nFrames, base.nFrames);
ser = ones(numel(ps), 1);                       % unmatched ordinals -> fail
ser(1:nCmp) = mean(res.paySym(1:nCmp,:) ~= base.paySym(1:nCmp,:), 2);
crcFailMask = ser > 1e-3;

missed = 0; degraded = 0; crcFails = 0; cleanRun = 0; k = j;
lastBad = j - 1; evTrail = []; serTrail = [];
while k <= numel(ps)
    if k > j
        gap = round((ps(k) - ps(k-1)) / frameLenSym) - 1;
        if gap > 0
            missed = missed + gap; cleanRun = 0; lastBad = k - 1;
        end
    end
    isClean = (ev(k) <= evmThr) && (pc(k) >= pcThr) && ~crcFailMask(k);
    if numel(evTrail) < 8, evTrail(end+1) = ev(k); serTrail(end+1) = ser(k); end %#ok<AGROW>
    if isClean
        cleanRun = cleanRun + 1;
        if cleanRun >= 3, break; end
    else
        degraded = degraded + (ev(k) > evmThr || pc(k) < pcThr);
        crcFails = crcFails + crcFailMask(k);
        cleanRun = 0; lastBad = k;
    end
    k = k + 1;
end

s.injFrame        = j;
s.framesMissed    = missed;
s.framesDegraded  = degraded;
s.framesCRCFail   = crcFails;
% total bad slots seen in the walk = missed + detected-but-failed frames
if lastBad >= j
    badDet = sum(~((ev(j:lastBad) <= evmThr) & (pc(j:lastBad) >= pcThr) ...
                   & ~crcFailMask(j:lastBad)));
else
    badDet = 0;
end
s.framesToRecover = missed + badDet;
s.lastBadFrame    = lastBad;
s.evmTrail        = evTrail;          % EVM of first frames from injection on
s.serTrail        = serTrail;         % payload mismatch rate, same frames
s.peakEVM         = max(ev(j:min(j+12, numel(ev))));
s.recovered       = (cleanRun >= 3);
end
