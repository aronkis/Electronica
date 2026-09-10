function info = fec_remove_scrambler(sys, loop)
% fec_remove_scrambler  Bypass the HDL Data Scrambler in the Tx FEC path so the
% air carries UN-scrambled FEC-encoded + interleaved coded bits.
%
% NO-SCRAMBLE ZedBoard FEC-Tx variant (pairs with a no-descramble Jupiter). The
% scrambler/descrambler cross-board PN coupling is blocking the FEC decode on
% hardware; removing BOTH sides is the decisive test (the scrambler is only
% spectral whitening; the deint+Viterbi are proven correct).
%
% MECHANISM (verified by topology introspection of the built DUT):
%   The 'HDL Data Scrambler' subsystem realizes a multiplicative LFSR scrambler:
%     dataIn -> Delay -> {Switch in3 (UNSCRAMBLED) , BIT_XOR2 in1}
%     BIT_XOR2 (= Delay XOR LFSR feedback) -> Switch in1 (SCRAMBLED)
%     EnableScrambling (Constant) -> Switch in2 (control); Criteria 'u2 > 0'
%     Switch -> Delay3 -> dataOut ;  valid path -> Delay4 -> validOut
%   With EnableScrambling=true the Switch passes the SCRAMBLED bit (in1).
%   Setting EnableScrambling=FALSE flips the Switch to pass in3 = the UNSCRAMBLED
%   dataIn (1-cycle Delay), keeping ALL pipeline delays (Delay/Delay3/Delay4)
%   and the valid alignment to the QPSK Modulator BIT-IDENTICAL -- only the XOR
%   with the PN sequence is removed. The frame size, framing signals, bit ORDER
%   and the FEC encoder + 16-col BRAM interleaver are UNTOUCHED, so the Jupiter
%   no-descramble decoder inverts the encoder/interleaver bit-exactly.
%
% This is the minimal, latency-preserving way to make the air UN-scrambled
% without disturbing the FEC datapath. Apply AFTER the FEC overlay + interleaver
% BRAM fit, BEFORE HDL codegen. Idempotent.

if nargin < 1 || isempty(sys),  sys  = 'commhdlQPSKTxRxLoopback'; end
if nargin < 2 || isempty(loop), loop = [sys '/TxRxComposite']; end

qtx = [loop '/Transmitter/QPSK Tx'];
scr = [qtx '/HDL Data Scrambler'];
ec  = [scr '/EnableScrambling'];
sw  = [scr '/Switch'];

% Locate the scrambler + its EnableScrambling constant in the SYNTHESIZED DUT.
assert(~isempty(find_system(qtx,'SearchDepth',1,'LookUnderMasks','all', ...
    'BlockType','SubSystem','Name','HDL Data Scrambler')), ...
    'HDL Data Scrambler not found under %s', qtx);
assert(~isempty(find_system(scr,'SearchDepth',1,'LookUnderMasks','all', ...
    'BlockType','Constant','Name','EnableScrambling')), ...
    'EnableScrambling constant not found under %s', scr);

% Read-back the pre-state for the record.
preVal      = get_param(ec,'Value');
swCriteria  = get_param(sw,'Criteria');
swThreshold = get_param(sw,'Threshold');

% Sanity: the Switch must gate on the EnableScrambling control with 'u2 > 0'
% so that 0/false selects the UNSCRAMBLED data path (input 3 = delayed dataIn).
assert(strcmp(swCriteria,'u2 > Threshold'), ...
    'unexpected Switch Criteria "%s" -- bypass assumption invalid', swCriteria);

% Confirm the Switch control (in2) is driven by EnableScrambling and the
% UNSCRAMBLED path (in3) is the plain Delay (dataIn pipeline), NOT the XOR.
swph = get_param(sw,'PortHandles');
src_name = @(pn) get_param(get_param(get_param(get_param(swph.Inport(pn),'Line'), ...
    'SrcPortHandle'),'Parent'),'Name');
assert(strcmp(src_name(2),'EnableScrambling'), ...
    'Switch control (in2) not EnableScrambling (got %s)', src_name(2));
assert(strcmp(src_name(3),'Delay'), ...
    'Switch unscrambled path (in3) not the dataIn Delay (got %s)', src_name(3));

% ---- THE BYPASS: force EnableScrambling = false ----
% This routes the UNSCRAMBLED, 1-cycle-delayed dataIn through the Switch with all
% other pipeline delays intact => UN-scrambled bits, identical bit order/framing.
set_param(ec,'Value','false');
postVal = get_param(ec,'Value');
assert(strcmpi(strtrim(postVal),'false'), ...
    'EnableScrambling did not take "false" (got "%s")', postVal);

% Threshold is 0; 'false'(=0) is NOT > 0 -> Switch selects input 3 (unscrambled).
fprintf(['fec_remove_scrambler: HDL Data Scrambler BYPASSED -- EnableScrambling ', ...
    '%s -> %s (Switch "%s", Thr=%s => unscrambled dataIn path). ', ...
    'FEC encoder + BRAM interleaver UNTOUCHED.\n'], ...
    preVal, postVal, swCriteria, swThreshold);

info = struct('scrambler', scr, 'enableConst', ec, ...
    'preVal', preVal, 'postVal', postVal, ...
    'switchCriteria', swCriteria, 'switchThreshold', swThreshold);
end
