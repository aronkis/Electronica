% build_variant_byte.m -- BYTE-image Vivado build driver (G2).
% Same mechanism as build_variant_jupiter_240k5.m BUT runs the BYTE-complete
% assemble (assemble_jupiter_240k5_byte.m: phases 0..2.11 + 2.12-2.15 byte
% overlays + in-fabric FEC encoder + byte plumbing) instead of the non-byte
% base assemble. Then the byte reference-design IP-core workflow
% (hdlworkflow_loopback.m: 'JUPITER (RX & TX, BYTE DMA)', byte IOInterface
% maps at x"158", cadence patch retired). The runWorkflow CreateProject task
% is expected to fail on the insert-path bug -> the orchestrator finishes with
% complete_byte_t8.tcl (stock DAC wiring + the 9 byte DUT<->breakout connects).
% G2 sim gates (assemble, model oracle, checkhdl+makehdl, S1B netlist, S1 ROM)
% must have PASSED before launching this.
KITDIR=fileparts(mfilename('fullpath'));
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
cd(KITDIR); addpath(KITDIR);   % kit LAST -> its params (sps=8, Rsym 1.92e6) win
fprintf('build_variant_byte cwd=%s\n', pwd);

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

% BYTE-complete assemble: base phases 0..2.11 + byte overlays 2.12-2.15 +
% in-fabric infoValid-gated K5 encoder + PN9 filler + byte plumbing + gates.
run('assemble_jupiter_240k5_byte.m');

% Phase 3: byte reference-design IP-core workflow (CreateProject may fail).
run('hdlworkflow_loopback.m');
fprintf('VARIANT_BUILD_DONE: %s\n', 'jupiter_240k5_byte');
