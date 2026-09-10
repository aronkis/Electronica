% sps4_sync_sweep_k5.m -- TIMING-RECOVERY / RESOLVER gate for the sps=4 rate rung
% (Task A3). The sps=4 build REVERTS the sps-8 symbol-sync surgery (Interpolation
% Control decrement fi(1/sps), GTED tap spans, timing_hardening wlim) and takes
% the phase-ambiguity resolver look-back to its NATIVE window (LB = 10*sps-40 = 0
% at sps=4). Those SS / GTED / resolver paths are exactly what this gate stresses.
%
% METHOD: single-pass closed-loop model sim. The DUT's own Transmitter (ROM path,
% tx_data_source=0) emits the golden 240k5 air; an in-harness Impair block feeds
% it back into the Receiver through the EXTERNAL ADC path (rx_input_select=1)
% after applying, per sweep cell:
%   * carrier frequency offset  (CFO): a phase ramp foffNorm rad / bus-sample
%   * static carrier phase      (QUADRANT k*pi/2): forces the QPSK 4-fold
%     ambiguity into quadrant k so the resolver's preamble-correlation window
%     (native at sps=4) must undo it -- the real test of LB=0
%   * timing offset             (fractional symbol): an INTEGER bus-sample delay,
%     since at sps=4 one symbol = 8 bus samples (30.72e6 = 2x the 15.36e6 rail),
%     so +-0.25 / +-0.5 symbol = +-2 / +-4 bus samples (no interpolation needed).
% The Impair block reads only PAST buffered samples (delay >= 4), so it has no
% direct feedthrough and cannot form an algebraic loop; being sim-only, cos/sin
% are fine (it is never HDL-generated).
%
% PASS (per cell): the BIST re-locks and decodes the golden frame --
%   cap_out == 0x04922282  AND  bit_errors stop increasing in steady state.
% A wrong-quadrant resolve (the failure LB=0 would cause if the native window
% were mis-placed) leaves cap_out != golden and bit_errors climbing -> FAIL.
%
% GRID: CFO {0, +-max} x timing {0, +-0.25, +-0.5} at nominal quadrant, PLUS the
% resolver worst case -- all four quadrants at nonzero timing offset and CFO.
% Writes SPS4_SYNC_SWEEP_K5.txt; errors on any cell FAIL.

KITDIR = fileparts(mfilename('fullpath'));
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
cd(KITDIR); addpath(KITDIR);
cfg = frame_config_k5();
assert(cfg.Sps==4, 'sps4_sync_sweep_k5: QPSK_SPS must be 4 for this gate (got %d)', cfg.Sps);

logf='sps4_sync_sweep_k5.log'; if exist(logf,'file'), delete(logf); end
diary(logf);
fprintf('=== sps4_sync_sweep_k5 %s (sps=%d) ===\n', char(datetime('now')), cfg.Sps);

sys='commhdlQPSKTxRxLoopback'; loop=[sys '/TxRxComposite'];

% ---------------- (0) ensure the sps4 byte variant is assembled ----------------
need=true;
if exist(fullfile(KITDIR,'commhdlQPSKTxRxLoopback.slx'),'file')
    load_system(sys);
    d=get_param(sys,'Description');
    if contains(d,'modem') && contains(d,'T8ratefix') ...
            && contains(d, sprintf('sps%d/', cfg.Sps)), need=false; end
end
if need
    fprintf('model is not the assembled sps%d byte variant -- running assemble\n', cfg.Sps);
    % release the stale in-memory copy loaded above (see sim_byte_gate_k5 note):
    % build_composite_local delete+copyfiles this .slx, so a lingering load
    % would make its save_system fail with "changed on disk since loaded".
    if bdIsLoaded(sys), close_system(sys,0); end
    run('assemble_jupiter_240k5_byte.m');
end
load_system(sys);
% pin current system: the InitFcn's qpskFindTxInputData(gcs) otherwise trips on
% a comm library left current by a preceding assemble (see sim_byte_gate_k5).
set_param(0,'CurrentSystem',sys);
evalin('base', get_param(sys,'InitFcn'));

% ---------------- (1) golden reference ----------------
G = load(fullfile(fileparts(KITDIR),'contract','golden_k5.mat'));
CAPG = uint32(G.capOut);
assert(CAPG==uint32(hex2dec('04922282')), 'golden capOut mismatch');

% ---------------- (2) harness (closed loop, external ADC) ----------------
h = build_sweep_harness(sys, loop);

% bus-sample counts: sps=4 -> 1 symbol = 4 rail samples = 8 bus samples (30.72e6)
busPerSym = 2*cfg.Sps;                 % 8
baseDelay = busPerSym;                 % 1-symbol base (integer symbols are absorbed)
% CFO: alpha = fraction of symbol rate; max within the carrier-loop pull-in
% (CSBnXTsamp=0.005). foffNorm = 2*pi*alpha/busPerSym rad per bus sample.
alphaMax = 0.004;
foff = @(a) 2*pi*a/busPerSym;

% ---------------- (3) sweep grid ----------------
cells = {};   % {label, alpha, offSym, quadK}
% base grid: CFO x timing at nominal quadrant 0
for a = [0 +alphaMax -alphaMax]
    for off = [0 +0.25 -0.25 +0.5 -0.5]
        cells{end+1} = {sprintf('CFO%+.3f off%+.2f q0', a, off), a, off, 0}; %#ok<SAGROW>
    end
end
% resolver worst case: ALL FOUR QUADRANTS at nonzero timing offset (+CFO)
for k = 0:3
    cells{end+1} = {sprintf('CFO%+.3f off+0.50 q%d', +alphaMax, k), +alphaMax, +0.5, k}; %#ok<SAGROW>
    cells{end+1} = {sprintf('CFO%+.3f off-0.50 q%d', -alphaMax, k), -alphaMax, -0.5, k}; %#ok<SAGROW>
end

T = 0.012;   % ~40 frames @ sps4 (frame = 4532 rail beats @15.36M = 295 us)
ovT = getenv('SWEEP_T'); if ~isempty(ovT), T = str2double(ovT); fprintf('DEBUG T=%g\n',T); end

results = cell(numel(cells),2);
allPass = true;
for ci = 1:numel(cells)
    c = cells{ci}; label=c{1}; a=c{2}; off=c{3}; k=c{4};
    assignin('base','sw_foffNorm', foff(a));
    assignin('base','sw_quadK',    double(k));
    assignin('base','sw_delay',    double(baseDelay + round(off*busPerSym)));
    set_param(h,'StopTime', num2str(T));
    so = sim(h);
    [ok, summ] = judge_cell(so, CAPG, T);
    results{ci,1}=label; results{ci,2}=summ;
    allPass = allPass && ok;
    fprintf('CELL %-28s -> %s | %s\n', label, ternary(ok,'PASS','FAIL'), summ);
end

% ---------------- (4) verdict ----------------
fid=fopen(fullfile(KITDIR,'SPS4_SYNC_SWEEP_K5.txt'),'w');
fprintf(fid,'============ sps=4 TIMING-RECOVERY / RESOLVER SWEEP ============\n');
fprintf(fid,'date: %s\nresult: %s\n', char(datetime('now')), ternary(allPass,'PASS','FAIL'));
fprintf(fid,'method: closed-loop model sim; DUT Tx(ROM) air -> Impair(CFO+quadrant+timing)\n');
fprintf(fid,'  -> external ADC (rx_input_select=1) -> DUT Rx; pass = cap_out golden + errors steady.\n');
fprintf(fid,'sps=4 changes exercised: SS Interpolation Control fi(0.25)/bitshift2, GTED far z-4/mid z-4,\n');
fprintf(fid,'  timing_hardening wlim 255/1024, resolver NATIVE look-back (LB=10*sps-40=0).\n');
fprintf(fid,'CFO max alpha=%.3f (frac of symbol rate); timing {0,+-0.25,+-0.5} sym = int bus-sample delays.\n', alphaMax);
fprintf(fid,'---- cells ----\n');
for ci=1:numel(cells)
    fprintf(fid,'%-28s : %s\n', results{ci,1}, results{ci,2});
end
fprintf(fid,'================================================================\n');
fclose(fid);
fprintf('WROTE SPS4_SYNC_SWEEP_K5.txt (%s)\n', ternary(allPass,'PASS','FAIL'));
assert(allPass, 'SPS4_SYNC_SWEEP_K5 FAILED (see SPS4_SYNC_SWEEP_K5.txt)');
diary off;
fprintf('SPS4_SYNC_SWEEP_K5_DONE PASS\n');

% ======================= local functions =======================
function h = build_sweep_harness(sys, loop)
h='sps4_sweep_harness';
if bdIsLoaded(h), close_system(h,0); end
new_system(h);
add_block([sys '/TxRxComposite'], [h '/DUT'], 'Position',[700 80 1050 980]);

% SIM-ONLY stubs (verbatim from sim_byte_gate_k5): BIST msgdec disp branch +
% RxAlign behavioral-Viterbi latency retune (41 -> 25).
cdb = [h '/DUT/Receiver/Capture Data Bits/MATLAB Function'];
ch = sfroot().find('-isa','Stateflow.EMChart','Path',cdb);
assert(~isempty(ch), 'Capture Data Bits chart not found in harness copy');
scr = ch(1).Script;
scr = regexprep(scr,'msgarray_dec = char\([^\n]*\n','');
scr = regexprep(scr,'N = length\(msgarray_dec\)[^\n]*\n','');
scr = regexprep(scr,'strAscii_dec = reshape\(msgarray_dec[^\n]*\n','');
scr = regexprep(scr,'msg = char\(bin2dec[^\n]*\n','');
scr = regexprep(scr,'\s*disp\(msg\);','');
ch(1).Script = scr;
ra = [h '/DUT/Receiver/QPSK Rx/FEC Decoder Wrapper/RxAlign'];
ch2 = sfroot().find('-isa','Stateflow.EMChart','Path',ra);
assert(~isempty(ch2), 'RxAlign chart not found in harness copy');
scr2 = ch2(1).Script;
assert(contains(scr2,'uint16(41)'), 'RxAlign +41 latency constant not found');
ch2(1).Script = strrep(scr2,'uint16(41)','uint16(25)');

% introspect composite port maps
im = containers.Map; om = containers.Map;
for b = reshape(find_system(loop,'SearchDepth',1,'BlockType','Inport'),1,[])
    im(get_param(b{1},'Name')) = struct('port',str2double(get_param(b{1},'Port')), ...
        'dt',get_param(b{1},'OutDataTypeStr'), 'st',get_param(b{1},'SampleTime'));
end
for b = reshape(find_system(loop,'SearchDepth',1,'BlockType','Outport'),1,[])
    om(get_param(b{1},'Name')) = str2double(get_param(b{1},'Port'));
end

% --- Impair block: DUT tx air -> impaired ADC I/Q (closed loop) ---
add_block('simulink/User-Defined Functions/MATLAB Function',[h '/Impair'],'Position',[300 120 400 200]);
imp = sfroot().find('-isa','Stateflow.EMChart','Path',[h '/Impair']);
imp.Script = sprintf([ ...
'function [aI, aQ] = impair(tI, tQ, foffNorm, quadK, delaySamps)\n' ...
'%%#codegen\n' ...
'persistent phase bufI bufQ idx\n' ...
'MAXD = int32(32);\n' ...
'if isempty(phase)\n' ...
'    phase = 0;\n' ...
'    bufI = zeros(double(MAXD)+1,1);\n' ...
'    bufQ = zeros(double(MAXD)+1,1);\n' ...
'    idx = int32(1);\n' ...
'end\n' ...
'bufI(idx) = double(tI); bufQ(idx) = double(tQ);\n' ...
'dl = int32(delaySamps); if dl < int32(1), dl = int32(1); end; if dl > MAXD, dl = MAXD; end\n' ...
'dsamp = mod(idx - int32(1) - dl, MAXD+int32(1)) + int32(1);\n' ...
'dI = bufI(dsamp); dQ = bufQ(dsamp);\n' ...
'th = phase + double(quadK)*(pi/2);\n' ...
'c = cos(th); s = sin(th);\n' ...
'aI = int16(max(-32768, min(32767, round(dI*c - dQ*s))));\n' ...
'aQ = int16(max(-32768, min(32767, round(dI*s + dQ*c))));\n' ...
'phase = phase + foffNorm;\n' ...
'if phase > pi, phase = phase - 2*pi; elseif phase < -pi, phase = phase + 2*pi; end\n' ...
'idx = idx + int32(1); if idx > MAXD+int32(1), idx = int32(1); end\n']);
% sweep parameters (base-ws constants, updated per cell)
add_block('built-in/Constant',[h '/c_foff'], 'Value','sw_foffNorm','OutDataTypeStr','double','Position',[120 210 160 230]);
add_block('built-in/Constant',[h '/c_quad'], 'Value','sw_quadK',   'OutDataTypeStr','double','Position',[120 250 160 270]);
add_block('built-in/Constant',[h '/c_delay'],'Value','sw_delay',   'OutDataTypeStr','double','Position',[120 290 160 310]);
% tx air taps -> Impair inputs 1,2
add_line(h, sprintf('DUT/%d', om('tx_dataOutI')), 'Impair/1', 'autorouting','on');
add_line(h, sprintf('DUT/%d', om('tx_dataOutQ')), 'Impair/2', 'autorouting','on');
add_line(h, 'c_foff/1',  'Impair/3', 'autorouting','on');
add_line(h, 'c_quad/1',  'Impair/4', 'autorouting','on');
add_line(h, 'c_delay/1', 'Impair/5', 'autorouting','on');
% impaired I/Q -> ADC inputs. adc_validIn is a 1-in-2 toggle @30.72M (the
% proven sim_byte_gate valid: recovers the 15.36e6 rail from the REP'd air).
% The I/Q are delayed relative to this free-running valid -> timing offset.
connect_in(h, im, 'adc_dataInI', 'Impair/1');
connect_in(h, im, 'adc_dataInQ', 'Impair/2');
add_block('simulink/User-Defined Functions/MATLAB Function',[h '/VGen'],'Position',[150 40 220 80]);
vg = sfroot().find('-isa','Stateflow.EMChart','Path',[h '/VGen']);
vg.Script = sprintf(['function v = vgen(tick)\npersistent p\nif isempty(p), p=false; end\n' ...
    'p = ~p;\nv = p && logical(tick);\n']);
add_block('built-in/Constant',[h '/Tick'],'Value','true','OutDataTypeStr','boolean', ...
    'SampleTime','1/30.72e6','Position',[60 40 100 60]);
add_line(h,'Tick/1','VGen/1');
connect_in(h, im, 'adc_validIn', 'VGen/1');

% --- external ADC path selected; ROM Tx source ---
special = {'adc_dataInI','adc_dataInQ','adc_validIn'};
drive_const(h, im, 'rx_input_select', 'true');    special{end+1}='rx_input_select';
drive_const(h, im, 'tx_data_source',  '0');       special{end+1}='tx_data_source';
% every remaining inport -> typed zero/false constant
for nm = im.keys
    if any(strcmp(nm{1}, special)), continue; end
    s = im(nm{1});
    if strcmpi(s.dt,'boolean'), val='false'; else val='0'; end
    drive_const(h, im, nm{1}, val);
end

% --- log BIST oracles; terminate the rest ---
ph = get_param([h '/DUT'],'PortHandles');
logNames = {'packets_out','bit_errors_out','cap_out'};
for k=1:numel(ph.Outport)
    nm = get_param(ph.Outport(k),'Name'); %#ok<NASGU>
    add_block('built-in/Terminator',sprintf('%s/T%d',h,k),'Position',[1150 60+25*k 1170 78+25*k]);
    add_line(h, sprintf('DUT/%d',k), sprintf('T%d/1',k), 'autorouting','on');
end
% (the tx_dataOut/validOut ports feed the Impair/adc lines above AND are also
%  terminated by the loop; a fan-out from an outport line is fine.)
for nm = logNames
    p = ph.Outport(om(nm{1}));
    set_param(p,'DataLogging','on','DataLoggingNameMode','Custom','DataLoggingName',nm{1});
end
set_param(h,'SolverType','Fixed-step','Solver','FixedStepDiscrete', ...
    'SignalLogging','on','SignalLoggingName','logsout','SaveFormat','Dataset');
end

function drive_const(h, im, name, val)
assert(im.isKey(name), 'composite inport %s missing', name);
s = im(name);
b = [h '/k_' name];
st = s.st; if isempty(st) || strcmp(strtrim(st),'-1'), st = 'inf'; end  % drive at the port's declared rate
add_block('built-in/Constant', b, 'Value', val, 'OutDataTypeStr', s.dt, ...
    'SampleTime', st, 'Position',[60 400+20*s.port 100 416+20*s.port]);
add_line(h, ['k_' name '/1'], sprintf('DUT/%d', s.port), 'autorouting','on');
end

function connect_in(h, im, name, srcSpec)
assert(im.isKey(name), 'composite inport %s missing', name);
add_line(h, srcSpec, sprintf('DUT/%d', im(name).port), 'autorouting','on');
end

function [ok, summary] = judge_cell(so, CAPG, T)
L = so.logsout;
els = cell(L.numElements,2);
for i=1:L.numElements, e=L{i}; els{i,1}=e.Name; els{i,2}=e.Values; end
capTs = pick(els,'cap_out'); errTs = pick(els,'bit_errors_out'); pkTs = pick(els,'packets_out');
cap = uint32(capTs.Data(end));
tLate = 0.60*T;
eLate = double(errTs.Data(find(errTs.Time<=tLate,1,'last')));
eEnd  = double(errTs.Data(end));
pkEnd = double(pkTs.Data(end));
ok = (cap==CAPG) && (eEnd==eLate) && (pkEnd>=8);
summary = sprintf('cap=0x%08X (gold 0x%08X) errs@60%%=%d end=%d pk=%d -> %s', ...
    cap, CAPG, eLate, eEnd, pkEnd, ternary(ok,'PASS','FAIL'));
end

function ts = pick(els, nm)
idx = find(strcmp(els(:,1), nm), 1);
assert(~isempty(idx), 'logged element %s missing', nm);
ts = els{idx,2};
assert(isa(ts,'timeseries'), 'log %s is %s, expected timeseries', nm, class(ts));
end

function s = ternary(c,a,b), if c, s=a; else, s=b; end, end
