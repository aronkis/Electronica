function rx_framing_overlay_k5(sys, base)
% rx_framing_overlay_k5 -- scale the RX Packet Controller payload span to the
% configured DataBitsPerPacket so the deinterleaver receives a FULL frame.
%
% ROOT CAUSE (Task A2 f1536 RX-decode bug -- deinterleaver output garbage while
% the demod input was bit-exact golden):
%   The base-model RX "End Generator"
%     Receiver/QPSK Rx/Frequency and Time Synchronizer/Packet Controller/End Generator
%   hardcodes the k5 payload span as the literal 1120 (= DataBitsPerPacket/2
%   QPSK symbols; each QPSK symbol carries 2 payload bits) in BOTH of its
%   frame-length elements:
%     - Compare To Constant : const        = '1120-1'
%     - HDL Counter         : CountMax      = '1120 -1'
%                             CountWordLen  = 'nextpow2(1120-1)'   (= 11 bits)
%   These literals never scaled with DataBitsPerPacket. For k5
%   (DataBitsPerPacket=2240) 1120 happens to be correct, so the bug was latent.
%   At f1536 (DataBitsPerPacket=24640) the span SHOULD be 12320 symbols, but the
%   End Generator ended every frame after only 1120 symbols = 2240 bits. The
%   deinterleaver (fecRxDeint, CODED=24592) then wrote only ~2240 of its 24592
%   ping-pong-bank cells per frame and read a mostly-EMPTY bank -> cap_deint
%   garbage (0x00010000 vs golden 0x52B9CE5C) even though cap_in (demod hard
%   bits) was bit-exact golden. Additionally the 11-bit counter width could not
%   even represent 12319, so a naive CountMax bump alone would still cap at 2047.
%
% FIX (config-driven, mirrors the PROVEN TX precedent): derive the span from the
% QPSK Rx mask variable `dataBitsPerPacket` (= RxParams.DataBitsPerPacket, itself
% single-sourced from frame_config_k5). The TX-side Data Bits FIFO counter at
% comparable subsystem depth already uses `dataBitsPerPacket*2 - 1` for its
% CountMax and resolves fine, so the mask variable is in scope here too.
%   - Compare To Constant : const        = 'dataBitsPerPacket/2 - 1'
%   - HDL Counter         : CountMax      = 'dataBitsPerPacket/2 - 1'
%                           CountWordLen  = 'nextpow2(dataBitsPerPacket/2 - 1)'
%   k5   : evaluates to 1120-1 and nextpow2(1119)=11 -> BYTE-IDENTICAL behavior
%          to the shipped literal (gate G0 untouched).
%   f1536: evaluates to 12320-1 and nextpow2(12319)=14 -> full-frame span, wide
%          enough counter; the deint now writes/reads the full CODED=24592 bank.
%
% Applies to EVERY Packet Controller/End Generator found under `base` (the
% composite has one RX copy). Idempotent (re-setting to the same expression is a
% no-op). Apply AFTER the composite exists (assemble Phase 1+).

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end

CONST_EXPR = 'dataBitsPerPacket/2 - 1';
CMAX_EXPR  = 'dataBitsPerPacket/2 - 1';
CWL_EXPR   = 'nextpow2(dataBitsPerPacket/2 - 1)';

% Find the RX Packet Controller(s) that own an End Generator.
pcs = find_system(base, 'LookUnderMasks','all', 'FollowLinks','on', ...
    'BlockType','SubSystem', 'Name','Packet Controller');
nPatched = 0;
for i = 1:numel(pcs)
    egs = find_system(pcs{i}, 'SearchDepth',1, 'LookUnderMasks','all', ...
        'FollowLinks','on', 'BlockType','SubSystem', 'Name','End Generator');
    if isempty(egs), continue; end
    for j = 1:numel(egs)
        eg = egs{j};
        % Locate the two frame-length elements by their DISTINCTIVE PARAMETERS
        % (robust to the embedded-newline block name "Compare\nTo Constant" and
        % to library-link SourceType search quirks): the Compare To Constant
        % owns 'const'+'relop'; the HDL Counter owns 'CountMax'.
        [cmp, cnt] = deal({}, {});
        blks = find_system(eg, 'SearchDepth',1, 'LookUnderMasks','all', ...
            'FollowLinks','on', 'Type','block');
        for b = reshape(blks,1,[])
            pn = fieldnames(get_param(b{1},'ObjectParameters'));
            if any(strcmp(pn,'const')) && any(strcmp(pn,'relop')), cmp{end+1} = b{1}; end %#ok<AGROW>
            if any(strcmp(pn,'CountMax')), cnt{end+1} = b{1}; end %#ok<AGROW>
        end
        assert(numel(cmp)==1, 'rx_framing_overlay_k5: expected 1 Compare To Constant in %s (found %d)', eg, numel(cmp));
        assert(numel(cnt)==1, 'rx_framing_overlay_k5: expected 1 HDL Counter in %s (found %d)', eg, numel(cnt));
        % ORDER MATTERS: the HDL Counter mask validates CountMax against the
        % current CountWordLen on every set_param. Widen CountWordLen FIRST (else
        % setting CountMax=12319 while the width is still nextpow2(1119)=11 bits
        % -> "Count to value cannot be represented"). Old CountMax (1119) always
        % fits the new 14-bit width, so widen-then-raise is safe both directions.
        set_param(cnt{1}, 'CountWordLen', CWL_EXPR);
        set_param(cnt{1}, 'CountMax', CMAX_EXPR);
        set_param(cmp{1}, 'const', CONST_EXPR);
        nPatched = nPatched + 1;
        fprintf('rx_framing_overlay_k5: %s -> const/CountMax=%s, CountWordLen=%s\n', ...
            strrep(eg,[base '/'],''), CMAX_EXPR, CWL_EXPR);
    end
end
assert(nPatched >= 1, 'rx_framing_overlay_k5: no Packet Controller/End Generator found under %s', base);
fprintf('rx_framing_overlay_k5: DONE (patched %d End Generator(s); RX payload span now = dataBitsPerPacket/2 symbols)\n', nPatched);
end
