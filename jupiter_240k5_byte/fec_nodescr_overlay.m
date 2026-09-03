function fec_nodescr_overlay(sys, base)
% fec_nodescr_overlay -- BYPASS the HDL Data Descrambler in the Rx FEC path.
%
% DECISIVE A/B VARIATION: 9 iterations of stage-by-stage chasing kept pushing
% the fault upstream while the model says every block is correct; the fine
% pn_phase sweep (0..30) proved the descrambler PN never cancels on HW (CAP_IN
% varies with 0x150 -> the reg works, but never reaches 0x00000C5E), so the
% corruption is UPSTREAM of the descrambler. This variant removes the
% scrambler/descrambler PN coupling ENTIRELY: the FEC decoder consumes the demod
% coded bits DIRECTLY (demod -> deinterleave -> Viterbi -> BIST, no descramble).
% A matching NO-SCRAMBLE ZedBoard Tx is built in parallel, so the air is
% un-scrambled and the demod coded bits ARE the deinterleaver input.
%
%   IF this decodes (BER -> coded floor after the 0x138 skip sweep) -> the
%     scrambler/descrambler coupling was the bug.
%   IF it still fails -> the fault is demod / frame-sync / the FEC-encoder Tx
%     path itself (narrowed decisively).
%
% Apply AFTER fec_insert/fec_counters/fec_skipreg/fec_capture. Do NOT apply the
% pn_phase overlay (moot without a descrambler). Idempotent.
%
% Rewires:  demod(dataOut/startOut/endOut/validOut) -> FEC Decoder Wrapper(1..4)
% Removes:  HDL Data Descrambler from the datapath (deleted).

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
qrx  = [base '/Receiver/QPSK Rx'];
dm   = [qrx '/QPSK Demodulator'];
ds   = [qrx '/HDL Data Descrambler'];
dec  = [qrx '/FEC Decoder Wrapper'];

% Idempotency: if the descrambler is already gone, skip.
if isempty(find_system(qrx,'SearchDepth',1,'LookUnderMasks','all', ...
        'BlockType','SubSystem','Name','HDL Data Descrambler'))
    fprintf('fec_nodescr_overlay: descrambler already removed -- skipping\n');
    return;
end

assert(~isempty(find_system(qrx,'SearchDepth',1,'LookUnderMasks','all', ...
    'BlockType','SubSystem','Name','FEC Decoder Wrapper')), ...
    'FEC Decoder Wrapper not found -- run fec_insert_overlay first');

% The descrambler currently feeds the FEC Decoder Wrapper ports 1..4 (data,
% start, end, valid) -- inserted by fec_insert_overlay. Delete those 4 lines.
for p = 1:4
    delete_line(qrx, sprintf('HDL Data Descrambler/%d', p), sprintf('FEC Decoder Wrapper/%d', p));
end

% The descrambler INPUT comes either directly from the demod (base model) or via
% DescramPnPhase (if the pn_phase overlay ran). We are NOT applying pn_phase in
% this variant, so the descrambler is fed straight from the demod. Delete the
% 4 demod->descrambler lines, then delete the descrambler block entirely.
for p = 1:4
    delete_line(qrx, sprintf('QPSK Demodulator/%d', p), sprintf('HDL Data Descrambler/%d', p));
end
delete_block(ds);

% Wire the demod outputs DIRECTLY into the FEC Decoder Wrapper (no descramble).
% demod 1=dataOut 2=startOut 3=endOut 4=validOut -> wrapper 1=bitsIn 2=startIn
% 3=endIn 4=validIn (same port semantics the descrambler had).
add_line(qrx, 'QPSK Demodulator/1', 'FEC Decoder Wrapper/1', 'autorouting','on');
add_line(qrx, 'QPSK Demodulator/2', 'FEC Decoder Wrapper/2', 'autorouting','on');
add_line(qrx, 'QPSK Demodulator/3', 'FEC Decoder Wrapper/3', 'autorouting','on');
add_line(qrx, 'QPSK Demodulator/4', 'FEC Decoder Wrapper/4', 'autorouting','on');

fprintf('fec_nodescr_overlay: HDL Data Descrambler BYPASSED+REMOVED; demod -> FEC Decoder Wrapper direct\n');
end
