function ss8_fix_overlay()
% ss8_fix_overlay -- set the Symbol Synchronizer sample-per-symbol configuration
% on this kit's SOURCE model commhdlQPSKTxRx.slx to match QPSK_SPS.
%
% sps=8 (default): the 240-ksym design point. THREE Symbol Synchronizer items
% must be moved from the MathWorks stock sps=4 configuration to sps=8:
%   (1) Interpolation Control (MATLAB Function): counter decrement fi(1/sps)
%       and mu scaling bitshift(x, log2(sps)). At sps=4 (stock): fi(0.25),
%       bitshift(,2). At sps=8: fi(0.125), bitshift(,3).
%   (2) Gardner TED/GTED: fixed tap delays. At sps=4 (stock) the far tap is
%       z-4 (Delay2/3/6/7 = 1) and the mid tap z-4 (Delay8/11 = 2), giving
%       e = x[n-4]*(x[n-6]-x[n-2]) -- a 4-sps Gardner. At sps=8 the taps span
%       8 with midpoint 4: Delay2/3/6/7 = 3 (far z-8), Delay8/11 = 4 (mid z-6);
%       e = x[n-6]*(x[n-10]-x[n-2]). Late tap stays n-2, so Gardner TED/Delay10
%       (strobe alignment) = 4 in BOTH configurations.
% (ROOT CAUSE for the sps=8 fix proven by Verilator RTL replay, contract/RXROOT.txt.)
%
% sps=4 (Task A3 rate rung): CONVERGENT REVERT. The committed source model is
% carried in its sps=8-overlaid state (the .slx is a tracked build artifact --
% no pristine stock donor exists), so "reverting the sps-8 surgery" means
% actively undoing (1) and (2) back to the documented MathWorks stock sps=4
% values. Each revert site FIRST asserts the sps=8 from-state (so a drifted
% model fails loudly rather than being reverted from an unexpected baseline),
% then rewrites to stock sps=4. sps is ORTHOGONAL to frame geometry.
%
% Model->tap mapping (verified against generated RTL):
%   re: In1 -> Delay(1) -> Delay1(1) -> Delay2 -> Delay3   (far tap)
%                      \-> Delay8                           (mid tap)
%   im: Delay4,Delay5,Delay6,Delay7 / Delay11 identically.
%
% Idempotent (both directions). Apply AFTER rate_240k_overlay, BEFORE
% timing_hardening_overlay / build_composite_local.

cfg = frame_config_k5();
sps = cfg.Sps;
assert(sps==8 || sps==4, 'ss8_fix_overlay: unsupported sps=%d (4 or 8)', sps);

sys = 'commhdlQPSKTxRx';
load_system(sys);
ss = [sys '/Receiver/QPSK Rx/Frequency and Time Synchronizer/Symbol Synchronizer'];

% target / from-state literals keyed on sps (target = this build; from = the
% OTHER config, asserted before any rewrite so an unexpected baseline fails)
if sps == 8
    decT = 'fi(0.125,1,11,10)';                 decF = 'fi(0.25,1,11,10)';
    shT  = 'bitshift(bitand(mask,countReg),3)'; shF  = 'bitshift(bitand(mask,countReg),2)';
    farT = '3'; farF = '1';   % far tap: z-8 (sps8) <- z-4 (sps4)
    midT = '4'; midF = '2';   % mid tap: z-6 (sps8) <- z-4 (sps4)
else % sps == 4
    decT = 'fi(0.25,1,11,10)';                  decF = 'fi(0.125,1,11,10)';
    shT  = 'bitshift(bitand(mask,countReg),2)'; shF  = 'bitshift(bitand(mask,countReg),3)';
    farT = '1'; farF = '3';
    midT = '2'; midF = '4';
end

% ---- (1) Interpolation Control MATLAB Function ----
ic  = [ss '/Interpolation Control'];
cfgIC = get_param(ic, 'MATLABFunctionConfiguration');
code  = cfgIC.FunctionScript;
if contains(code, decT) && contains(code, shT)
    fprintf('ss8_fix_overlay: Interpolation Control already sps=%d (%s) -- skip\n', sps, decT);
else
    assert(contains(code, decF), 'Interpolation Control: from-state %s not found', decF);
    assert(contains(code, shF),  'Interpolation Control: from-state %s not found', shF);
    code = strrep(code, decF, decT);
    code = strrep(code, shF,  shT);
    cfgIC.FunctionScript = code;
    fprintf('ss8_fix_overlay: Interpolation Control decrement %s->%s, mu %s->%s (sps=%d)\n', ...
        decF, decT, shF, shT, sps);
end

% ---- (2) GTED tap delays ----
g = [ss '/Gardner TED/GTED'];
farBlks = {'Delay2','Delay3','Delay6','Delay7'};
for k = 1:numel(farBlks)
    b = [g '/' farBlks{k}];
    dl = strtrim(get_param(b, 'DelayLength'));
    if strcmp(dl, farT)
        fprintf('ss8_fix_overlay: GTED/%s already %s -- skip\n', farBlks{k}, farT);
    else
        assert(strcmp(dl, farF), 'GTED/%s unexpected from-state DelayLength %s (expected %s)', farBlks{k}, dl, farF);
        set_param(b, 'DelayLength', farT);
        fprintf('ss8_fix_overlay: GTED/%s DelayLength %s -> %s (far tap, sps=%d)\n', farBlks{k}, farF, farT, sps);
    end
end
midBlks = {'Delay8','Delay11'};
for k = 1:numel(midBlks)
    b = [g '/' midBlks{k}];
    dl = strtrim(get_param(b, 'DelayLength'));
    if strcmp(dl, midT)
        fprintf('ss8_fix_overlay: GTED/%s already %s -- skip\n', midBlks{k}, midT);
    else
        assert(strcmp(dl, midF), 'GTED/%s unexpected from-state DelayLength %s (expected %s)', midBlks{k}, dl, midF);
        set_param(b, 'DelayLength', midT);
        fprintf('ss8_fix_overlay: GTED/%s DelayLength %s -> %s (mid tap, sps=%d)\n', midBlks{k}, midF, midT, sps);
    end
end

% strobe alignment (late tap) is z-2 in BOTH configs -> Delay10 = 4 unchanged
d10 = strtrim(get_param([ss '/Gardner TED/Delay10'], 'DelayLength'));
assert(strcmp(d10, '4'), 'Gardner TED/Delay10 expected 4, got %s', d10);

save_system(sys);
fprintf('ss8_fix_overlay: saved %s (sps=%d)\n', which(sys), sps);
end
