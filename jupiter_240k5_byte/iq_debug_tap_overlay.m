function iq_debug_tap_overlay(sys, base)
% iq_debug_tap_overlay -- ACTIVATE the (existing, dangling) runtime debug tap
% and add boundary-derived loop-STATE pair registers. Campaign B1 (error hunt).
%
% (1) TAP MUX ACTIVATION: QPSK Rx already contains a complete diag mux --
%     MultiPortSwitch fed by debugMuxCtrl (= composite iq_debug_mux inport,
%     AXI 0x10C) selecting {0: AGC out, 1: post-symbol-sync, 2: post-carrier-
%     sync, 3: recovered constellation}, serialized through Data Type
%     Conversion -> Complex to Real-Imag -> Receiver outports 5/6 -- which are
%     DANGLING at the composite, so codegen erased the whole path (the netlist
%     never referenced iq_debug_mux). This overlay rewires the composite
%     debugI/debugQ outports (-> rx DMA channel voltage1, 'IP Data 2/3 OUT')
%     from the raw ADC to the muxed stream. debugValid stays adc_validIn, so
%     voltage1 carries the HELD selected stream sample-aligned with voltage0
%     (receiver-input IQ) -- the live/replay diff instrument.
%     NOTE: voltage1 no longer duplicates raw ADC (nothing consumed that).
%
% (2) STATE PAIR REGISTERS (boundary-derived "pull other state"): a StatePair
%     probe in QPSK Rx latches, every 4096th rail beat, the packed stored-int
%     I/Q of the AGC input, AGC output, carrier-sync input (= CFC out, newly
%     exported from FTS) and carrier-sync output. Host derives AGC gain
%     (|out|/|in| -- the AGC is a memoryless multiply at sample level) and the
%     carrier NCO rotation (angle(out*conj(in))) -- reset/slip/excursion
%     forensics at error instants without touching library internals.
%     4 new AXI read regs: 0x160 STATE_AGC_IN, 0x164 STATE_AGC_OUT,
%     0x168 STATE_CS_IN, 0x16C STATE_CS_OUT. Packing: (uint16(I)<<16)|uint16(Q)
%     stored-integer (sfix16_En14 reinterpret).
%
% Apply AFTER the donor phases + fec overlays (needs the diag mux + FTS).
% Idempotent. hdlworkflow_loopback.m maps the 4 new ports (see its state-pair
% section); assemble gate asserts both features.

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
rcv = [base '/Receiver'];
qrx = [rcv '/QPSK Rx'];
fts = [qrx '/Frequency and Time Synchronizer'];

% ---------------- (1) tap mux activation ----------------
dbgI = [base '/debugI'];
lh = get_param(dbgI, 'LineHandles');
srcname = get_param(get_param(lh.Inport(1), 'SrcBlockHandle'), 'Name');
if strcmp(srcname, 'Receiver')
    fprintf('iq_debug_tap_overlay: tap mux already wired -- skipping (1)\n');
else
    % the diag chain's DTC must be a stored-integer reinterpret, not a
    % real-world convert (which would CLIP sfix16_En14 to +-2 LSBs of int16)
    dtc = [qrx '/Data Type Conversion'];
    if ~strcmp(get_param(dtc, 'ConvertRealWorld'), 'Stored Integer (SI)')
        set_param(dtc, 'ConvertRealWorld', 'Stored Integer (SI)');
        fprintf('iq_debug_tap_overlay: diag DTC forced to Stored Integer (SI)\n');
    end
    lhQ = get_param([base '/debugQ'], 'LineHandles');
    delete_line(lh.Inport(1));
    delete_line(lhQ.Inport(1));
    add_line(base, 'Receiver/5', 'debugI/1', 'autorouting', 'on');
    add_line(base, 'Receiver/6', 'debugQ/1', 'autorouting', 'on');
    fprintf(['iq_debug_tap_overlay: debugI/Q <- Receiver muxed diag ' ...
             '(0x10C sel: 0=AGC out,1=postSS,2=postCS,3=constellation)\n']);
end

% ---------------- (2) state pair registers ----------------
% LEAN (QPSK_LEAN=1): STRIP the boundary state-pairs (0x160-0x16C). Section (1)
% above -- the 0x10C runtime tap mux + dual-DMA -- is KEPT (the verification
% instrument); only the debug state-snapshot ports are dropped.
if ~isempty(getenv('QPSK_LEAN'))
    fprintf('iq_debug_tap_overlay: LEAN -- 0x10C mux kept, state-pairs (2) stripped\n');
    return;
end
if ~isempty(find_system(qrx, 'SearchDepth',1, 'LookUnderMasks','all', ...
        'FollowLinks','on', 'Name','StatePairProbe'))
    fprintf('iq_debug_tap_overlay: StatePairProbe already present -- skipping (2)\n');
    return;
end

% 2a. export CFC output (carrier-sync input) from FTS as a new outport
nFtsOut = numel(find_system(fts, 'SearchDepth',1, 'BlockType','Outport'));
assert(nFtsOut == 9, 'FTS outport count %d != 9 (model drifted)', nFtsOut);
add_block('built-in/Outport', [fts '/postCoarseFreq'], 'Port', '10', ...
    'Position', [1450 620 1480 636]);
add_line(fts, 'Coarse Frequency Compensator/1', 'postCoarseFreq/1', ...
    'autorouting', 'on');

% 2b. StatePairProbe in QPSK Rx
add_block('simulink/User-Defined Functions/MATLAB Function', ...
    [qrx '/StatePairProbe'], 'Position', [340 1100 480 1220]);
set_fcn_script([qrx '/StatePairProbe'], statePairProbe_src());
snames = {'state_agc_in','state_agc_out','state_cs_in','state_cs_out'};
nOutQ = numel(find_system(qrx, 'SearchDepth',1, 'LookUnderMasks','all', ...
    'BlockType','Outport'));
qports = zeros(1,4);
for k = 1:4
    qports(k) = nOutQ + k;
    add_block('built-in/Outport', [qrx '/' snames{k}], ...
        'Port', num2str(qports(k)), 'Position', [900 1100+30*k 930 1116+30*k]);
end
add_line(qrx, 'dataIn/1', 'StatePairProbe/1', 'autorouting','on');   % AGC in
add_line(qrx, 'Automatic Gain Control/1', 'StatePairProbe/2', 'autorouting','on');
add_line(qrx, 'Frequency and Time Synchronizer/10', 'StatePairProbe/3', 'autorouting','on'); % CS in (CFC out)
add_line(qrx, 'Frequency and Time Synchronizer/6', 'StatePairProbe/4', 'autorouting','on');  % CS out
for k = 1:4
    add_line(qrx, sprintf('StatePairProbe/%d', k), [snames{k} '/1'], 'autorouting','on');
end
fprintf('iq_debug_tap_overlay: StatePairProbe + 4 outports in QPSK Rx (ports %s)\n', mat2str(qports));

% 2c. surface: QPSK Rx -> Receiver -> TxRxComposite (fec_capture pattern)
levels = { rcv, 'QPSK Rx'; base, 'Receiver' };
childPorts = qports;
for L = 1:size(levels,1)
    parent = levels{L,1};
    child  = levels{L,2};
    nOut0 = numel(find_system(parent, 'SearchDepth',1, 'LookUnderMasks','all', ...
        'BlockType','Outport'));
    newPorts = zeros(1,4);
    for k = 1:4
        thisPort = nOut0 + k;
        add_block('built-in/Outport', [parent '/' snames{k}], ...
            'Port', num2str(thisPort), 'Position', [980 1100+30*thisPort 1010 1116+30*thisPort]);
        add_line(parent, sprintf('%s/%d', child, childPorts(k)), ...
            [snames{k} '/1'], 'autorouting','on');
        newPorts(k) = thisPort;
    end
    childPorts = newPorts;
    fprintf('iq_debug_tap_overlay: surfaced state pairs through %s (ports %s)\n', ...
        parent, mat2str(newPorts));
end
fprintf(['iq_debug_tap_overlay: DONE -- tap mux live (0x10C) + state pairs ' ...
         '(AXI 0x160/0x164/0x168/0x16C via hdlworkflow)\n']);
end

% ===================== helpers =====================
function set_fcn_script(blk, src)
rt = sfroot;
chart = rt.find('-isa','Stateflow.EMChart','Path',blk);
chart.Script = src;
end

function src = statePairProbe_src()
% Latch packed stored-int I/Q pairs of (AGC in, AGC out, CS in, CS out) every
% 4096th rail beat. Each output is one atomically-readable uint32:
%   (uint16 stored-int I) << 16 | (uint16 stored-int Q)
% Host: int16 halves reinterpret as sfix16_En14; AGC gain = |out|/|in|;
% carrier rotation = angle(out * conj(in)). ~59 Hz update at the 240 ksym
% rail -- two devmem reads land inside one update window essentially always.
src = sprintf([ ...
'function [agcIn, agcOut, csIn, csOut] = statePairProbe(uAgcIn, uAgcOut, uCsIn, uCsOut)\n' ...
'%%#codegen\n' ...
'persistent rAI rAO rCI rCO cnt;\n' ...
'if isempty(rAI)\n' ...
'  rAI=uint32(0); rAO=uint32(0); rCI=uint32(0); rCO=uint32(0); cnt=uint16(0);\n' ...
'end\n' ...
'a=rAI; b=rAO; c=rCI; d=rCO; n=cnt;\n' ...
'if n == uint16(0)\n' ...
'  a = pack_iq(uAgcIn); b = pack_iq(uAgcOut);\n' ...
'  c = pack_iq(uCsIn);  d = pack_iq(uCsOut);\n' ...
'end\n' ...
'n = n + uint16(1);\n' ...
'if n >= uint16(4096), n = uint16(0); end\n' ...
'agcIn = a; agcOut = b; csIn = c; csOut = d;\n' ...
'rAI=a; rAO=b; rCI=c; rCO=d; cnt=n;\n' ...
'end\n' ...
'function p = pack_iq(u)\n' ...
'ri = reinterpretcast(real(u), numerictype(0,16,0));\n' ...
'qi = reinterpretcast(imag(u), numerictype(0,16,0));\n' ...
'p = bitor(bitshift(uint32(ri), 16), uint32(qi));\n' ...
'end\n']);
end
