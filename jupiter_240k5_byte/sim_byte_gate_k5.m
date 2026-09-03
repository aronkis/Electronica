% sim_byte_gate_k5.m -- MODEL-LEVEL byte-path oracle gate for the
% jupiter_240k5_byte kit (internal loopback, tx_data_source=1).
%
% Drives the composite's byte interface with the K5 golden info field
% ('ADI Hello World' 120 bits + the rng(9002) 964-bit PN pad =
% k5_240/golden_k5.mat info -- the SAME info content the pre-coded ROM
% encodes), packed byte-0-first/MSB-first-per-byte into 35 x uint64 words
% per frame (info in the first 1084 bits, zero fill after), through a
% handshake-reactive AXIS source.
%
% ORACLES (per the K.1 spec):
%  (a) AIR: the transmitted coded bitstream (QPSK modulator symbol stream,
%      logged inside the DUT copy) must be BIT-EXACT to
%      k5_240/rom_words_70_k5.txt frame-for-frame -- the strongest oracle
%      (catches encoder/interleaver/cadence/framing errors). The byte
%      branch has a structural ONE-FRAME latency (ping-pong interleaver),
%      so the gate requires: every frame from the first golden frame on is
%      golden, with the first golden frame arriving within the startup
%      allowance.
%  (b) BIST: cap_out == 0x04922282 (golden) and bit_errors STOPS increasing
%      (zero new errors over the steady-state window; early frames may
%      count errors from the encoder-warmup/alignment garbage frame).
%  (c) BYTE-RX: the byte_rx stream returns the SAME info bytes -- 16 x
%      uint64 words/frame (first 128 B = 1024 of the 1084 info bits;
%      trailing 60 discarded by contract, WORDS_PER_PACKET=16).
%
% RUNS:
%  A: word-ALIGNED stream (idx0=1), golden info      -- full oracles
%  B: ROTATED word phase (idx0=18), golden info      -- steady-state oracles
%     (the shifter must converge via the in-band first-word marker)
%  C: aligned, ALTERNATE PN pad (message kept, pad inverted) -- the MUX
%     DISCRIMINATOR: air must be bit-exact to host-encode(altInfo) and
%     NOT equal to the ROM frame (proves the air really comes from the
%     in-fabric encoder fed by the bytes, not a stuck-at-ROM BitMux);
%     BIST stays golden (message window unchanged); byte_rx returns the
%     ALT info bytes.
%  D: REGRESSION, tx_data_source=0 (ROM path) -- air == ROM from the first
%     full frame, BIST golden, byte_rx returns the info bytes too (the
%     serializer taps the decoded stream regardless of the Tx source).
%
% Also self-checks the host-side K5 contract first: gate->convenc(K=5
% [35 23])->interleave(136x16 perm r*16+c)->+64 ones == the ROM payload.
%
% Writes SIM_BYTE_GATE_K5.txt. Errors out on any gate failure.

KITDIR=fileparts(mfilename('fullpath'));
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
cd(KITDIR); addpath(KITDIR);   % kit LAST -> its params win

logf='sim_byte_gate_k5.log'; if exist(logf,'file'), delete(logf); end
diary(logf);
fprintf('=== sim_byte_gate_k5 %s ===\n', char(datetime('now')));

sys='commhdlQPSKTxRxLoopback'; loop=[sys '/TxRxComposite'];

% ---------------- (0) ensure the byte variant is assembled ----------------
need=true;
if exist(fullfile(KITDIR,'commhdlQPSKTxRxLoopback.slx'),'file')
    load_system(sys);
    d=get_param(sys,'Description');
    if contains(d,'jupiter_240k5_byte') && contains(d,'T8ratefix'), need=false; end
end
if need
    fprintf('model is not the assembled byte variant -- running assemble\n');
    run('assemble_jupiter_240k5_byte.m');
end
load_system(sys);
evalin('base', get_param(sys,'InitFcn'));

% ---------------- (1) goldens + host-side contract self-check -------------
G = load(fullfile(fileparts(KITDIR),'k5_240','golden_k5.mat'));
info    = double(G.info(:));  msgBitsG = double(G.msgBits(:));
CAPG    = uint32(G.capOut);
assert(numel(info)==1084 && isequal(info(1:120),msgBitsG) ...
    && CAPG==uint32(hex2dec('04922282')), 'golden_k5.mat sanity failed');
romLit = strtrim(fileread(fullfile(fileparts(KITDIR),'k5_240','rom_words_70_k5.txt')));
romW = eval(romLit); %#ok<EVLDIR>
rombits = unpack_words32(romW);                       % 2240x1 (0/1)
% PN9 filler (T8 fix 6bcaa62): golden payload tail; hard-reject a stale
% pre-PN9 golden/ROM pair (64-ones filler)
fillBits = double(G.payload(2177:2240));
assert(numel(fillBits)==64 && ~all(fillBits==1), 'STALE golden_k5.mat: filler is 64 ones (pre-6bcaa62)');
assert(isequal(rombits(2177:2240), fillBits(:)), 'ROM file vs golden_k5.mat filler mismatch');
encFrame = host_encode_k5(info, fillBits);
assert(isequal(encFrame(:), rombits(:)), ...
    'HOST-CONTRACT FAIL: host encode(info) != ROM payload');
fprintf('host K5 contract self-check OK (encode(info)+PN9 filler == ROM payload, 2240 bits)\n');
infoAlt = info; infoAlt(121:end) = 1 - infoAlt(121:end);   % message kept, pad inverted
encAlt = host_encode_k5(infoAlt, fillBits);
assert(~isequal(encAlt(:), rombits(:)), 'alt-pad frame degenerately equals ROM?!');
txWordsG   = pack_bits64([info;    zeros(2240-1084,1)]);   % 35x1 uint64
txWordsAlt = pack_bits64([infoAlt; zeros(2240-1084,1)]);
rxGoldG    = pack_bits64(info(1:1024));                    % 16x1 uint64
rxGoldAlt  = pack_bits64(infoAlt(1:1024));

% ---------------- (2) harness ----------------
h = build_harness_k5(sys, loop);
T = 0.030;   % ~50 frames (frame = 9064 rail beats @15.36M = 590 us, T8 rate fix)
% debug-only short-run override (plumbing shakeout; gates WILL fail short):
ovT = getenv('BYTEGATE_T');
if ~isempty(ovT), T = str2double(ovT); fprintf('DEBUG: T override = %g s\n', T); end

% ---------------- (3) runs + judgments ----------------
resA = run_case_k5(h, 'A aligned/golden ', txWordsG,   1, 1, T);
[okA, sumA] = judge_case(resA, rombits, rxGoldG,  CAPG, 3, 'A', rombits);
resB = run_case_k5(h, 'B rotated/golden ', txWordsG,  18, 1, T);
[okB, sumB] = judge_case(resB, rombits, rxGoldG,  CAPG, 8, 'B', rombits);
resC = run_case_k5(h, 'C aligned/ALTpad ', txWordsAlt, 1, 1, T);
[okC, sumC] = judge_case(resC, encAlt,  rxGoldAlt, CAPG, 3, 'C', rombits);
resD = run_case_k5(h, 'D ROM regression ', txWordsG,   1, 0, T);
[okD, sumD] = judge_case(resD, rombits, rxGoldG,  CAPG, 2, 'D', rombits);

allPass = okA && okB && okC && okD;
fid=fopen(fullfile(KITDIR,'SIM_BYTE_GATE_K5.txt'),'w');
fprintf(fid,'============ jupiter_240k5_byte MODEL-LEVEL BYTE GATE ============\n');
fprintf(fid,'date: %s\nresult: %s\n', char(datetime('now')), ternary(allPass,'PASS','FAIL'));
fprintf(fid,'oracles: (a) air bits vs k5 ROM words (modulator symbol log, pi/4-Gray\n');
fprintf(fid,'  inverse, 13-sym Barker frame find), (b) cap_out 0x04922282 + bit_errors\n');
fprintf(fid,'  steady, (c) byte_rx = 16x uint64 info words/frame (WPP=16).\n');
fprintf(fid,'run A (aligned, golden info): %s\n', sumA);
fprintf(fid,'run B (rotated idx0=18):      %s\n', sumB);
fprintf(fid,'run C (ALT pad discriminator):%s\n', sumC);
fprintf(fid,'run D (ROM path regression):  %s\n', sumD);
fprintf(fid,'byte-branch latency: air frame N carries encode(byte frame N-1) --\n');
fprintf(fid,'  ping-pong interleaver, structural one-frame pipeline (documented).\n');
fprintf(fid,'==================================================================\n');
fclose(fid);
fprintf('WROTE SIM_BYTE_GATE_K5.txt (%s)\n', ternary(allPass,'PASS','FAIL'));
assert(allPass, 'SIM_BYTE_GATE_K5 FAILED');
diary off;
fprintf('SIM_BYTE_GATE_K5_DONE PASS\n');

% ======================= local functions =======================
function h = build_harness_k5(sys, loop)
h='byte_harness_k5';
if bdIsLoaded(h), close_system(h,0); end
new_system(h);
add_block([sys '/TxRxComposite'], [h '/DUT'], 'Position',[700 80 1050 980]);
% SIM-ONLY: stub the disp-of-decoded-string branch in the BIST msgdec chart of
% the HARNESS COPY (UTF-8->UTF-16 codegen error on garbage bytes; the kit's
% proven workaround, verbatim from jupiter_240k5/build_rcv_harness.m). The
% BIST count/packets/errors math is preserved bit-exact; only the cosmetic
% char()/disp() of the decoded message is removed.
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
fprintf('harness: BIST msgdec disp-branch stubbed (sim-only, math preserved)\n');
% SIM-ONLY: RxAlign latency retune in the HARNESS COPY. The shipped model's
% '+41' is the NETLIST-measured gated-Viterbi latency in deintValid beats
% (RXROOT E8; lb_v6c netlist loopback reaches cap_out golden with it). The
% BEHAVIORAL comm Viterbi block leads the RTL pipeline by exactly 16 beats
% in model sim -- diagnosed from run A: cap_out read 0xA6120492 = the exact
% LSB-first pack of info bits 16..47 ('I',' ','H','e'), i.e. the decode was
% perfect but emission started 16 bits late. 41-16=25 aligns the model sim;
% the kit model keeps 41 (the netlist gate re-proves it on the real RTL).
ra = [h '/DUT/Receiver/QPSK Rx/FEC Decoder Wrapper/RxAlign'];
ch2 = sfroot().find('-isa','Stateflow.EMChart','Path',ra);
assert(~isempty(ch2), 'RxAlign chart not found in harness copy');
scr2 = ch2(1).Script;
assert(contains(scr2,'uint16(41)'), 'RxAlign +41 latency constant not found');
ch2(1).Script = strrep(scr2,'uint16(41)','uint16(25)');
fprintf('harness: RxAlign latency 41 -> 25 (sim-only; behavioral-Viterbi lead = 16 beats)\n');
% introspect the composite port maps (byte kit port numbers are dynamic)
im = containers.Map; om = containers.Map;
for b = reshape(find_system(loop,'SearchDepth',1,'BlockType','Inport'),1,[])
    im(get_param(b{1},'Name')) = struct('port',str2double(get_param(b{1},'Port')), ...
        'dt',get_param(b{1},'OutDataTypeStr'),'st',get_param(b{1},'SampleTime'));
end
for b = reshape(find_system(loop,'SearchDepth',1,'BlockType','Outport'),1,[])
    om(get_param(b{1},'Name')) = str2double(get_param(b{1},'Port'));
end
% --- adc_validIn: 1-in-2 toggle @30.72M (Tx pacing via DS_TxValid) ---
add_block('simulink/User-Defined Functions/MATLAB Function',[h '/VGen'],'Position',[150 80 220 120]);
vg = sfroot().find('-isa','Stateflow.EMChart','Path',[h '/VGen']);
vg.Script = sprintf(['function v = vgen(tick)\npersistent p\nif isempty(p), p=false; end\n' ...
    'p = ~p;\nv = p && logical(tick);\n']);
add_block('built-in/Constant',[h '/Tick'],'Value','true','OutDataTypeStr','boolean', ...
    'SampleTime','1/30.72e6','Position',[60 80 100 100]);
add_line(h,'Tick/1','VGen/1');
connect_in(h, im, 'adc_validIn', 'VGen/1');
% --- static drives ---
mkc = @(nm,dt,val,st) add_block('built-in/Constant',[h '/' nm],'Value',val, ...
    'OutDataTypeStr',dt,'SampleTime',st,'Position',[60 140+40*double(nm(end)) 100 160+40*double(nm(end))]);
mkc('c_adcI','int16','0','1/30.72e6');        connect_in(h, im, 'adc_dataInI','c_adcI/1');
mkc('c_adcQ','int16','0','1/30.72e6');        connect_in(h, im, 'adc_dataInQ','c_adcQ/1');
mkc('c_rstCS','boolean','false','1/15.36e6'); connect_in(h, im, 'rstCS','c_rstCS/1');
mkc('c_dbgmux','uint32','0','1/15.36e6');     connect_in(h, im, 'iq_debug_mux','c_dbgmux/1');
mkc('c_rxsel','boolean','false','1/15.36e6'); connect_in(h, im, 'rx_input_select','c_rxsel/1'); % INTERNAL
mkc('c_hostI','int16','0','1/30.72e6');       connect_in(h, im, 'host_txI','c_hostI/1');
mkc('c_hostQ','int16','0','1/30.72e6');       connect_in(h, im, 'host_txQ','c_hostQ/1');
mkc('c_hostV','boolean','true','1/30.72e6');  connect_in(h, im, 'host_txValid','c_hostV/1');
mkc('c_txsel','uint32','0','1/15.36e6');      connect_in(h, im, 'tx_source_select','c_txsel/1');
mkc('c_skip','uint32','0','1/15.36e6');       connect_in(h, im, 'skip_count','c_skip/1');
mkc('c_txds','uint32','txds_val','1/15.36e6');connect_in(h, im, 'tx_data_source','c_txds/1');
mkc('c_brr','boolean','true','1/30.72e6');    connect_in(h, im, 'byte_rx_ready','c_brr/1');
% --- handshake-reactive byte source (donor bytetx sim_byte_gate pattern) ---
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
% byte_ready feedback DUT -> ByteSrc
add_line(h, sprintf('DUT/%d', om('byte_ready')), 'ByteSrc/1', 'autorouting','on');
% --- terminate every other DUT outport; enable logging on the oracles ---
ph = get_param([h '/DUT'],'PortHandles');
logNames = {'packets_out','bit_errors_out','cap_out', ...
            'byte_rx_data','byte_rx_valid','byte_rx_last','byte_rx_user'};
for k=1:numel(ph.Outport)
    if k ~= om('byte_ready')
        tb = sprintf('%s/T%d',h,k);
        add_block('built-in/Terminator',tb,'Position',[1150 60+30*k 1170 80+30*k]);
        add_line(h, sprintf('DUT/%d',k), sprintf('T%d/1',k), 'autorouting','on');
    end
end
for nm = logNames
    p = ph.Outport(om(nm{1}));
    set_param(p,'DataLogging','on','DataLoggingNameMode','Custom','DataLoggingName',nm{1});
end
% --- log the QPSK modulator symbol stream inside the DUT copy (air oracle) ---
qtx = [h '/DUT/Transmitter/QPSK Tx'];
mods = find_system(qtx,'SearchDepth',1,'LookUnderMasks','all','FollowLinks','on', ...
    'Regexp','on','Name','.*Modulator.*');
assert(~isempty(mods), 'QPSK Modulator block not found under %s', qtx);
mph = get_param(mods{1},'PortHandles');
for k=1:numel(mph.Outport)
    set_param(mph.Outport(k),'DataLogging','on','DataLoggingNameMode','Custom', ...
        'DataLoggingName',sprintf('modTap%d',k));
end
fprintf('harness: modulator tap = %s (%d output ports logged)\n', ...
    strrep(mods{1},[h '/DUT/'],''), numel(mph.Outport));
set_param(h,'SolverType','Fixed-step','Solver','FixedStepDiscrete', ...
    'SignalLogging','on','SignalLoggingName','logsout','SaveFormat','Dataset');
end

function connect_in(h, im, name, srcSpec)
assert(im.isKey(name), 'composite inport %s missing', name);
add_line(h, srcSpec, sprintf('DUT/%d', im(name).port), 'autorouting','on');
end

function res = run_case_k5(h, label, words, idx0, txds, T)
assignin('base','byte_words', words(:));
assignin('base','byte_start_idx', uint32(idx0));
assignin('base','txds_val', uint32(txds));
set_param(h,'StopTime', num2str(T));
fprintf('--- RUN %s (idx0=%d txds=%d T=%gs) ---\n', label, idx0, txds, T);
so = sim(h);
L = so.logsout;
res.label = label; res.T = T;
% robust logsout access: iterate elements by name (Dataset.get can return
% Dataset/[] on odd matches; plain element iteration never does)
els = cell(L.numElements,2);
for i=1:L.numElements
    e = L{i};
    els{i,1} = e.Name;
    els{i,2} = e.Values;
end
fprintf('  logged elements: %s\n', strjoin(els(:,1).', ', '));
res.pkTs  = pick_ts(els,'packets_out');
res.errTs = pick_ts(els,'bit_errors_out');
res.capTs = pick_ts(els,'cap_out');
% modulator symbols: classify the logged modTap channels --
%   complex channel        -> constellation points
%   logical (or 0/1-only)  -> symbol valid
%   two real channels      -> I, Q in port order
mv=[]; pts=[]; reD={};
for k=1:8
    nm = sprintf('modTap%d',k);
    idx = find(strcmp(els(:,1),nm),1);
    if isempty(idx), continue; end
    v = els{idx,2};
    assert(isa(v,'timeseries'), 'log %s is a %s (bus?), expected timeseries', nm, class(v));
    d = v.Data;
    if ~isreal(d)
        pts = d;
    elseif islogical(d) || all(double(d(:))==0 | double(d(:))==1)
        mv = logical(d);
    else
        reD{end+1} = double(d); %#ok<AGROW>
    end
end
assert(~isempty(mv), 'modulator valid channel not identified');
if ~isempty(pts)
    res.sym = double(pts(mv));
else
    assert(numel(reD)>=2, 'modulator I/Q channels not identified');
    res.sym = complex(reD{1}(mv), reD{2}(mv));
end
% byte-rx accepted words (ready tied true -> one valid beat per word)
bv = logical(pick_ts(els,'byte_rx_valid').Data);
res.rxw = uint64(pick_ts(els,'byte_rx_data').Data(bv));
res.rxl = logical(pick_ts(els,'byte_rx_last').Data(bv));
res.rxu = logical(pick_ts(els,'byte_rx_user').Data(bv));
res.pk  = double(res.pkTs.Data(end));
res.err = double(res.errTs.Data(end));
res.cap = uint32(res.capTs.Data(end));
fprintf('%s: packets=%d errors=%d cap_out=0x%08X syms=%d rxwords=%d\n', ...
    strtrim(label), res.pk, res.err, res.cap, numel(res.sym), numel(res.rxw));
end

function ts = pick_ts(els, nm)
idx = find(strcmp(els(:,1), nm), 1);
assert(~isempty(idx), 'logged element %s missing', nm);
ts = els{idx,2};
assert(isa(ts,'timeseries'), 'log %s is a %s, expected timeseries', nm, class(ts));
end

function [ok, summary] = judge_case(res, refbits, rxGold, CAPG, startAllow, tag, rombits)
% (a) air oracle
[nFrames, firstGold, nGold, tailGold, frErr] = air_frames_k5(res.sym, refbits);
fprintf('[%s] air: %d full frames, firstGolden=%d, golden=%d, all-after-first-golden=%d, perFrameErr=%s\n', ...
    tag, nFrames, firstGold, nGold, tailGold, mat2str(frErr(1:min(end,30))));
gate_air = (nFrames >= 15) && ~isnan(firstGold) && (firstGold <= startAllow) ...
           && tailGold && (nGold >= 10);
% discriminator (run C): steady-state frames must NOT be the ROM frame
gate_disc = true;
if ~isequal(refbits(:), rombits(:))
    [~, fgR, ~, tailR] = air_frames_k5(res.sym, rombits);
    gate_disc = ~(tailR && ~isnan(fgR));   % ROM pattern must NOT match steady state
    fprintf('[%s] discriminator: steady air==ROM? %s (must be false)\n', tag, string(~gate_disc));
end
% (b) BIST
tLate = 0.70*res.T;
eLate = double(res.errTs.Data(find(res.errTs.Time<=tLate,1,'last')));
pLate = double(res.pkTs.Data(find(res.pkTs.Time<=tLate,1,'last')));
gate_bist = (res.cap == CAPG) && (res.err == eLate) && (res.pk >= pLate+4) && (res.pk >= 10);
fprintf('[%s] bist: cap=0x%08X (golden 0x%08X) errs@70%%=%d errs@end=%d pkts %d->%d -> %s\n', ...
    tag, res.cap, CAPG, eLate, res.err, pLate, res.pk, string(gate_bist));
% (c) byte-rx packets
gate_rx = false; npk = 0; rxdetail = 'no complete packets';
li = find(res.rxl);
if numel(li) >= 3
    pkts = {};
    for k=2:numel(li)
        seg = li(k-1)+1 : li(k);
        pkts{end+1} = seg; %#ok<AGROW>
    end
    npk = numel(pkts);
    ncheck = min(4, npk);
    okp = true;
    for k = npk-ncheck+1 : npk
        seg = pkts{k};
        wv = res.rxw(seg); uv = res.rxu(seg); lv = res.rxl(seg);
        okp = okp && numel(seg)==16 && isequal(wv(:), rxGold(:)) ...
             && uv(1) && ~any(uv(2:end)) && lv(end) && ~any(lv(1:end-1));
    end
    gate_rx = okp && npk >= 4;
    rxdetail = sprintf('%d complete packets, last %d checked', npk, ncheck);
end
fprintf('[%s] byte-rx: %s -> %s\n', tag, rxdetail, string(gate_rx));
ok = gate_air && gate_disc && gate_bist && gate_rx;
fprintf('[%s] RESULT: %s\n', tag, ternary(ok,'PASS','FAIL'));
summary = sprintf( ...
    'air(frames=%d firstGold=%d golden=%d tailGold=%d) bist(cap=%08X errsLate=%d pk=%d) rx(%s) => %s', ...
    nFrames, firstGold, nGold, tailGold, res.cap, res.err-eLate, res.pk, rxdetail, ternary(ok,'PASS','FAIL'));
end

function [nFrames, firstGold, nGold, tailGold, frErr] = air_frames_k5(sym, refbits)
% symbol stream -> quadrants -> Barker frame starts -> payload bits vs refbits
sI = real(sym)>0; sQ = imag(sym)>0;
q  = double(sI)*2 + double(sQ);
bark = logical([1 1 1 1 1 0 0 1 1 0 1 0 1]);
preQ = zeros(1,13); preQ(~bark) = 3;     % b=1 -> (-,-) q=0 ; b=0 -> (+,+) q=3
qr = q(:).'; n = numel(qr);
starts = [];
for i=1:n-12
    if isequal(qr(i:i+12), preQ), starts(end+1)=i; end %#ok<AGROW>
end
bitI = double(~sQ); bitQ = double(~sI);  % pi/4-Gray inverse (s1_analyze convention)
nFrames=0; frErr=[];
for i=1:numel(starts)
    s0 = starts(i);
    if s0+13+1120-1 > n, break; end
    idx = s0+13 : s0+13+1120-1;
    bits = reshape([bitI(idx) bitQ(idx)].',[],1);
    frErr(end+1) = sum(bits(:) ~= refbits(:)); %#ok<AGROW>
    nFrames = nFrames+1;
end
gold = (frErr==0);
firstGold = NaN; nGold = sum(gold); tailGold = false;
fi_ = find(gold,1);
if ~isempty(fi_)
    firstGold = fi_;
    tailGold = all(gold(fi_:end));
end
end

function w = pack_bits64(bits)
% byte-0-first, MSB-first per byte; word = LSB byte first (qpskByteBitShifter
% inverse / ByteDmaRegisters.pack convention). Zero-pads to a word multiple.
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

function bits = unpack_words32(words)
% ROM packing inverse: word w = bits[32w..32w+31], MSB-first
bits = zeros(32*numel(words),1);
for w2=0:numel(words)-1
    for bb=0:31
        bits(w2*32+bb+1) = double(bitget(uint32(words(w2+1)), 32-bb));
    end
end
end

function payload = host_encode_k5(infoVec, fillBits)
% The K5 on-air contract (k5_240/packet_k5.m STEP B, host reference):
% [info; 4 zero tail] -> convenc(poly2trellis(5,[35 23])) -> 2176 -> legacy
% interleave (perm r*16+c over ROWS=136) -> + 64-bit PN9 filler (T8 fix
% 6bcaa62; passed in from golden_k5.mat payload tail) -> 2240.
trellis = poly2trellis(5,[35 23]);
encIn = [infoVec(:); zeros(4,1)];
coded = convenc(encIn, trellis); assert(numel(coded)==2176);
ROWS=136; COLS=16; CODED=2176;
il = zeros(CODED,1);
for beat=0:CODED-1
    r = mod(beat,ROWS); c = floor(beat/ROWS); perm = r*COLS+c;
    if perm < CODED, il(beat+1) = coded(perm+1); end
end
payload = [il; fillBits(:)];
end

function s = ternary(c,a,b)
if c, s=a; else, s=b; end
end
