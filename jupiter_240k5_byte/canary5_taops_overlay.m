function canary5_taops_overlay(sys, base)
% canary5_taops_overlay -- T8.8: SyncPulse COMPARISON OPERAND exposure.
% Purpose: finish the stall localization. Everything upstream is exonerated
% live (T8.5 canaries: no shadow-loop tear, no enable starvation, through
% hundreds of 26-37ms 0x104 freezes). The one remaining suspect is the
% SyncPulse fire condition itself (Timing_Adjust.v:153):
%     fire = (timing_Reference == Unit_Delay_Enabled_Synchronous3)
% a STRICT equality between the wrapping 0..12332 counter and the latched
% Peak_Search report capture. This overlay makes both operands (plus the
% Peak Search source report) AXI-readable, with an in-fabric
% beats-since-last-match counter, so ONE register read mid-freeze tells us
% which operand is wrong and by how much.
%
% AXI read regs (hdlworkflow mappings added separately, block-guarded):
%   0x1E0 ta_ops  u32  {timing_Reference[13:0] << 14 | Unit_Delay_En_Sync3[13:0]}
%                      (single atomic read captures BOTH equality operands)
%   0x1E4 ta_diag u32  {beatsSinceMatch[15:0] << 16 | PeakSearch tref[13:0]}
%                      (beatsSinceMatch saturates at 65535; healthy value
%                       always < ~790 beats = one frame period)
% EXPECTATION: in every functional sim beatsSinceMatch < 790 forever. On
% hardware mid-freeze: beatsSinceMatch large, and ta_ops shows the exact
% operand pair that never matches.
%
% Apply after canary_instrumentation_overlay (independent; both PD-level).
% Idempotent. Clone of the proven p1d surfacing + canary MLFB idioms.

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end

rcv = [base '/Receiver'];
qrx = [rcv '/QPSK Rx'];
fts = [qrx '/Frequency and Time Synchronizer'];
pd  = [fts '/Preamble Detector'];
ps  = [pd '/Peak Search'];
ta  = [pd '/Timing Adjust'];

snames = {'ta_ops','ta_diag'};
lo = 'LookUnderMasks';
nl = sprintf('\n');

% Idempotency marker
if ~isempty(find_system(base,'SearchDepth',1,'BlockType','Outport','Name',snames{1}))
    fprintf('canary5_taops_overlay: already present -- skipping\n');
    return;
end
assert(~isempty(find_system(pd,'SearchDepth',1,'Name','Timing Adjust')), ...
    'canary5_taops_overlay: Timing Adjust not found at %s', pd);

% ---- 1. surface the two TA equality operands ----
nTa = numel(find_system(ta,'SearchDepth',1,lo,'all','BlockType','Outport'));
taAdd = { ...
    'timing Reference',                        'c5_taref'; ...
    ['Unit Delay Enabled' nl 'Synchronous3'],  'c5_udel3'};
for k = 1:size(taAdd,1)
    add_block('built-in/Outport',[ta '/' taAdd{k,2}],'Port',num2str(nTa+k), ...
        'Position',[1400 500+30*k 1430 516+30*k]);
    add_line(ta, [taAdd{k,1} '/1'], [taAdd{k,2} '/1'], 'autorouting','on');
end
taPorts = nTa + (1:size(taAdd,1));
fprintf('canary5: Timing Adjust operands surfaced (ports %s)\n', mat2str(taPorts));

% ---- 2. surface the Peak Search report source ----
nPs = numel(find_system(ps,'SearchDepth',1,lo,'all','BlockType','Outport'));
add_block('built-in/Outport',[ps '/c5_psref'],'Port',num2str(nPs+1), ...
    'Position',[1400 500 1430 516]);
add_line(ps, 'timing Reference/1', 'c5_psref/1', 'autorouting','on');
fprintf('canary5: Peak Search tref surfaced (port %d)\n', nPs+1);

% ---- 3. TaOps packer MLFB at PD level ----
add_block('simulink/User-Defined Functions/MATLAB Function',[pd '/TaOpsPack'], ...
    'Position',[1500 1000 1650 1120]);
set_fcn_script([pd '/TaOpsPack'], taOpsPack_src());
add_line(pd, sprintf('Timing Adjust/%d', taPorts(1)), 'TaOpsPack/1', 'autorouting','on');
add_line(pd, sprintf('Timing Adjust/%d', taPorts(2)), 'TaOpsPack/2', 'autorouting','on');
add_line(pd, sprintf('Peak Search/%d',   nPs+1),      'TaOpsPack/3', 'autorouting','on');

% ---- 4. PD outports ----
nPd0 = numel(find_system(pd,'SearchDepth',1,lo,'all','BlockType','Outport'));
pdPorts = zeros(1,2);
for k = 1:2
    add_block('built-in/Outport', [pd '/' snames{k}], 'Port', num2str(nPd0+k), ...
        'Position',[1700 1000+30*k 1730 1016+30*k]);
    add_line(pd, sprintf('TaOpsPack/%d', k), [snames{k} '/1'], 'autorouting','on');
    pdPorts(k) = nPd0+k;
end

% ---- 5. surface: PD -> FTS -> QPSK Rx -> Receiver -> TxRxComposite ----
levels = { fts, 'Preamble Detector'; qrx, 'Frequency and Time Synchronizer'; ...
           rcv, 'QPSK Rx'; base, 'Receiver' };
childPorts = pdPorts;
for L = 1:size(levels,1)
    parent = levels{L,1};
    child  = levels{L,2};
    nOut0 = numel(find_system(parent,'SearchDepth',1,lo,'all','BlockType','Outport'));
    newPorts = zeros(1,2);
    for k = 1:2
        thisPort = nOut0 + k;
        add_block('built-in/Outport', [parent '/' snames{k}], ...
            'Port', num2str(thisPort), 'Position', [1080 1400+28*thisPort 1110 1416+28*thisPort]);
        add_line(parent, sprintf('%s/%d', child, childPorts(k)), ...
            [snames{k} '/1'], 'autorouting','on');
        newPorts(k) = thisPort;
    end
    childPorts = newPorts;
    fprintf('canary5: surfaced through %s (ports %s)\n', parent, mat2str(newPorts));
end

fprintf('canary5_taops_overlay: DONE -- SyncPulse operands live (AXI 0x1E0-0x1E4)\n');
end

% ===================== helpers =====================
function set_fcn_script(blk, src)
rt = sfroot;
chart = rt.find('-isa','Stateflow.EMChart','Path',blk);
chart.Script = src;
end

function src = taOpsPack_src()
% Pure packing + a beats-since-last-match saturating counter. No effect on
% the datapath; every functional sim shows bsm < ~790 (one frame period).
src = sprintf([ ...
'function [taOps, taDiag] = taOpsPack(taref, udel3, psref)\n' ...
'%%#codegen\n' ...
'persistent bsm\n' ...
'if isempty(bsm), bsm = uint16(0); end\n' ...
'a = uint32(taref); b = uint32(udel3); p = uint32(psref);\n' ...
'if a == b\n' ...
'  bsm = uint16(0);\n' ...
'elseif bsm < uint16(65535)\n' ...
'  bsm = bsm + uint16(1);\n' ...
'end\n' ...
'taOps  = bitor(bitshift(bitand(a, uint32(16383)), 14), bitand(b, uint32(16383)));\n' ...
'taDiag = bitor(bitshift(uint32(bsm), 16), bitand(p, uint32(16383)));\n']);
end
