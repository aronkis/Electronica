function taps_240k5_overlay(sys, base)
% taps_240k5_overlay -- zed_240k5 Rx OBSERVABILITY TAPS (design 4.3).
% ZED ADAPTATION of jupiter_240k5/taps_240k5_overlay.m: the two tap REGISTERS
% ONLY -- the jupiter capture-DMA retarget (its section 4) is DELIBERATELY
% OMITTED on this board per the task's resource-diet constraint (and the zed
% composite's debugI1/Q1 already carry the Receiver's own debug taps per
% build_composite_local.m; nothing is rewired here).
%
% Adds two new AXI READ registers (offsets in the reserved gap above 0x14C):
%
%   0x150 rstcs_count : free-running uint32 counter of RISING EDGES of the
%         CFO-step-detector carrier-sync reset -- the INTERNAL rstCS, i.e.
%         the 'Coarse Frequency Compensator' outport 3 signal that feeds
%         Carrier Synchronizer/3 (internalRst). This is the signal gated by
%         the CFOChangeDetectThreshold compare blocks (fi +-thr,1,22,21).
%         The host 0x110 rstCS (manualRst, CS port 4) is NOT counted.
%         Reset by the modem soft-reset 0x000 (persistent -> sync reset).
%         (VERIFIED on this model: CarrierSync in3 <- CFC/3, in4 <- rstCS.)
%
%   0x154 cfc_est : latest Coarse Frequency Compensator normalized frequency
%         estimate (FTS outport 8 'normCoarseFreqEst', sfix21_En21 --
%         VERIFIED FTS outport list on this model), REGISTERED (Delay 1) and
%         exposed as the raw stored integer: host decodes
%         normEst = double(typecast(uint32(reg),'int32'))/2^21.
%
% Apply AFTER fec_insert/counters/skipreg/capture/nodescr, BEFORE codegen.
% Idempotent.

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
loop = base;
rcv  = [loop '/Receiver'];
qrx  = [loop '/Receiver/QPSK Rx'];
fts  = [qrx '/Frequency and Time Synchronizer'];

% Idempotency marker
if ~isempty(find_system(loop,'SearchDepth',1,'BlockType','Outport','Name','rstcs_count'))
    fprintf('taps_240k5_overlay: taps already present -- skipping\n');
    return;
end
assert(~isempty(find_system(fts,'SearchDepth',0)), 'FTS not found at %s', fts);

% ============================================================================
% (1) Inside FTS: surface the CFO-step-detector reset (CFC outport 3, the
%     line CFC/3 -> Carrier Synchronizer/3) on a new FTS outport 'rstcsDet'.
%     normCoarseFreqEst is ALREADY FTS outport 8 -- no FTS edit needed for it.
% ============================================================================
nOutFts = numel(find_system(fts,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
ftsDetPort = nOutFts + 1;   % expected 9
add_block('built-in/Outport', [fts '/rstcsDet'], 'Port', num2str(ftsDetPort), ...
    'Position',[1050 40+40*ftsDetPort 1080 60+40*ftsDetPort]);
add_line(fts, 'Coarse Frequency Compensator/2', 'rstcsDet/1', 'autorouting','on'); % RXROOT F1 fix: CFC/2 = rstCS (CFC/3 is validOut -- old wiring counted symbol strobes, the on-chip "rstcs storm" was this miswire)
fprintf('taps_240k5_overlay: FTS rstcsDet outport %d <- Coarse Frequency Compensator/2 (rstCS)\n', ftsDetPort);

% ============================================================================
% (2) Inside QPSK Rx: rising-edge counter + registered SI capture of the est.
% ============================================================================
% (2a) RstCsCounter MATLAB Function
add_block('simulink/User-Defined Functions/MATLAB Function', [qrx '/RstCsCounter'], ...
    'Position',[900 1100 1000 1160]);
set_fcn_script([qrx '/RstCsCounter'], sprintf([ ...
'function c = rstCsCount(e)\n' ...
'%%#codegen\n' ...
'%% Count RISING EDGES of the CFO-step-detector carrier-sync reset (AXI 0x150).\n' ...
'%% Saturating; reset by the modem soft-reset 0x000 via the persistent init.\n' ...
'persistent prev cnt;\n' ...
'if isempty(prev), prev = false; cnt = uint32(0); end\n' ...
'n = cnt;\n' ...  %% sync-semantics compliant: locals, persist last (RXROOT E11c)
'if e && ~prev && n < uint32(4294967295)\n' ...
'    n = n + uint32(1);\n' ...
'end\n' ...
'c = n;\n' ...
'cnt = n;\n' ...
'prev = logical(e);\n']));
add_line(qrx, sprintf('Frequency and Time Synchronizer/%d', ftsDetPort), ...
    'RstCsCounter/1', 'autorouting','on');

% (2b) cfc_est: FTS/8 (normCoarseFreqEst) -> SI reinterpret to uint32 -> Delay(1)
add_block('built-in/DataTypeConversion', [qrx '/CfcEstSI'], ...
    'OutDataTypeStr','uint32', 'ConvertRealWorld','Stored Integer (SI)', ...
    'Position',[900 1200 950 1230]);
add_block('built-in/Delay', [qrx '/CfcEstReg'], 'DelayLength','1', ...
    'Position',[970 1200 1000 1230]);
add_line(qrx, 'Frequency and Time Synchronizer/8', 'CfcEstSI/1', 'autorouting','on');
add_line(qrx, 'CfcEstSI/1', 'CfcEstReg/1', 'autorouting','on');

% (2c) new QPSK Rx outports (explicit port tracking, counters-overlay style)
tap_names = {'rstcs_count','cfc_est'};
tap_srcs  = {'RstCsCounter/1','CfcEstReg/1'};
nOutQ = numel(find_system(qrx,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
childTapPorts = (nOutQ+1):(nOutQ+2);
for k = 1:2
    add_block('built-in/Outport', [qrx '/' tap_names{k}], ...
        'Port', num2str(childTapPorts(k)), 'Position',[1050 1100+40*k 1080 1116+40*k]);
    add_line(qrx, tap_srcs{k}, [tap_names{k} '/1'], 'autorouting','on');
end
fprintf('taps_240k5_overlay: QPSK Rx rstcs_count/cfc_est outports %s\n', mat2str(childTapPorts));

% ============================================================================
% (3) Surface through Receiver -> TxRxComposite (counters-overlay pattern).
% ============================================================================
levels = { rcv, 'QPSK Rx'; loop, 'Receiver' };
for L = 1:size(levels,1)
    parent = levels{L,1};
    child  = levels{L,2};
    nOut0 = numel(find_system(parent,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
    newPorts = zeros(1,2);
    for k = 1:2
        thisPort = nOut0 + k;
        add_block('built-in/Outport', [parent '/' tap_names{k}], ...
            'Port', num2str(thisPort), 'Position',[1100 1100+30*thisPort 1130 1116+30*thisPort]);
        add_line(parent, sprintf('%s/%d', child, childTapPorts(k)), ...
            [tap_names{k} '/1'], 'autorouting','on');
        newPorts(k) = thisPort;
    end
    childTapPorts = newPorts;
    fprintf('taps_240k5_overlay: surfaced taps through %s (out-ports %s)\n', parent, mat2str(newPorts));
end

% (4) capture retarget: OMITTED on the zed build (resource-diet task
%     constraint: taps are the two registers ONLY; debugI1/Q1 keep their
%     stock build_composite_local wiring to the Receiver debug taps).
fprintf('taps_240k5_overlay: capture retarget SKIPPED (zed diet: registers only)\n');

fprintf('taps_240k5_overlay: DONE -- rstcs_count@0x150 + cfc_est@0x154 outports on TxRxComposite\n');
end

% ===================== helpers =====================
function set_fcn_script(blk, src)
rt = sfroot;
chart = rt.find('-isa','Stateflow.EMChart','Path',blk);
chart.Script = src;
end
