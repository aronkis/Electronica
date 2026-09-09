% ram_probe_rxdeint.m -- SIZE-INDEPENDENT probe: does HDL Coder map the FEC
% ping-pong deinterleaver's persistent banks (fecRxDeint ramA/ramB) to RAM
% when MapPersistentVarsToRAM='on'? The access pattern (TWO reads/step from the
% read bank: perm0 & perm1, + one write to the write bank) is the documented
% BRAM-fit risk and is IDENTICAL for k5 and f1536 (only array SIZE differs), so
% this runs on whatever assembled model is on disk. It is NOT a gate; it just
% captures HDL Coder's RAM-mapping diagnostics so the f1536 RAM deliverable is
% evidenced rather than assumed. Writes ram_probe.out.
%
% Usage: run from the kit dir with paths set (run_assemble_byte-style env).
KITDIR = fileparts(mfilename('fullpath'));
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
cd(KITDIR); addpath(KITDIR);
sys='commhdlQPSKTxRxLoopback'; loop=[sys '/TxRxComposite'];
load_system(sys);
evalin('base', get_param(sys,'InitFcn'));
cfg = frame_config_k5();
dec  = [loop '/Receiver/QPSK Rx/FEC Decoder Wrapper'];
rblk = [dec '/RxDeint'];
% force the RAM request on for the probe (f1536 overlay already sets it; on k5
% we set it here so the diagnostic is exercised at the identical access pattern)
hdlset_param(rblk, 'MapPersistentVarsToRAM', 'on');
fprintf('RAM_PROBE frame=%s RxDeint MapPersistentVarsToRAM=%s (banks %d bits x2)\n', ...
    cfg.Frame, hdlget_param(rblk,'MapPersistentVarsToRAM'), cfg.CodedBits);

diary(fullfile(KITDIR,'ram_probe.out')); diary on;
ok = false; msg = '';
try
    % checkhdl on the wrapper surfaces RAM-mapping conformance without a full
    % netlist build; capture its messages.
    hdlset_param(sys, 'HDLSubsystem', dec);
    checkhdl(dec);
    ok = true; msg = 'checkhdl completed';
catch e
    msg = ['checkhdl error: ' e.message];
end
fprintf('RAM_PROBE checkhdl: %s (%s)\n', string(ok), msg);
% Also try a scoped makehdl to capture the actual RAM inference lines.
try
    makehdl(dec, 'TargetLanguage','Verilog', ...
        'TargetDirectory', fullfile(KITDIR,'ram_probe_hdl'));
    fprintf('RAM_PROBE makehdl: DONE\n');
catch e2
    fprintf('RAM_PROBE makehdl: error: %s\n', e2.message);
end
diary off;
fprintf('RAM_PROBE_DONE\n');
