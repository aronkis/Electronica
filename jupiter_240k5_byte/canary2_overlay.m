function canary2_overlay(sys, base)
% canary2_overlay -- T8.6: critical-path canary + shadow extension.
% Builds on canary_instrumentation_overlay (T8.5, must be applied first).
%
% (A) PATH CANARY (composite level, AXI 0x18C): four graduated multiply-chain
%     replicas (N=2..5 stages of 32x32->slice mixes, ~7 ns/stage vs the
%     32.5 ns clk budget; the design's real WNS is ~+1 ns so the long chains
%     bracket the true margin). Each chain: a FAST leg computed combinationally
%     in ONE cycle and latched, vs a RELAXED reference computing the identical
%     function split across TWO cycles. Functionally identical forever ->
%     counters read 0 in every simulation; on silicon, clock-margin erosion
%     fails the longest fast leg FIRST regardless of which functional circuit
%     is the real victim. Doubles as a temperature-margin thermometer.
%     NOTE: the N=5 chain may legitimately fail setup at build time -- that is
%     by design (a hotter-than-critical sentinel); post-build timing checks
%     must whitelist CanaryFast paths.
%     Anti-CSE: fast and ref legs live in SEPARATE MLFB blocks (separate HDL
%     modules) so synthesis cannot share their logic.
%
% (B) IC SHADOW (Symbol Synchronizer, 0x190/0x194): a second Interpolation
%     Control (fresh MLFB, script copied from the primary at apply time) fed
%     the 1-beat-delayed Delta (reuses T8.5's DlyVP); primary mu/Underflow
%     delayed 1 beat vs shadow -> first-divergence beat + event count.
%     countReg offsets persist (mod-1 counter), so post-hit mismatches recur
%     -- the count measures ongoing disagreement, the beat stamps the first.
%
% (C) CARRIER LF SHADOW (Carrier Synchronizer, 0x198/0x19C): copy of the
%     carrier Loop Filter fed 1-beat-delayed {e, validIn, internalRst,
%     externalRst}; taps on BOTH true state regs (P-hold sfix29_En29 +
%     integrator sfix39_En39 -- the only recursive state, HDL-verified).
%     Because both copies sync-clear on the (aligned) rst chain, they RE-SYNC
%     at every carrier reset -> the count = divergence episodes per session.
%
% (D) NCO TWIN REPLICAS (Carrier Synchronizer, 0x1A0): the real NCO phase
%     accumulator is hidden inside a library block (no tap), so two identical
%     phase-accumulator replicas run 1 beat apart on the same tapped inputs
%     (phaseInc=LF v, valid=LF valid, rst=the DDS reset AND). Mutual
%     divergence = a physical upset in this fabric region/structure (canary
%     semantics, NOT a true shadow of the real register -- documented).
%
% (E) STROBE FORENSIC RECAL (updates T8.5 ShadowScore): 0x184 becomes
%     {maxGap[31:16] | minGap[15:0]} since soft reset -- self-calibrating
%     band (the fixed >12 skip threshold was rate-miscalibrated).
%
% New AXI read regs (hdlworkflow): 0x18C path_canary {c5|c4|c3|c2 u8 sat},
% 0x190 ic_div_beat, 0x194 ic_div_cnt, 0x198 cs_lf_div_beat,
% 0x19C cs_lf_div_cnt, 0x1A0 nco_div_beat. All clear on soft reset 0x000.
% Idempotent. Apply at assemble Phase 2.12e.

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end

rcv = [base '/Receiver'];
qrx = [rcv '/QPSK Rx'];
fts = [qrx '/Frequency and Time Synchronizer'];
ss  = [fts '/Symbol Synchronizer'];
cs  = [fts '/Carrier Synchronizer'];

if ~isempty(find_system(base,'SearchDepth',1,'BlockType','Outport','Name','path_canary'))
    fprintf('canary2_overlay: already present -- skipping\n');
    return;
end
assert(~isempty(find_system(ss,'SearchDepth',1,'Name','ShadowScore')), ...
    'canary2_overlay: apply AFTER canary_instrumentation_overlay');

%% ================= (E) strobe forensic recalibration =================
cfgS = get_param([ss '/ShadowScore'], 'MATLABFunctionConfiguration');
code = cfgS.FunctionScript;
if contains(code, 'mingap')
    fprintf('canary2_overlay: ShadowScore minGap recal already present -- skip\n');
else
    code = strrep(code, 'persistent pc pb ib ipl isl mg sk gap bt pmPrev', ...
                        'persistent pc pb ib ipl isl mg mingap gap bt pmPrev');
    code = strrep(code, 'mg=uint16(0); sk=uint16(0); gap=uint16(0);', ...
                        'mg=uint16(0); mingap=uint16(65535); gap=uint16(0);');
    code = strrep(code, sprintf(['if und\n  if gap > mg, mg = gap; end\n' ...
        '  if gap > uint16(12) && sk < uint16(65535), sk = sk + uint16(1); end\n  gap = uint16(0);\nend']), ...
        sprintf(['if und\n  if gap > mg, mg = gap; end\n' ...
        '  if gap < mingap, mingap = gap; end\n  gap = uint16(0);\nend']));
    code = strrep(code, 'strobeFor = bitor(bitshift(uint32(mg),16), uint32(sk));', ...
                        'strobeFor = bitor(bitshift(uint32(mg),16), uint32(mingap));');
    assert(contains(code,'mingap'), 'ShadowScore recal patch failed');
    cfgS.FunctionScript = code;
    fprintf('canary2_overlay: ShadowScore strobe field -> {maxGap|minGap}\n');
end

%% ================= (A) path canary (composite level) =================
add_block('simulink/User-Defined Functions/MATLAB Function', [base '/CanaryLfsr'], ...
    'Position',[200 1550 300 1590]);
set_fcn_script([base '/CanaryLfsr'], sprintf([ ...
'function x = canaryLfsr()\n%%#codegen\n' ...
'persistent s\nif isempty(s), s = uint32(2463534242); end\n' ...
'x = s;\n' ...
's = bitxor(s, bitshift(s, 13));\n' ...
's = bitxor(s, bitshift(s, -17));\n' ...
's = bitand(bitxor(s, bitshift(s, 5)), uint32(4294967295));\n']));

add_block('simulink/User-Defined Functions/MATLAB Function', [base '/CanaryFast'], ...
    'Position',[340 1540 460 1610]);
set_fcn_script([base '/CanaryFast'], canaryFast_src());
add_line(base, 'CanaryLfsr/1', 'CanaryFast/1', 'autorouting','on');

add_block('simulink/User-Defined Functions/MATLAB Function', [base '/CanaryRef'], ...
    'Position',[340 1630 460 1700]);
set_fcn_script([base '/CanaryRef'], canaryRef_src());
add_line(base, 'CanaryLfsr/1', 'CanaryRef/1', 'autorouting','on');

add_block('simulink/User-Defined Functions/MATLAB Function', [base '/CanaryScore'], ...
    'Position',[520 1580 620 1650]);
set_fcn_script([base '/CanaryScore'], sprintf([ ...
'function y = canaryScore(f2,f3,f4,f5,r2,r3,r4,r5)\n%%#codegen\n' ...
'persistent c2 c3 c4 c5 warm\n' ...
'if isempty(c2), c2=uint8(0); c3=uint8(0); c4=uint8(0); c5=uint8(0); warm=uint8(0); end\n' ...
'if warm < uint8(8)\n  warm = warm + uint8(1);\nelse\n' ...
'  if f2 ~= r2 && c2 < uint8(255), c2 = c2 + uint8(1); end\n' ...
'  if f3 ~= r3 && c3 < uint8(255), c3 = c3 + uint8(1); end\n' ...
'  if f4 ~= r4 && c4 < uint8(255), c4 = c4 + uint8(1); end\n' ...
'  if f5 ~= r5 && c5 < uint8(255), c5 = c5 + uint8(1); end\n' ...
'end\n' ...
'y = bitor(bitor(uint32(c2), bitshift(uint32(c3),8)), ...\n' ...
'          bitor(bitshift(uint32(c4),16), bitshift(uint32(c5),24)));\n']));
for k = 1:4
    add_line(base, sprintf('CanaryFast/%d',k), sprintf('CanaryScore/%d',k), 'autorouting','on');
    add_line(base, sprintf('CanaryRef/%d',k),  sprintf('CanaryScore/%d',k+4), 'autorouting','on');
end
nOut = numel(find_system(base,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
add_block('built-in/Outport', [base '/path_canary'], 'Port', num2str(nOut+1), ...
    'Position',[680 1600 710 1616]);
add_line(base, 'CanaryScore/1', 'path_canary/1', 'autorouting','on');
fprintf('canary2_overlay: path canary (4 graduated chains) at composite level\n');

%% ================= (B) IC shadow (Symbol Synchronizer) =================
icp = [ss '/Interpolation Control'];
cfgIC = get_param(icp, 'MATLABFunctionConfiguration');
add_block('simulink/User-Defined Functions/MATLAB Function', ...
    [ss '/Interpolation Control Shadow'], 'Position',[820 760 940 830]);
% SHADOW-ONLY init compensation: the IC decrements 1/8 EVERY beat regardless
% of input (affine, not linear), so the shadow's one extra leading beat
% (consuming the delay's initial 0) costs exactly one decrement -- a
% PERMANENT mod-1 offset (the beat-2 divergence on images b9955699/6b612fb4).
% Initializing the shadow counter to +1/8 makes the leading beat land it
% exactly on the primary's initial state.
shadowScript = strrep(cfgIC.FunctionScript, ...
    'countReg  = fi(0,1,11,10);', ...
    'countReg  = fi(0.125,1,11,10); %% shadow leading-beat offset compensation');
assert(~strcmp(shadowScript, cfgIC.FunctionScript), 'IC countReg init anchor not found');
set_fcn_script([ss '/Interpolation Control Shadow'], shadowScript);
% Delta delayed 1 beat: reuse T8.5's DlyVP? DlyVP delays LF stateP, NOT v.
% The primary IC input is fed from 'Loop Filter/1' (v). Add a dedicated delay.
add_block('simulink/Discrete/Delay', [ss '/DlyDelta'], 'DelayLength','1', ...
    'Position',[740 770 780 800]);
% feed the shadow from the PRIMARY IC's ACTUAL input source (traced, not
% assumed -- the beat-2 lying-instrument lesson from image b9955699)
lhIC = get_param(icp, 'LineHandles');
srcIC = get_param(lhIC.Inport(1), 'SrcPortHandle');
dphD = get_param([ss '/DlyDelta'], 'PortHandles');
add_line(ss, srcIC, dphD.Inport(1), 'autorouting','on');
add_line(ss, 'DlyDelta/1', 'Interpolation Control Shadow/1', 'autorouting','on');
% primary outputs delayed for compare
add_block('simulink/Discrete/Delay', [ss '/DlyMU'],  'DelayLength','1', 'Position',[740 840 780 870]);
add_line(ss, 'Interpolation Control/1', 'DlyMU/1', 'autorouting','on');
add_block('simulink/Discrete/Delay', [ss '/DlyUND'], 'DelayLength','1', 'Position',[740 880 780 910]);
add_line(ss, 'Interpolation Control/2', 'DlyUND/1', 'autorouting','on');
add_block('simulink/User-Defined Functions/MATLAB Function', [ss '/ShadowScoreIC'], ...
    'Position',[1000 800 1110 880]);
set_fcn_script([ss '/ShadowScoreIC'], sprintf([ ...
'function [divBeat, divCnt] = shadowScoreIC(muP, muS, undP, undS)\n%%#codegen\n' ...
'persistent db dc bt mPrev\n' ...
'if isempty(db), db=uint32(0); dc=uint32(0); bt=uint32(0); mPrev=false; end\n' ...
'bt = bt + uint32(1);\n' ...
'm = (muP ~= muS) || (undP ~= undS);\n' ...
'if m && ~mPrev\n' ...
'  if db == uint32(0), db = bt; end\n' ...
'  if dc < uint32(4294967295), dc = dc + uint32(1); end\n' ...
'end\n' ...
'mPrev = m;\n' ...
'divBeat = db; divCnt = dc;\n']));
add_line(ss, 'DlyMU/1',  'ShadowScoreIC/1', 'autorouting','on');
add_line(ss, 'Interpolation Control Shadow/1', 'ShadowScoreIC/2', 'autorouting','on');
add_line(ss, 'DlyUND/1', 'ShadowScoreIC/3', 'autorouting','on');
add_line(ss, 'Interpolation Control Shadow/2', 'ShadowScoreIC/4', 'autorouting','on');
nSs = numel(find_system(ss,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
add_block('built-in/Outport', [ss '/ic_div_beat'], 'Port', num2str(nSs+1), 'Position',[1150 810 1180 826]);
add_line(ss, 'ShadowScoreIC/1', 'ic_div_beat/1', 'autorouting','on');
add_block('built-in/Outport', [ss '/ic_div_cnt'],  'Port', num2str(nSs+2), 'Position',[1150 850 1180 866]);
add_line(ss, 'ShadowScoreIC/2', 'ic_div_cnt/1', 'autorouting','on');
fprintf('canary2_overlay: IC shadow + score in Symbol Synchronizer\n');

%% ================= (C) carrier LF shadow (Carrier Synchronizer) =================
lf2 = [cs '/Loop Filter'];
ud0 = find_system(lf2,'SearchDepth',1,'Name','Unit Delay Enabled Resettable Synchronous');
ud1 = find_system(lf2,'SearchDepth',1,'Name','Unit Delay Enabled Resettable Synchronous1');
assert(~isempty(ud0) && ~isempty(ud1), 'carrier LF state blocks not found');
nLf2 = numel(find_system(lf2,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
add_block('built-in/Outport', [lf2 '/stateP'], 'Port', num2str(nLf2+1), 'Position',[950 300 980 316]);
add_line(lf2, 'Unit Delay Enabled Resettable Synchronous/1', 'stateP/1', 'autorouting','on');
add_block('built-in/Outport', [lf2 '/stateI'], 'Port', num2str(nLf2+2), 'Position',[950 340 980 356]);
add_line(lf2, 'Unit Delay Enabled Resettable Synchronous1/1', 'stateI/1', 'autorouting','on');

add_block(lf2, [cs '/Loop Filter Shadow'], 'Position',[500 700 620 800]);
% delay ALL FOUR inputs by 1 beat, fed from the primary's own sources
innames = {'DlyE2','DlyVLD2','DlyIRST2','DlyERST2'};
lh2 = get_param(lf2, 'LineHandles');
for k = 1:4
    add_block('simulink/Discrete/Delay', [cs '/' innames{k}], 'DelayLength','1', ...
        'Position',[400 680+40*k 440 705+40*k]);
    srcPH = get_param(lh2.Inport(k), 'SrcPortHandle');
    dph = get_param([cs '/' innames{k}], 'PortHandles');
    add_line(cs, srcPH, dph.Inport(1), 'autorouting','on');
    add_line(cs, [innames{k} '/1'], sprintf('Loop Filter Shadow/%d', k), 'autorouting','on');
end
% primary state taps delayed 1 beat; shadow taps are its (copied) new outports
add_block('simulink/Discrete/Delay', [cs '/DlyPP2'], 'DelayLength','1', 'Position',[700 700 740 730]);
add_line(cs, sprintf('Loop Filter/%d', nLf2+1), 'DlyPP2/1', 'autorouting','on');
add_block('simulink/Discrete/Delay', [cs '/DlyIP2'], 'DelayLength','1', 'Position',[700 740 740 770]);
add_line(cs, sprintf('Loop Filter/%d', nLf2+2), 'DlyIP2/1', 'autorouting','on');
add_block('simulink/User-Defined Functions/MATLAB Function', [cs '/ShadowScoreCS'], ...
    'Position',[820 700 930 790]);
set_fcn_script([cs '/ShadowScoreCS'], sprintf([ ...
'function [divBeat, divCnt] = shadowScoreCS(pP, pS, iP, iS)\n%%#codegen\n' ...
'persistent db dc bt mPrev\n' ...
'if isempty(db), db=uint32(0); dc=uint32(0); bt=uint32(0); mPrev=false; end\n' ...
'bt = bt + uint32(1);\n' ...
'm = (pP ~= pS) || (iP ~= iS);\n' ...
'if m && ~mPrev\n' ...
'  if db == uint32(0), db = bt; end\n' ...
'  if dc < uint32(4294967295), dc = dc + uint32(1); end\n' ...
'end\n' ...
'mPrev = m;\n' ...
'divBeat = db; divCnt = dc;\n']));
add_line(cs, 'DlyPP2/1', 'ShadowScoreCS/1', 'autorouting','on');
add_line(cs, sprintf('Loop Filter Shadow/%d', nLf2+1), 'ShadowScoreCS/2', 'autorouting','on');
add_line(cs, 'DlyIP2/1', 'ShadowScoreCS/3', 'autorouting','on');
add_line(cs, sprintf('Loop Filter Shadow/%d', nLf2+2), 'ShadowScoreCS/4', 'autorouting','on');
fprintf('canary2_overlay: carrier LF shadow + score in Carrier Synchronizer\n');

%% ================= (D) NCO twin replicas: CUT (T8.6.1) =================
% The NcoCanary MLFB failed boolean type propagation twice in gate stage 2;
% as a canary-not-shadow for a library-hidden register it is the lowest-value
% element -- removed from this build. NCO instrumentation returns in a
% recon-first P1b iteration. 0x1A0 stays reserved (reads undefined/0).

%% ================= surface CS-level signals =================
nCs = numel(find_system(cs,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
csnames = {'cs_lf_div_beat','cs_lf_div_cnt'};
cssrc   = {'ShadowScoreCS/1','ShadowScoreCS/2'};
csPorts = zeros(1,2);
for k = 1:2
    add_block('built-in/Outport', [cs '/' csnames{k}], 'Port', num2str(nCs+k), ...
        'Position',[1000 860+34*k 1030 876+34*k]);
    add_line(cs, cssrc{k}, [csnames{k} '/1'], 'autorouting','on');
    csPorts(k) = nCs + k;
end

%% ================= surface through the hierarchy =================
% SS signals (ic_div_beat, ic_div_cnt) start at SS; CS signals start at CS.
groups = { {ss,'Symbol Synchronizer'}, {'ic_div_beat','ic_div_cnt'}, [nSs+1, nSs+2]; ...
           {cs,'Carrier Synchronizer'}, csnames, csPorts };
levels = { fts, ''; qrx, 'Frequency and Time Synchronizer'; ...
           rcv, 'QPSK Rx'; base, 'Receiver' };
for g = 1:size(groups,1)
    childBlk = groups{g,1}{2};
    gnames = groups{g,2};
    childPorts = groups{g,3};
    for L = 1:size(levels,1)
        parent = levels{L,1};
        child = levels{L,2};
        if L == 1, child = childBlk; end
        nOut0 = numel(find_system(parent,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
        newPorts = zeros(1,numel(gnames));
        for k = 1:numel(gnames)
            thisPort = nOut0 + k;
            add_block('built-in/Outport', [parent '/' gnames{k}], ...
                'Port', num2str(thisPort), 'Position',[1120 1300+26*thisPort 1150 1316+26*thisPort]);
            add_line(parent, sprintf('%s/%d', child, childPorts(k)), ...
                [gnames{k} '/1'], 'autorouting','on');
            newPorts(k) = thisPort;
        end
        childPorts = newPorts;
        if L > 1, childBlk = child; end %#ok<NASGU>
        child = levels{L,2}; %#ok<NASGU>
    end
    fprintf('canary2_overlay: surfaced %s through hierarchy\n', strjoin(gnames,','));
end

fprintf('canary2_overlay: DONE (path_canary 0x18C, ic 0x190/0x194, cs_lf 0x198/0x19C; 0x1A0 reserved)\n');
end

% ===================== helpers =====================
function set_fcn_script(blk, src)
rt = sfroot;
chart = rt.find('-isa','Stateflow.EMChart','Path',blk);
chart.Script = src;
end

function s = chainStage()
% one canary stage: 32x32->64 multiply, shift, xor -- DSP + fabric mix
s = ['function y = stg(x, K, C)\n' ...
     'y = bitxor(uint32(bitand(bitshift(uint64(x) * uint64(K), -13), uint64(4294967295))), C);\n'];
end

function src = canaryFast_src()
% full-depth single-cycle chains latched into persistent regs
src = sprintf([ ...
'function [f2,f3,f4,f5] = canaryFast(x)\n%%#codegen\n' ...
'persistent r2 r3 r4 r5\n' ...
'if isempty(r2), r2=uint32(0); r3=uint32(0); r4=uint32(0); r5=uint32(0); end\n' ...
'f2=r2; f3=r3; f4=r4; f5=r5;\n' ...
'a = stg(x, uint32(2654435761), uint32(2166136261));\n' ...
'b = stg(a, uint32(2246822519), uint32(3266489917));\n' ...
'c = stg(b, uint32(3299170593), uint32(668265263));\n' ...
'd = stg(c, uint32(374761393),  uint32(2542024007));\n' ...
'e = stg(d, uint32(2869860233), uint32(1540483477));\n' ...
'r2 = b;\nr3 = c;\nr4 = d;\nr5 = e;\n' ...
'end\n' chainStage() 'end\n']);
end

function src = canaryRef_src()
% identical chains split across TWO cycles (relaxed timing), aligned to Fast
src = sprintf([ ...
'function [r2,r3,r4,r5] = canaryRef(x)\n%%#codegen\n' ...
'persistent m2 m3 m4 m5\n' ...
'if isempty(m2), m2=uint32(0); m3=uint32(0); m4=uint32(0); m5=uint32(0); end\n' ...
'%% second halves (computed on last beat''s midpoints) -- outputs match\n' ...
'%% CanaryFast''s registered outputs beat-for-beat\n' ...
'r2 = stg(m2, uint32(2246822519), uint32(3266489917));\n' ...
'c  = stg(m3, uint32(3299170593), uint32(668265263));\n' ...
'r3 = c;\n' ...
'd  = stg(stg(m4, uint32(3299170593), uint32(668265263)), uint32(374761393), uint32(2542024007));\n' ...
'r4 = d;\n' ...
'e3 = stg(stg(m5, uint32(3299170593), uint32(668265263)), uint32(374761393), uint32(2542024007));\n' ...
'r5 = stg(e3, uint32(2869860233), uint32(1540483477));\n' ...
'%% first halves for NEXT beat\n' ...
'a = stg(x, uint32(2654435761), uint32(2166136261));\n' ...
'b = stg(a, uint32(2246822519), uint32(3266489917));\n' ...
'm2 = a;\nm3 = b;\nm4 = b;\nm5 = b;\n' ...
'end\n' chainStage() 'end\n']);
end
