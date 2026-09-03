function p1b_decision_taps_overlay(sys, base)
% p1b_decision_taps_overlay -- census + latches for the FTS DECISION stages,
% the last un-instrumented corner of the receiver (P1B_TAP_MAP.md recon).
%
% After the 2026-07-15 ledger correction, ALL episode damage is modem-level:
% ~2.6 frames/episode never frame-sync + ~4.7 decode garbage + ~2.7 biterr,
% while every loop register is RTL-faithful and the input is clean. The
% suspects are the decision stages: Preamble Detector (Peak Search, FIFO,
% Timing Adjust), Packet Controller, Phase Ambiguity. This overlay counts
% every decision event and latches the key values; 5 Hz poll deltas at
% episode bins name the first stage whose cadence breaks.
%
% All taps are READ-ONLY branches at PARENT-graph level (no masked-subsystem
% or library-Reference internals touched; two signals are existing free
% Terminator taps). MLFB inputs are DTC-SI isolated + port-pinned (the
% double-probe and back-prop lessons).
%
% AXI (poll at 5 Hz; all packed uint32):
%   0x1B4  {ta_sync_cnt[15:0]  << 16 | ps_done_cnt[15:0]}
%   0x1B8  {fifo_hiwater[7:0] << 24 | ps_succ_cnt[7:0] << 16 | ps_off_last[15:0]}
%   0x1BC  fifo_pop_cnt
%   0x1C0  {pc_end_cnt[15:0]  << 16 | pc_start_cnt[15:0]}
%   0x1C4  pc_pend_cnt (pending-SR rising edges)
%   0x1C8  {pa_est_last[15:0] << 16 | pa_flip_cnt[15:0]}  (flip = top-3-bit sector change)

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end

rcv = [base '/Receiver'];
qrx = [rcv '/QPSK Rx'];
fts = [qrx '/Frequency and Time Synchronizer'];
pd  = [fts '/Preamble Detector'];
pc  = [fts '/Packet Controller'];
pa  = [fts '/Phase Ambiguity Estimation and Correction'];

if ~isempty(find_system(pd,'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','Name','PdCensus'))
    fprintf('p1b_decision_taps_overlay: already present -- skipping\n');
    return;
end

lo = 'LookUnderMasks'; fl = 'FollowLinks';

% =========== (1) Preamble Detector census ===========
add_block('simulink/User-Defined Functions/MATLAB Function',[pd '/PdCensus'], ...
    'Position',[1050 900 1170 1020]);
set_fcn_script([pd '/PdCensus'], sprintf([ ...
'function [w1, w2, w3] = pdCensus(done, succ, off, taSync, nEnt, vPop)\n' ...
'%%#codegen\n' ...
'persistent cDone cSucc pSucc cSync cPop hiw offL\n' ...
'if isempty(cDone)\n' ...
'    cDone = uint32(0); cSucc = uint32(0); pSucc = false;\n' ...
'    cSync = uint32(0); cPop = uint32(0); hiw = uint8(0); offL = uint16(0);\n' ...
'end\n' ...
'if done,   cDone = cDone + uint32(1); offL = off; end\n' ...
'if succ && ~pSucc, cSucc = cSucc + uint32(1); end\n' ...
'pSucc = logical(succ);\n' ...
'if taSync, cSync = cSync + uint32(1); end\n' ...
'if vPop,   cPop  = cPop  + uint32(1); end\n' ...
'if nEnt > hiw, hiw = nEnt; end\n' ...
'w1 = bitor(bitshift(bitand(cSync, uint32(65535)), 16), bitand(cDone, uint32(65535)));\n' ...
'w2 = bitor(bitor(bitshift(uint32(hiw), 24), ...\n' ...
'     bitshift(bitand(cSucc, uint32(255)), 16)), uint32(offL));\n' ...
'w3 = cPop;\n']));
pin_types([pd '/PdCensus'], struct('done','boolean','succ','boolean', ...
    'off','uint16','taSync','boolean','nEnt','uint8','vPop','boolean', ...
    'w1','uint32','w2','uint32','w3','uint32'));
% Peak Search boundary outputs (1=timingOffset, 2=done, 3=success)
add_block('simulink/Signal Attributes/Data Type Conversion',[pd '/P1bOffSi'], ...
    'OutDataTypeStr','fixdt(0,16,0)','ConvertRealWorld','Stored Integer (SI)', ...
    'Position',[980 900 1010 920]);
add_line(pd, 'Peak Search/1', 'P1bOffSi/1', 'autorouting','on');
add_line(pd, 'P1bOffSi/1', 'PdCensus/3', 'autorouting','on');
add_line(pd, 'Peak Search/2', 'PdCensus/1', 'autorouting','on');
add_line(pd, 'Peak Search/3', 'PdCensus/2', 'autorouting','on');
% Timing Adjust SyncPulse (outport 3)
add_line(pd, 'Timing Adjust/3', 'PdCensus/4', 'autorouting','on');
% FIFO free taps: out2 numEntries (-> Terminator), out3 validPop (-> Terminator1)
add_block('simulink/Signal Attributes/Data Type Conversion',[pd '/P1bEntSi'], ...
    'OutDataTypeStr','fixdt(0,8,0)','ConvertRealWorld','Stored Integer (SI)', ...
    'Position',[980 950 1010 970]);
add_line(pd, 'FIFO/2', 'P1bEntSi/1', 'autorouting','on');
add_line(pd, 'P1bEntSi/1', 'PdCensus/5', 'autorouting','on');
add_line(pd, 'FIFO/3', 'PdCensus/6', 'autorouting','on');
nPd = numel(find_system(pd,'SearchDepth',1,lo,'all','BlockType','Outport'));
pdnames = {'p1b_pd_w1','p1b_pd_w2','p1b_pd_w3'};
pdPorts = zeros(1,3);
for k = 1:3
    add_block('built-in/Outport',[pd '/' pdnames{k}],'Port',num2str(nPd+k), ...
        'Position',[1220 900+30*k 1250 916+30*k]);
    add_line(pd, sprintf('PdCensus/%d',k), [pdnames{k} '/1'], 'autorouting','on');
    pdPorts(k) = nPd+k;
end
fprintf('p1b: Preamble Detector census wired\n');

% =========== (2) Packet Controller census ===========
add_block('simulink/User-Defined Functions/MATLAB Function',[pc '/PcCensus'], ...
    'Position',[900 600 1000 700]);
set_fcn_script([pc '/PcCensus'], sprintf([ ...
'function [w1, w2] = pcCensus(pend, endp, startp)\n' ...
'%%#codegen\n' ...
'persistent cPend pPend cEnd cStart\n' ...
'if isempty(cPend)\n' ...
'    cPend = uint32(0); pPend = false; cEnd = uint32(0); cStart = uint32(0);\n' ...
'end\n' ...
'if pend && ~pPend, cPend = cPend + uint32(1); end\n' ...
'pPend = logical(pend);\n' ...
'if endp,   cEnd   = cEnd   + uint32(1); end\n' ...
'if startp, cStart = cStart + uint32(1); end\n' ...
'w1 = bitor(bitshift(bitand(cEnd, uint32(65535)), 16), bitand(cStart, uint32(65535)));\n' ...
'w2 = cPend;\n']));
pin_types([pc '/PcCensus'], struct('pend','boolean','endp','boolean', ...
    'startp','boolean','w1','uint32','w2','uint32'));
add_line(pc, 'MATLAB Function/1', 'PcCensus/1', 'autorouting','on');
add_line(pc, 'End Generator/1',   'PcCensus/2', 'autorouting','on');
add_line(pc, sprintf('Logical\nOperator/1'), 'PcCensus/3', 'autorouting','on');
nPc = numel(find_system(pc,'SearchDepth',1,lo,'all','BlockType','Outport'));
pcnames = {'p1b_pc_w1','p1b_pc_w2'};
pcPorts = zeros(1,2);
for k = 1:2
    add_block('built-in/Outport',[pc '/' pcnames{k}],'Port',num2str(nPc+k), ...
        'Position',[1050 600+30*k 1080 616+30*k]);
    add_line(pc, sprintf('PcCensus/%d',k), [pcnames{k} '/1'], 'autorouting','on');
    pcPorts(k) = nPc+k;
end
fprintf('p1b: Packet Controller census wired\n');

% =========== (3) Phase Ambiguity census ===========
% avgEst is COMPLEX (averaged complex products; the corrector derives the
% quadrant from it). The QUADRANT is the decision: take just the sign bits
% via Compare-To-Zero -> booleans (no fixed-point gymnastics).
add_block('simulink/User-Defined Functions/MATLAB Function',[pa '/PaCensus'], ...
    'Position',[900 500 1000 570]);
set_fcn_script([pa '/PaCensus'], sprintf([ ...
'function w = paCensus(negRe, negIm)\n' ...
'%%#codegen\n' ...
'persistent cFlip pSec init\n' ...
'if isempty(cFlip)\n' ...
'    cFlip = uint32(0); pSec = uint8(0); init = false;\n' ...
'end\n' ...
'sec = uint8(2)*uint8(negRe) + uint8(negIm);\n' ...
'if init && sec ~= pSec, cFlip = cFlip + uint32(1); end\n' ...
'pSec = sec; init = true;\n' ...
'w = bitor(bitshift(uint32(sec), 30), bitand(cFlip, uint32(1073741823)));\n']));
pin_types([pa '/PaCensus'], struct('negRe','boolean','negIm','boolean','w','uint32'));
paEstPort = str2double(get_param([pa '/Average Estimates/avgEst'],'Port'));
add_block('simulink/Math Operations/Complex to Real-Imag',[pa '/P1bEstSplit'], ...
    'Output','Real and imag','Position',[790 505 820 535]);
add_block('simulink/Logic and Bit Operations/Compare To Zero',[pa '/P1bNegRe'], ...
    'relop','<','OutDataTypeStr','boolean','Position',[840 500 870 520]);
add_block('simulink/Logic and Bit Operations/Compare To Zero',[pa '/P1bNegIm'], ...
    'relop','<','OutDataTypeStr','boolean','Position',[840 530 870 550]);
add_line(pa, sprintf('Average Estimates/%d', paEstPort), 'P1bEstSplit/1', 'autorouting','on');
add_line(pa, 'P1bEstSplit/1', 'P1bNegRe/1', 'autorouting','on');
add_line(pa, 'P1bEstSplit/2', 'P1bNegIm/1', 'autorouting','on');
add_line(pa, 'P1bNegRe/1', 'PaCensus/1', 'autorouting','on');
add_line(pa, 'P1bNegIm/1', 'PaCensus/2', 'autorouting','on');
nPa = numel(find_system(pa,'SearchDepth',1,lo,'all','BlockType','Outport'));
add_block('built-in/Outport',[pa '/p1b_pa_w1'],'Port',num2str(nPa+1), ...
    'Position',[1050 520 1080 536]);
add_line(pa, 'PaCensus/1', 'p1b_pa_w1/1', 'autorouting','on');
fprintf('p1b: Phase Ambiguity census wired\n');

% =========== surface all six words through the hierarchy ===========
groups = { pd, 'Preamble Detector', pdnames, pdPorts; ...
           pc, 'Packet Controller', pcnames, pcPorts; ...
           pa, 'Phase Ambiguity Estimation and Correction', {'p1b_pa_w1'}, nPa+1 };
levels = { fts, ''; qrx, 'Frequency and Time Synchronizer'; ...
           rcv, 'QPSK Rx'; base, 'Receiver' };
for g = 1:size(groups,1)
    childBlk = groups{g,2};
    gnames = groups{g,3};
    childPorts = groups{g,4};
    for L = 1:size(levels,1)
        parent = levels{L,1};
        child = levels{L,2};
        if L == 1, child = childBlk; end
        nOut0 = numel(find_system(parent,'SearchDepth',1,lo,'all','BlockType','Outport'));
        newPorts = zeros(1,numel(gnames));
        for k = 1:numel(gnames)
            thisPort = nOut0 + k;
            add_block('built-in/Outport', [parent '/' gnames{k}], ...
                'Port', num2str(thisPort), 'Position',[1300 1500+26*thisPort 1330 1516+26*thisPort]);
            add_line(parent, sprintf('%s/%d', child, childPorts(k)), ...
                [gnames{k} '/1'], 'autorouting','on');
            newPorts(k) = thisPort;
        end
        childPorts = newPorts;
    end
    fprintf('p1b: surfaced %s\n', strjoin(gnames,','));
end

fprintf('p1b_decision_taps_overlay: DONE (0x1B4-0x1C8)\n');
end

% ===================== helpers =====================
function set_fcn_script(blk, src)
rt = sfroot;
chart = rt.find('-isa','Stateflow.EMChart','Path',blk);
chart.Script = src;
end

function pin_types(blk, spec)
ch = sfroot().find('-isa','Stateflow.EMChart','Path',blk);
for d = ch.getChildren()'
    if ~isa(d,'Stateflow.Data'), continue; end
    if isfield(spec, d.Name), d.DataType = spec.(d.Name); end
end
end
