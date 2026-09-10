function cfg = evm_config_1536k()
%EVM_CONFIG_1536K  Rate/loop config for the R3 (61.44 MSPS / sps4) f1536 link.
%   cfg = evm_config_1536k() is the rate-ladder sibling of evm_config_240k(),
%   supplying the SAME field names for evm_from_tap / evm_ideal_ref /
%   evm_metrics / evm_report / frame_taxonomy so the reproduction harness is
%   geometry-parameterized (only the config + capture geometry change between
%   240k and R3). See evm_config_240k.m for the field contract.
%
%   R3 geometry (jupiter plan A3 rate ladder, deployed Image B):
%     SSI 61.44 MSPS, sps=4  -> Rsym = 15.36 Msym/s, IPCORE_CLK 122.88 MHz.
%   f1536 frame geometry (k5_240/PACKET_F1536.txt, frame_config_k5.m 'f1536'):
%     payload 24640 bits (385 x 64-bit words) -> 12320 payload symbols;
%     + 13-Barker preamble = 12333 symbols/frame.
%   The 13-bit Barker preamble and the pi/4-Gray QPSK constellation are
%   UNCHANGED from the 240k link -- only the payload length and rate differ, so
%   PreambleSymbols is still taken from commhdlQPSKTxRxParameters() verbatim and
%   only DataBitsPerPacket is overridden to the f1536 value.

cfg = struct();

% ---- rate geometry (R3: 61.44 MSPS / sps4) -------------------------------
cfg.Rsym    = 15.36e6;   % symbol rate, sym/s (61.44 MSPS / 4)
cfg.Sps     = 4;         % samples per symbol at the tap (sps4 rung)
cfg.Fs      = cfg.Rsym * cfg.Sps;   % 61.44e6 Sa/s -- the ADRV9002 SSI / tap rail rate
cfg.Beta    = 0.5;       % sqrt-RRC rolloff (rcosdesign(0.5,4,4), stock sps4 design point)
cfg.RrcSpan = 4;         % RRC filter span in symbols

% ---- tap fixed-point scaling (unchanged from 240k) -----------------------
cfg.TapFracBits = 14;             % sfix16_En14
cfg.TapScale    = 2^cfg.TapFracBits;

% ---- debug tap mode map (AXI reg 0x10C) -- identical mode numbering -------
% Mode semantics (0/1/2/3/5) are the same overlay-defined values as 240k
% (iq_debug_tap_overlay.m / cfc_tap_overlay.m). The HOLD FACTOR per mode is
% measured from the data at runtime by evm_from_tap (median duplicate-run
% length), NOT assumed to be cfg.Sps -- so the mode-1/2 half-rate-hold caveat
% carries over; mode 3 (constellation) remains the most trustworthy tap. At
% sps=4 an ideal 1-sample/symbol hold implies a mean duplicate run of Sps=4.
cfg.TapModes = struct( ...
    'AGC_OUT',            0, ...   % raw rail rate, not held
    'POST_SYMBOL_SYNC',   1, ...   % held (measure factor at runtime)
    'POST_CARRIER_SYNC',  2, ...   % held, lower-confidence
    'CONSTELLATION',      3, ...   % held ~Sps, cleanest recovery target
    'CFC_OUT',            5);      % held, rate unverified

% ---- loop constants -------------------------------------------------------
% Normalized (Bn*T) loop bandwidths are kept at the 240k values initially
% (jupiter plan A3: normalized constants carry across the ladder; per-rung
% retune is a runtime register write via loop_gain_axi_overlay 0x170-0x184).
% Referred to Hz they scale with Rsym (e.g. CSBnXTsamp*Rsym = 76.8 kHz here).
cfg.AGCReference               = 0.25;
cfg.AGCLoopGain                = 2e-3;
cfg.CSBnXTsamp                 = 0.005;   % carrier-sync normalized loop BW
cfg.SSBnXTsamp                 = 0.01;    % symbol-sync normalized loop BW
cfg.CFOChangeDetectThreshold   = 0.0125;
cfg.PreambleThresholdScaldB    = -1.25;

cfg.Fs_at_loop = cfg.Rsym;                            % CS tracks at 1 samp/symbol
cfg.CarrierLoopBWHz = cfg.CSBnXTsamp * cfg.Fs_at_loop;

% ---- preamble / framing (13-bit Barker shared; payload = f1536) -----------
repo = '/home/tcollins/dev/qpsk_ai/TransceiverToolbox';
if exist(fullfile(repo,'setup.m'),'file')
    run(fullfile(repo,'setup.m'));
    addpath(repo);
end
qdir = fullfile(repo,'trx_examples','targeting','QPSKTxRxHDLExample');
if exist(qdir,'dir'), addpath(qdir); end
P = commhdlQPSKTxRxParameters();

cfg.PreambleSymbols = P.preambleSymbols(:);       % 13 complex pi/4-QPSK symbols (shared)
cfg.NPreambleSym    = numel(cfg.PreambleSymbols); % 13
% f1536 payload OVERRIDE: commhdlQPSKTxRxParameters() returns the 240k default
% (2240); the f1536 build's payload is 24640 bits = 385 x 64-bit words (see
% k5_240/PACKET_F1536.txt, jupiter_240k5_byte/frame_config_k5.m 'f1536' case,
% qpsk_tun.c F1536_PAYLOAD_BITS).
cfg.DataBitsPerPacket = 24640;
cfg.PaySymPerFrame    = cfg.DataBitsPerPacket/2;                 % 12320
cfg.FrameLenSym       = cfg.NPreambleSym + cfg.PaySymPerFrame;   % 12333

cfg.IdealConstellation = exp(1i*(pi/4 + (0:3)*(pi/2)));
cfg.RefRMS = sqrt(mean(abs(cfg.IdealConstellation).^2));  % == 1

end
