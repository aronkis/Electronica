function p1e_comp_overlay(sys, base)
% p1e_comp_overlay -- HDL compensation for the 148 tick +32-symbol displacement.
%
% Mechanism (proven bit-true in the splice testbench, /dev/shm/hdlproto hdlD2):
% at each ~1.5 s ADRV9002 housekeeping tick, unit 148 inserts 256 samples
% (+32 symbols) into the delivered stream.  The Timing Adjust fires the
% stale-grid window's start pulse 32 symbols early in data terms BEFORE the
% displaced preamble can be reported (the report only comes at window wrap),
% so one frame per insert transition is written into the deinterleaver 64
% coded-bits shifted and lost.  Compensation:
%
%   arm    : at newPk time in Timing Adjust, d = (psTref - accOff) mod 1133
%            == 32.  The arm precedes the stale window's deint startIn by
%            (PD FIFO transit - 32) symbols + demod latency -- an invariant
%            that holds in both the RTL sim and live clocking, so the pending
%            skip is always consumed by the correct (stale-grid) window.
%   cancel : freshest-newPk-wins (a later newPk with d ~= 32 clears) plus a
%            report-time backstop (timingOffsetValid with report delta ~= 32);
%            a set/clr collision resolves to clear = safe no-skip default.
%   consume: RxDeint skips the 64 stale head write-bits at the next startIn.
%            The stale window's 2240-bit span is [64 stale][2176 true]; the
%            skip moves the write capture from [0..2175] to [64..2239] = the
%            displaced frame's coded bits exactly.
%
% Recovers the stale-grid casualty (one frame per insert transition,
% unconditionally).  The mosaic window containing the physical insertion is
% information-theoretically unrecoverable and stays lost.  The -32 recovery
% transition is benign in the live census (zero loss) and never arms (d=1101).
%
% Apply AFTER p1d_pd_telemetry_overlay (reuses its surfaced Peak Search
% outports) and AFTER fec_insert_overlay_rxonly_k5 (patches the RxDeint MLFB).
% Idempotent.

if nargin < 1, sys = bdroot; end %#ok<NASGU>
if nargin < 2 || isempty(base), base = sys; end

qrx = [base '/Receiver/QPSK Rx'];
fts = [qrx '/Frequency and Time Synchronizer'];
pd  = [fts '/Preamble Detector'];
ps  = [pd '/Peak Search'];
ta  = [pd '/Timing Adjust'];
dec = [qrx '/FEC Decoder Wrapper'];

lo = 'LookUnderMasks';

if ~isempty(find_system(ta,'SearchDepth',1,lo,'all','FollowLinks','on','Name','P1eArm'))
    fprintf('p1e_comp_overlay: already present -- skipping\n');
    return;
end

% ---------- 1. Peak Search surfaced ports (created by the p1d overlay) ----------
trefPort  = str2double(get_param([ps '/p1c_tref'],  'Port'));
newpkPort = str2double(get_param([ps '/p1c_newpk'], 'Port'));
assert(~isnan(trefPort) && ~isnan(newpkPort), 'p1e: p1d PS ports missing');

% ---------- 2. Timing Adjust: inports + P1eArm MLFB + set/clr outports ----------
taIn  = find_system(ta,'SearchDepth',1,lo,'all','BlockType','Inport');
taOut = find_system(ta,'SearchDepth',1,lo,'all','BlockType','Outport');
nTaIn = numel(taIn); nTaOut = numel(taOut);

% locate TA inports 1 (timingOffset) and 2 (timingOffsetValid) by port number
inp1 = ''; inp2 = '';
for k = 1:nTaIn
    p = get_param(taIn{k}, 'Port');
    if strcmp(p, '1'), inp1 = get_param(taIn{k}, 'Name'); end
    if strcmp(p, '2'), inp2 = get_param(taIn{k}, 'Name'); end
end
assert(~isempty(inp1) && ~isempty(inp2), 'p1e: TA inports 1/2 not found');

add_block('built-in/Inport', [ta '/psTref'],  'Port', num2str(nTaIn+1), ...
    'Position', [40 620 70 636]);
add_block('built-in/Inport', [ta '/psNewpk'], 'Port', num2str(nTaIn+2), ...
    'Position', [40 660 70 676]);

add_block('simulink/User-Defined Functions/MATLAB Function', [ta '/P1eArm'], ...
    'Position', [220 600 360 720]);
set_fcn_script([ta '/P1eArm'], p1eArm_src());

nlc = sprintf('\n');
accBlk = ['Unit Delay Enabled' nlc 'Synchronous3'];   % accOff register (p1d-proven name)

add_line(ta, 'psTref/1',       'P1eArm/1', 'autorouting','on');
add_line(ta, 'psNewpk/1',      'P1eArm/2', 'autorouting','on');
add_line(ta, [inp1 '/1'],      'P1eArm/3', 'autorouting','on');   % timingOffset
add_line(ta, [inp2 '/1'],      'P1eArm/4', 'autorouting','on');   % timingOffsetValid
add_line(ta, [accBlk '/1'],    'P1eArm/5', 'autorouting','on');   % accOff

add_block('built-in/Outport', [ta '/p1e_set'], 'Port', num2str(nTaOut+1), ...
    'Position', [420 620 450 636]);
add_block('built-in/Outport', [ta '/p1e_clr'], 'Port', num2str(nTaOut+2), ...
    'Position', [420 660 450 676]);
add_line(ta, 'P1eArm/1', 'p1e_set/1', 'autorouting','on');
add_line(ta, 'P1eArm/2', 'p1e_clr/1', 'autorouting','on');
fprintf('p1e: Timing Adjust P1eArm inserted (TA in %d->%d, out %d->%d)\n', ...
    nTaIn, nTaIn+2, nTaOut, nTaOut+2);

% ---------- 3. PD level: PS -> TA feeds, TA -> PD outports ----------
add_line(pd, sprintf('Peak Search/%d', trefPort),  sprintf('Timing Adjust/%d', nTaIn+1), 'autorouting','on');
add_line(pd, sprintf('Peak Search/%d', newpkPort), sprintf('Timing Adjust/%d', nTaIn+2), 'autorouting','on');

nPdOut = numel(find_system(pd,'SearchDepth',1,lo,'all','BlockType','Outport'));
add_block('built-in/Outport', [pd '/p1e_set'], 'Port', num2str(nPdOut+1), ...
    'Position', [1500 1000 1530 1016]);
add_block('built-in/Outport', [pd '/p1e_clr'], 'Port', num2str(nPdOut+2), ...
    'Position', [1500 1040 1530 1056]);
add_line(pd, sprintf('Timing Adjust/%d', nTaOut+1), 'p1e_set/1', 'autorouting','on');
add_line(pd, sprintf('Timing Adjust/%d', nTaOut+2), 'p1e_clr/1', 'autorouting','on');

% ---------- 4. FTS level: PD -> FTS outports ----------
nFtsOut = numel(find_system(fts,'SearchDepth',1,lo,'all','BlockType','Outport'));
add_block('built-in/Outport', [fts '/p1e_set'], 'Port', num2str(nFtsOut+1), ...
    'Position', [1500 1000 1530 1016]);
add_block('built-in/Outport', [fts '/p1e_clr'], 'Port', num2str(nFtsOut+2), ...
    'Position', [1500 1040 1530 1056]);
add_line(fts, sprintf('Preamble Detector/%d', nPdOut+1), 'p1e_set/1', 'autorouting','on');
add_line(fts, sprintf('Preamble Detector/%d', nPdOut+2), 'p1e_clr/1', 'autorouting','on');
fprintf('p1e: set/clr routed PD -> FTS (FTS out %d->%d)\n', nFtsOut, nFtsOut+2);

% ---------- 5. FEC Decoder Wrapper: inports -> RxDeint ----------
nDecIn = numel(find_system(dec,'SearchDepth',1,lo,'all','BlockType','Inport'));
add_block('built-in/Inport', [dec '/p1eSet'], 'Port', num2str(nDecIn+1), ...
    'Position', [40 400 70 416]);
add_block('built-in/Inport', [dec '/p1eClr'], 'Port', num2str(nDecIn+2), ...
    'Position', [40 440 70 456]);

% ---------- 6. RxDeint MLFB: pend/skip logic (bit-true mirror of hdlD2) ----------
rt = sfroot;
chart = rt.find('-isa','Stateflow.EMChart','Path',[dec '/RxDeint']);
assert(~isempty(chart), 'p1e: RxDeint chart not found');
src = chart.Script;
src = rep1(src, 'fecRxDeint(dataIn, startIn, endIn, validIn)', ...
                'fecRxDeint(dataIn, startIn, endIn, validIn, setIn, clrIn)');
src = rep1(src, 'persistent ramA ramB rdBank wptr pcnt hold0 hold1 rdGate;', ...
                'persistent ramA ramB rdBank wptr pcnt hold0 hold1 rdGate skipCnt pendD;');
src = rep1(src, 'hold0=false; hold1=false; rdGate=false; end', ...
                'hold0=false; hold1=false; rdGate=false; skipCnt=uint16(0); pendD=false; end');
src = rep1(src, 'rb=rdBank; w=wptr; pc=pcnt; g=rdGate; h0=hold0; h1=hold1;', ...
                ['rb=rdBank; w=wptr; pc=pcnt; g=rdGate; h0=hold0; h1=hold1;' nlc ...
                 'skc=skipCnt; pend=(pendD || logical(setIn)) && ~logical(clrIn);']);
src = rep1(src, 'if startIn, w=uint16(0); pc=uint16(0); rb=~rb; g=true; end', ...
                ['if startIn, w=uint16(0); pc=uint16(0); rb=~rb; g=true; ' ...
                 'if pend, skc=uint16(64); pend=false; else, skc=uint16(0); end, end']);
src = rep1(src, ['  if w < CODED' nlc], ...
                ['  if skc > uint16(0)' nlc '    skc = skc - uint16(1);' nlc ...
                 '  elseif w < CODED' nlc]);
src = rep1(src, 'rdBank=rb; wptr=w; pcnt=pc; rdGate=g; hold0=h0; hold1=h1;', ...
                'rdBank=rb; wptr=w; pcnt=pc; rdGate=g; hold0=h0; hold1=h1; skipCnt=skc; pendD=pend;');
chart.Script = src;
fprintf('p1e: RxDeint pend/skip logic patched\n');

add_line(dec, 'p1eSet/1', 'RxDeint/5', 'autorouting','on');
add_line(dec, 'p1eClr/1', 'RxDeint/6', 'autorouting','on');

% ---------- 7. QPSK Rx level: FTS -> FEC Decoder Wrapper ----------
add_line(qrx, sprintf('Frequency and Time Synchronizer/%d', nFtsOut+1), ...
    sprintf('FEC Decoder Wrapper/%d', nDecIn+1), 'autorouting','on');
add_line(qrx, sprintf('Frequency and Time Synchronizer/%d', nFtsOut+2), ...
    sprintf('FEC Decoder Wrapper/%d', nDecIn+2), 'autorouting','on');
fprintf('p1e_comp_overlay: complete (FTS %d/%d -> FEC wrapper %d/%d)\n', ...
    nFtsOut+1, nFtsOut+2, nDecIn+1, nDecIn+2);
end

% =========================================================================
function src = p1eArm_src()
% Registered outputs (persistent-read-first) = one-beat delay, identical to
% the hdlD2 netlist p1e_set_r/p1e_clr_r registers.
src = [ ...
'function [setOut, clrOut] = p1eArm(psTref, psNewpk, timingOffset, timingOffsetValid, accOff)' 10 ...
'%#codegen' 10 ...
'persistent setR clrR;' 10 ...
'if isempty(setR), setR=false; clrR=false; end' 10 ...
'setOut = setR; clrOut = clrR;' 10 ...
'tr = uint16(psTref); ac = uint16(accOff); to = uint16(timingOffset);' 10 ...
'if tr >= ac, d2 = tr - ac; else, d2 = (tr + uint16(1133)) - ac; end' 10 ...
'if to >= ac, d1 = to - ac; else, d1 = (to + uint16(1133)) - ac; end' 10 ...
'npk = logical(psNewpk); tov = logical(timingOffsetValid);' 10 ...
'% v3 qualifier: arm only when the displaced window''s fire is provably' 10 ...
'% stale (fire at acc + FIFO transit 566 sym precedes the wrap report at' 10 ...
'% 1132 -> acc <= 530 with margin).  Late-acc windows are re-anchored by' 10 ...
'% the freshest-offset fix already; skipping them is the proven harm case' 10 ...
'% (two-capture 6-phase sweeps: acc=454 help 6/6, acc=875 harm 6/6).' 10 ...
'% A missed arm falls back to stock behavior (safe).' 10 ...
'setR = npk && (d2 == uint16(32)) && (ac <= uint16(530));' 10 ...
'clrR = (npk && (d2 ~= uint16(32))) || (tov && (d1 ~= uint16(32)));' 10 ...
];
end

function s = rep1(s, old, new)
n = length(strfind(s, old));
assert(n == 1, 'p1e rep1: pattern x%d (want 1): %s', n, old);
s = strrep(s, old, new);
end

function set_fcn_script(blk, src)
rt = sfroot; chart = rt.find('-isa','Stateflow.EMChart','Path',blk); chart.Script = src;
end
