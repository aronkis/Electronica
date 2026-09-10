function res = float_tap_window(iqfile, outcsv)
%FLOAT_TAP_WINDOW  Float receiver (float_baseline_f1536) on one DDR tap window.
% Per-frame CSV + one summary line. Sample-domain taps only (raw input / RRC out).
here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here, '..', 'evm'));
res = float_baseline_f1536(iqfile);
writetable(res.perFrame, outcsv);
fprintf('FLOAT_WINDOW frames=%d bitErrors=%d ber=%.3g frameRecovery=%.3f hypStable=%d cfoHz=%.0f\n', ...
    res.nFrames, res.bitErrors, res.ber, res.frameRecovery, res.hypStable, res.cfoAppliedHz);
end
