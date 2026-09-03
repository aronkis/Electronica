function p1c_pd_telemetry_overlay(sys, base)
% p1c_pd_telemetry_overlay -- FULL beat-exact Preamble Detector state+input
% telemetry (debug-mux stream). The sim-mirroring instrument: the captured
% stream carries BOTH the PD's exact input (dataIn/validIn per symbol beat)
% and its complete decision state, so the netlist Preamble_Detector.v can be
% driven with identical input and compared register-for-register against
% the live stream at the exact beats of an episode.
%
% Per SYMBOL (validIn beat) an 8-word snapshot is latched and emitted over
% the following 8 rail beats (one 32-bit word per beat = the tap's full
% bandwidth). Slot layout:
%   S0 {tag=0xD[31:28], tRef[27:17], tOff[16:6], done,newPk,succ,thrEx,sync,armed[5:0]}
%   S1 corr[31:0]                (Correlator dataOut, SI of sfix32_En26)
%   S2 {taRef[31:21], accOff[20:10], fifoEnt[9:1], vPop[0]}
%   S3 {dataI[31:16], dataQ[15:0]}   <-- the exact PD input symbol
%   S4 tRefLong[31:0]            (free-running symbol timestamp)
%   S5 runningMax[31:0]          (SI of sfix32_En26)
%   S6 heldPeakTs[31:0]          (timestamp latched at each peak; was a
%                                 free Terminator tap -- peak-to-peak deltas
%                                 vs 1133 ARE the displacement measurement)
%   S7 {0xA5[31:24], symCtr[23:0]}
%
% Read-only taps throughout; new outports added INSIDE Peak Search (masked,
% plain subsystem -- add_block legal) and Timing Adjust. All MLFB ports
% pinned + DTC-SI isolated (double-probe / back-prop lessons). In the LEAN
% build this stream lands on debug-mux MODE 4 (modes 0-3 stock).

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end

rcv = [base '/Receiver'];
qrx = [rcv '/QPSK Rx'];
fts = [qrx '/Frequency and Time Synchronizer'];
pd  = [fts '/Preamble Detector'];
ps  = [pd '/Peak Search'];
ta  = [pd '/Timing Adjust'];

if ~isempty(find_system(pd,'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','Name','PdTelemetry'))
    fprintf('p1c_pd_telemetry_overlay: already present -- skipping\n');
    return;
end

lo = 'LookUnderMasks';
nl = sprintf('\n');

% ---------- 1. surface Peak Search internals (inside the mask) ----------
% blocks: 'timing Reference' (mod-1133 counter), 'timing Reference Long'
% (32-bit), running max ('Unit Delay Enabled Resettable\nSynchronous'),
% new-peak strobe ('Logical\nOperator4'), held peak timestamp
% ('Unit Delay Enabled\nSynchronous1' -> currently a Terminator).
nPs = numel(find_system(ps,'SearchDepth',1,lo,'all','BlockType','Outport'));
psAdd = { ...
    'timing Reference',                                'p1c_tref'; ...
    'timing Reference Long',                           'p1c_treflong'; ...
    ['Unit Delay Enabled Resettable' nl 'Synchronous'],'p1c_runmax'; ...
    ['Logical' nl 'Operator4'],                        'p1c_newpk'; ...
    ['Unit Delay Enabled' nl 'Synchronous1'],          'p1c_heldts'};
psPorts = zeros(1,size(psAdd,1));
for k = 1:size(psAdd,1)
    add_block('built-in/Outport',[ps '/' psAdd{k,2}],'Port',num2str(nPs+k), ...
        'Position',[1400 300+30*k 1430 316+30*k]);
    add_line(ps, [psAdd{k,1} '/1'], [psAdd{k,2} '/1'], 'autorouting','on');
    psPorts(k) = nPs+k;
end
fprintf('p1c: Peak Search internals surfaced (%d ports)\n', size(psAdd,1));

% ---------- 2. surface Timing Adjust internals ----------
nTa = numel(find_system(ta,'SearchDepth',1,lo,'all','BlockType','Outport'));
taAdd = { ...
    'State Register',                          'p1c_armed'; ...
    'timing Reference',                        'p1c_taref'; ...
    ['Unit Delay Enabled' nl 'Synchronous3'],  'p1c_accoff'};
taPorts = zeros(1,size(taAdd,1));
for k = 1:size(taAdd,1)
    add_block('built-in/Outport',[ta '/' taAdd{k,2}],'Port',num2str(nTa+k), ...
        'Position',[1400 300+30*k 1430 316+30*k]);
    add_line(ta, [taAdd{k,1} '/1'], [taAdd{k,2} '/1'], 'autorouting','on');
    taPorts(k) = nTa+k;
end
fprintf('p1c: Timing Adjust internals surfaced (%d ports)\n', size(taAdd,1));

% ---------- 3. the PD-level telemetry MLFB ----------
add_block('simulink/User-Defined Functions/MATLAB Function',[pd '/PdTelemetry'], ...
    'Position',[1500 700 1650 950]);
set_fcn_script([pd '/PdTelemetry'], sprintf([ ...
'function [telI, telQ] = pdTelemetry(validIn, dI, dQ, corr, thrEx, tRef, tOff, ' ...
'done, newPk, succ, sync, armed, taRef, accOff, fifoEnt, vPop, tRefLong, runMax, heldTs)\n' ...
'%%#codegen\n' ...
'persistent slot symCtr s0 s1 s2 s3 s4 s5 s6 s7\n' ...
'if isempty(slot)\n' ...
'    slot = uint8(7); symCtr = uint32(0);\n' ...
'    s0 = uint32(0); s1 = uint32(0); s2 = uint32(0); s3 = uint32(0);\n' ...
'    s4 = uint32(0); s5 = uint32(0); s6 = uint32(0); s7 = uint32(0);\n' ...
'end\n' ...
'if validIn\n' ...
'    symCtr = symCtr + uint32(1);\n' ...
'    flags = uint32(done) + bitshift(uint32(newPk),1) + bitshift(uint32(succ),2) + ...\n' ...
'            bitshift(uint32(thrEx),3) + bitshift(uint32(sync),4) + bitshift(uint32(armed),5);\n' ...
'    s0 = bitor(bitor(bitor(bitshift(uint32(13),28), bitshift(uint32(bitand(tRef,uint16(2047))),17)), ...\n' ...
'         bitshift(uint32(bitand(tOff,uint16(2047))),6)), flags);\n' ...
'    s1 = corr;\n' ...
'    s2 = bitor(bitor(bitor(bitshift(uint32(bitand(taRef,uint16(2047))),21), ...\n' ...
'         bitshift(uint32(bitand(accOff,uint16(2047))),10)), ...\n' ...
'         bitshift(uint32(bitand(fifoEnt,uint16(511))),1)), uint32(vPop));\n' ...
'    s3 = bitor(bitshift(uint32(reinterpretcast(dI,numerictype(0,16,0))),16), ...\n' ...
'         uint32(reinterpretcast(dQ,numerictype(0,16,0))));\n' ...
'    s4 = tRefLong;\n' ...
'    s5 = runMax;\n' ...
'    s6 = heldTs;\n' ...
'    s7 = bitor(bitshift(uint32(165),24), bitand(symCtr,uint32(16777215)));\n' ...
'    slot = uint8(0);\n' ...
'end\n' ...
'switch slot\n' ...
'  case uint8(0), w = s0;\n' ...
'  case uint8(1), w = s1;\n' ...
'  case uint8(2), w = s2;\n' ...
'  case uint8(3), w = s3;\n' ...
'  case uint8(4), w = s4;\n' ...
'  case uint8(5), w = s5;\n' ...
'  case uint8(6), w = s6;\n' ...
'  otherwise,     w = s7;\n' ...
'end\n' ...
'if slot < uint8(7), slot = slot + uint8(1); end\n' ...
'telI = reinterpretcast(uint16(bitshift(w, -16)), numerictype(1,16,0));\n' ...
'telQ = reinterpretcast(uint16(bitand(w, uint32(65535))), numerictype(1,16,0));\n']));
pin_types([pd '/PdTelemetry'], struct( ...
    'validIn','boolean','dI','int16','dQ','int16','corr','uint32', ...
    'thrEx','boolean','tRef','uint16','tOff','uint16','done','boolean', ...
    'newPk','boolean','succ','boolean','sync','boolean','armed','boolean', ...
    'taRef','uint16','accOff','uint16','fifoEnt','uint16','vPop','boolean', ...
    'tRefLong','uint32','runMax','uint32','heldTs','uint32', ...
    'telI','fixdt(1,16,0)','telQ','fixdt(1,16,0)'));

% ---------- 4. wire the 19 inputs (DTC-SI isolation on non-boolean) ----------
    function siwire(srcSpec, dtcName, dtStr, dstPort)
        add_block('simulink/Signal Attributes/Data Type Conversion',[pd '/' dtcName], ...
            'OutDataTypeStr',dtStr,'ConvertRealWorld','Stored Integer (SI)', ...
            'Position',[1430 700+18*dstPort 1460 714+18*dstPort]);
        add_line(pd, srcSpec, [dtcName '/1'], 'autorouting','on');
        add_line(pd, [dtcName '/1'], sprintf('PdTelemetry/%d',dstPort), 'autorouting','on');
    end
% PD input pair + valid: trace the lines feeding the Correlator
lhC = get_param([pd '/Correlator'],'LineHandles');
srcD_re = get_param(lhC.Inport(1),'SrcPortHandle');   % dataIn (complex? -> see below)
% The PD dataIn is complex sfix16 at model level; split for the MLFB:
add_block('simulink/Math Operations/Complex to Real-Imag',[pd '/P1cSplit'], ...
    'Output','Real and imag','Position',[1380 660 1410 690]);
phSplit = get_param([pd '/P1cSplit'],'PortHandles');
add_line(pd, srcD_re, phSplit.Inport(1), 'autorouting','on');
for kk = 1:2
    dn = sprintf('P1cDSi%d', kk);
    add_block('simulink/Signal Attributes/Data Type Conversion',[pd '/' dn], ...
        'OutDataTypeStr','fixdt(1,16,0)','ConvertRealWorld','Stored Integer (SI)', ...
        'Position',[1420 655+20*kk 1450 669+20*kk]);
    add_line(pd, sprintf('P1cSplit/%d',kk), [dn '/1'], 'autorouting','on');
    add_line(pd, [dn '/1'], sprintf('PdTelemetry/%d',kk+1), 'autorouting','on');
end
% validIn = the Correlator's valid input (same line class); trace inport 2
srcV = get_param(lhC.Inport(2),'SrcPortHandle');
phT = get_param([pd '/PdTelemetry'],'PortHandles');
add_line(pd, srcV, phT.Inport(1), 'autorouting','on');
% corr + thresholdExceeded: the Peak Search inport lines
lhPS = get_param(ps,'LineHandles');
add_block('simulink/Signal Attributes/Data Type Conversion',[pd '/P1cCorrSi'], ...
    'OutDataTypeStr','fixdt(0,32,0)','ConvertRealWorld','Stored Integer (SI)', ...
    'Position',[1430 730 1460 744]);
add_line(pd, get_param(lhPS.Inport(1),'SrcPortHandle'), ...
    get_param([pd '/P1cCorrSi'],'PortHandles').Inport(1), 'autorouting','on');
add_line(pd, 'P1cCorrSi/1', 'PdTelemetry/4', 'autorouting','on');
add_line(pd, get_param(lhPS.Inport(2),'SrcPortHandle'), phT.Inport(5), 'autorouting','on');
% Peak Search internals (surfaced above) + existing outputs
siwire(sprintf('Peak Search/%d', psPorts(1)), 'P1cTrefSi',   'fixdt(0,16,0)', 6);
siwire('Peak Search/1',                       'P1cToffSi',   'fixdt(0,16,0)', 7);
add_line(pd, 'Peak Search/2', 'PdTelemetry/8',  'autorouting','on');  % done
add_line(pd, sprintf('Peak Search/%d', psPorts(4)), 'PdTelemetry/9', 'autorouting','on'); % newPk
add_line(pd, 'Peak Search/3', 'PdTelemetry/10', 'autorouting','on');  % success
add_line(pd, 'Timing Adjust/3', 'PdTelemetry/11', 'autorouting','on');% sync
add_line(pd, sprintf('Timing Adjust/%d', taPorts(1)), 'PdTelemetry/12', 'autorouting','on'); % armed
siwire(sprintf('Timing Adjust/%d', taPorts(2)), 'P1cTaRefSi', 'fixdt(0,16,0)', 13);
siwire(sprintf('Timing Adjust/%d', taPorts(3)), 'P1cAccSi',   'fixdt(0,16,0)', 14);
siwire('FIFO/2',                                'P1cEntSi',   'fixdt(0,16,0)', 15);
add_line(pd, 'FIFO/3', 'PdTelemetry/16', 'autorouting','on');         % vPop
siwire(sprintf('Peak Search/%d', psPorts(2)), 'P1cTlongSi', 'fixdt(0,32,0)', 17);
siwire(sprintf('Peak Search/%d', psPorts(3)), 'P1cRmaxSi',  'fixdt(0,32,0)', 18);
siwire(sprintf('Peak Search/%d', psPorts(5)), 'P1cHeldSi',  'fixdt(0,32,0)', 19);

% ---------- 5. surface the stream + widen the debug mux ----------
% PD -> FTS -> QRX, then combine + DTC into a new mux data input.
gnames = {'p1c_telI','p1c_telQ'};
nPd = numel(find_system(pd,'SearchDepth',1,lo,'all','BlockType','Outport'));
for k = 1:2
    add_block('built-in/Outport',[pd '/' gnames{k}],'Port',num2str(nPd+k), ...
        'Position',[1700 700+30*k 1730 716+30*k]);
    add_line(pd, sprintf('PdTelemetry/%d',k), [gnames{k} '/1'], 'autorouting','on');
end
% surface PD -> FTS only; the mux lives at QRX and reads the FTS ports
pdTelPorts = [nPd+1, nPd+2];
nFts0 = numel(find_system(fts,'SearchDepth',1,lo,'all','BlockType','Outport'));
ftsPorts = [nFts0+1, nFts0+2];
for k = 1:2
    add_block('built-in/Outport',[fts '/' gnames{k}],'Port',num2str(ftsPorts(k)), ...
        'Position',[1700 1400+26*ftsPorts(k) 1730 1416+26*ftsPorts(k)]);
    add_line(fts, sprintf('Preamble Detector/%d', pdTelPorts(k)), [gnames{k} '/1'], 'autorouting','on');
end
mux = find_system(qrx,'SearchDepth',1,lo,'all','BlockType','MultiPortSwitch');
assert(numel(mux)==1, 'p1c: expected one debug MultiPortSwitch');
mux = mux{1};
nIn = str2double(get_param(mux,'Inputs'));
set_param(mux,'Inputs',num2str(nIn+1));
add_block('simulink/Math Operations/Real-Imag to Complex',[qrx '/P1cToCplx'], ...
    'Input','Real and imag','Position',[1450 1700 1490 1740]);
add_line(qrx, sprintf('Frequency and Time Synchronizer/%d', ftsPorts(1)), 'P1cToCplx/1', 'autorouting','on');
add_line(qrx, sprintf('Frequency and Time Synchronizer/%d', ftsPorts(2)), 'P1cToCplx/2', 'autorouting','on');
add_block('simulink/Signal Attributes/Data Type Conversion',[qrx '/P1cDtc'], ...
    'OutDataTypeStr','fixdt(1,16,14)','ConvertRealWorld','Stored Integer (SI)', ...
    'Position',[1510 1705 1550 1735]);
add_line(qrx, 'P1cToCplx/1', 'P1cDtc/1', 'autorouting','on');
add_line(qrx, 'P1cDtc/1', sprintf('%s/%d', get_param(mux,'Name'), nIn+2), 'autorouting','on');

fprintf('p1c_pd_telemetry_overlay: DONE (PD state+input stream on debug-mux mode %d)\n', nIn);
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
