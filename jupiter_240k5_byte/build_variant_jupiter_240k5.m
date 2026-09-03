% build_variant_jupiter_240k5.m -- full Vivado build driver (Task 4 / S2).
% Same mechanism as donor fec_jupiter_rxfix/build_variant_fec_dbg.m: assemble
% the model (assemble_jupiter_240k5.m does all overlays + pre-synth gates),
% then run the IP-core-generation workflow. S1 (checkhdl_gate_240k5.m +
% s1 iverilog gate) must have PASSED before launching this.
KITDIR='/mnt/onetb/scratch/qpsk_variants/jupiter_240k5_byte';
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
cd(KITDIR); addpath(KITDIR);   % kit LAST -> its params (sps=8, stock thr) win
fprintf('build_variant_jupiter_240k5 cwd=%s\n', pwd);

try
    hdlsetuptoolpath('ToolName','Xilinx Vivado','ToolPath','/tools/Xilinx/2025.1/Vivado/bin/vivado');
catch err
    fprintf('hdlsetuptoolpath warning: %s\n', err.message);
end

% Wipe stale projects so HDL Coder smart-build cannot skip steps.
try; rmdir(fullfile(pwd,'hdl_prj_jupiter_composite'),'s'); catch; end
try; rmdir(fullfile(pwd,'hdl_prj_jupiter_rx'),'s'); catch; end
try; rmdir(fullfile(pwd,'slprj'),'s'); catch; end

sys = 'commhdlQPSKTxRxLoopback';
loop = [sys '/TxRxComposite']; %#ok<NASGU>

% Phases 0..2.11 + pre-synth gates
run('assemble_jupiter_240k5.m');

% Phase 3: synthesize + implement + bitgen (JUPITER rxtx reference design).
run('hdlworkflow_loopback.m');
fprintf('VARIANT_BUILD_DONE: %s\n', 'jupiter_240k5');
