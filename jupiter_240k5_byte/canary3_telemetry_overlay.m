function canary3_telemetry_overlay(sys, base)
% canary3_telemetry_overlay -- T8.7 P1a-core: STATE TELEMETRY broadcast.
% Continuously rotates the never-forgetting synchronizer-loop state through a
% new debug-mux mode (0x10C = 4), one 32-bit word per rail beat as {I=hi16,
% Q=lo16} on the rx2-lpc tap stream. 24-slot rotation -> a complete state
% image every 24 beats (~1.6 us): thousands of full snapshots per episode,
% timestamped by stream position. Feeds the T8.7 state-injected replay
% (rtl_sim/sim_byte_inject; see STATE_CAPTURE_PLAN.md).
%
% P1a-core scope (all block names verified in T8.5/T8.6 work):
%   slots 0..7   Symbol Sync Loop Filter: integrator(Delay), P(Delay1),
%                Delay4, Delay6, Delay3, Delay5, Delay2 lo/hi (sfix40)
%   slot  8      Interpolation Control {und[22] | countReg[21:11] | mu[10:0]}
%                (IC script gains a 3rd output exposing countReg)
%   slots 9..17  Carrier LF: stateP, stateI lo/hi, {Delay7|Delay5} pack,
%                Delay6, Delay2, Delay1, Delay3 lo/hi
%   slots 18..21 AGC integrator re lo/hi, im lo/hi (sfix34, complex)
%   slot  22     marker 0xA5C0FFEE   slot 23  image counter
% P1b (deferred, needs name recon): CFC estimator, Peak Search/Timing
% Adjust/FIFO/Packet Controller decision state. NCO phase is library-hidden:
% fitted at injection time (plan section 'harness').
%
% Requires canary_instrumentation_overlay + canary2_overlay applied (uses
% their Loop Filter state outports). Idempotent. Zero datapath impact: the
% mux default stays 0 and modes 0-3 are unchanged.

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end

rcv = [base '/Receiver'];
qrx = [rcv '/QPSK Rx'];
fts = [qrx '/Frequency and Time Synchronizer'];
ss  = [fts '/Symbol Synchronizer'];
cs  = [fts '/Carrier Synchronizer'];
agc = [qrx '/Automatic Gain Control'];

if ~isempty(find_system(qrx,'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','Name','TelemetrySerializer'))
    fprintf('canary3_telemetry_overlay: already present -- skipping\n');
    return;
end
assert(~isempty(find_system(cs,'SearchDepth',1,'Name','Loop Filter Shadow')), ...
    'canary3: apply AFTER canary2_overlay');

%% ---- 1. widen the state taps on both loop filters ----
lf1 = [ss '/Loop Filter'];   % SS LF: outports v(1), stateP(2), stateI(3) exist
for spec = {{'Delay4','st_d4'},{'Delay6','st_d6'},{'Delay3','st_d3'},{'Delay5','st_d5'},{'Delay2','st_d2'}}
    blk = spec{1}{1}; nm = spec{1}{2};
    if isempty(find_system(lf1,'SearchDepth',1,'BlockType','Outport','Name',nm))
        n = numel(find_system(lf1,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
        add_block('built-in/Outport',[lf1 '/' nm],'Port',num2str(n+1),'Position',[950 260+30*n 980 276+30*n]);
        add_line(lf1,[blk '/1'],[nm '/1'],'autorouting','on');
    end
end
lf2 = [cs '/Loop Filter'];   % CS LF: v,valid,rst,stateP(4),stateI(5) exist
for spec = {{'Delay7','st_d7'},{'Delay5','st_d5'},{'Delay6','st_d6'},{'Delay2','st_d2'},{'Delay1','st_d1'},{'Delay3','st_d3'}}
    blk = spec{1}{1}; nm = spec{1}{2};
    if isempty(find_system(lf2,'SearchDepth',1,'BlockType','Outport','Name',nm))
        n = numel(find_system(lf2,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
        add_block('built-in/Outport',[lf2 '/' nm],'Port',num2str(n+1),'Position',[950 380+30*n 980 396+30*n]);
        add_line(lf2,[blk '/1'],[nm '/1'],'autorouting','on');
    end
end
% AGC LF integrator (complex sfix34)
alf = [agc '/Loop Filter'];
if isempty(find_system(alf,'SearchDepth',1,'BlockType','Outport','Name','st_integ'))
    n = numel(find_system(alf,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
    add_block('built-in/Outport',[alf '/st_integ'],'Port',num2str(n+1),'Position',[900 200 930 216]);
    add_line(alf,'Delay1/1','st_integ/1','autorouting','on');
end
fprintf('canary3: loop-filter state taps widened\n');

%% ---- 2. IC script: expose countReg as a 3rd output ----
icp = [ss '/Interpolation Control'];
cfg = get_param(icp,'MATLABFunctionConfiguration');
code = cfg.FunctionScript;
if ~contains(code,'stateWord')
    code = strrep(code, 'function [mu,Underflow] = Interpolation_ctrl(Delta)', ...
                        'function [mu,Underflow,stateWord] = Interpolation_ctrl(Delta)');
    anchor = 'Underflow = underflowReg;';
    assert(contains(code,anchor),'IC anchor missing');
    code = strrep(code, anchor, sprintf(['Underflow = underflowReg;\n' ...
        '   %% T8.7 telemetry: {und[22] | countReg[21:11] | mu[10:0]} stored-int\n' ...
        '   stateWord = bitor(bitor(uint32(reinterpretcast(muReg, numerictype(0,11,0))), ...\n' ...
        '       bitshift(uint32(reinterpretcast(countReg, numerictype(0,11,0))), 11)), ...\n' ...
        '       bitshift(uint32(underflowReg), 22));\n']));
    cfg.FunctionScript = code;
    fprintf('canary3: IC stateWord output added\n');
end

%% ---- 3. surface state signals to QPSK Rx level ----
% SS group: 7 LF words + IC stateWord  (SS -> FTS -> QRX)
ssnames = {'t_ss_i','t_ss_p','t_ss_d4','t_ss_d6','t_ss_d3','t_ss_d5','t_ss_d2','t_ic'};
sssrc   = {'Loop Filter/3','Loop Filter/2','Loop Filter/4','Loop Filter/5', ...
           'Loop Filter/6','Loop Filter/7','Loop Filter/8','Interpolation Control/3'};
% NOTE: LF outport numbers: v=1,stateP=2,stateI=3 then st_d4..st_d2 = 4..8;
% t_ss_i=stateI(3), t_ss_p=stateP(2), then 4..8 in added order.
nSs = numel(find_system(ss,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
ssPorts = zeros(1,8);
for k = 1:8
    add_block('built-in/Outport',[ss '/' ssnames{k}],'Port',num2str(nSs+k), ...
        'Position',[1200 500+26*k 1230 516+26*k]);
    add_line(ss, sssrc{k}, [ssnames{k} '/1'], 'autorouting','on');
    ssPorts(k) = nSs+k;
end
% CS group: 9 words (stateP, stateI, d7,d5,d6,d2,d1,d3) -- stateI/d3 wide
csnames = {'t_cs_p','t_cs_i','t_cs_d7','t_cs_d5','t_cs_d6','t_cs_d2','t_cs_d1','t_cs_d3'};
cssrc   = {'Loop Filter/4','Loop Filter/5','Loop Filter/6','Loop Filter/7', ...
           'Loop Filter/8','Loop Filter/9','Loop Filter/10','Loop Filter/11'};
nCs = numel(find_system(cs,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
csPorts = zeros(1,8);
for k = 1:8
    add_block('built-in/Outport',[cs '/' csnames{k}],'Port',num2str(nCs+k), ...
        'Position',[1200 500+26*k 1230 516+26*k]);
    add_line(cs, cssrc{k}, [csnames{k} '/1'], 'autorouting','on');
    csPorts(k) = nCs+k;
end
% AGC group: 1 complex word (AGC -> QRX is one hop; AGC LF -> AGC first)
nAgc = numel(find_system(agc,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
alfN = numel(find_system(alf,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
add_block('built-in/Outport',[agc '/t_agc_i'],'Port',num2str(nAgc+1),'Position',[1100 400 1130 416]);
add_line(agc, sprintf('Loop Filter/%d', alfN), 't_agc_i/1', 'autorouting','on');
% surface SS/CS groups through FTS
nFts = numel(find_system(fts,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
allnames = [ssnames csnames];
allsrcblk = [repmat({'Symbol Synchronizer'},1,8) repmat({'Carrier Synchronizer'},1,8)];
allports = [ssPorts csPorts];
ftsPorts = zeros(1,16);
for k = 1:16
    add_block('built-in/Outport',[fts '/' allnames{k}],'Port',num2str(nFts+k), ...
        'Position',[1300 700+24*k 1330 716+24*k]);
    add_line(fts, sprintf('%s/%d', allsrcblk{k}, allports(k)), [allnames{k} '/1'], 'autorouting','on');
    ftsPorts(k) = nFts+k;
end
fprintf('canary3: 16 FTS + 1 AGC state signals surfaced to QPSK Rx inputs\n');

%% ---- 4. TelemetrySerializer at QPSK Rx level ----
add_block('simulink/User-Defined Functions/MATLAB Function',[qrx '/TelemetrySerializer'], ...
    'Position',[1250 1500 1400 1650]);
set_fcn_script([qrx '/TelemetrySerializer'], telemetrySerializer_src());
% Pin explicit port types on the chart data. With 'Inherit: Same as Simulink'
% the propagation engine analyzes the body with a double PROBE before the
% source types resolve, and reinterpretcast hard-errors on the probe (probe5
% diary: "reinterpretcast is not defined for inputs of data type double" on
% ssD2). Explicit types kill the probe. Types are the probe4 compiled ground
% truth of the 17 tapped signals.
telTypes = struct( ...
    'ssI','fixdt(1,30,23)','ssP','fixdt(1,30,23)','ssD4','fixdt(1,30,23)', ...
    'ssD6','fixdt(1,30,23)','ssD3','fixdt(1,30,23)','ssD5','fixdt(1,30,23)', ...
    'ssD2','fixdt(1,40,24)','icW','uint32','csP','fixdt(1,29,29)', ...
    'csI','fixdt(1,39,39)','csD7','fixdt(1,13,10)','csD5','fixdt(1,13,10)', ...
    'csD6','fixdt(1,29,26)','csD2','fixdt(1,29,29)','csD1','fixdt(1,29,26)', ...
    'csD3','fixdt(1,39,39)','agcI','fixdt(1,34,28)', ...
    'telI','fixdt(1,16,0)','telQ','fixdt(1,16,0)');
tsch = sfroot().find('-isa','Stateflow.EMChart','Path',[qrx '/TelemetrySerializer']);
tsd = tsch.getChildren();
nPinned = 0;
for i = 1:numel(tsd)
    if isa(tsd(i),'Stateflow.Data') && isfield(telTypes, tsd(i).Name)
        tsd(i).DataType = telTypes.(tsd(i).Name);
        nPinned = nPinned + 1;
    end
end
assert(nPinned == 19, 'canary3: pinned %d/19 serializer port types', nPinned);
fprintf('canary3: serializer port types pinned (17 in + 2 out)\n');
% DTC Stored-Integer casts between the tap outports and the serializer.
% Without them the pinned types BACK-PROPAGATE through the tap outports into
% the primary loop-filter Delay states -- fine in the loopback (natural types
% match the netlist) but a hard conflict in byte_harness_k5, whose fresh-model
% default hardware config makes 'Inherit via internal rule' Gains compute
% sfix32 where the loopback computes sfix29 (gate stage-2 failure 2026-07-13).
% A specified DTC output resolves instantly (no MLFB double-probe), stops the
% back-prop, is an identity wire in the loopback/netlist context, and only
% SI-truncates in the harness sim (telemetry values are not gate-checked).
telInTypes = {'fixdt(1,30,23)','fixdt(1,30,23)','fixdt(1,30,23)','fixdt(1,30,23)', ...
              'fixdt(1,30,23)','fixdt(1,30,23)','fixdt(1,40,24)','', ...
              'fixdt(1,29,29)','fixdt(1,39,39)','fixdt(1,13,10)','fixdt(1,13,10)', ...
              'fixdt(1,29,26)','fixdt(1,29,29)','fixdt(1,29,26)','fixdt(1,39,39)', ...
              'fixdt(1,34,28)'};
for k = 1:16
    if isempty(telInTypes{k})   % icW: uint32 MLFB output, already resolved
        add_line(qrx, sprintf('Frequency and Time Synchronizer/%d', ftsPorts(k)), ...
            sprintf('TelemetrySerializer/%d', k), 'autorouting','on');
    else
        dn = sprintf('TelSi%d', k);
        add_block('simulink/Signal Attributes/Data Type Conversion',[qrx '/' dn], ...
            'OutDataTypeStr',telInTypes{k},'ConvertRealWorld','Stored Integer (SI)', ...
            'Position',[1180 1490+26*k 1220 1506+26*k]);
        add_line(qrx, sprintf('Frequency and Time Synchronizer/%d', ftsPorts(k)), ...
            [dn '/1'], 'autorouting','on');
        add_line(qrx, [dn '/1'], sprintf('TelemetrySerializer/%d', k), 'autorouting','on');
    end
end
add_block('simulink/Signal Attributes/Data Type Conversion',[qrx '/TelSiAgc'], ...
    'OutDataTypeStr',telInTypes{17},'ConvertRealWorld','Stored Integer (SI)', ...
    'Position',[1180 1946 1220 1962]);
add_line(qrx, sprintf('Automatic Gain Control/%d', nAgc+1), 'TelSiAgc/1', 'autorouting','on');
add_line(qrx, 'TelSiAgc/1', 'TelemetrySerializer/17', 'autorouting','on');
fprintf('canary3: DTC-SI isolation casts inserted on 16 tapped state signals\n');

%% ---- 5. extend the debug mux to mode 4 = telemetry ----
mux = find_system(qrx,'SearchDepth',1,'LookUnderMasks','all','BlockType','MultiPortSwitch');
assert(numel(mux)==1, 'expected exactly one debug MultiPortSwitch in QPSK Rx, found %d', numel(mux));
mux = mux{1};
nIn = str2double(get_param(mux,'Inputs'));
set_param(mux,'Inputs',num2str(nIn+1));
% mux data inputs are complex (I+jQ) -- serializer outputs telI/telQ int16;
% combine via Real-Imag to Complex
add_block('simulink/Math Operations/Real-Imag to Complex',[qrx '/TelToCplx'], ...
    'Input','Real and imag','Position',[1450 1540 1490 1580]);
add_line(qrx,'TelemetrySerializer/1','TelToCplx/1','autorouting','on');
add_line(qrx,'TelemetrySerializer/2','TelToCplx/2','autorouting','on');
% match the switch's data type bit-exactly (stored-integer cast to sfix16_En14
% pair -- the same DTC-SI idiom as the T8.5 tap)
add_block('simulink/Signal Attributes/Data Type Conversion',[qrx '/TelDtc'], ...
    'OutDataTypeStr','fixdt(1,16,14)','ConvertRealWorld','Stored Integer (SI)', ...
    'Position',[1510 1545 1550 1575]);
add_line(qrx,'TelToCplx/1','TelDtc/1','autorouting','on');
% data ports on MultiPortSwitch: port 1 = control, data = 2..nIn+1; new last data port
add_line(qrx,'TelDtc/1',sprintf('%s/%d', get_param(mux,'Name'), nIn+2),'autorouting','on');
fprintf('canary3: debug mux widened to mode 4 = state telemetry\n');

fprintf('canary3_telemetry_overlay: DONE (0x10C=4 -> 24-slot state broadcast)\n');
end

% ===================== helpers =====================
function set_fcn_script(blk, src)
rt = sfroot;
chart = rt.find('-isa','Stateflow.EMChart','Path',blk);
chart.Script = src;
end

function src = telemetrySerializer_src()
% 24-slot rotation; each beat emits one u32 as {telI=hi16, telQ=lo16} int16.
% Wide words split lo/hi (lo = bits 15:0 in Q of one slot... full u32 per
% slot: hi16->I, lo16->Q). fi taps reinterpret to stored-int.
src = sprintf([ ...
'function [telI, telQ] = telemetrySerializer(ssI, ssP, ssD4, ssD6, ssD3, ssD5, ssD2, icW, ...\n' ...
'    csP, csI, csD7, csD5, csD6, csD2, csD1, csD3, agcI)\n' ...
'%%#codegen\n' ...
'persistent slot img\n' ...
'if isempty(slot), slot = uint8(0); img = uint32(0); end\n' ...
'w = uint32(0);\n' ...
'switch slot\n' ...
'  case uint8(0),  w = uint32(reinterpretcast(ssI,  numerictype(0,30,0)));\n' ...
'  case uint8(1),  w = uint32(reinterpretcast(ssP,  numerictype(0,30,0)));\n' ...
'  case uint8(2),  w = uint32(reinterpretcast(ssD4, numerictype(0,30,0)));\n' ...
'  case uint8(3),  w = uint32(reinterpretcast(ssD6, numerictype(0,30,0)));\n' ...
'  case uint8(4),  w = uint32(reinterpretcast(ssD3, numerictype(0,30,0)));\n' ...
'  case uint8(5),  w = uint32(reinterpretcast(ssD5, numerictype(0,30,0)));\n' ...
'  case uint8(6),  w = uint32(bitsliceget(reinterpretcast(ssD2, numerictype(0,40,0)), 32, 1));\n' ...
'  case uint8(7),  w = uint32(bitsliceget(reinterpretcast(ssD2, numerictype(0,40,0)), 40, 33));\n' ...
'  case uint8(8),  w = icW;\n' ...
'  case uint8(9),  w = uint32(reinterpretcast(csP, numerictype(0,29,0)));\n' ...
'  case uint8(10), w = uint32(bitsliceget(reinterpretcast(csI, numerictype(0,39,0)), 32, 1));\n' ...
'  case uint8(11), w = uint32(bitsliceget(reinterpretcast(csI, numerictype(0,39,0)), 39, 33));\n' ...
'  case uint8(12), w = bitor(uint32(reinterpretcast(csD7, numerictype(0,13,0))), ...\n' ...
'                      bitshift(uint32(reinterpretcast(csD5, numerictype(0,13,0))), 13));\n' ...
'  case uint8(13), w = uint32(reinterpretcast(csD6, numerictype(0,29,0)));\n' ...
'  case uint8(14), w = uint32(reinterpretcast(csD2, numerictype(0,29,0)));\n' ...
'  case uint8(15), w = uint32(reinterpretcast(csD1, numerictype(0,29,0)));\n' ...
'  case uint8(16), w = uint32(bitsliceget(reinterpretcast(csD3, numerictype(0,39,0)), 32, 1));\n' ...
'  case uint8(17), w = uint32(bitsliceget(reinterpretcast(csD3, numerictype(0,39,0)), 39, 33));\n' ...
'  case uint8(18), w = uint32(bitsliceget(reinterpretcast(real(agcI), numerictype(0,34,0)), 32, 1));\n' ...
'  case uint8(19), w = uint32(bitsliceget(reinterpretcast(real(agcI), numerictype(0,34,0)), 34, 33));\n' ...
'  case uint8(20), w = uint32(bitsliceget(reinterpretcast(imag(agcI), numerictype(0,34,0)), 32, 1));\n' ...
'  case uint8(21), w = uint32(bitsliceget(reinterpretcast(imag(agcI), numerictype(0,34,0)), 34, 33));\n' ...
'  case uint8(22), w = uint32(2781216750);\n' ...   % 0xA5C0FFEE marker
'  otherwise,      w = img;\n' ...
'end\n' ...
'slot = slot + uint8(1);\n' ...
'if slot >= uint8(24)\n  slot = uint8(0);\n  img = img + uint32(1);\nend\n' ...
'telI = reinterpretcast(uint16(bitshift(w, -16)), numerictype(1,16,0));\n' ...
'telQ = reinterpretcast(uint16(bitand(w, uint32(65535))), numerictype(1,16,0));\n']);
end
