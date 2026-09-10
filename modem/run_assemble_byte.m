% run_assemble_byte.m -- driver: paths + assemble (no checkhdl). Used while
% authoring; the real gates are checkhdl_gate_240k5_byte.m / sim_byte_gate_k5.m.
KITDIR=fileparts(mfilename('fullpath'));
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
cd(KITDIR); addpath(KITDIR);   % kit LAST -> its params win
run('assemble_jupiter_240k5_byte.m');
fprintf('RUN_ASSEMBLE_BYTE_DONE\n');
