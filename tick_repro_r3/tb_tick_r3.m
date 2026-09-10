function out = tb_tick_r3(varargin)
%TB_TICK_R3  Simulink testbench for a timing insertion at R3 (61.44 MSPS/f1536).
%
%   out = tb_tick_r3('Name',Value,...)
%
%   R3 companion of ../tick_repro/tb_tick_256_k5.m. Injects a +N-symbol insertion
%   (default +32 = the 240k tick's processing-domain displacement, = 128 samples
%   at sps=4) into the f1536 receive chain and shows the frame-offset step. See
%   README_TICK_R3.md -- NOTE the periodic 148 tick was NOT observed at R3; this
%   reproduces the receiver's RESPONSE to a timing insertion at the higher rate.
%
%   STAGE A (self-contained, VALIDATED): synth f1536 frame stream (12333 sym/
%     frame), insert +N symbols, recover frame starts by differential-Barker
%     correlation -> a clean +N-symbol frame-spacing step.
%   STAGE B (needs an f1536 P1D-assembled loopback model loaded): drive the real
%     RTL Preamble Detector (pd_harness_k5.m mechanics) with baseline vs inserted
%     symbol streams.
%
%   Name/Value: 'Raw' (default ../two_jup/r3cap/20260729_135508_fwd/pair.iq),
%     'N0' (2000000), 'Mode' ('repeat'|'noise'|'phase90'|'zeros'),
%     'InsertSyms' (32), 'Model' ('commhdlQPSKTxRxLoopback'), 'NFrames' (10),
%     'SpliceFrame' (5), 'Sps' (4).

here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..', 'tick_repro'));     % make_spliced_iq (shared)
repo = fileparts(here);
p = inputParser;
p.addParameter('Raw', fullfile(repo,'two_jup','r3cap','20260729_135508_fwd','pair.iq'));
p.addParameter('N0', 2000000); p.addParameter('Mode','repeat');
p.addParameter('InsertSyms', 32);
p.addParameter('Model','commhdlQPSKTxRxLoopback');
p.addParameter('NFrames', 10); p.addParameter('SpliceFrame', 5);
p.addParameter('Sps', 4);
p.parse(varargin{:}); o = p.Results;

% ---- R3 / f1536 geometry ----
sps = o.Sps; DataBitsPerPacket = 24640; spf = 49332;
preSyms = local_preamble(); nPre = numel(preSyms);
frameLenSym = nPre + DataBitsPerPacket/2;         % 12333
nInsSamp = o.InsertSyms * sps;                     % 128 for +32 sym @ sps4

% ---- sample-level spliced .iq for the netlist path (obj_byte_f1536) ----
spliced = fullfile(tempdir, sprintf('r3_spliced_n%d_%s.iq', o.N0, o.Mode));
try
    make_spliced_iq(o.Raw, spliced, o.N0, nInsSamp, o.Mode, sps, spf);
catch me
    fprintf('(sample-level splice skipped: %s)\n', me.message); spliced = '';
end

% ---- STAGE A: synth +N-symbol insertion -> frame-offset step ----
fprintf('\n== STAGE A: synth +%d-symbol insertion at R3 (f1536, %d sym/frame) ==\n', ...
    o.InsertSyms, frameLenSym);
symBase = local_synth(o.NFrames, preSyms, frameLenSym);
atSym   = o.SpliceFrame * frameLenSym;
symSpl  = local_insert_syms(symBase, atSym, o.InsertSyms, o.Mode);
psB = local_frame_offsets(symBase, preSyms, nPre, frameLenSym);
psS = local_frame_offsets(symSpl,  preSyms, nPre, frameLenSym);
dB = diff(psB); dS = diff(psS);
[~, ji] = max(dS - frameLenSym); step = dS(ji) - frameLenSym;
fprintf('STAGE A: baseline spacing median=%.0f (expect %d)\n', median(dB), frameLenSym);
fprintf('STAGE A: spliced spacing at frame %d = %d (=%d+%d) -> %s\n', ji, dS(ji), ...
    frameLenSym, step, ternary(step==o.InsertSyms, sprintf('+%d CONFIRMED',o.InsertSyms), '(check params)'));

fh = figure('Name', sprintf('R3 +%d-symbol insertion: frame-offset step', o.InsertSyms));
subplot(2,1,1); plot(dB,'.-'); yline(frameLenSym,'k--'); grid on;
ylabel('spacing (sym)'); title(sprintf('BASELINE inter-frame spacing (flat = %d)', frameLenSym));
subplot(2,1,2); plot(dS,'.-'); hold on; yline(frameLenSym,'k--');
xline(ji,'r-',sprintf('%+d @ frame %d',step,ji)); grid on;
ylabel('spacing (sym)'); xlabel('frame #');
title(sprintf('SPLICED: +%d-symbol step at the insertion', o.InsertSyms));

out = struct('spliced', spliced, 'jumpFrame', ji, 'stepSym', step, ...
    'insertSyms', o.InsertSyms, 'insertSamples', nInsSamp, ...
    'symBase', symBase, 'symSpliced', symSpl, 'stageB', false, 'fig', fh);

% ---- STAGE B: drive the real RTL Preamble Detector (f1536 model) ----
loop = o.Model;
if ~bdIsLoaded(loop)
    fprintf(['\n== STAGE B SKIPPED: model "%s" not loaded. Assemble the f1536 model\n' ...
        '   with the p1d overlay + load_system(''%s'') to drive the RTL PD. ==\n'], loop, loop);
    return;
end
pdPath = [loop '/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector'];
if isempty(find_system(pdPath,'SearchDepth',0,'LookUnderMasks','all','FollowLinks','on'))
    fprintf('\n== STAGE B SKIPPED: %s not found ==\n', pdPath); return;
end
fprintf('\n== STAGE B: driving the extracted RTL Preamble Detector (sps=%d) ==\n', sps);
offB = local_drive_pd(loop, pdPath, symBase, sps);
offS = local_drive_pd(loop, pdPath, symSpl,  sps);
figure('Name','R3 RTL Preamble Detector (Simulink): baseline vs spliced');
plot(offB,'.-'); hold on; plot(offS,'.-'); grid on;
legend('baseline','spliced'); xlabel('symbol'); ylabel('PD reported offset');
title(sprintf('R3 RTL PD: +%d offset step at the insertion', o.InsertSyms));
out.stageB = true; out.pdOffBase = offB; out.pdOffSpliced = offS;
end

% ============================ helpers (identical to tb_tick_256_k5) ========
function s = ternary(c,a,b), if c, s=a; else, s=b; end, end
function pre = local_preamble()
b = [1 1 1 1 1 -1 -1 1 1 -1 1 -1 1].'; pre = exp(1i*pi/4) * b;
end
function sym = local_synth(NF, preSyms, frameLenSym)
nPay = frameLenSym - numel(preSyms); qpsk = exp(1i*(pi/4 + (0:3)*pi/2));
sym = zeros(NF*frameLenSym, 1);
for f = 1:NF
    pay = qpsk(randi(4, nPay, 1)).';
    sym((f-1)*frameLenSym + (1:frameLenSym)) = [preSyms; pay];
end
end
function y = local_insert_syms(sym, atSym, n, mode)
switch lower(mode)
    case 'repeat',  ins = sym(atSym-n+1:atSym);
    case 'phase90', ins = sym(atSym-n+1:atSym) * exp(1i*pi/2);
    case 'zeros',   ins = zeros(n,1);
    otherwise, qpsk = exp(1i*(pi/4 + (0:3)*pi/2)); ins = qpsk(randi(4,n,1)).';
end
y = [sym(1:atSym); ins(:); sym(atSym+1:end)];
end
function ps0 = local_frame_offsets(sym, preSyms, nPre, frameLenSym)
dps = preSyms(2:end) .* conj(preSyms(1:end-1));
dsy = sym(2:end) .* conj(sym(1:end-1));
ccd = abs(conv(dsy, conj(flipud(dps)))); ccd = ccd / (max(ccd)+eps);
[~, pk] = findpeaks(ccd, 'MinPeakHeight', 0.4, 'MinPeakDistance', round(0.6*frameLenSym));
ps0 = pk - (nPre - 2);
ps0 = ps0(ps0 >= 1 & ps0 + frameLenSym - 1 <= numel(sym));
end
function off = local_drive_pd(loop, pdPath, sym, sps)
h = 'tb_tick_r3_pd'; if bdIsLoaded(h), close_system(h,0); end
new_system(h);
cs = getActiveConfigSet(loop); csc = cs.copy; csc.Name='tbr3_cfg';
attachConfigSet(h,csc,true); setActiveConfigSet(h,'tbr3_cfg');
mwsS = get_param(loop,'ModelWorkspace'); mwsD = get_param(h,'ModelWorkspace');
for v = reshape(mwsS.whos,1,[]), mwsD.assignin(v.name, mwsS.getVariable(v.name)); end
anc = { [loop '/TxRxComposite'], [loop '/TxRxComposite/Receiver'], ...
        [loop '/TxRxComposite/Receiver/QPSK Rx'], ...
        [loop '/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer'], pdPath };
for a = anc
    try, mv = get_param(a{1},'MaskWSVariables');
        for k=1:numel(mv), mwsD.assignin(mv(k).Name, mv(k).Value); end
    catch, end
end
add_block(pdPath, [h '/PD'], 'Position',[400 80 700 520]);
ins = find_system([h '/PD'],'SearchDepth',1,'BlockType','Inport');
outs = find_system([h '/PD'],'SearchDepth',1,'BlockType','Outport');
inNames = cellfun(@(b)get_param(b,'Name'), ins,'UniformOutput',false);
outNames = cellfun(@(b)get_param(b,'Name'), outs,'UniformOutput',false);
dtIn = cellfun(@(b)get_param(b,'OutDataTypeStr'), ins,'UniformOutput',false);
vIdx = find(contains(dtIn,'boolean'),1);
if isempty(vIdx), vIdx = find(contains(lower(inNames),'valid'),1); end
dIdx = 3 - vIdx;
pIn = cellfun(@(b)str2double(get_param(b,'Port')), ins);
pOut = cellfun(@(b)str2double(get_param(b,'Port')), outs);
% --- OFFSET OUTPORT: adjust if your f1536 PD build names it differently ---
offIdx = find(contains(lower(outNames),'off') | contains(lower(outNames),'timing'),1);
if isempty(offIdx), offIdx = 1; warning('tb_tick_r3:offport','using outport 1'); end
nSym = numel(sym); nBeat = nSym*sps;
dI = zeros(nBeat,1); dQ = zeros(nBeat,1); val = false(nBeat,1);
for k=1:nSym, seg=(k-1)*sps+(1:sps); dI(seg)=real(sym(k)); dQ(seg)=imag(sym(k)); val(seg(end))=true; end
t=(0:nBeat-1)';
assignin('base','tbr3_data', timeseries(complex(dI,dQ)*2^-14, t));
assignin('base','tbr3_valid', timeseries(val, t));
add_block('simulink/Sources/From Workspace',[h '/SrcD'],'VariableName','tbr3_data','SampleTime','1','Interpolate','off','ZeroCross','off','OutputAfterFinalValue','Holding final value','Position',[80 100 180 130]);
add_block('simulink/Sources/From Workspace',[h '/SrcV'],'VariableName','tbr3_valid','SampleTime','1','Interpolate','off','ZeroCross','off','OutputAfterFinalValue','Holding final value','Position',[80 200 180 230]);
add_block('simulink/Signal Attributes/Data Type Conversion',[h '/DtcD'],'OutDataTypeStr','fixdt(1,16,14)','Position',[220 105 270 125]);
add_block('simulink/Signal Attributes/Data Type Conversion',[h '/DtcV'],'OutDataTypeStr','boolean','Position',[220 205 270 225]);
add_line(h,'SrcD/1','DtcD/1'); add_line(h,'DtcD/1',sprintf('PD/%d',pIn(dIdx)));
add_line(h,'SrcV/1','DtcV/1'); add_line(h,'DtcV/1',sprintf('PD/%d',pIn(vIdx)));
add_block('simulink/Sinks/To Workspace',[h '/OffW'],'VariableName','tbr3_off','SaveFormat','Array','SampleTime','1','Position',[820 100 900 130]);
add_line(h,sprintf('PD/%d',pOut(offIdx)),'OffW/1');
for k=1:numel(outs)
    if k==offIdx, continue; end
    add_block('simulink/Sinks/Terminator',[h sprintf('/T%d',k)],'Position',[820 240+30*k 840 260+30*k]);
    add_line(h,sprintf('PD/%d',pOut(k)),sprintf('T%d/1',k));
end
set_param(h,'SolverType','Fixed-step','Solver','FixedStepDiscrete','FixedStep','1','StopTime',num2str(nBeat-1),'SaveOutput','off','SaveTime','off','SignalLogging','off');
so = sim(h,'ReturnWorkspaceOutputs','on');
raw = double(so.get('tbr3_off')); raw = raw(:);
off = raw((1:nSym)*sps);
end
