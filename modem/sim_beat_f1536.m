% sim_beat_f1536.m -- LONG-DWELL beat-hunt run for the ~120 s periodic
% error-burst beat observed on silicon (two boards, deterministic).
%
% SILICON INVARIANT (in FRAMES, not seconds): burst beat every ~149,100
% f1536 frames (119.75 s at the 803.2 us silicon frame period), burst
% duration ~6200-10000 frames, sizes quantized in two alternating species
% (~293.2k / ~215.0k errors), quiet floor ~0.05 err/frame, first burst at
% arm + ~190,500 frames. Target dwell: >= 1.5x period = 223,700 frames.
%
% MODEL: modem commhdlQPSKTxRxLoopback (byte variant, assembled
% for f1536; run-D config = tx_data_source=0 ROM path, digital loopback --
% the exact source config the silicon beat was observed with). Harness is
% the sim_byte_gate_k5 build (verbatim chart stubs / RxAlign retune) MINUS
% the full-rate modulator/byte-rx logging (which would be hundreds of GB at
% this dwell), PLUS:
%   * decimated logging (~4 samples/frame) of the cumulative counters:
%     bit_errors_out, packets_out (+ cap_out cheap sanity),
%   * a syncPulse cumulative counter tapped inside the DUT copy at
%     Frequency and Time Synchronizer/Packet Controller (silicon framesync
%     counted ~1256/s vs structural 1245 -- ~11 extra pulses/s),
%   * the Data Bits FIFO sim-only Assertion/Assertion1 DISABLED in the
%     harness copy (they would halt a long run; silicon has no assertion)
%     and replaced with cumulative violation-beat counters (candidate beat
%     mechanism: Data_Bits_FIFO "count to 12332" vs End_Generator
%     "count to 12319", delta 13).
%
% PLAN: (1) calibration leg ~200 frames with tic/toc in the fastest sim
% mode that works (rapid -> accelerator -> normal); (2) extrapolate; full
% 223,700-frame run if <= 20 h wall, else the longest useful prefix that
% fits ~12 h; (3) per-frame CSV + .mat under beat_run/; (4) burst analysis
% + verdict appended to the log and BEAT_RESULT_f1536.txt.
%
% Launch detached:
%   QPSK_FRAME=f1536 QPSK_SPS=4 matlab -batch "run('sim_beat_f1536.m')"

KITDIR = fileparts(mfilename('fullpath'));
setenv('QPSK_FRAME','f1536'); setenv('QPSK_SPS','4');   % match assembled variant
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
cd(KITDIR); addpath(KITDIR);
cfg = frame_config_k5();
assert(strcmp(cfg.Frame,'f1536'), 'cfg is not f1536');

outdir = fullfile(KITDIR,'beat_run');
if ~exist(outdir,'dir'), mkdir(outdir); end
logf = fullfile(outdir,'sim_beat_f1536.log');
diary(logf);
fprintf('=== sim_beat_f1536 %s ===\n', char(datetime('now')));

sys  = 'commhdlQPSKTxRxLoopback';
loop = [sys '/TxRxComposite'];
load_system(sys);
d = get_param(sys,'Description');
assert(contains(d,['frame=' cfg.Frame]) && contains(d,sprintf('sps%d/',cfg.Sps)), ...
    'model .slx is not the assembled f1536/sps%d byte variant: %s', cfg.Sps, d);
set_param(0,'CurrentSystem',sys);
evalin('base', get_param(sys,'InitFcn'));

framePeriod = (13 + cfg.PayloadBits/2) * cfg.Sps / 15.36e6;   % rail beats / 15.36e6
BEAT_FRAMES   = 149100;                 % silicon beat period, frames
TARGET_FRAMES = 223700;                 % 1.5x beat period
FIRST_BURST_F = 190500;                 % silicon first burst, frames after arm
fprintf('framePeriod = %.4f ms; target %d frames = %.1f s model time\n', ...
    framePeriod*1e3, TARGET_FRAMES, TARGET_FRAMES*framePeriod);

% ---- byte-source words (run-D drive: golden info; txds=0 -> ROM on air) ----
G = load(fullfile(fileparts(KITDIR),'contract',sprintf('golden_%s.mat',cfg.Frame)));
info = double(G.info(:));
txWordsG = pack_bits64([info; zeros(cfg.PayloadBits-cfg.InfoBits,1)]);

% ---------------- harness ----------------
h = build_beat_harness(sys, loop, cfg);

assignin('base','byte_words', txWordsG(:));
assignin('base','byte_start_idx', uint32(1));
assignin('base','txds_val', uint32(0));            % ROM path (run D / silicon config)

% ---------------- (1) calibration ----------------
CAL_FRAMES = 200;
Tcal = CAL_FRAMES * framePeriod;
modes = {'rapid','accelerator','normal'};
mode = ''; calWall = NaN;
% BEAT_FPS: skip the ~46-min timed calibration when the rate is already known
% (measured 2026-08-18: rapid mode 200 frames / 2780 s = 0.0719 f/s)
ovFps = getenv('BEAT_FPS');
if ~isempty(ovFps)
    mode = 'rapid'; set_param(h,'SimulationMode',mode);
    calWall = CAL_FRAMES / str2double(ovFps);
    fprintf('BEAT_FPS override: %s f/s (calibration skipped, mode=rapid)\n', ovFps);
end
if isempty(mode)
for m = modes
    try
        set_param(h,'SimulationMode',m{1});
        fprintf('--- calibration attempt: %s mode ---\n', m{1});
        % warmup (build/JIT) -- short, untimed
        set_param(h,'StopTime', num2str(5*framePeriod));
        so = sim(h);
        assert(~isempty(so.logsout) && so.logsout.numElements >= 3, 'warmup produced no logs');
        % timed leg
        set_param(h,'StopTime', num2str(Tcal));
        t0 = tic; so = sim(h); calWall = toc(t0);
        L = so.logsout;
        fprintf('calibration OK in %s mode: %d frames in %.1f s wall = %.2f frames/s\n', ...
            m{1}, CAL_FRAMES, calWall, CAL_FRAMES/calWall);
        fprintf('  logged: %s\n', strjoin(arrayfun(@(i) L{i}.Name, 1:L.numElements,'UniformOutput',false),', '));
        for i=1:L.numElements
            e=L{i}; fprintf('  cal end value %-16s = %g (%d samples)\n', e.Name, double(e.Values.Data(end)), numel(e.Values.Data));
        end
        mode = m{1};
        break
    catch ME
        fprintf('mode %s FAILED: %s\n', m{1}, ME.message);
    end
end
end
assert(~isempty(mode), 'no simulation mode worked');
fps = CAL_FRAMES / calWall;

% ---------------- (2) extrapolate + choose dwell ----------------
fullWallH = TARGET_FRAMES / fps / 3600;
fprintf('PROJECTION: %d frames at %.2f frames/s = %.1f h wall\n', TARGET_FRAMES, fps, fullWallH);
if fullWallH <= 20
    runFrames = TARGET_FRAMES;
    fprintf('DECISION: full 1.5x-beat run (%d frames), ETA %.1f h\n', runFrames, fullWallH);
else
    runFrames = min(TARGET_FRAMES, floor(fps*12*3600));
    fprintf('DECISION: >20 h projected -- longest useful ~12 h prefix = %d frames (%.2fx beat period; first-burst frame %d %s reach)\n', ...
        runFrames, runFrames/BEAT_FRAMES, FIRST_BURST_F, ternary(runFrames>=FIRST_BURST_F,'WITHIN','OUT OF'));
end
Trun = runFrames * framePeriod;
fprintf('launching dwell: StopTime=%.3f s (%d frames), mode=%s, ETA %s\n', ...
    Trun, runFrames, mode, char(datetime('now')+seconds(runFrames/fps)));
if ~isempty(getenv('BEAT_CAL_ONLY'))
    fprintf('BEAT_CAL_ONLY set -- stopping after calibration/projection\n');
    fprintf('SIM_BEAT_F1536_CAL_DONE mode=%s fps=%.2f projH=%.2f runFrames=%d\n', mode, fps, fullWallH, runFrames);
    diary off; return
end

% ---------------- (3) the dwell ----------------
set_param(h,'StopTime', num2str(Trun));
t0 = tic; so = sim(h); dwellWall = toc(t0);
fprintf('dwell DONE: %.1f s wall (%.2f frames/s)\n', dwellWall, runFrames/dwellWall);
L = so.logsout;

% ---------------- (4) per-frame resample + save ----------------
getts = @(nm) local_get(L, nm);
errTs = getts('bit_errors_out'); pkTs = getts('packets_out');
snTs  = getts('sync_count');     ovTs = getts('fifo_ov_viol');
unTs  = getts('fifo_un_viol');   capTs= getts('cap_out');
fb = (1:runFrames)' * framePeriod;                    % frame-boundary times
prev = @(ts) interp1([-1; ts.Time(:); 1e12], [0; double(ts.Data(:)); double(ts.Data(end))], fb, 'previous');
cumErr = prev(errTs); cumPk = prev(pkTs); cumSn = prev(snTs);
cumOv = prev(ovTs); cumUn = prev(unTs);
Tt = table((1:runFrames)', cumErr, cumSn, cumPk, cumOv, cumUn, ...
    'VariableNames', {'frame','cum_bit_errors','cum_sync','cum_packets','cum_fifo_ov_beats','cum_fifo_un_beats'});
csvf = fullfile(outdir,'beat_perframe_f1536.csv');
writetable(Tt, csvf);
save(fullfile(outdir,'beat_run_f1536.mat'), 'errTs','pkTs','snTs','ovTs','unTs','capTs', ...
    'framePeriod','runFrames','mode','fps','calWall','dwellWall','-v7.3');
fprintf('wrote %s (+ .mat)\n', csvf);

% ---------------- (5) analysis + verdict ----------------
dErr = diff([0; cumErr]);                              % per-frame error delta
floorMask = dErr <= 5;                                 % quiet-floor frames
floorRate = mean(dErr(floorMask));
inBurst = dErr > 100;                                  % burst frames (silicon burst ~30-47 err/frame sustained; model may differ)
if ~any(inBurst), inBurst = dErr > 20; end             % relaxed fallback
bs = find(diff([0; inBurst])==1); be = find(diff([inBurst; 0])==-1);
% merge bursts separated by <2000 frames
k=1;
while k < numel(bs)
    if bs(k+1)-be(k) < 2000, be(k)=be(k+1); bs(k+1)=[]; be(k+1)=[]; else, k=k+1; end
end
fprintf('\n===== BEAT ANALYSIS =====\n');
fprintf('frames simulated: %d (%.2fx silicon beat period %d)\n', runFrames, runFrames/BEAT_FRAMES, BEAT_FRAMES);
fprintf('total bit errors: %d; quiet-floor rate: %.4f err/frame (silicon ~0.05)\n', cumErr(end), floorRate);
fprintf('sync pulses: %d over %d frames = %.4f/frame (silicon ~1.0088: 1256/1245)\n', cumSn(end), runFrames, cumSn(end)/runFrames);
fprintf('packets: %d; FIFO ov viol beats: %d; un viol beats: %d\n', cumPk(end), cumOv(end), cumUn(end));
nB = numel(bs);
fprintf('bursts detected: %d\n', nB);
for k=1:nB
    sz = cumErr(be(k)) - cumErr(max(bs(k)-1,1));
    fprintf('  burst %d: frames %d..%d (dur %d), size %.1fk errors\n', k, bs(k), be(k), be(k)-bs(k)+1, sz/1e3);
end
if nB >= 2
    iv = diff(bs);
    fprintf('burst intervals (frames): %s (silicon %d)\n', mat2str(iv(:)'), BEAT_FRAMES);
end
% verdict
covOK = runFrames >= 1.5*BEAT_FRAMES;
if nB >= 2 && any(abs(diff(bs) - BEAT_FRAMES) < 0.15*BEAT_FRAMES)
    verdict = 'REPRODUCED';
elseif nB >= 1 && ~covOK
    verdict = 'PREFIX-INCONCLUSIVE';
elseif covOK
    verdict = 'NOT-REPRODUCED';
else
    verdict = 'PREFIX-INCONCLUSIVE';
end
fprintf('VERDICT: %s\n', verdict);
fid = fopen(fullfile(outdir,'BEAT_RESULT_f1536.txt'),'w');
fprintf(fid,'sim_beat_f1536 %s\nmode=%s calRate=%.2f f/s dwell=%d frames (%.2fx beat) wall=%.1f s\n', ...
    char(datetime('now')), mode, fps, runFrames, runFrames/BEAT_FRAMES, dwellWall);
fprintf(fid,'totalErr=%d floor=%.4f/frame sync/frame=%.4f bursts=%d\nVERDICT: %s\n', ...
    cumErr(end), floorRate, cumSn(end)/runFrames, nB, verdict);
fclose(fid);
fprintf('SIM_BEAT_F1536_DONE %s\n', verdict);
diary off;

% ======================= local functions =======================
function h = build_beat_harness(sys, loop, cfg)
h='beat_harness_f1536';
if bdIsLoaded(h), close_system(h,0); end
new_system(h);
add_block([sys '/TxRxComposite'], [h '/DUT'], 'Position',[700 80 1050 980]);
% --- verbatim sim_byte_gate_k5 chart stubs (BIST msgdec disp; RxAlign 41->25) ---
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
fprintf('harness: gate chart stubs applied (msgdec disp; RxAlign 41->25)\n');
% --- DISABLE the Data Bits FIFO sim-only assertions; tap violation counters ---
fifoNoHdl = [h '/DUT/Transmitter/QPSK Tx/Bit Packetizer/Data Bits FIFO/No HDL/No HDL'];
anames = {'Assertion','fifo_ov_viol'; 'Assertion1','fifo_un_viol'};
for k=1:size(anames,1)
    ab = [fifoNoHdl '/' anames{k,1}];
    set_param(ab,'Enabled','off');
    lh = get_param(ab,'LineHandles');
    srcPh = get_param(lh.Inport(1),'SrcPortHandle');
    cb = [fifoNoHdl '/BeatCnt' num2str(k)];
    add_block('simulink/User-Defined Functions/MATLAB Function', cb, ...
        'Position',[900 300+120*k 980 360+120*k]);
    cc = sfroot().find('-isa','Stateflow.EMChart','Path',cb);
    cc.Script = sprintf(['function c = cnt(p)\npersistent n\nif isempty(n), n = uint32(0); end\n' ...
        'if ~p\n    n = n + uint32(1);\nend\nc = n;\n']);   % Assertion fires on FALSE input
    cph = get_param(cb,'PortHandles');
    add_line(fifoNoHdl, srcPh, cph.Inport(1), 'autorouting','on');
    set_param(cph.Outport(1),'DataLogging','on','DataLoggingNameMode','Custom', ...
        'DataLoggingName',anames{k,2}, ...
        'DataLoggingDecimateData','on','DataLoggingDecimation','12333');
    fprintf('harness: %s disabled; violation-beat counter logged as %s\n', anames{k,1}, anames{k,2});
end
% --- syncPulse cumulative counter (Packet Controller output feed) ---
pc = [h '/DUT/Receiver/QPSK Rx/Frequency and Time Synchronizer/Packet Controller'];
spOut = [pc '/syncPulse'];
bt = get_param(spOut,'BlockType');
if strcmp(bt,'Outport')
    lh = get_param(spOut,'LineHandles');
    srcPh = get_param(lh.Inport(1),'SrcPortHandle');
elseif strcmp(bt,'Inport')
    % Inport block: its output port IS the sync pulse signal inside pc
    php = get_param(spOut,'PortHandles');
    srcPh = php.Outport(1);
else
    error('Packet Controller/syncPulse has unexpected BlockType %s', bt);
end
scb = [pc '/BeatSyncCnt'];
add_block('simulink/User-Defined Functions/MATLAB Function', scb, 'Position',[900 600 980 660]);
sc = sfroot().find('-isa','Stateflow.EMChart','Path',scb);
sc.Script = sprintf(['function c = cnt(p)\npersistent n\nif isempty(n), n = uint32(0); end\n' ...
    'if p\n    n = n + uint32(1);\nend\nc = n;\n']);
sph = get_param(scb,'PortHandles');
add_line(pc, srcPh, sph.Inport(1), 'autorouting','on');
set_param(sph.Outport(1),'DataLogging','on','DataLoggingNameMode','Custom', ...
    'DataLoggingName','sync_count', ...
    'DataLoggingDecimateData','on','DataLoggingDecimation','12333');
fprintf('harness: syncPulse cumulative counter logged as sync_count\n');
% --- introspect composite port maps ---
im = containers.Map; om = containers.Map;
for b = reshape(find_system(loop,'SearchDepth',1,'BlockType','Inport'),1,[])
    im(get_param(b{1},'Name')) = struct('port',str2double(get_param(b{1},'Port')));
end
for b = reshape(find_system(loop,'SearchDepth',1,'BlockType','Outport'),1,[])
    om(get_param(b{1},'Name')) = str2double(get_param(b{1},'Port'));
end
% --- adc_validIn: 1-in-2 toggle @30.72M ---
add_block('simulink/User-Defined Functions/MATLAB Function',[h '/VGen'],'Position',[150 80 220 120]);
vg = sfroot().find('-isa','Stateflow.EMChart','Path',[h '/VGen']);
vg.Script = sprintf(['function v = vgen(tick)\npersistent p\nif isempty(p), p=false; end\n' ...
    'p = ~p;\nv = p && logical(tick);\n']);
add_block('built-in/Constant',[h '/Tick'],'Value','true','OutDataTypeStr','boolean', ...
    'SampleTime','1/30.72e6','Position',[60 80 100 100]);
add_line(h,'Tick/1','VGen/1');
connect_in(h, im, 'adc_validIn', 'VGen/1');
% --- static drives (verbatim gate values) ---
mkc = @(nm,dt,val,st) add_block('built-in/Constant',[h '/' nm],'Value',val, ...
    'OutDataTypeStr',dt,'SampleTime',st,'Position',[60 140+40*double(nm(end)) 100 160+40*double(nm(end))]);
mkc('c_adcI','int16','0','1/30.72e6');        connect_in(h, im, 'adc_dataInI','c_adcI/1');
mkc('c_adcQ','int16','0','1/30.72e6');        connect_in(h, im, 'adc_dataInQ','c_adcQ/1');
mkc('c_rstCS','boolean','false','1/15.36e6'); connect_in(h, im, 'rstCS','c_rstCS/1');
mkc('c_dbgmux','uint32','0','1/15.36e6');     connect_in(h, im, 'iq_debug_mux','c_dbgmux/1');
mkc('c_rxsel','boolean','false','1/15.36e6'); connect_in(h, im, 'rx_input_select','c_rxsel/1'); % INTERNAL loopback
mkc('c_hostI','int16','0','1/30.72e6');       connect_in(h, im, 'host_txI','c_hostI/1');
mkc('c_hostQ','int16','0','1/30.72e6');       connect_in(h, im, 'host_txQ','c_hostQ/1');
mkc('c_hostV','boolean','true','1/30.72e6');  connect_in(h, im, 'host_txValid','c_hostV/1');
mkc('c_txsel','uint32','0','1/15.36e6');      connect_in(h, im, 'tx_source_select','c_txsel/1');
mkc('c_skip','uint32','0','1/15.36e6');       connect_in(h, im, 'skip_count','c_skip/1');
mkc('c_txds','uint32','txds_val','1/15.36e6');connect_in(h, im, 'tx_data_source','c_txds/1');
mkc('c_brr','boolean','true','1/30.72e6');    connect_in(h, im, 'byte_rx_ready','c_brr/1');
% --- handshake-reactive byte source (gate pattern; f1536 skid-lag delay) ---
add_block('simulink/User-Defined Functions/MATLAB Function',[h '/ByteSrc'],'Position',[150 470 230 530]);
bs = sfroot().find('-isa','Stateflow.EMChart','Path',[h '/ByteSrc']);
bs.Script = sprintf([ ...
'function [data, valid, first] = src(ready, words, idx0)\n' ...
'persistent idx\n' ...
'if isempty(idx), idx = uint32(idx0); end\n' ...
'data = words(idx);\n' ...
'valid = true;\n' ...
'first = (idx == uint32(1));\n' ...
'if ready\n' ...
'    idx = idx + 1;\n' ...
'    if idx > uint32(numel(words)), idx = uint32(1); end\n' ...
'end\n']);
add_block('built-in/Constant',[h '/WordsConst'],'Value','byte_words', ...
    'OutDataTypeStr','uint64','Position',[60 540 100 560]);
add_block('built-in/Constant',[h '/StartIdxConst'],'Value','byte_start_idx', ...
    'OutDataTypeStr','uint32','Position',[60 580 100 600]);
add_line(h,'WordsConst/1','ByteSrc/2');
add_line(h,'StartIdxConst/1','ByteSrc/3');
connect_in(h, im, 'byte_data',  'ByteSrc/1');
connect_in(h, im, 'byte_valid', 'ByteSrc/2');
connect_in(h, im, 'byte_first', 'ByteSrc/3');
if strcmp(cfg.Frame,'f1536')
    add_block('built-in/Delay', [h '/SkidLagDly'], ...
        'DelayLength', num2str(qpskByteSkidLag()), 'Position',[110 470 140 490]);
    add_line(h, sprintf('DUT/%d', om('byte_ready')), 'SkidLagDly/1', 'autorouting','on');
    add_line(h, 'SkidLagDly/1', 'ByteSrc/1', 'autorouting','on');
else
    add_line(h, sprintf('DUT/%d', om('byte_ready')), 'ByteSrc/1', 'autorouting','on');
end
% --- terminate all DUT outports; DECIMATED logging on the counters only ---
ph = get_param([h '/DUT'],'PortHandles');
logNames = {'bit_errors_out','packets_out','cap_out'};
for k=1:numel(ph.Outport)
    if k ~= om('byte_ready')
        tb = sprintf('%s/T%d',h,k);
        add_block('built-in/Terminator',tb,'Position',[1150 60+30*k 1170 80+30*k]);
        add_line(h, sprintf('DUT/%d',k), sprintf('T%d/1',k), 'autorouting','on');
    end
end
for nm = logNames
    p = ph.Outport(om(nm{1}));
    set_param(p,'DataLogging','on','DataLoggingNameMode','Custom','DataLoggingName',nm{1}, ...
        'DataLoggingDecimateData','on','DataLoggingDecimation','12333');
end
set_param(h,'SolverType','Fixed-step','Solver','FixedStepDiscrete', ...
    'SignalLogging','on','SignalLoggingName','logsout','SaveFormat','Dataset');
fprintf('harness built: decimated logging (~4 samples/frame) on %s + sync_count + FIFO viol counters\n', ...
    strjoin(logNames,', '));
end

function connect_in(h, im, name, srcSpec)
assert(im.isKey(name), 'composite inport %s missing', name);
add_line(h, srcSpec, sprintf('DUT/%d', im(name).port), 'autorouting','on');
end

function ts = local_get(L, nm)
ts = [];
for i=1:L.numElements
    if strcmp(L{i}.Name, nm), ts = L{i}.Values; return; end
end
error('logged element %s missing', nm);
end

function w = pack_bits64(bits)
n = ceil(numel(bits)/64)*64;
b = zeros(n,1); b(1:numel(bits)) = double(bits(:));
B = reshape(b,8,[]).';
bytes = uint64(B * (2.^(7:-1:0)).');
nw = n/64; w = zeros(nw,1,'uint64');
for k=1:nw
    v = uint64(0);
    for j=0:7, v = bitor(v, bitshift(bytes((k-1)*8+j+1), 8*j)); end
    w(k) = v;
end
end

function s = ternary(c,a,b)
if c, s=a; else, s=b; end
end
