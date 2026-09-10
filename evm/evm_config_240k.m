function cfg = evm_config_240k()
%EVM_CONFIG_240K  Rate/loop config struct for the 240 ksym/s Jupiter QPSK link.
%   cfg = evm_config_240k() returns a struct consumed by evm_from_tap,
%   evm_ideal_ref, evm_metrics and evm_report. NOTHING in those algorithms
%   should hardcode 1.92e6 / 8 / 240e3 -- everything rate-dependent must be
%   read from this struct, because a rate ladder (up to 15.36 Msym/s) is
%   being built in parallel and will supply a sibling cfg (e.g.
%   evm_config_1536k.m) with the same field names.
%
%   Values are pulled from / verified consistent with
%   jupiter_240k5_byte/commhdlQPSKTxRxParameters.m (read-only; never modified).

cfg = struct();

% ---- rate geometry -------------------------------------------------------
cfg.Rsym    = 240e3;     % symbol rate, sym/s
cfg.Sps     = 8;         % samples per symbol at the tap (commhdlQPSKTxRxParameters: SamplesPerSymbol)
cfg.Fs      = cfg.Rsym * cfg.Sps;   % 1.92e6 Sa/s -- the ADRV9002 SSI / tap rail rate
cfg.Beta    = 0.5;       % sqrt-RRC rolloff (rollOffFactor in commhdlQPSKTxRxParameters)
cfg.RrcSpan = 4;         % RRC filter span in symbols (RRCFilterSpanInSymbols)

% ---- tap fixed-point scaling ---------------------------------------------
cfg.TapFracBits = 14;             % sfix16_En14
cfg.TapScale    = 2^cfg.TapFracBits;

% ---- debug tap mode map (AXI reg 0x10C) -----------------------------------
% Verified against jupiter_240k5_byte/iq_debug_tap_overlay.m (modes 0-3
% comment + fprintf) and jupiter_240k5_byte/cfc_tap_overlay.m (mode 5,
% "Apply AFTER canary3_telemetry_overlay (mode numbering: 4=telemetry,
% 5=CFC)"). Mode 4 (telemetry) is NOT an IQ stream and is intentionally
% absent from this map -- do not feed it to evm_from_tap.
cfg.TapModes = struct( ...
    'AGC_OUT',            0, ...   % raw rail rate, NOT held -- pre timing/carrier sync
    'POST_SYMBOL_SYNC',   1, ...   % HELD; empirically ~2 samples/symbol in captured data (see NOTE below)
    'POST_CARRIER_SYNC',  2, ...   % HELD; empirically ~2 samples/symbol, noisier hold boundaries
    'CONSTELLATION',      3, ...   % HELD; empirically ~1 sample/symbol (sps=8 hold), the cleanest recovery target
    'CFC_OUT',            5);      % HELD (per SS->CFC->CS ordering comment in cfc_tap_overlay.m); rate unverified, no captured mode-5 data available in this task

% NOTE (recorded ambiguity, task C1): tap_smoke.sh captures do NOT expose a
% separate debugValid channel over iio_readdev (only voltage0_i/voltage0_q
% land in the file) -- debugValid is sample-aligned/folded into voltage0 per
% iq_debug_tap_overlay.m's comment ("debugValid stays adc_validIn ... voltage1
% carries the HELD selected stream sample-aligned with voltage0"), so a HELD
% stream can only be recovered by detecting consecutive-duplicate runs in the
% captured int16 words, not by reading an explicit valid flag. Measured on
% two_jup/tapsmoke/20260712_052321_A (1.92 MHz rail, Rsym=240k so an ideal
% 1-sample/symbol hold implies a mean duplicate run of Sps=8):
%   mode 0: dup_frac=0.000  (continuous, not held -- as expected for raw AGC out)
%   mode 1: dup_frac=0.750, mean run=4.0  -> collapsed rate ~= 2*Rsym (480 ksym/s)
%   mode 2: dup_frac=0.750, mean run=4.0 but run length STD~1.1-3.0 (min1/max15) ->
%           the hold boundary is unreliable via exact-duplicate detection this
%           deep in the carrier-sync loop (residual rotation/quantization noise
%           can perturb the stored int16 mid-hold), so duplicate-collapse alone
%           UNDER-decimates (lands near 2*Rsym, not Rsym) and is noisy.
%   mode 3: dup_frac=0.876, mean run~8.08 -> collapsed rate ~= Rsym (240 ksym/s), matches sps.
% CONCLUSION: mode map semantics (0/1/2/3/5) are taken verbatim from the two
% overlay files above and are NOT themselves ambiguous. What IS ambiguous/
% verified-empirically is the HOLD FACTOR of each mode's tap stream, which is
% NOT simply cfg.Sps for every mode (modes 1/2 hold at ~Sps/2, not Sps).
% evm_from_tap therefore measures the hold factor from the data at runtime
% (median duplicate-run length) rather than assuming cfg.Sps, and reports the
% detected factor + method in res.decimation so a wrong assumption is visible
% rather than silently baked in. Treat mode-2 EVM numbers as lower-confidence
% for this reason; mode 3 is the most trustworthy hardware-loop EVM tap.

% ---- loop constants (jupiter_240k5_byte/commhdlQPSKTxRxParameters.m) ------
cfg.AGCReference               = 0.25;
cfg.AGCLoopGain                = 2e-3;
cfg.CSBnXTsamp                 = 0.005;   % carrier-sync normalized loop BW (of Rsym, 1 sample/symbol domain)
cfg.SSBnXTsamp                 = 0.01;    % symbol-sync normalized loop BW
cfg.CFOChangeDetectThreshold   = 0.0125;
cfg.PreambleThresholdScaldB    = -1.25;

% Carrier-sync loop tracks at 1 sample/symbol (comm.CarrierSynchronizer with
% SamplesPerSymbol=1 in decode_ref_k5.m), so its closed-loop bandwidth in Hz
% referred to the symbol-rate domain is CSBnXTsamp*Rsym. Used to mark the
% loop-BW line on the phase-error PSD plot.
cfg.Fs_at_loop = cfg.Rsym;
cfg.CarrierLoopBWHz = cfg.CSBnXTsamp * cfg.Fs_at_loop;

% ---- preamble / framing (13-bit Barker, pi/4-Gray QPSK) -------------------
% Pulled directly from commhdlQPSKTxRxParameters() (TransceiverToolbox repo)
% so the exact preamble symbols / frame length match the deployed HDL bit-for-bit.
repo = '/home/tcollins/dev/qpsk_ai/TransceiverToolbox';
if exist(fullfile(repo,'setup.m'),'file')
    run(fullfile(repo,'setup.m'));
    addpath(repo);
end
qdir = fullfile(repo,'trx_examples','targeting','QPSKTxRxHDLExample');
if exist(qdir,'dir'), addpath(qdir); end
P = commhdlQPSKTxRxParameters();

cfg.PreambleSymbols = P.preambleSymbols(:);       % 13 complex pi/4-QPSK symbols
cfg.NPreambleSym    = numel(cfg.PreambleSymbols); % 13
cfg.DataBitsPerPacket = P.DataBitsPerPacket;       % 2240
cfg.PaySymPerFrame    = cfg.DataBitsPerPacket/2;   % 1120
cfg.FrameLenSym       = cfg.NPreambleSym + cfg.PaySymPerFrame; % 1133

% Ideal reference constellation (unit-magnitude pi/4-Gray QPSK points), used
% to normalize EVM ("normalized to reference-constellation RMS").
cfg.IdealConstellation = exp(1i*(pi/4 + (0:3)*(pi/2)));
cfg.RefRMS = sqrt(mean(abs(cfg.IdealConstellation).^2));  % == 1

end
