function movsum_hardening_overlay(sys, base)
% movsum_hardening_overlay -- T8.9: corruption-tolerant preamble threshold sum.
% ROOT CAUSE (task #13/#15, confirmed on silicon 2026-08-04): the Correlator's
% Magnitude Squared and Moving Sum computes E1 via a RECURSIVE accumulator
% (Delay14: acc += new - oldest). Any physical upset of Delay14 persists
% FOREVER (the windowed-difference stream is oblivious to an offset): upset
% magnitude selects the phenotype -- >=+2^29 = 5..100-frame sputter stalls
% (the deployed image's class), >=+2^30 = permanent mute until re-arm. Live
% FROZEN-class mutes showed the exact signature (accepted Peak report frozen
% 180-650 frames, Peak searching, delivery gated).
%
% FIX: replace the E1 derivation with a NON-RECURSIVE direct sum -- a parallel
% 12-deep enabled tap chain off Delay4 (mirroring the 13-deep window Delay),
% a 13-input wrap-exact Sum, and a 1-beat alignment register matching Delay5's
% phase; Delay11 (the 11-deep E1 output pipeline) is re-routed to it. The
% recursive loop (Add/Delay5/Add1/Delay14) is left in place but drives nothing.
% Feedforward-only => ANY state corruption flushes within 13 valid samples
% (~0.9 us) instead of persisting. Output is bit-exact with the recursion in
% uncorrupted operation (identical zero reset state, same enable phase, exact
% integer adds); verified by netlist A/B in the harness.
%
% Env-gated at assemble via QPSK_MOVSUM_HARDEN=1. Idempotent. No AXI regs.

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end

ms = [base '/Receiver/QPSK Rx/Frequency and Time Synchronizer/' ...
      'Preamble Detector/Correlator/Magnitude Squared and Moving Sum'];

if ~isempty(find_system(ms,'SearchDepth',1,'Name','HardSum'))
    fprintf('movsum_hardening_overlay: already present -- skipping\n');
    return;
end
assert(~isempty(find_system(ms,'SearchDepth',1,'Name','Delay14')), ...
    'movsum_hardening_overlay: Delay14 not found at %s', ms);

d4  = [ms '/Delay4'];
win = [ms '/Delay'];      % the 13-deep window delay (enabled)
d11 = [ms '/Delay11'];    % 11-deep E1 output pipeline

% ---- the enable source feeding the window delay ----
% On these Delay blocks (ShowEnablePort on) the enable is the SECOND INPORT
% (probe 2026-08-05: window Delay inports = {Delay4 data, Delay8 enable}).
wph = get_param(win,'PortHandles');
assert(numel(wph.Inport)>=2 && get_param(wph.Inport(2),'Line')~=-1, ...
    'movsum_hardening_overlay: window Delay enable inport not connected');
enLine = get_param(wph.Inport(2),'Line');
enSrcName = get_param(get_param(enLine,'SrcBlockHandle'),'Name');
assert(strcmp(enSrcName,'Delay8'), ...
    'movsum_hardening_overlay: window enable source is %s, expected Delay8', enSrcName);

% ---- data type of the summed stream (Delay4 output) ----
% E1/Add1 are sfix32_En28 in the generated RTL; pin the Sum to exactly that.
sumDT = 'fixdt(1,32,28)';

% ---- 13-deep parallel tap chain, same enable as the window ----
% NOTE (harness-caught 2026-08-05): the sum must use ONLY valid-captured taps.
% Delay4's output is a rail-rate stream that moves between valids; the original
% recursion samples it only at valid edges. Summing raw Delay4 broke decode
% (3/77 frames). 13 registered taps = the exact window Sigma x_k..x_{k-12}.
prev = 'Delay4';
for k = 1:13
    hb = sprintf('%s/HardTap%d', ms, k);
    add_block('built-in/Delay', hb, 'DelayLength','1', ...
        'ShowEnablePort','on', 'Position',[600 700+34*k 640 726+34*k]);
    add_line(ms, [strrep(prev,[ms '/'],'') '/1'], sprintf('HardTap%d/1',k), 'autorouting','on');
    add_line(ms, 'Delay8/1', sprintf('HardTap%d/2',k), 'autorouting','on');
    prev = hb;
end

% ---- 13-input direct sum (wrap, floor -- exact integer adds) ----
add_block('built-in/Sum', [ms '/HardSum'], 'Inputs', repmat('+',1,13), ...
    'OutDataTypeStr', sumDT, 'AccumDataTypeStr', sumDT, ...
    'SaturateOnIntegerOverflow','off', 'RndMeth','Floor', ...
    'Position',[720 760 760 1140]);
for k = 1:13
    add_line(ms, sprintf('HardTap%d/1',k), sprintf('HardSum/%d',k), 'autorouting','on');
end

% ---- 1-beat alignment register (matches Delay5's rail-beat phase) ----
add_block('built-in/Delay', [ms '/HardSumD'], 'DelayLength','1', ...
    'Position',[800 940 840 966]);
add_line(ms, 'HardSum/1', 'HardSumD/1', 'autorouting','on');

% ---- re-route the E1 pipeline input: Add1 -> Delay11 becomes HardSumD -> Delay11
d11ph = get_param(d11,'PortHandles');
oldLine = get_param(d11ph.Inport(1),'Line');
assert(oldLine~=-1, 'movsum_hardening_overlay: Delay11 input unconnected');
delete_line(oldLine);
add_line(ms, 'HardSumD/1', 'Delay11/1', 'autorouting','on');

fprintf(['movsum_hardening_overlay: DONE -- E1 now non-recursive ' ...
         '(13-tap direct sum; corruption flushes in <=13 valids)\n']);
end
