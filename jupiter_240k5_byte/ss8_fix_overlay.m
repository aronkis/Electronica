function ss8_fix_overlay()
% ss8_fix_overlay -- fix the Symbol Synchronizer 4-sps leftovers at the restored
% 8-sps/240-ksym design point, on this kit's SOURCE model commhdlQPSKTxRx.slx.
%
% ROOT CAUSE (proven by Verilator RTL replay of real air, see k5_240/RXROOT.txt):
% rate_240k_overlay retargeted the model to sps=8 but THREE Symbol Synchronizer
% items still hardcode sps=4:
%   (1) Interpolation Control (MATLAB Function): counter decrement fi(0.25) = 1/4
%       and mu scaling bitshift(x,2) = x*4 (=x/W with W=1/4). At 8 sps the mod-1
%       counter must decrement 1/8 and mu = x*8.
%   (2) Gardner TED/GTED: fixed tap delays give e = x[n-4]*(x[n-6]-x[n-2]) --
%       one-symbol span of 4 samples and midpoint at 2 samples = a 4-sps Gardner.
%       At 8 sps the taps must span 8 with midpoint 4:
%       e = x[n-6]*(x[n-10]-x[n-2]).  (Late tap stays at n-2, so the strobe
%       alignment delay 'Gardner TED/Delay10' = 4 stays UNCHANGED.)
% Model->tap mapping (verified against generated RTL):
%   re: In1 -> Delay(1) -> Delay1(1) -> Delay2(1) -> Delay3(1)   (far tap z-4)
%                      \-> Delay8(2-deep)                        (mid tap z-4)
%   im: Delay4,Delay5,Delay6,Delay7 / Delay11 identically.
% Fix: Delay2,Delay3,Delay6,Delay7: 1 -> 3  (far tap z-8)
%      Delay8,Delay11:              2 -> 4  (mid tap z-6; the extra 2 matches the
%                                            z-2 pipeline of the far-tap product leg)
%
% Idempotent. Apply AFTER rate_240k_overlay, BEFORE build_composite_local.

sys = 'commhdlQPSKTxRx';
load_system(sys);
ss = [sys '/Receiver/QPSK Rx/Frequency and Time Synchronizer/Symbol Synchronizer'];

% ---- (1) Interpolation Control MATLAB Function ----
ic  = [ss '/Interpolation Control'];
cfg = get_param(ic, 'MATLABFunctionConfiguration');
code = cfg.FunctionScript;
if contains(code, 'fi(0.125,1,11,10)')
    fprintf('ss8_fix_overlay: Interpolation Control already at 1/8 -- skip\n');
else
    assert(contains(code, 'fi(0.25,1,11,10)'), 'Interpolation Control: 0.25 literal not found');
    assert(contains(code, 'bitshift(bitand(mask,countReg),2)'), 'Interpolation Control: bitshift(,2) not found');
    code = strrep(code, 'fi(0.25,1,11,10)', 'fi(0.125,1,11,10)');
    code = strrep(code, 'bitshift(bitand(mask,countReg),2)', 'bitshift(bitand(mask,countReg),3)');
    cfg.FunctionScript = code;
    fprintf('ss8_fix_overlay: Interpolation Control W 1/4 -> 1/8, mu x4 -> x8\n');
end

% ---- (2) GTED tap delays ----
g = [ss '/Gardner TED/GTED'];
farfix = {'Delay2','Delay3','Delay6','Delay7'};
for k = 1:numel(farfix)
    b = [g '/' farfix{k}];
    dl = strtrim(get_param(b, 'DelayLength'));
    if strcmp(dl, '3')
        fprintf('ss8_fix_overlay: %s already 3 -- skip\n', farfix{k});
    else
        assert(strcmp(dl, '1'), 'GTED/%s unexpected DelayLength %s', farfix{k}, dl);
        set_param(b, 'DelayLength', '3');
        fprintf('ss8_fix_overlay: GTED/%s DelayLength 1 -> 3 (far tap z-8)\n', farfix{k});
    end
end
midfix = {'Delay8','Delay11'};
for k = 1:numel(midfix)
    b = [g '/' midfix{k}];
    dl = strtrim(get_param(b, 'DelayLength'));
    if strcmp(dl, '4')
        fprintf('ss8_fix_overlay: %s already 4 -- skip\n', midfix{k});
    else
        assert(strcmp(dl, '2'), 'GTED/%s unexpected DelayLength %s', midfix{k}, dl);
        set_param(b, 'DelayLength', '4');
        fprintf('ss8_fix_overlay: GTED/%s DelayLength 2 -> 4 (mid tap z-6)\n', midfix{k});
    end
end

% strobe alignment must stay 4 (late tap unchanged at z-2)
d10 = strtrim(get_param([ss '/Gardner TED/Delay10'], 'DelayLength'));
assert(strcmp(d10, '4'), 'Gardner TED/Delay10 expected 4, got %s', d10);

save_system(sys);
fprintf('ss8_fix_overlay: saved %s\n', which(sys));
end
