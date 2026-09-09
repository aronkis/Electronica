% loop_gain_poke_test_k5.m -- GATE 3 for Task C3 (runtime loop-gain AXI regs).
%
% Proves the loop_gain_axi_overlay mux paths are LIVE (not synthesized/optimized
% away) and, for the clean fixed-point gains, that the stored-integer reinterpret
% is fi-EXACT. Standalone harness (does NOT edit sim_byte_gate_k5.m); mirrors that
% gate's DUT drives but wires all 6 loop-gain composite inports to base-workspace
% Constants so any register can be poked without rebuilding.
%
% Covers all THREE structural kinds so a wrong fraction length / wiring bug in
% any mux is caught (not just cs_prop_gain):
%   cs_prop_gain  (clean ufix16 gain) : P0=0, P1=SI(G), P2=SI(2G)
%   ss_prop_gain  (clean sfix24 gain) : P0=0, P1=SI(G), P2=SI(2G)
%   agc_loop_gain (double-param gain) : P0=0,          P2=SI(2G)   [no P1: chosen fi]
%   cfo_threshold (compare, not mul)  : P0=0,          P2=SI(2G)   [no P1: compare]
% Sub-case semantics:
%   P0 reg=0            -> compiled default; cap_out must be golden.
%   P1 reg=SI(G)        -> mux TRUE path at the compiled constant; cap_out must be
%                          BYTE-IDENTICAL to P0 (reinterpret fi-exact + reaches
%                          datapath). Asserted only for clean-fi gains.
%   P2 reg=SI(2G)       -> detuned loop must STILL LOCK (air frames decode).
%
% Requires the model assembled with QPSK_LEAN=1 + QPSK_LOOP_GAIN_AXI=1 (the
% loop-gain inports exist). One MATLAB -batch at a time (share host with A2).

function loop_gain_poke_test_k5()
KITDIR = fileparts(mfilename('fullpath'));
assert(strcmp(pwd, KITDIR), 'run from %s (pwd=%s)', KITDIR, pwd);
addpath(KITDIR);
sys='commhdlQPSKTxRxLoopback'; loop=[sys '/TxRxComposite'];
cfg = frame_config_k5();
ALLREGS = {'cs_prop_gain','cs_integ_gain','ss_prop_gain','ss_integ_gain','agc_loop_gain','cfo_threshold'};

% which registers to exercise: {name, checkP1, checkP2}. P0(reg=0) is NOT re-run
% here -- zero-default bit-identity is proven by the gate-2 sim_byte_gate all-zero
% run; P1 compares directly to the golden constant CAPG. Coverage spans all three
% structural kinds and both native-fi fraction lengths (ufix16 CS, sfix24 SS):
%   cs_prop (clean ufix16): P1 fi-exact (cap==golden) + P2 tunable(locks)
%   ss_prop (clean sfix24): P1 fi-exact (cap==golden)
%   agc     (double param): P2 tunable(locks)
%   cfo     (compare)     : P2 tunable(locks)
SPECS = { 'cs_prop_gain', true,  true; ...
          'ss_prop_gain', true,  false; ...
          'agc_loop_gain', false, true; ...
          'cfo_threshold', false, true };
ov = getenv('POKE_REG');
if ~isempty(ov)
    isClean = ismember(ov,{'cs_prop_gain','cs_integ_gain','ss_prop_gain','ss_integ_gain'});
    SPECS = { ov, isClean, true };
end

% ---- ensure assembled with the overlay (LEAN + loop-gain) ----
need = true;
if exist(fullfile(KITDIR,'commhdlQPSKTxRxLoopback.slx'),'file')
    load_system(sys);
    if ~isempty(find_system(loop,'SearchDepth',1,'BlockType','Inport','Name','cs_prop_gain')), need=false; end
end
if need
    fprintf('poke: loop-gain inports absent -- assembling LEAN + loop-gain\n');
    setenv('QPSK_LEAN','1'); setenv('QPSK_LOOP_GAIN_AXI','1');
    run('assemble_jupiter_240k5_byte.m'); load_system(sys);
end
for r = ALLREGS
    assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Inport','Name',r{1})), ...
        'poke: loop-gain inport %s missing after assemble', r{1});
end
evalin('base', get_param(sys,'InitFcn'));

% ---- per-register stored-integer references (stashed by the overlay on the
%      TxRxComposite block's UserData) ----
ud = get_param(loop,'UserData');
assert(isstruct(ud) && isfield(ud,'loopGainAxi'), 'poke: TxRxComposite UserData.loopGainAxi missing');

% ---- golden vectors ----
G = load(fullfile(fileparts(KITDIR),'k5_240','golden_k5.mat'));
info = double(G.info(:)); CAPG = uint32(G.capOut);
rombits = unpack_words32(eval(strtrim(fileread(fullfile(fileparts(KITDIR),'k5_240','rom_words_70_k5.txt')))));
txWordsG = pack_bits64([info; zeros(cfg.PayloadBits-cfg.InfoBits,1)]);

% ---- harness (all 6 loop-gain inports driven by base vars pv_<name>) ----
h = build_poke_harness(sys, loop, ALLREGS);
T = 0.030; ovT=getenv('BYTEGATE_T'); if ~isempty(ovT), T=str2double(ovT); end

fid=fopen(fullfile(KITDIR,'LOOP_GAIN_POKE_K5.txt'),'w');
fprintf(fid,'=========== Task C3 loop-gain AXI POKE TEST (gate 3) ===========\n');
fprintf(fid,'date: %s\n', char(datetime('now')));
allok = true;
for s = 1:size(SPECS,1)
    reg = SPECS{s,1}; checkP1 = SPECS{s,2}; checkP2 = SPECS{s,3};
    ref = ud.loopGainAxi.(reg);
    SI1 = double(ref.si); SI2 = round(2*SI1); W = ref.w;
    pack = @(si) uint32(mod(si, 2^W));
    fprintf('\n==== POKE %s  fi[s=%d w=%d f=%d] SI(G)=%d 2x=%d ====\n', reg, ref.s,ref.w,ref.f, SI1, SI2);

    % P0(reg=0) NOT re-run here (gate 2 sim_byte_gate proves zero-default identity).
    p1ok = true; p2lock = true; nf1=NaN; fg1=NaN; nf2=NaN; fg2=NaN;
    arr1=NaN; arr2=NaN; arrOK1=true; arrOK2=true;
    isGainTap = ismember(reg,{'cs_prop_gain','ss_prop_gain','agc_loop_gain'});
    % P1: drive SI(G). DISCRIMINATING: the muxed coefficient signal INSIDE the DUT
    % must equal SI(G) exactly (proves the threaded value arrived at the intended
    % constant + reinterpret fi is exact -- the decode oracle alone cannot show
    % this). cap==golden additionally confirms the runtime Product reproduces the
    % compiled gain.
    if checkP1
        setzeros(ALLREGS); setone(reg, pack(SI1)); r1 = run_poke(h, [reg ' P1 '], txWordsG, T);
        [nf1, fg1] = air_decode(r1.sym, rombits);
        if isfield(r1.sig,['coeff_' reg])
            arr1 = round(r1.sig.(['coeff_' reg]) * 2^ref.f); arrOK1 = (arr1 == SI1);
        else, arrOK1=false; end
        p1ok = (r1.cap==CAPG) && arrOK1 && ~isnan(fg1);
    end
    % P2: drive SI(2G). Coefficient (gains) must read SI(2G) / nz (cfo) must arm,
    % AND the detuned loop must still LOCK => value reaches datapath + tunable.
    if checkP2
        setzeros(ALLREGS); setone(reg, pack(SI2)); r2 = run_poke(h, [reg ' P2 '], txWordsG, T);
        [nf2, fg2] = air_decode(r2.sym, rombits);
        if isGainTap
            if isfield(r2.sig,['coeff_' reg]), arr2 = round(r2.sig.(['coeff_' reg]) * 2^ref.f); arrOK2 = (arr2 == SI2); else, arrOK2=false; end
        else
            if isfield(r2.sig,'nz_cfo_threshold'), arr2 = round(r2.sig.nz_cfo_threshold); arrOK2 = (arr2 == 1); else, arrOK2=false; end
        end
        p2lock = (nf2>=10) && ~isnan(fg2) && arrOK2;
    end
    regok = p1ok && p2lock;
    allok = allok && regok;

    fprintf(fid,'\n-- %-14s fi[s=%d w=%d f=%d] SI(G)=%d --\n', reg, ref.s,ref.w,ref.f, SI1);
    if checkP1
        fprintf(fid,'  P1 reg=SI(G)=%d : muxCoeff SI=%d (want %d, arrived+fi-exact=%s)  cap=0x%08X(golden)  frames=%d -> %s\n', ...
            SI1, arr1, SI1, tf(arrOK1), r1.cap, nf1, tf(p1ok));
    end
    if checkP2
        if isGainTap
            fprintf(fid,'  P2 reg=SI(2G)=%d: muxCoeff SI=%d (want %d, arrived=%s)  cap=0x%08X frames=%d locks -> %s\n', ...
                SI2, arr2, SI2, tf(arrOK2), r2.cap, nf2, tf(p2lock));
        else
            fprintf(fid,'  P2 reg=SI(2G)=%d: mux nz=%d (armed=%s)  cap=0x%08X frames=%d locks -> %s\n', ...
                SI2, arr2, tf(arrOK2), r2.cap, nf2, tf(p2lock));
        end
    end
    fprintf(fid,'  => %s\n', tf(regok));
    fprintf('%s: P1=%s P2=%s -> %s\n', reg, tf(p1ok), tf(p2lock), tf(regok));
end
fprintf(fid,'\nMUX-LIVE + TUNABLE across CS/SS/AGC/CFO kinds: %s\n', tf(allok));
fprintf(fid,'RESULT: %s\n', tf(allok));
fprintf(fid,'================================================================\n');
fclose(fid);
fprintf('WROTE LOOP_GAIN_POKE_K5.txt (%s)\n', tf(allok));
assert(allok, 'LOOP_GAIN_POKE_K5 FAILED');
fprintf('LOOP_GAIN_POKE_K5_DONE PASS\n');
end

% ---- base-var pokes ----
function setzeros(regs)
for r=regs, assignin('base',['pv_' r{1}], uint32(0)); end
end
function setone(reg, val)
assignin('base',['pv_' reg], val);
end

% =================== harness (mirrors sim_byte_gate build_harness_k5) =========
function h = build_poke_harness(sys, loop, allregs)
h='loop_gain_poke_harness';
if bdIsLoaded(h), close_system(h,0); end
new_system(h);
add_block([sys '/TxRxComposite'], [h '/DUT'], 'Position',[700 80 1050 980]);
cdb = [h '/DUT/Receiver/Capture Data Bits/MATLAB Function'];
ch = sfroot().find('-isa','Stateflow.EMChart','Path',cdb); scr = ch(1).Script;
scr = regexprep(scr,'msgarray_dec = char\([^\n]*\n','');
scr = regexprep(scr,'N = length\(msgarray_dec\)[^\n]*\n','');
scr = regexprep(scr,'strAscii_dec = reshape\(msgarray_dec[^\n]*\n','');
scr = regexprep(scr,'msg = char\(bin2dec[^\n]*\n','');
scr = regexprep(scr,'\s*disp\(msg\);',''); ch(1).Script = scr;
ra = [h '/DUT/Receiver/QPSK Rx/FEC Decoder Wrapper/RxAlign'];
ch2 = sfroot().find('-isa','Stateflow.EMChart','Path',ra);
ch2(1).Script = strrep(ch2(1).Script,'uint16(41)','uint16(25)');
im = containers.Map; om = containers.Map;
for b = reshape(find_system(loop,'SearchDepth',1,'BlockType','Inport'),1,[])
    im(get_param(b{1},'Name')) = struct('port',str2double(get_param(b{1},'Port')), ...
        'dt',get_param(b{1},'OutDataTypeStr'),'st',get_param(b{1},'SampleTime'));
end
for b = reshape(find_system(loop,'SearchDepth',1,'BlockType','Outport'),1,[])
    om(get_param(b{1},'Name')) = str2double(get_param(b{1},'Port'));
end
add_block('simulink/User-Defined Functions/MATLAB Function',[h '/VGen'],'Position',[150 80 220 120]);
vg = sfroot().find('-isa','Stateflow.EMChart','Path',[h '/VGen']);
vg.Script = sprintf(['function v = vgen(tick)\npersistent p\nif isempty(p), p=false; end\n' ...
    'p = ~p;\nv = p && logical(tick);\n']);
add_block('built-in/Constant',[h '/Tick'],'Value','true','OutDataTypeStr','boolean', ...
    'SampleTime','1/30.72e6','Position',[60 80 100 100]);
add_line(h,'Tick/1','VGen/1'); connect_in(h, im, 'adc_validIn', 'VGen/1');
mkc = @(nm,dt,val,st) add_block('built-in/Constant',[h '/' nm],'Value',val, ...
    'OutDataTypeStr',dt,'SampleTime',st,'Position',[60 140+40*double(nm(end)) 100 160+40*double(nm(end))]);
mkc('c_adcI','int16','0','1/30.72e6');        connect_in(h, im, 'adc_dataInI','c_adcI/1');
mkc('c_adcQ','int16','0','1/30.72e6');        connect_in(h, im, 'adc_dataInQ','c_adcQ/1');
mkc('c_rstCS','boolean','false','1/15.36e6'); connect_in(h, im, 'rstCS','c_rstCS/1');
mkc('c_dbgmux','uint32','0','1/15.36e6');     connect_in(h, im, 'iq_debug_mux','c_dbgmux/1');
mkc('c_rxsel','boolean','false','1/15.36e6'); connect_in(h, im, 'rx_input_select','c_rxsel/1');
mkc('c_hostI','int16','0','1/30.72e6');       connect_in(h, im, 'host_txI','c_hostI/1');
mkc('c_hostQ','int16','0','1/30.72e6');       connect_in(h, im, 'host_txQ','c_hostQ/1');
mkc('c_hostV','boolean','true','1/30.72e6');  connect_in(h, im, 'host_txValid','c_hostV/1');
mkc('c_txsel','uint32','0','1/15.36e6');      connect_in(h, im, 'tx_source_select','c_txsel/1');
mkc('c_skip','uint32','0','1/15.36e6');       connect_in(h, im, 'skip_count','c_skip/1');
mkc('c_txds','uint32','0','1/15.36e6');       connect_in(h, im, 'tx_data_source','c_txds/1');
mkc('c_brr','boolean','true','1/30.72e6');    connect_in(h, im, 'byte_rx_ready','c_brr/1');
% the 6 loop-gain registers, each driven by a base var pv_<name>
y=880;
for r = allregs
    o = im(r{1});
    add_block('built-in/Constant',[h '/PV_' r{1}],'Value',['pv_' r{1}], ...
        'OutDataTypeStr',o.dt,'SampleTime',o.st,'Position',[60 y 130 y+18]);
    connect_in(h, im, r{1}, ['PV_' r{1} '/1']); y=y+22;
    assignin('base',['pv_' r{1}], uint32(0));
end
% byte source
add_block('simulink/User-Defined Functions/MATLAB Function',[h '/ByteSrc'],'Position',[150 470 230 530]);
bs = sfroot().find('-isa','Stateflow.EMChart','Path',[h '/ByteSrc']);
bs.Script = sprintf([ ...
'function [data, valid, first] = src(ready, words, idx0)\n' ...
'persistent idx\nif isempty(idx), idx = uint32(idx0); end\n' ...
'data = words(idx);\nvalid = true;\nfirst = (idx == uint32(1));\n' ...
'if ready\n    idx = idx + 1;\n    if idx > uint32(numel(words)), idx = uint32(1); end\nend\n']);
add_block('built-in/Constant',[h '/WordsConst'],'Value','byte_words','OutDataTypeStr','uint64','Position',[60 540 100 560]);
add_block('built-in/Constant',[h '/StartIdxConst'],'Value','uint32(1)','OutDataTypeStr','uint32','Position',[60 580 100 600]);
add_line(h,'WordsConst/1','ByteSrc/2'); add_line(h,'StartIdxConst/1','ByteSrc/3');
connect_in(h, im, 'byte_data','ByteSrc/1'); connect_in(h, im, 'byte_valid','ByteSrc/2'); connect_in(h, im, 'byte_first','ByteSrc/3');
add_line(h, sprintf('DUT/%d', om('byte_ready')), 'ByteSrc/1', 'autorouting','on');
ph = get_param([h '/DUT'],'PortHandles');
for k=1:numel(ph.Outport)
    if k ~= om('byte_ready')
        add_block('built-in/Terminator',sprintf('%s/T%d',h,k),'Position',[1150 60+30*k 1170 80+30*k]);
        add_line(h, sprintf('DUT/%d',k), sprintf('T%d/1',k), 'autorouting','on');
    end
end
set_param(ph.Outport(om('cap_out')),'DataLogging','on','DataLoggingNameMode','Custom','DataLoggingName','cap_out');
qtx = [h '/DUT/Transmitter/QPSK Tx'];
mods = find_system(qtx,'SearchDepth',1,'LookUnderMasks','all','FollowLinks','on','Regexp','on','Name','.*Modulator.*');
mph = get_param(mods{1},'PortHandles');
for k=1:numel(mph.Outport)
    set_param(mph.Outport(k),'DataLogging','on','DataLoggingNameMode','Custom','DataLoggingName',sprintf('modTap%d',k));
end
% DISCRIMINATING taps: log the mux-internal coefficient SIGNAL so we can prove the
% threaded AXI value actually ARRIVES at the intended constant with the exact fi
% (a mis-thread or wrong fraction length would show here; the decode oracle
% cannot). For the 3 gain kinds log coeff (MLFB port 1); for CFO log nz (port 3,
% = the value reached the compare-mux and armed the runtime path).
d='DUT/Receiver/QPSK Rx/Frequency and Time Synchronizer/';
taps = { [d 'Carrier Synchronizer/Loop Filter/LGMux_cs_prop_gain'], 1, 'coeff_cs_prop_gain'; ...
         [d 'Symbol Synchronizer/Loop Filter/LGMux_ss_prop_gain'],  1, 'coeff_ss_prop_gain'; ...
         'DUT/Receiver/QPSK Rx/Automatic Gain Control/Loop Filter/LGMux_agc_loop_gain', 1, 'coeff_agc_loop_gain'; ...
         [d 'Coarse Frequency Compensator/CFO step change detector/LGMux_cfo_threshold'], 3, 'nz_cfo_threshold' };
for t=1:size(taps,1)
    blk = [h '/' taps{t,1}];
    assert(~isempty(find_system(h,'LookUnderMasks','all','FollowLinks','on','Name',get_param2name(taps{t,1}))), ...
        'poke tap: mux block %s not found', taps{t,1});
    ph2 = get_param(blk,'PortHandles');
    set_param(ph2.Outport(taps{t,2}),'DataLogging','on','DataLoggingNameMode','Custom','DataLoggingName',taps{t,3});
end
set_param(h,'SolverType','Fixed-step','Solver','FixedStepDiscrete', ...
    'SignalLogging','on','SignalLoggingName','logsout','SaveFormat','Dataset');
% golden words are static for the poke
end

function nm = get_param2name(path)
parts = strsplit(path,'/'); nm = parts{end};
end

function connect_in(h, im, name, srcSpec)
assert(im.isKey(name), 'composite inport %s missing', name);
add_line(h, srcSpec, sprintf('DUT/%d', im(name).port), 'autorouting','on');
end

function res = run_poke(h, label, words, T)
assignin('base','byte_words', words(:));
set_param(h,'StopTime', num2str(T));
so = sim(h); L = so.logsout;
els = cell(L.numElements,2);
for i=1:L.numElements, e=L{i}; els{i,1}=e.Name; els{i,2}=e.Values; end
capTs = els{find(strcmp(els(:,1),'cap_out'),1),2};
res.cap = uint32(capTs.Data(end));
mv=[]; pts=[]; reD={};
for k=1:8
    idx = find(strcmp(els(:,1),sprintf('modTap%d',k)),1);
    if isempty(idx), continue; end
    d = els{idx,2}.Data;
    if ~isreal(d), pts=d;
    elseif islogical(d) || all(double(d(:))==0 | double(d(:))==1), mv=logical(d);
    else, reD{end+1}=double(d); end %#ok<AGROW>
end
if ~isempty(pts), res.sym = double(pts(mv));
else, res.sym = complex(reD{1}(mv), reD{2}(mv)); end
% mux-internal coefficient / nz signals (steady-state last sample, real-world)
res.sig = struct();
for nm = {'coeff_cs_prop_gain','coeff_ss_prop_gain','coeff_agc_loop_gain','nz_cfo_threshold'}
    idx = find(strcmp(els(:,1),nm{1}),1);
    if ~isempty(idx), dd=els{idx,2}.Data; res.sig.(nm{1})=double(dd(end)); end
end
fprintf('  %s: cap_out=0x%08X syms=%d\n', strtrim(label), res.cap, numel(res.sym));
end

function [nFrames, firstGold] = air_decode(sym, refbits)
payloadSyms = frame_config_k5().PayloadBits/2;
sI = real(sym)>0; sQ = imag(sym)>0; q = double(sI)*2 + double(sQ);
bark = logical([1 1 1 1 1 0 0 1 1 0 1 0 1]);
preQ = zeros(1,13); preQ(~bark)=3;
qr=q(:).'; n=numel(qr); starts=[];
for i=1:n-12, if isequal(qr(i:i+12),preQ), starts(end+1)=i; end, end %#ok<AGROW>
bitI=double(~sQ); bitQ=double(~sI); nFrames=0; frErr=[];
for i=1:numel(starts)
    s0=starts(i); if s0+13+payloadSyms-1>n, break; end
    idx=s0+13:s0+13+payloadSyms-1;
    bits=reshape([bitI(idx) bitQ(idx)].',[],1);
    frErr(end+1)=sum(bits(:)~=refbits(:)); nFrames=nFrames+1; %#ok<AGROW>
end
fg=find(frErr==0,1); if isempty(fg), firstGold=NaN; else, firstGold=fg; end
end

function bits = unpack_words32(words)
bits = zeros(32*numel(words),1);
for w2=0:numel(words)-1
    v=uint32(words(w2+1));
    for b=0:31, bits(32*w2+b+1)=double(bitget(v,32-b)); end
end
end

function w = pack_bits64(bits)
n=ceil(numel(bits)/64)*64; b=zeros(n,1); b(1:numel(bits))=double(bits(:));
B=reshape(b,8,[]).'; bytes=uint64(B*(2.^(7:-1:0)).'); nw=n/64; w=zeros(nw,1,'uint64');
for k=1:nw, v=uint64(0); for j=0:7, v=bitor(v,bitshift(bytes((k-1)*8+j+1),8*j)); end, w(k)=v; end
end

function s = tf(b), if b, s='PASS'; else, s='FAIL'; end, end
function s = ternary(c,a,b), if c, s=a; else, s=b; end, end
