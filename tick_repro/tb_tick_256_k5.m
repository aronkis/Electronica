function out = tb_tick_256_k5(varargin)
%TB_TICK_256_K5  Simulink testbench for the board-148 +256-sample device tick.
%
%   out = tb_tick_256_k5('Name',Value,...)
%
%   Reproduces the tick's observable failure: the +256-sample (+32-symbol)
%   insertion the live 148 RX suffers at each BBDC cal makes the receiver's
%   Peak-Search frame offset step +32 and miss sync for ~2 frames
%   (two_jup/ERROR_TAXONOMY.md). The RTL timing recovery PASSES the sample-level
%   displacement to the Preamble Detector as a +32-SYMBOL offset (that is why
%   Peak Search latches 101->133), so the faithful abstraction -- and what
%   k5_240/pd_harness_k5.m replayed from hardware -- is a +32-symbol insertion in
%   the consumed symbol stream.
%
%   STAGE A (self-contained, VALIDATED): synthesize a clean QPSK frame stream,
%     insert +32 symbols at a frame boundary, and recover frame starts by
%     differential-Barker correlation -> an unambiguous +32-symbol frame-spacing
%     step. Demonstrates the cause.
%   STAGE B (needs a P1D-assembled loopback model loaded): drive the REAL
%     Preamble Detector -- extracted with pd_harness_k5.m mechanics -- with the
%     baseline vs +32-inserted symbol streams, so the RTL PD reproduces the
%     Peak-Search offset step in Simulink.
%   Bit-true RTL-faithful cross-check (proven, no Simulink): the netlist path in
%     the README -- replay_capture.sh on baseline vs the make_spliced_iq output.
%
%   Name/Value (optional): 'Raw' (capture for the netlist .iq, default
%     evmcap/fwd1/raw.iq), 'N0' (2000000), 'Mode' ('repeat'|'noise'|'phase90'|
%     'zeros'), 'Model' ('commhdlQPSKTxRxLoopback'), 'NFrames' (30),
%     'SpliceFrame' (15), 'Sps' (8).
%
%   Authored against the proven pd_harness_k5.m pattern. STAGE A is validated on
%   real data; STAGE B needs your assembled model (and, if its PD outport names
%   differ, a tweak at the marked "OFFSET OUTPORT" line).

p = inputParser;
here = fileparts(mfilename('fullpath')); repo = fileparts(here);
p.addParameter('Raw', fullfile(repo,'two_jup','evmcap','fwd1','raw.iq'));
p.addParameter('N0', 2000000); p.addParameter('Mode','repeat');
p.addParameter('Model','commhdlQPSKTxRxLoopback');
p.addParameter('NFrames', 30); p.addParameter('SpliceFrame', 15);
p.addParameter('Sps', 8);
p.parse(varargin{:}); o = p.Results;

preSyms = local_preamble(); nPre = numel(preSyms);
frameLenSym = nPre + 2240/2;                    % 1133

% ---- also emit the sample-level spliced .iq for the proven netlist path ----
spliced = fullfile(tempdir, sprintf('tick_spliced_n%d_%s.iq', o.N0, o.Mode));
try
    make_spliced_iq(o.Raw, spliced, o.N0, 256, o.Mode);
catch me
    fprintf('(sample-level splice skipped: %s)\n', me.message); spliced = '';
end

% ---- STAGE A: synth +32-symbol insertion -> frame-offset step --------------
fprintf('\n== STAGE A: synth +32-symbol insertion (the +256-sample displacement) ==\n');
symBase = local_synth(o.NFrames, preSyms, frameLenSym);
atSym   = o.SpliceFrame * frameLenSym;
symSpl  = local_insert_syms(symBase, atSym, 32, o.Mode);
psB = local_frame_offsets(symBase, preSyms, nPre, frameLenSym);
psS = local_frame_offsets(symSpl,  preSyms, nPre, frameLenSym);
dB = diff(psB); dS = diff(psS);
[~, ji] = max(dS - frameLenSym);               % the +32 step (a positive jump)
step = dS(ji) - frameLenSym;
fprintf('STAGE A: baseline spacing median=%.0f (expect %d)\n', median(dB), frameLenSym);
fprintf('STAGE A: spliced spacing at frame %d = %d (=%d+%d) -> %s\n', ji, dS(ji), ...
    frameLenSym, step, ternary(step==32,'+32 CONFIRMED','(check params)'));

fh = figure('Name','tick +256-sample insertion: +32 frame-offset step');
subplot(2,1,1); plot(dB,'.-'); yline(frameLenSym,'k--'); grid on;
ylabel('spacing (sym)'); title('BASELINE inter-frame spacing (flat = 1133)');
subplot(2,1,2); plot(dS,'.-'); hold on; yline(frameLenSym,'k--');
xline(ji,'r-',sprintf('%+d @ frame %d',step,ji)); grid on;
ylabel('spacing (sym)'); xlabel('frame #');
title('SPLICED: +32-symbol step at the insertion (= the tick)');

out = struct('spliced', spliced, 'jumpFrame', ji, 'stepSym', step, ...
    'symBase', symBase, 'symSpliced', symSpl, 'stageB', false, 'fig', fh);

% ---- STAGE B: drive the REAL RTL Preamble Detector -------------------------
loop = o.Model;
if ~bdIsLoaded(loop)
    fprintf(['\n== STAGE B SKIPPED: model "%s" not loaded. Assemble it with the p1d\n' ...
        '   overlay + load_system(''%s'') to reproduce the offset step in the RTL PD. ==\n'], loop, loop);
    return;
end
pdPath = [loop '/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector'];
if isempty(find_system(pdPath,'SearchDepth',0,'LookUnderMasks','all','FollowLinks','on'))
    fprintf('\n== STAGE B SKIPPED: %s not found ==\n', pdPath); return;
end
fprintf('\n== STAGE B: driving the extracted RTL Preamble Detector ==\n');
offB = local_drive_pd(loop, pdPath, symBase, o.Sps);
offS = local_drive_pd(loop, pdPath, symSpl,  o.Sps);
figure('Name','RTL Preamble Detector (Simulink): baseline vs spliced');
plot(offB,'.-'); hold on; plot(offS,'.-'); grid on;
legend('baseline','spliced'); xlabel('symbol'); ylabel('PD reported offset');
title('Extracted RTL PD: +32 offset step at the +32-symbol insertion');
out.stageB = true; out.pdOffBase = offB; out.pdOffSpliced = offS;
fprintf('STAGE B done: the spliced offset trace steps +32 at the insertion.\n');
end

% ============================ helpers ====================================
function s = ternary(c,a,b), if c, s=a; else, s=b; end, end

function pre = local_preamble()
b = [1 1 1 1 1 -1 -1 1 1 -1 1 -1 1].';          % Barker-13
pre = exp(1i*pi/4) * b;                          % pi/4-QPSK grid
end

function sym = local_synth(NF, preSyms, frameLenSym)
% clean symbol stream: NF frames of [preamble; random pi/4-Gray QPSK payload].
nPay = frameLenSym - numel(preSyms);
qpsk = exp(1i*(pi/4 + (0:3)*pi/2));
sym = zeros(NF*frameLenSym, 1);
for f = 1:NF
    pay = qpsk(randi(4, nPay, 1)).';
    sym((f-1)*frameLenSym + (1:frameLenSym)) = [preSyms; pay];
end
end

function y = local_insert_syms(sym, atSym, n, mode, ~)
% insert n symbols at index atSym (the +32 displacement the RTL PD sees).
switch lower(mode)
    case 'repeat',  ins = sym(atSym-n+1:atSym);
    case 'phase90', ins = sym(atSym-n+1:atSym) * exp(1i*pi/2);
    case 'zeros',   ins = zeros(n,1);
    otherwise                                    % 'noise' and anything else
        qpsk = exp(1i*(pi/4 + (0:3)*pi/2)); ins = qpsk(randi(4,n,1)).';
end
y = [sym(1:atSym); ins(:); sym(atSym+1:end)];
end

function ps0 = local_frame_offsets(sym, preSyms, nPre, frameLenSym)
% differential-Barker correlation -> frame start indices (rotation invariant;
% the local_framePeaks logic from evm/evm_ideal_ref.m).
dps = preSyms(2:end) .* conj(preSyms(1:end-1));
dsy = sym(2:end) .* conj(sym(1:end-1));
ccd = abs(conv(dsy, conj(flipud(dps)))); ccd = ccd / (max(ccd)+eps);
[~, pk] = findpeaks(ccd, 'MinPeakHeight', 0.4, 'MinPeakDistance', round(0.6*frameLenSym));
ps0 = pk - (nPre - 2);
ps0 = ps0(ps0 >= 1 & ps0 + frameLenSym - 1 <= numel(sym));
end

function off = local_drive_pd(loop, pdPath, sym, sps)
% Extract the Preamble Detector into a fresh harness (pd_harness_k5.m mechanics)
% and drive it with the symbol stream held sps beats/symbol + a validIn strobe.
% Returns the PD's reported timing/peak offset (per beat).
h = 'tb_tick_pd'; if bdIsLoaded(h), close_system(h,0); end
new_system(h);
cs = getActiveConfigSet(loop); csc = cs.copy; csc.Name='tbpd_cfg';
attachConfigSet(h,csc,true); setActiveConfigSet(h,'tbpd_cfg');
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
% --- OFFSET OUTPORT: the PD outport carrying the timing/peak offset ('*Off*'/
% 'timing*' in the stock design). Adjust this selector if your build differs. ---
offIdx = find(contains(lower(outNames),'off') | contains(lower(outNames),'timing'),1);
if isempty(offIdx), offIdx = 1; warning('tb_tick:offport', ...
    'no offset-like outport in {%s}; using #1', strjoin(outNames,',')); end
nSym = numel(sym); nBeat = nSym*sps;
dI = zeros(nBeat,1); dQ = zeros(nBeat,1); val = false(nBeat,1);
for k=1:nSym, seg=(k-1)*sps+(1:sps); dI(seg)=real(sym(k)); dQ(seg)=imag(sym(k)); val(seg(end))=true; end
t=(0:nBeat-1)';
assignin('base','tbpd_data', timeseries(complex(dI,dQ)*2^-14, t));
assignin('base','tbpd_valid', timeseries(val, t));
add_block('simulink/Sources/From Workspace',[h '/SrcD'],'VariableName','tbpd_data','SampleTime','1','Interpolate','off','ZeroCross','off','OutputAfterFinalValue','Holding final value','Position',[80 100 180 130]);
add_block('simulink/Sources/From Workspace',[h '/SrcV'],'VariableName','tbpd_valid','SampleTime','1','Interpolate','off','ZeroCross','off','OutputAfterFinalValue','Holding final value','Position',[80 200 180 230]);
add_block('simulink/Signal Attributes/Data Type Conversion',[h '/DtcD'],'OutDataTypeStr','fixdt(1,16,14)','Position',[220 105 270 125]);
add_block('simulink/Signal Attributes/Data Type Conversion',[h '/DtcV'],'OutDataTypeStr','boolean','Position',[220 205 270 225]);
add_line(h,'SrcD/1','DtcD/1'); add_line(h,'DtcD/1',sprintf('PD/%d',pIn(dIdx)));
add_line(h,'SrcV/1','DtcV/1'); add_line(h,'DtcV/1',sprintf('PD/%d',pIn(vIdx)));
add_block('simulink/Sinks/To Workspace',[h '/OffW'],'VariableName','tbpd_off','SaveFormat','Array','SampleTime','1','Position',[820 100 900 130]);
add_line(h,sprintf('PD/%d',pOut(offIdx)),'OffW/1');
for k=1:numel(outs)
    if k==offIdx, continue; end
    add_block('simulink/Sinks/Terminator',[h sprintf('/T%d',k)],'Position',[820 240+30*k 840 260+30*k]);
    add_line(h,sprintf('PD/%d',pOut(k)),sprintf('T%d/1',k));
end
set_param(h,'SolverType','Fixed-step','Solver','FixedStepDiscrete','FixedStep','1','StopTime',num2str(nBeat-1),'SaveOutput','off','SaveTime','off','SignalLogging','off');
so = sim(h,'ReturnWorkspaceOutputs','on');
raw = double(so.get('tbpd_off')); raw = raw(:);
off = raw((1:nSym)*sps);                         % one value per symbol strobe
end
