function byte_tx_overlay_k5(sys, loop)
% byte_tx_overlay_k5 -- port of tools/add_byte_tx_path.m to the jupiter_240k5
% COMPOSITE copy (applied to <loop>/Transmitter, NOT the source library):
% the host->FPGA byte-transfer path into the Transmitter.
%
% Verified against THIS kit's actual Input Data wiring (probe 2026-07-07,
% fec_jupiter_rxfix lineage -- matches the donor's introspected map):
%   * Input Data inports: enb(1), reset(2, terminated); outports txData(1),
%     txValid(2), msg_count_out(3)
%   * Message Generator boundary: in1 = chart reset <- 'Cast To Boolean'
%     (delayed stop feedback), in2 = chart enable <- 'enb'
%   * MG out 1 = chart 'out'  -> txData (the wire the BitMux replaces)
%     MG out 3 = chart 'start'-> Terminator1 (we branch off it)
%
% Additions (generator pacing untouched):
%   Transmitter inports 5..8: extWord (uint64), extWordAvail (boolean),
%                             extBitSel (boolean), extWordFirst (boolean);
%                             outport 9: extWordPop.
%   Input Data inports  3..6: same quartet; outport 4: extWordPop.
%   Input Data/ByteBitShifter: MATLAB Function wrapping qpskByteBitShifter
%     (unit-tested single source of truth, copied verbatim into this kit).
%     enable/reset tap the SAME sources the msggen chart receives ('enb' and
%     'Cast To Boolean'); start taps MG out 3. pop is exported as a TOGGLE
%     (flips on each word latch) so it survives the 15.36M->30.72M crossing.
%   Input Data/BitMux: Switch (u2 ~= 0) -- u1 = shifter bit (REWIRED to the
%     in-fabric FEC encoder output by fec_tx_encoder_overlay_k5.m), u2 =
%     extBitSel, u3 = chart out (pre-coded K5 ROM); output replaces the
%     chart-out wire into txData.
%
% Idempotent: skips if ByteBitShifter already present. Does NOT save.

if nargin < 1, sys = bdroot; end %#ok<NASGU>
if nargin < 2 || isempty(loop), loop = [bdroot '/TxRxComposite']; end
tx = [loop '/Transmitter'];
id = [tx '/Input Data'];

if ~isempty(find_system(id,'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','Name','ByteBitShifter'))
    fprintf('byte_tx_overlay_k5: byte path already present -- skipping\n');
    return;
end

% --- (0) introspect + assert the expected Input Data topology ---
mg = [id '/Message Generator'];
assert(~isempty(find_system(id,'SearchDepth',1,'LookUnderMasks','all', ...
    'FollowLinks','on','Name','Message Generator')), 'Message Generator not found in %s', id);
pc = get_param(mg,'PortConnectivity');
% inputs first: port '1' (chart reset) <- Cast To Boolean, port '2' (enable) <- enb
assert(contains(get_param(pc(1).SrcBlock,'Name'),'Cast To Boolean'), ...
    'MG in1 source is %s, expected Cast To Boolean', get_param(pc(1).SrcBlock,'Name'));
assert(strcmp(get_param(pc(2).SrcBlock,'Name'),'enb'), ...
    'MG in2 source is %s, expected enb', get_param(pc(2).SrcBlock,'Name'));
% MG out1 -> txData, MG out3 -> Terminator1
assert(any(arrayfun(@(b) strcmp(get_param(b,'Name'),'txData'), pc(3).DstBlock)), ...
    'MG out1 does not feed txData');
assert(any(arrayfun(@(b) strcmp(get_param(b,'Name'),'Terminator1'), pc(5).DstBlock)), ...
    'MG out3 (start) does not feed Terminator1');
nInId  = numel(find_system(id,'SearchDepth',1,'LookUnderMasks','all','FollowLinks','on','BlockType','Inport'));
nOutId = numel(find_system(id,'SearchDepth',1,'LookUnderMasks','all','FollowLinks','on','BlockType','Outport'));
assert(nInId==2 && nOutId==3, 'Input Data ports %d in/%d out (expected 2/3)', nInId, nOutId);
txph = get_param(tx,'PortHandles');
assert(numel(txph.Inport)==4 && numel(txph.Outport)==8, ...
    'Transmitter ports %d in/%d out (expected 4/8)', numel(txph.Inport), numel(txph.Outport));
fprintf('byte_tx_overlay_k5: topology asserts OK (Input Data 2/3, Transmitter 4/8)\n');

% --- (1) Input Data: new boundary ports ---
idin = { 'extWord','uint64',3; 'extWordAvail','boolean',4; ...
         'extBitSel','boolean',5; 'extWordFirst','boolean',6 };
for k = 1:size(idin,1)
    blk = [id '/' idin{k,1}];
    add_block('built-in/Inport', blk, 'Port', num2str(idin{k,3}), ...
        'Position', [40 300+40*k 70 320+40*k]);
    set_param(blk, 'OutDataTypeStr', idin{k,2});
end
add_block('built-in/Outport', [id '/extWordPop'], 'Port', '4', ...
    'Position', [620 480 650 500]);

% --- (2) Input Data: ByteBitShifter MATLAB Function block ---
add_block('simulink/User-Defined Functions/MATLAB Function', ...
    [id '/ByteBitShifter'], 'Position', [330 330 450 450]);
ch = sfroot().find('-isa','Stateflow.EMChart','Path', [id '/ByteBitShifter']);
assert(~isempty(ch), 'ByteBitShifter chart not found');
ch.Script = sprintf([ ...
'function [bit, popToggle] = byteBitShifterBlk(enable, reset, start, extWord, extWordAvail, extWordFirst)\n' ...
'%% Block wrapper around qpskByteBitShifter (the unit-tested single source\n' ...
'%% of truth). Persistent state only; the effective enable matches the\n' ...
'%% Message Generator chart''s active condition (enable && ~reset) so the\n' ...
'%% shifter emits bits on exactly the generator''s bit steps. pop is\n' ...
'%% exported as a toggle (one flip per word latch OR discard) to survive\n' ...
'%% the slow->fast rate crossing; upstream edge-detects it into a pulse.\n' ...
'persistent state tog\n' ...
'if isempty(state)\n' ...
'    state = qpskByteBitShifter();\n' ...
'    tog = false;\n' ...
'end\n' ...
'en = logical(enable) && ~logical(reset);\n' ...
'[bit, pop, state] = qpskByteBitShifter(state, en, logical(start), ...\n' ...
'    uint64(extWord), logical(extWordAvail), logical(extWordFirst));\n' ...
'if pop\n' ...
'    tog = ~tog;\n' ...
'end\n' ...
'popToggle = tog;\n']);

% shifter inputs: SAME enable source as the chart (enb inport), SAME reset
% source as the chart (Cast To Boolean = delayed stop), chart start (MG/3,
% branch off the terminated line), and the new external word ports.
add_line(id, 'enb/1',               'ByteBitShifter/1', 'autorouting','on');
add_line(id, 'Cast To Boolean/1',   'ByteBitShifter/2', 'autorouting','on');
add_line(id, 'Message Generator/3', 'ByteBitShifter/3', 'autorouting','on');
add_line(id, 'extWord/1',           'ByteBitShifter/4', 'autorouting','on');
add_line(id, 'extWordAvail/1',      'ByteBitShifter/5', 'autorouting','on');
add_line(id, 'extWordFirst/1',      'ByteBitShifter/6', 'autorouting','on');
add_line(id, 'ByteBitShifter/2',    'extWordPop/1',     'autorouting','on');

% --- (3) bit mux: Switch replaces the chart-out -> txData wire ---
delete_line(id, 'Message Generator/1', 'txData/1');
add_block('built-in/Switch', [id '/BitMux'], 'Criteria','u2 ~= 0', ...
    'Position', [500 330 530 370]);
add_line(id, 'ByteBitShifter/1',    'BitMux/1', 'autorouting','on');
add_line(id, 'extBitSel/1',         'BitMux/2', 'autorouting','on');
add_line(id, 'Message Generator/1', 'BitMux/3', 'autorouting','on');
add_line(id, 'BitMux/1', 'txData/1', 'autorouting','on');

% --- (4) Transmitter: new boundary ports, propagate to Input Data ---
txin = { 'extWord','uint64',5; 'extWordAvail','boolean',6; ...
         'extBitSel','boolean',7; 'extWordFirst','boolean',8 };
for k = 1:size(txin,1)
    blk = [tx '/' txin{k,1}];
    add_block('built-in/Inport', blk, 'Port', num2str(txin{k,3}), ...
        'Position', [30 700+40*k 60 720+40*k]);
    set_param(blk, 'OutDataTypeStr', txin{k,2});
end
add_block('built-in/Outport', [tx '/extWordPop'], 'Port', '9', ...
    'Position', [700 740 730 760]);
add_line(tx, 'extWord/1',      'Input Data/3', 'autorouting','on');
add_line(tx, 'extWordAvail/1', 'Input Data/4', 'autorouting','on');
add_line(tx, 'extBitSel/1',    'Input Data/5', 'autorouting','on');
add_line(tx, 'extWordFirst/1', 'Input Data/6', 'autorouting','on');
add_line(tx, 'Input Data/4',   'extWordPop/1', 'autorouting','on');

% --- (5) verify ---
txph = get_param(tx,'PortHandles');
assert(numel(txph.Inport)==8 && numel(txph.Outport)==9, ...
    'post: Transmitter ports %d in/%d out (expected 8/9)', numel(txph.Inport), numel(txph.Outport));
fprintf('byte_tx_overlay_k5: DONE (Transmitter in 5..8 ext*, out 9 extWordPop; ByteBitShifter + BitMux in Input Data)\n');
end
