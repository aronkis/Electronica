function movsum_tmr_overlay(sys, base)
% movsum_tmr_overlay -- FIX VARIANT B: triple modular redundancy on the
% Correlator's recursive threshold accumulator (Delay14).
%
% ROOT CAUSE (task #13/#15, confirmed on silicon 2026-08-04; see
% movsum_hardening_overlay.m for FIX VARIANT A, the non-recursive rewrite):
% Magnitude Squared and Moving Sum computes the adaptive preamble threshold
% E1 via a RECURSIVE accumulator:
%   Delay4 -> Add (window subtract) -> Delay5 -> Add1 (= Delay5 + Delay14) ->
%   Delay14 (1-deep, enable = Delay7) [feedback] -> Delay11 (11-deep) -> E1
% Any single upset of Delay14 persists FOREVER (the windowed-difference
% stream is oblivious to an accumulated offset). Injection: +2^28 absorbed,
% +2^29 = multi-frame sputter stalls, +2^30 = permanent decode mute.
%
% FIX (variant B): triplicate the Delay14 feedback register (Delay14,
% Delay14B, Delay14C -- identical input, identical enable source Delay7,
% identical inherited data type) and majority-vote the three every beat. The
% voted value:
%   (1) replaces the direct Delay14->Add1 connection (Add1 = Delay5 + voter)
%   (2) is what Add1 recomputes from on the NEXT enabled beat, and since all
%       three registers latch Add1's output, a corrupted copy is pulled back
%       to the voted (majority) value within one enabled beat instead of
%       staying wrong forever. No separate write-back path is needed: wiring
%       the voter into Add1's second input and leaving Add1 -> {Delay14,
%       Delay14B,Delay14C} as the common input satisfies both requirements
%       with the SAME wire.
% Delay11 (E1 output pipeline) is untouched -- it already reads Add1's
% output, so it inherits the corrected (voted) value automatically.
%
% Bitwise majority vote is done via reinterpretcast to an unsigned integer
% of the same width (same idiom as canary_instrumentation_overlay.m's
% shadowScore: reinterpretcast(x, numerictype(0,W,0)) for bit ops on a
% signed fi, then reinterpretcast back), because bitand/bitor on a signed fi
% are rejected by checkhdl. Accumulator word is sfix32_En28 (confirmed via
% movsum_hardening_overlay.m header + Add1 "Inherit: Same as first input"
% tracing to Delay5/Delay4/window Delay, all sfix32_En28); vote is done in
% numerictype(0,32,0) and reinterpreted back to numerictype(1,32,28).
%
% *** SYNTHESIS CAVEAT (MUST READ BEFORE AN IMAGE BUILD) ***
% Delay14/Delay14B/Delay14C are FUNCTIONALLY IDENTICAL registers (same
% input, same enable, same reset). Vivado synthesis (and HDL Coder's default
% register-merge / equivalent-register-removal optimization) will try to
% collapse them back into ONE register, silently defeating this fix -- the
% netlist would simulate correctly in Verilator (which does NOT perform this
% merge) while the deployed bitstream reverts to a single point-of-failure
% accumulator. Before any Vivado image build carrying this fix, the build
% flow MUST mark all three copies as non-mergeable, e.g.:
%   - Vivado XDC/Tcl: `set_property KEEP true [get_cells ...Delay14*_reg]`
%     and/or `set_property DONT_TOUCH true [get_cells ...Delay14*_reg]`
%     on Delay14_reg, Delay14B_reg, Delay14C_reg (post-synth, before P&R).
%   - Or HDL Coder: set the block/model "Preserve resource" / register
%     retention property on the three Delay blocks so codegen emits
%     equivalent (* keep = "true" *) / (* dont_touch = "true" *) attributes
%     directly in the generated Verilog.
% This overlay does NOT add those attributes itself (HDL Coder's Simulink
% Delay block has no direct dont_touch dialog parameter in this release);
% it is a REQUIRED, SEPARATE step in the image-build flow. Not needed for
% Verilator netlist-sim validation (no such merge occurs there), but a
% reviewer MUST be told before this ships to silicon.
%
% TIMING: the voter sits in the accumulator feedback path (Delay14 output ->
% voter -> Add1 -> {Delay14,Delay14B,Delay14C} input), adding one small
% combinational block (3-input AND/OR tree, ~32 bits wide) to that loop's
% combinational depth. The design has roughly 4 ns of slack at an 8 ns clock
% in this region; a majority-vote tree (2-3 gate levels) should fit, but
% this MUST be confirmed by static timing analysis after synthesis -- not
% verified by this overlay or by the (unclocked-delay) Verilator bit-true
% sim, which has no notion of propagation delay.
%
% AREA: +2 x sfix32_En28 registers (Delay14B, Delay14C) + one small
% MATLAB-Function-synthesized majority voter (~3 LUTs deep x 32 bits wide).
%
% Env-gated at assemble via QPSK_MOVSUM_TMR=1 (mirrors QPSK_MOVSUM_HARDEN).
% Mutually exclusive with movsum_hardening_overlay (variant A) in practice --
% apply only one fix variant per build. Idempotent.

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end

ms = [base '/Receiver/QPSK Rx/Frequency and Time Synchronizer/' ...
      'Preamble Detector/Correlator/Magnitude Squared and Moving Sum'];

if ~isempty(find_system(ms,'SearchDepth',1,'Name','Delay14B'))
    fprintf('movsum_tmr_overlay: already present -- skipping\n');
    return;
end
assert(~isempty(find_system(ms,'SearchDepth',1,'Name','Delay14')), ...
    'movsum_tmr_overlay: Delay14 not found at %s', ms);
assert(~isempty(find_system(ms,'SearchDepth',1,'Name','Add1')), ...
    'movsum_tmr_overlay: Add1 not found at %s', ms);
assert(~isempty(find_system(ms,'SearchDepth',1,'Name','Delay7')), ...
    'movsum_tmr_overlay: Delay7 not found at %s', ms);

d14 = [ms '/Delay14'];
a1  = [ms '/Add1'];

% ---- confirm the wiring this overlay depends on (probe 2026-08-05) ----
% Delay14 inport1 (data) <- Add1;  inport2 (enable) <- Delay7.
% Add1 inport1 <- Delay5;          inport2 <- Delay14 (the feedback we cut).
d14ph = get_param(d14,'PortHandles');
assert(numel(d14ph.Inport)>=2, 'movsum_tmr_overlay: Delay14 missing enable inport');
dataLine = get_param(d14ph.Inport(1),'Line');
enLine   = get_param(d14ph.Inport(2),'Line');
assert(dataLine~=-1 && enLine~=-1, 'movsum_tmr_overlay: Delay14 inports unconnected');
dataSrc = get_param(get_param(dataLine,'SrcBlockHandle'),'Name');
enSrc   = get_param(get_param(enLine,'SrcBlockHandle'),'Name');
assert(strcmp(dataSrc,'Add1'), ...
    'movsum_tmr_overlay: Delay14 data source is %s, expected Add1', dataSrc);
assert(strcmp(enSrc,'Delay7'), ...
    'movsum_tmr_overlay: Delay14 enable source is %s, expected Delay7', enSrc);

a1ph = get_param(a1,'PortHandles');
assert(numel(a1ph.Inport)==2, 'movsum_tmr_overlay: Add1 expected 2 inports');
a1in2Line = get_param(a1ph.Inport(2),'Line');
assert(a1in2Line~=-1, 'movsum_tmr_overlay: Add1 inport2 unconnected');
a1in2Src = get_param(get_param(a1in2Line,'SrcBlockHandle'),'Name');
assert(strcmp(a1in2Src,'Delay14'), ...
    'movsum_tmr_overlay: Add1 inport2 source is %s, expected Delay14', a1in2Src);

% ---- 1. two more copies of the accumulator register: same input, same enable ----
d14pos = get_param(d14,'Position');
w = d14pos(3)-d14pos(1); h = d14pos(4)-d14pos(2);
add_block(d14, [ms '/Delay14B'], ...
    'Position', [d14pos(1) d14pos(2)+140 d14pos(1)+w d14pos(2)+140+h]);
add_block(d14, [ms '/Delay14C'], ...
    'Position', [d14pos(1) d14pos(2)+280 d14pos(1)+w d14pos(2)+280+h]);
add_line(ms, 'Add1/1',  'Delay14B/1', 'autorouting','on');
add_line(ms, 'Delay7/1','Delay14B/2', 'autorouting','on');
add_line(ms, 'Add1/1',  'Delay14C/1', 'autorouting','on');
add_line(ms, 'Delay7/1','Delay14C/2', 'autorouting','on');
fprintf('movsum_tmr_overlay: Delay14B + Delay14C added (same input=Add1, enable=Delay7)\n');

% ---- 2. bitwise majority voter over the three copies ----
voterPos = [d14pos(1)+120 d14pos(2)+40 d14pos(1)+260 d14pos(2)+300];
add_block('simulink/User-Defined Functions/MATLAB Function', [ms '/AccVoter'], ...
    'Position', voterPos);
set_fcn_script([ms '/AccVoter'], accVoter_src());
add_line(ms, 'Delay14/1',  'AccVoter/1', 'autorouting','on');
add_line(ms, 'Delay14B/1', 'AccVoter/2', 'autorouting','on');
add_line(ms, 'Delay14C/1', 'AccVoter/3', 'autorouting','on');
fprintf('movsum_tmr_overlay: AccVoter (bitwise majority, sfix32_En28) added\n');

% ---- 3. cut Delay14->Add1 direct feedback; route AccVoter->Add1 instead ----
% Add1 = Delay5 + voter(Delay14,Delay14B,Delay14C). Since Add1's output is
% ALSO the common input to all three registers (unchanged wiring, step 1),
% this single rewire is both the "feed the sum" and the "write back the
% voted/re-converged value into all three copies" requirement.
delete_line(a1in2Line);
add_line(ms, 'AccVoter/1', 'Add1/2', 'autorouting','on');
fprintf(['movsum_tmr_overlay: DONE -- Add1 in2 now driven by AccVoter ' ...
         '(TMR accumulator live, all 3 copies re-converge every enabled beat)\n']);
end

% ===================== helpers =====================
function set_fcn_script(blk, src)
rt = sfroot;
chart = rt.find('-isa','Stateflow.EMChart','Path',blk);
chart.Script = src;
end

function src = accVoter_src()
% Bitwise majority vote of three sfix32_En28 accumulator copies. checkhdl
% rejects bitand/bitor on a signed fi directly, so vote in an unsigned
% same-width reinterpretation (same idiom as canary_instrumentation_overlay
% .m's shadowScore) and reinterpretcast the result back to the accumulator's
% numerictype. Purely combinational -- no persistent state, no arithmetic on
% the accumulated value (bit-exact majority per bit position).
% Accumulator word is sfix32_En28 == numerictype(1,32,28) (confirmed: Add1
% "Inherit: Same as first input" traces to Delay5/Delay4/window Delay, all
% sfix32_En28 per movsum_hardening_overlay.m). Hardcoded (not derived via
% numerictype(a)) to match the fixed-type idiom already proven through
% checkhdl in canary_instrumentation_overlay.m's shadowScore.
% NOTE: vote directly on the ufix32_En0 REINTERPRETATION (no uint32() value
% cast in between) -- wrapping reinterpretcast's fi result in uint32() is a
% VALUE cast, not a bit cast, and risks silently rounding/saturating the
% clean (uncorrupted) case, which would fail gate 1 (bit-exact baseline)
% even though the fix is otherwise correct. bitand/bitor on same-numerictype
% fi operands are supported by Fixed-Point Designer / HDL codegen directly.
src = sprintf([ ...
'function v = accVoter(a,b,c)\n' ...
'%%#codegen\n' ...
'au = reinterpretcast(a, numerictype(0,32,0));\n' ...
'bu = reinterpretcast(b, numerictype(0,32,0));\n' ...
'cu = reinterpretcast(c, numerictype(0,32,0));\n' ...
'vu = bitor(bitand(au,bu), bitor(bitand(au,cu), bitand(bu,cu)));\n' ...
'v = reinterpretcast(vu, numerictype(1,32,28));\n']);
end
