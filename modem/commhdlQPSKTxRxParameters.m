%commhdlQPSKTxRxParameters script generates parameters for QPSK Transmitter and Receiver required for initialization.
%   Params = commhdlQPSKTxRxParameters() returns, a structure containing 
%   constants used by the model commhdlQPSKTxRx.slx.
% 
%   Note: This function is called in mask initializations of the QPSK Tx
%   and QPSK Rx subsystems in the model commhdlQPSKTxRx.slx.
%   

%   Copyright 2020-2023 The MathWorks, Inc. 

function Params = commhdlQPSKTxRxParameters()

   cfg = frame_config_k5();   % single source of truth for frame geometry + sps
   Params.Preamble                 = generatePreamble();
   Params.QPSKConstellation        = double(fi(QPSKModulate([0 0 1 0 1 1 0 1].'),1,16,15));
   Params.DataBitsPerPacket        = cfg.PayloadBits;   % 2240 (= CodedBits + FillerBits)
   % --- frame geometry mirrored from frame_config_k5 (new fields; k5 -> identical) ---
   Params.InfoBitsPerPacket        = cfg.InfoBits;
   Params.TailBitsPerPacket        = cfg.TailBits;
   Params.CodedBitsPerPacket       = cfg.CodedBits;
   Params.InterleaveRows           = cfg.InterleaveRows;
   Params.InterleaveCols           = cfg.InterleaveCols;
   Params.FillerBits               = cfg.FillerBits;
   Params.PayloadWords64           = cfg.PayloadWords64;
   Params.RomWords32               = cfg.RomWords32;
   Params.SamplesPerSymbol         = cfg.Sps; % jupiter_240k5: 4 -> 8. Restores the true 240-ksym design point
                                        % at the 1.92 MHz SSI (air was accidentally 480 ksym at sps=4).
                                        % PAIRED with Rsym 1.92e6 -> 0.96e6 in the model (Input Data mask +
                                        % the four 1/(Rsym*4) hardcoded sample times -> 1/(Rsym*SamplesPerSymbol),
                                        % see rate_240k_overlay.m) so the model QPSK rail Rsym*sps stays 7.68e6.
   Params.RRCFilterSpanInSymbols   = 4;
   rollOffFactor                   = 0.5;
   Params.RRCCoef                  = rcosdesign(rollOffFactor,...
                                         Params.RRCFilterSpanInSymbols,...
                                         Params.SamplesPerSymbol);
   Params.preambleSymbols          = QPSKModulate(Params.Preamble);
   Params.rxPreambleMFCoeffs       = flip(conj(Params.preambleSymbols)).';
   Params.rxPreambleMFCoeffs       = Params.rxPreambleMFCoeffs/13;
   Params.txDataRAMAddrWidth       = nextpow2(Params.DataBitsPerPacket*2);
   Params.BitsPerPacket            = length(Params.Preamble) + Params.DataBitsPerPacket;
   
   % AGC Parameters
   Params.AGCReference           = 0.25;
   Params.AGCLoopGain            = 2e-3;
   
   % Carrier Synchronizer Parameters
   CSBnXTsamp             = 0.005;
   CSdoo                  = 1/sqrt(2);
   CSth                   = CSBnXTsamp/(CSdoo + 0.25/CSdoo);
   CSd                    = 1+2*CSdoo*CSth+CSth^2;
   CSKp                   = sqrt(2);
   CSK0                   = 1;
   CSLoopFilterPropGain   = 4*CSdoo*(CSth/CSd)*(1/(CSKp*CSK0));
   CSLoopFilterIntegGain  = 4*(CSth^2/CSd)*(1/(CSKp*CSK0));
   CFOChangeDetectThreshold = 0.0125;    % RXFIX RE-APPLIED (2026-07-09): widen the CFO-step-change deadband.
                                         % Stock 0.0015625 (=3277 En21, ~697 Hz on this kit) false-fired the
                                         % carrier-sync reset (internalRst) ~52/s at the flooring condition
                                         % (HW rstcs=3101/60s while the real CFO was a stable 26 Hz) -> carrier
                                         % loss-of-lock RESET STORM -> BER floor / ~40% frame yield. Confirmed:
                                         % ideal receiver decodes the same samples 0/220; pre-carrier-loop cause.
                                         % 0.0125 (=26214 En21, ~5577 Hz) clears the ~3 kHz storm-break knee and
                                         % the good-lock p99 jitter (835 Hz), still catches real CFO steps >=~3kHz.
                                         % Prior-validated on real air (jupiter_t8pn/RXFIX.txt: resets 9->1).
   
   Params.CSKp                  = CSKp;
   Params.CSK0                  = CSK0;
   Params.CSLoopFilterPropGain  = CSLoopFilterPropGain;
   Params.CSLoopFilterIntegGain = CSLoopFilterIntegGain;
   Params.CFOChangeDetectThreshold = CFOChangeDetectThreshold;
   
   % Symbol Synchronizer Parameters
   SSBnXTsamp             = 0.01;
   SSdoo                  = 1/sqrt(2);
   SSth                   = SSBnXTsamp/(SSdoo + 0.25/SSdoo);
   SSd                    = 1+2*SSdoo*SSth+SSth^2;
   SSKp                   = 2.7;
   SSK0                   = -1;
   SSLoopFilterPropGain   = 4*SSdoo*(SSth/SSd)*(1/(SSKp*SSK0));
   SSLoopFilterIntegGain  = 4*(SSth^2/SSd)*(1/(SSKp*SSK0));
   
   Params.SSKp                  = SSKp;
   Params.SSK0                  = SSK0;
   Params.SSLoopFilterPropGain  = SSLoopFilterPropGain;
   Params.SSLoopFilterIntegGain = SSLoopFilterIntegGain;
   
   % Preamble Detector Parameters
   PreambleThresholdScaldB       = -1.25;
   thresholdScalFac              = 10^(PreambleThresholdScaldB/10);
   rxPreambleMFEnergy            = sum(abs(Params.rxPreambleMFCoeffs).^2);
   Params.ThresoldGainFac        = fi(thresholdScalFac*rxPreambleMFEnergy,0,16,16);
   Params.SearchSamples          = Params.BitsPerPacket/2;
end


function preamble = generatePreamble()

  barkarCode13Bit = logical([1 1 1 1 1 0 0 1 1 0 1 0 1]);
  
  preambleI = barkarCode13Bit;
  preambleQ = preambleI;
  
  preamble = [preambleI;preambleQ];
  preamble = preamble(:);

end

function QPSKMod = QPSKModulate(sdata)
 
   sdataI = sdata(1:2:end);
   sdataQ = sdata(2:2:end);
   QPSKMod = pskmod(sdataI*2+sdataQ,4,pi/4,'gray');

end