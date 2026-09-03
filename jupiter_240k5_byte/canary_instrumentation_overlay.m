function canary_instrumentation_overlay(sys, base)
% canary_instrumentation_overlay -- T8.5 SHADOW TIMING LOOP + fabric canaries.
% Directly measures live-vs-deterministic divergence in the symbol-timing
% loop, converting the Class-1 clock/fabric attribution (ERROR_TAXONOMY, by
% elimination) into an on-chip measurement.
%
% Principle: an exact COPY of the (hardened) Loop Filter runs on the same TED
% error DELAYED BY ONE BEAT, so shadowState(k) == primaryState(k-1) bit-for-
% bit in ANY functional simulation, forever. On silicon, a physical
% disturbance (clock-margin erosion at the ADRV9002 tick, metastability,
% upset) strikes both copies at the same wall-clock instant but at different
% state indices -> they diverge -> comparators detect. The 1-beat offset also
% defeats equivalent-register merging in synthesis.
%
% Two comparison tiers:
%   P path (Delay1, 4-beat FIR memory -- self-heals after any upset):
%     counts EVERY upset event + stamps the beat of the last one -> multiple
%     events per session -> direct correlation against the 1.57 s tick.
%   Integrator (Delay, permanent memory): latches the beat and the ACTUAL
%     primary+shadow integrator words at FIRST divergence -- the exact bits
%     that flipped, live vs deterministic.
% Plus: symbol-strobe forensic (max inter-Underflow gap + skipped-strobe
% count; nominal spacing 8 beats, >12 = skipped strobe) and a free-running
% beat counter (host clock-rate cross-check + timestamp correlation).
%
% AXI read regs (hdlworkflow mappings added separately):
%   0x170 shdw_pdiv_cnt   u32  P-path upset events since soft reset
%   0x174 shdw_pdiv_beat  u32  beat stamp of the last P-path event
%   0x178 shdw_idiv_beat  u32  beat of FIRST integrator divergence (0 = none)
%   0x17C shdw_ip_latch   u32  primary integrator raw bits at that beat
%   0x180 shdw_is_latch   u32  shadow integrator raw bits at that beat
%   0x184 strobe_forensic u32  {maxInterStrobeGap[31:16] | skipCnt[15:0]}
%   0x188 beat_counter    u32  free-running rail-beat counter (wraps)
% All state clears on the modem soft reset 0x000 (persistent init / register
% reset), matching the AdcForensic contract. EXPECTATION: every simulation
% and every gate reads pdiv=0, idiv=0 -- any nonzero on hardware is a direct
% observation of non-functional (physical) state corruption.
%
% Apply at assemble Phase 2.12d (after iq_debug_tap_overlay). Idempotent.

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end

rcv = [base '/Receiver'];
qrx = [rcv '/QPSK Rx'];
fts = [qrx '/Frequency and Time Synchronizer'];
ss  = [fts '/Symbol Synchronizer'];
lf  = [ss '/Loop Filter'];

snames = {'shdw_pdiv_cnt','shdw_pdiv_beat','shdw_idiv_beat', ...
          'shdw_ip_latch','shdw_is_latch','strobe_forensic','beat_counter'};

% Idempotency marker
if ~isempty(find_system(base,'SearchDepth',1,'BlockType','Outport','Name',snames{1}))
    fprintf('canary_instrumentation_overlay: already present -- skipping\n');
    return;
end
assert(~isempty(find_system(ss,'SearchDepth',1,'Name','Loop Filter')), ...
    'canary_instrumentation_overlay: Loop Filter not found at %s', ss);
assert(~isempty(find_system(lf,'SearchDepth',1,'Name','IntegClamp')), ...
    'canary_instrumentation_overlay: apply AFTER timing_hardening_overlay (IntegClamp missing)');

% ---- 1. expose primary Loop Filter internals: P-path state + integrator ----
% (HDL-verified: Delay1 = P-path pipeline state, Delay = integrator register)
nLf = numel(find_system(lf,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
assert(nLf == 1, 'Loop Filter expected 1 outport (v), found %d', nLf);
add_block('built-in/Outport', [lf '/stateP'], 'Port', '2', 'Position', [900 200 930 216]);
add_line(lf, 'Delay1/1', 'stateP/1', 'autorouting','on');
add_block('built-in/Outport', [lf '/stateI'], 'Port', '3', 'Position', [900 240 930 256]);
add_line(lf, 'Delay/1', 'stateI/1', 'autorouting','on');
fprintf('canary_instrumentation_overlay: Loop Filter stateP/stateI outports added\n');

% ---- 2. shadow copy of the (hardened, state-tapped) Loop Filter ----
add_block(lf, [ss '/Loop Filter Shadow'], 'Position', [520 640 640 720]);

% feed the shadow from the SAME TED-error source, delayed one beat
lh  = get_param([ss '/Loop Filter'], 'LineHandles');
srcPH = get_param(lh.Inport(1), 'SrcPortHandle');
add_block('simulink/Discrete/Delay', [ss '/ShadowDelayE'], ...
    'DelayLength','1', 'Position', [440 660 480 690]);
dph = get_param([ss '/ShadowDelayE'], 'PortHandles');
add_line(ss, srcPH, dph.Inport(1), 'autorouting','on');
add_line(ss, 'ShadowDelayE/1', 'Loop Filter Shadow/1', 'autorouting','on');

% 1-beat delays on the PRIMARY taps so both compare legs are time-aligned
add_block('simulink/Discrete/Delay', [ss '/DlyPP'], 'DelayLength','1', 'Position', [700 600 740 630]);
add_line(ss, 'Loop Filter/2', 'DlyPP/1', 'autorouting','on');
add_block('simulink/Discrete/Delay', [ss '/DlyIP'], 'DelayLength','1', 'Position', [700 560 740 590]);
add_line(ss, 'Loop Filter/3', 'DlyIP/1', 'autorouting','on');
fprintf('canary_instrumentation_overlay: shadow Loop Filter + alignment delays wired\n');

% ---- 3. ShadowScore bookkeeping MLFB ----
add_block('simulink/User-Defined Functions/MATLAB Function', [ss '/ShadowScore'], ...
    'Position', [820 560 960 700]);
set_fcn_script([ss '/ShadowScore'], shadowScore_src());
add_line(ss, 'DlyPP/1',              'ShadowScore/1', 'autorouting','on');
add_line(ss, 'Loop Filter Shadow/2', 'ShadowScore/2', 'autorouting','on');
add_line(ss, 'DlyIP/1',              'ShadowScore/3', 'autorouting','on');
add_line(ss, 'Loop Filter Shadow/3', 'ShadowScore/4', 'autorouting','on');
add_line(ss, 'Interpolation Control/2', 'ShadowScore/5', 'autorouting','on');  % Underflow strobe

% ---- 4. Symbol Synchronizer outports ----
nSs0 = numel(find_system(ss,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
ssPorts = zeros(1,7);
for k = 1:7
    thisPort = nSs0 + k;
    add_block('built-in/Outport', [ss '/' snames{k}], 'Port', num2str(thisPort), ...
        'Position', [1000 540+30*k 1030 556+30*k]);
    add_line(ss, sprintf('ShadowScore/%d', k), [snames{k} '/1'], 'autorouting','on');
    ssPorts(k) = thisPort;
end
fprintf('canary_instrumentation_overlay: ShadowScore + 7 SS outports (ports %s)\n', mat2str(ssPorts));

% ---- 5. surface: SS -> FTS -> QPSK Rx -> Receiver -> TxRxComposite ----
levels = { fts, 'Symbol Synchronizer'; qrx, 'Frequency and Time Synchronizer'; ...
           rcv, 'QPSK Rx'; base, 'Receiver' };
childPorts = ssPorts;
for L = 1:size(levels,1)
    parent = levels{L,1};
    child  = levels{L,2};
    nOut0 = numel(find_system(parent,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
    newPorts = zeros(1,7);
    for k = 1:7
        thisPort = nOut0 + k;
        add_block('built-in/Outport', [parent '/' snames{k}], ...
            'Port', num2str(thisPort), 'Position', [1050 1100+28*thisPort 1080 1116+28*thisPort]);
        add_line(parent, sprintf('%s/%d', child, childPorts(k)), ...
            [snames{k} '/1'], 'autorouting','on');
        newPorts(k) = thisPort;
    end
    childPorts = newPorts;
    fprintf('canary_instrumentation_overlay: surfaced through %s (ports %s)\n', ...
        parent, mat2str(newPorts));
end

fprintf(['canary_instrumentation_overlay: DONE -- shadow loop + canaries live ' ...
         '(AXI 0x170-0x188 via hdlworkflow)\n']);
end

% ===================== helpers =====================
function set_fcn_script(blk, src)
rt = sfroot;
chart = rt.find('-isa','Stateflow.EMChart','Path',blk);
chart.Script = src;
end

function src = shadowScore_src()
% Bookkeeping only -- no signal arithmetic. pP/iP are the PRIMARY taps
% delayed 1 beat; pS/iS the shadow's (which runs on e delayed 1 beat), so in
% any functional simulation pP==pS and iP==iS on EVERY beat, by construction.
src = sprintf([ ...
'function [pdivCnt,pdivBeat,idivBeat,ipLatch,isLatch,strobeFor,beatCnt] = shadowScore(pP,pS,iP,iS,und)\n' ...
'%%#codegen\n' ...
'persistent pc pb ib ipl isl mg sk gap bt pmPrev\n' ...
'if isempty(pc)\n' ...
'  pc=uint32(0); pb=uint32(0); ib=uint32(0); ipl=uint32(0); isl=uint32(0);\n' ...
'  mg=uint16(0); sk=uint16(0); gap=uint16(0); bt=uint32(0); pmPrev=false;\n' ...
'end\n' ...
'bt = bt + uint32(1);\n' ...
'%% P-path upset events (FIR memory self-heals -> every upset = one edge)\n' ...
'pm = (pP ~= pS);\n' ...
'if pm && ~pmPrev\n' ...
'  pc = pc + uint32(1); pb = bt;\n' ...
'end\n' ...
'pmPrev = pm;\n' ...
'%% first integrator divergence: latch beat + both raw state words\n' ...
'if ib == uint32(0) && (iP ~= iS)\n' ...
'  ib = bt;\n' ...
'  ipl = uint32(reinterpretcast(iP, numerictype(0,30,0)));\n' ...
'  isl = uint32(reinterpretcast(iS, numerictype(0,30,0)));\n' ...
'end\n' ...
'%% symbol-strobe forensic (nominal Underflow spacing 8 beats; >12 = skip)\n' ...
'if gap < uint16(65535), gap = gap + uint16(1); end\n' ...
'if und\n' ...
'  if gap > mg, mg = gap; end\n' ...
'  if gap > uint16(12) && sk < uint16(65535), sk = sk + uint16(1); end\n' ...
'  gap = uint16(0);\n' ...
'end\n' ...
'pdivCnt = pc; pdivBeat = pb; idivBeat = ib; ipLatch = ipl; isLatch = isl;\n' ...
'strobeFor = bitor(bitshift(uint32(mg),16), uint32(sk));\n' ...
'beatCnt = bt;\n']);
end
