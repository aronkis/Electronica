function agc_gain_range_overlay(fracBits)
% agc_gain_range_overlay -- widen the Rx AGC gain word so the on-chip Rx locks
% at real OTA ADC levels, on this kit's SOURCE model commhdlQPSKTxRx.slx.
%
% agc_gain_range_overlay()          T8.3 default: fracBits=10 (gain +/-32)
% agc_gain_range_overlay(11)        first-cut fix   (gain +/-16)
%
% ROOT CAUSE (proven by Verilator RTL replay of the real GOOD-boot OTA capture
% split148.iq (scratch capture, no longer in the tree), see
% PHASEB_AGC_REPORT.txt (also no longer in the tree)):
% The AGC applies gain = LoopFilter output converted by the 'Data Type
% Conversion' block to sfix16_En14 -- back-propagation picked a +/-2.0 gain
% range (RTL: plain wrap slice gain_re[29:14]). The AGC target is
% |y|^2 = AGCReference = 0.25, so the minimum input the AGC can normalize is
% complex-rms 8192/2 = 4096 ADC counts: cable levels lock, the real OTA rail
% level (~290-360 rms; the ceiling-pinned AGC debug tap = ceiling x rail was
% proven on HW: 4576 = 16 x 286) needs gain ~14-28 -> the slice WRAPS ->
% garbage gain -> CFC junk -> acquire/reset cycling -> no lock.
%
% FIX (three coupled edits; all these types are inherit-driven in stock):
%  (a) delete the AGC-level 'Data Type Duplicate' (only enforces gain type ==
%      dataIn type; rejects any wider gain word at compile),
%  (b) pin AGC 'Data Type Conversion' (gain word) = fixdt(1,16,fracBits):
%        fracBits=11 -> +/-16 (+18 dB), fracBits=10 -> +/-32 (+24 dB),
%  (c) pin 'Loop Filter/Gain1' output = fixdt(1,44-fracBits,28): the loop
%      accumulator otherwise stays sfix33_En28 (+/-16, inherited from the
%      Error Detector err type) and the applied gain could never exceed 16
%      regardless of the gain-word range. 44-fracBits keeps LSB 2^-28 and
%      range == gain-word range (fracBits=11 -> 33 bits = stock width;
%      fracBits=10 -> 34 bits, +/-32). Add/Delay1/Delay2 inherit from Gain1
%      ('Same as first input' chain), so one pin widens the whole loop.
%
% Generated RTL (fracBits=10, codegen-proven in ovl_test; no longer in the tree):
%   Loop_Filter: 34-bit accumulator, Gain1_out = {8{mul[65]}, mul[65:40]}
%   AGC: gain word = gain_re[33:18] (full-accumulator slice -- wrap
%   structurally impossible), products data(En14) x gain(En10) -> [25:10].
%   Gain LSB 2^-10 = 9.8e-4 (vs loop step AGCLoopGain 2e-3); steady-state
%   bit_errors 0 at native/cable levels verified in Verilator.
%
% Verified in Verilator RTL sim on real OTA captures (split148/ab_modem):
% see PHASEB_AGC_REPORT.txt (En11: FOLLOW-UPs; En10: T8.3 section).
%
% Idempotent. Apply on the source model AFTER ss8_fix_overlay, BEFORE
% build_composite_local (same slot as the other source-model overlays).

if nargin < 1, fracBits = 10; end
assert(fracBits==10 || fracBits==11, 'fracBits must be 10 or 11');
gainDT = sprintf('fixdt(1,16,%d)', fracBits);
accDT  = sprintf('fixdt(1,%d,28)', 44-fracBits);

sys = 'commhdlQPSKTxRx';
load_system(sys);
agc = [sys '/Receiver/QPSK Rx/Automatic Gain Control'];
dtc = [agc '/Data Type Conversion'];
g1  = [agc '/Loop Filter/Gain1'];

% (a) The AGC-level 'Data Type Duplicate' ties the gain word to the dataIn
% type (sfix16_En14) -- it exists only to enforce that equality and carries
% no datapath. It must go, or the wider gain word is rejected at compile.
% (The Error Detector's own Data Type Duplicate is untouched.)
dtd = [agc sprintf('/Data Type\nDuplicate')];
if ~isempty(find_system(agc,'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','BlockType','DataTypeDuplicate'))
    lh = get_param(dtd, 'LineHandles');
    for h = lh.Inport(:)'
        if h > 0, delete_line(h); end
    end
    delete_block(dtd);
    fprintf('agc_gain_range_overlay: AGC-level Data Type Duplicate removed\n');
else
    fprintf('agc_gain_range_overlay: Data Type Duplicate already removed -- skip\n');
end

% (b) gain-word conversion
cur = strtrim(get_param(dtc, 'OutDataTypeStr'));
if strcmp(cur, gainDT)
    fprintf('agc_gain_range_overlay: gain DTC already %s -- skip\n', gainDT);
else
    set_param(dtc, 'OutDataTypeStr', gainDT);
    fprintf('agc_gain_range_overlay: gain DTC %s -> %s\n', cur, gainDT);
end

% (c) loop-filter accumulator range (via Gain1 output; Add/Delays inherit)
cur = strtrim(get_param(g1, 'OutDataTypeStr'));
if strcmp(cur, accDT)
    fprintf('agc_gain_range_overlay: Loop Filter Gain1 already %s -- skip\n', accDT);
else
    set_param(g1, 'OutDataTypeStr', accDT);
    fprintf('agc_gain_range_overlay: Loop Filter Gain1 %s -> %s\n', cur, accDT);
end

save_system(sys);
fprintf('agc_gain_range_overlay: saved %s (gain %s, accumulator %s)\n', sys, gainDT, accDT);
end
