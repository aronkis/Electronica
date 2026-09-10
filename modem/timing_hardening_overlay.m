function timing_hardening_overlay()
% timing_hardening_overlay -- T8.4 symbol-timing loop ANTI-WEDGE hardening on
% this kit's SOURCE model commhdlQPSKTxRx.slx (apply AFTER ss8_fix_overlay,
% BEFORE build_composite_local; idempotent; saves the slx).
%
% FIELD FAILURE (ERROR_TAXONOMY Class 4, sim-proven by rtl_sim/tb_timing_wedge.v):
% the Rice mod-1 counter in Symbol Synchronizer/Interpolation Control decrements
% by (0.125 + Delta) per beat and only strobes on underflow. If the Loop Filter
% output Delta ever reaches <= -0.125 (integrator wraps -- it has NO saturation,
% and the v = [23:13] output slice also wraps), the counter saturates high and
% Underflow NEVER fires again; with the Gardner TED silent (it only updates on
% strobes) the poisoned integrator holds forever. Live signature: postSymbolSync
% frozen at one constant, constellation all-zero, rstCS ineffective. The same
% mechanism transiently (integrator high-bit corruption at the ADRV9002 ~1.57 s
% device tick) produces the Class-1 episode frame losses.
%
% THREE BELTS (each alone prevents the permanent wedge; together they also
% bound Class-1 recovery):
%  (1) Interpolation Control (MATLAB Function): clamp Delta to +-127/1024
%      (= +-0.124023) at entry -> counter decrement >= 1 LSB -> underflow is
%      GUARANTEED within <= ~2047 beats; strobes can never stop permanently.
%  (2) Loop Filter integrator saturation: Saturation block 'IntegClamp'
%      (+-0.06) inserted between Add2 and {Delay, Delay4} -> the I-term cannot
%      hold a wedge-scale value; post-glitch recovery is bounded (~ms).
%      (Steady-state I-term = normalized clock-rate offset ~1e-6: 60000x margin.)
%  (3) Data Type Conversion17 SaturateOnIntegerOverflow = on -> the P+I to
%      sfix11_En10 conversion saturates at +-0.999 instead of wrap-aliasing.
% In-lock behavior is bit-identical (all three belts engage only at magnitudes
% ~4 orders above normal operation) -- the golden-decode gates must still pass.
%
% CARRIER loop (Loop Filter of Carrier Synchronizer) is deliberately UNTOUCHED
% (PI_GATE guards its constants).
%
% SPS PARAMETERIZATION (Task A3): the counter decrements by 1/sps per beat, so
% the wedge threshold is Delta <= -1/sps and the entry clamp must be just under
% 1/sps: wlim = (1024/sps - 1)/1024 (= 127/1024 at sps=8, 255/1024 at sps=4;
% leaves exactly 1 LSB of guaranteed decrement). The counter-line anchor carries
% fi(1/sps). All three belts are magnitude bounds ~4 orders above normal
% operation, so in-lock behavior stays bit-identical at every sps. The clamp is
% CONVERGENT on wlim: a model carried at the other sps's clamp value is corrected
% (asserting the other-sps from-value first).

cfg = frame_config_k5();
sps = cfg.Sps;
assert(sps==8 || sps==4, 'timing_hardening_overlay: unsupported sps=%d (4 or 8)', sps);
decLit    = sprintf('fi(%g,1,11,10)', 1/sps);        % fi(0.125,..) @8, fi(0.25,..) @4
wlimT     = sprintf('%d/1024', 1024/sps - 1);        % 127/1024 @8, 255/1024 @4
wlimOther = sprintf('%d/1024', 1024/(12-sps) - 1);   % the OTHER sps's clamp value

sys = 'commhdlQPSKTxRx';
load_system(sys);
ss = [sys '/Receiver/QPSK Rx/Frequency and Time Synchronizer/Symbol Synchronizer'];
lf = [ss '/Loop Filter'];

% ---- (1) Interpolation Control MATLAB Function: Delta entry clamp ----
ic  = [ss '/Interpolation Control'];
cfg = get_param(ic, 'MATLABFunctionConfiguration');
code = cfg.FunctionScript;
wlimDecl = sprintf('wlim = fi(%s,1,11,10);', wlimT);
if contains(code, 'anti-wedge clamp')
    if contains(code, wlimDecl)
        fprintf('timing_hardening_overlay: IC Delta clamp already present (wlim=%s) -- skip\n', wlimT);
    else
        % clamp present but carried at the other-sps value -> correct it
        assert(contains(code, sprintf('wlim = fi(%s,1,11,10);', wlimOther)), ...
            'IC clamp present with unexpected wlim (neither %s nor %s)', wlimT, wlimOther);
        code = strrep(code, wlimOther, wlimT);   % fixes both wlim= and -wlim occurrences
        cfg.FunctionScript = code;
        fprintf('timing_hardening_overlay: IC clamp wlim %s -> %s (sps=%d)\n', wlimOther, wlimT, sps);
    end
else
    anchor = sprintf('counter = bitand(mask,countReg)-Delta-%s;', decLit);
    assert(contains(code, anchor), 'Interpolation Control: counter line %s not found (run ss8_fix_overlay first)', anchor);
    clampcode = sprintf([ ...
        '   %% T8.4 anti-wedge clamp: if Delta <= -1/sps the decrementing counter\n' ...
        '   %% never underflows (strobes stop FOREVER -- Class-4 wedge / Class-1\n' ...
        '   %% episode mechanism; see tb_timing_wedge.v). Bound Delta so the\n' ...
        '   %% counter always decrements by >= 1 LSB.\n' ...
        '   wlim = fi(%s,1,11,10);\n' ...
        '   if Delta > wlim\n' ...
        '       Delta = wlim;\n' ...
        '   elseif Delta < -wlim\n' ...
        '       Delta = fi(-%s,1,11,10);\n' ...
        '   end\n   '], wlimT, wlimT);
    code = strrep(code, anchor, [clampcode anchor]);
    cfg.FunctionScript = code;
    fprintf('timing_hardening_overlay: IC Delta clamp inserted (+-%s, sps=%d)\n', wlimT, sps);
end

% ---- (2) Loop Filter integrator saturation ----
sat = [lf '/IntegClamp'];
if ~isempty(find_system(lf, 'SearchDepth', 1, 'Name', 'IntegClamp'))
    fprintf('timing_hardening_overlay: IntegClamp already present -- skip\n');
else
    % integrator topology (verified against generated TxRxCompo_ip_src_Loop_Filter_block1.v):
    %   Add2 = Delay6 + Delay ; Delay := Add2 (feedback) ; Delay4 := Add2 (output pipe)
    delete_line(lf, 'Add2/1', 'Delay/1');
    delete_line(lf, 'Add2/1', 'Delay4/1');
    add_block('simulink/Discontinuities/Saturation', sat, ...
        'UpperLimit', '0.06', 'LowerLimit', '-0.06', ...
        'OutDataTypeStr', 'Inherit: Same as input', ...
        'Position', [0 0 40 30]);
    add_line(lf, 'Add2/1', 'IntegClamp/1', 'autorouting', 'on');
    add_line(lf, 'IntegClamp/1', 'Delay/1', 'autorouting', 'on');
    add_line(lf, 'IntegClamp/1', 'Delay4/1', 'autorouting', 'on');
    fprintf('timing_hardening_overlay: IntegClamp (+-0.06) inserted Add2 -> {Delay, Delay4}\n');
end

% ---- (3) output conversion saturates instead of wrapping ----
dtc = [lf '/Data Type Conversion17'];
if strcmp(get_param(dtc, 'SaturateOnIntegerOverflow'), 'on')
    fprintf('timing_hardening_overlay: DTC17 already saturating -- skip\n');
else
    set_param(dtc, 'SaturateOnIntegerOverflow', 'on');
    fprintf('timing_hardening_overlay: DTC17 SaturateOnIntegerOverflow off -> on\n');
end

% ---- asserts (gate) ----
cfg2 = get_param(ic, 'MATLABFunctionConfiguration');
assert(contains(cfg2.FunctionScript, 'anti-wedge clamp'), 'IC clamp missing after apply');
assert(contains(cfg2.FunctionScript, wlimDecl), 'IC clamp wlim != %s for sps=%d after apply', wlimT, sps);
assert(~isempty(find_system(lf, 'SearchDepth', 1, 'Name', 'IntegClamp')), 'IntegClamp missing after apply');
assert(strcmp(get_param(dtc, 'SaturateOnIntegerOverflow'), 'on'), 'DTC17 saturation not set');
% carrier loop untouched (PI_GATE domain)
cs = [sys '/Receiver/QPSK Rx/Frequency and Time Synchronizer/Carrier Synchronizer'];
assert(isempty(find_system(cs, 'SearchDepth', 2, 'Name', 'IntegClamp')), 'carrier loop must stay untouched');

save_system(sys);
fprintf('timing_hardening_overlay: APPLIED + saved (%s.slx)\n', sys);
end
