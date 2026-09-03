% checkhdl_gate_240k5_byte.m -- assemble the FULL jupiter_240k5_byte DUT,
% checkhdl it (expect 0 errors), then makehdl the DUT Verilog for the
% netlist-level gates:
%   * S1 ROM regression  (rtl_sim/tb_tx_240k5.v + s1_analyze_240k5.m,
%     tx_data_source=0 structural: ext ports tied off in the TB)
%   * S1B byte gate      (rtl_sim/wrap_byte.v + sim_byte.cpp Verilator +
%     s1b_analyze_byte.m, tx_data_source=1, byte pins driven)
% NO Vivado synthesis. Pattern: jupiter_240k5/checkhdl_gate_240k5.m.
KITDIR=fileparts(mfilename('fullpath'));
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
cd(KITDIR); addpath(KITDIR);   % kit LAST -> its params win

logf='checkhdl_gate_240k5_byte.log'; if exist(logf,'file'), delete(logf); end
diary(logf);
fprintf('=== jupiter_240k5_byte checkhdl+makehdl gate %s ===\n', char(datetime('now')));

% clean stale
try; rmdir(fullfile(pwd,'hdl_prj_jupiter_composite'),'s'); catch; end
try; rmdir(fullfile(pwd,'slprj'),'s'); catch; end
try; rmdir(fullfile(pwd,'hdlsrc'),'s'); catch; end
try; rmdir(fullfile(pwd,'s1_rtl'),'s'); catch; end

sys='commhdlQPSKTxRxLoopback'; loop=[sys '/TxRxComposite'];
run('assemble_jupiter_240k5_byte.m');

% pi-integrity gate BEFORE compile/codegen: the demod 'Ph'=pi/4 and CS
% loop-filter fi(g/(2*pi)) masks evaluate against this workspace. A shadowed
% pi (the 2026-07-11 'for pi=' bug) skews the demod boundary 14.3deg from the
% constellation = the ~2-3e-3 OTA floor. Fail here, not on air.
assert(abs(pi - 3.141592653589793) < 1e-12, ...
    'GATE FAIL: pi is SHADOWED (pi=%.9g) -- masks would compile mis-evaluated', pi);

% comment sim-only FromFile (harness remnant)
try, set_param([sys '/RxCaptureFromHW'],'Commented','on'); catch, end

% compile gate
fprintf('\n=== Update Diagram ===\n');
updOK = false;
try, set_param(sys,'SimulationCommand','update'); updOK = true; fprintf('Update Diagram PASSED\n');
catch e, fprintf('Update Diagram FAILED: %s\n', e.message); end
try, set_param(sys,'SimulationCommand','stop'); catch, end
assert(updOK, 'Update Diagram failed -- aborting before checkhdl');

dqchk = find_system(loop,'LookUnderMasks','all','FollowLinks','on','BlockType','SubSystem','Name','QPSK Rx');
fprintf('QPSK Rx mask integAvgLen-2^12 intact = %d\n', ...
    contains(get_param(dqchk{1},'MaskInitialization'),'integAvgLen = 2^12;'));

fprintf('\n=== checkhdl(%s) Verilog ===\n', loop);
nErr=-1; nWarn=-1;
try
  msg=evalc(sprintf("checkhdl('%s','TargetLanguage','Verilog')", loop));
  fprintf('%s\n', msg);
  tok=regexp(msg,'complete with (\d+) error','tokens','once'); if ~isempty(tok), nErr=str2double(tok{1}); end
  tokw=regexp(msg,'(\d+) warning','tokens','once'); if ~isempty(tokw), nWarn=str2double(tokw{1}); end
catch e
  fprintf('checkhdl threw: %s\n', e.message);
  c=e.cause; for i=1:numel(c), try, fprintf('  CAUSE %d: %s\n',i,c{i}.message); catch, end; end
end
fprintf('CHECKHDL_ERRORS=%d CHECKHDL_WARNINGS=%d\n', nErr, nWarn);
assert(nErr==0, 'checkhdl errors=%d -- fix before netlist sims', nErr);

fid=fopen('CHECKHDL_240K5_BYTE.txt','w');
fprintf(fid,'JUPITER_240K5_BYTE_CHECKHDL %s\nerrors=%d warnings=%d\n', char(datetime('now')), nErr, nWarn);
fprintf(fid,'sps=8 Rsym=1.92e6 (T8 rate fix, rail 15.36e6=enb_1_2=240ksym) thr=0.0125 K5[35 23]TB25 ROWS136 CODED2176 ROMk5+byteDMA\n');
fprintf(fid,'IN-FABRIC infoValid-GATED K5 Tx encoder + 136x16 ping-pong interleaver + 64-bit PN9 filler (no gather, stock DAC wiring)\n');
fprintf(fid,'agc En10 +-32, regs 0x100..0x15C + tx_data_source 0x158, WPP=16, RD=JUPITER (RX & TX, BYTE DMA)\n');
fclose(fid);
fprintf('WROTE CHECKHDL_240K5_BYTE.txt\n');

% ---- makehdl for the netlist gates (plain RTL codegen, no IP core flow) ----
fprintf('\n=== makehdl(%s) -> s1_rtl/hdlsrc ===\n', loop);
hdlset_param(sys, 'TargetLanguage','Verilog');
hdlset_param(sys, 'TargetDirectory','s1_rtl/hdlsrc');
makehdl(loop);
vdir = fullfile('s1_rtl','hdlsrc','commhdlQPSKTxRxLoopback');
% T8 rate fix (Rsym 1.92e6): the v6 RXROOT cadence patch is RETIRED -- the Rx now
% lands natively on enb_1_2 and cadence_rtl_patch's pattern-match assert fails
% (patch_receiver_jupiter). Mirrors hdlworkflow_loopback.m (cadence_patch_ipcore
% commented out). The netlist gates must validate the UN-patched HDL = what the
% real Vivado build ships.
% cadence_rtl_patch(vdir, 'jupiter');
d = dir(fullfile(vdir,'*.v'));
fprintf('MAKEHDL_DONE: %d Verilog files in %s\n', numel(d), vdir);

% ---- generated-HDL constant gates (the authoritative param proof) ----
allv = '';
for k=1:numel(d), allv = [allv fileread(fullfile(vdir,d(k).name))]; end %#ok<AGROW>
gThrStock = contains(allv,'22''sb0000000000110011001101');  % stock 3277 En21 (HDL emits BINARY) -- must be GONE
gThrRxfix = contains(allv,'22''sb0000000110011001100110');  % RXFIX 26214 En21 (HDL emits BINARY) -- must be PRESENT
gRom      = contains(allv,'1204691830');   % K5 ROM word[0]
fprintf('HDL GREP: thr3277(ABSENT expected)=%d thr26214(present)=%d romword0(present)=%d\n', gThrStock, gThrRxfix, gRom);
assert(gThrRxfix && ~gThrStock, 'HDL GATE FAIL: RXFIX threshold not applied (3277=%d, 26214=%d)', gThrStock, gThrRxfix);
assert(gRom, 'HDL GATE FAIL: K5 ROM word[0] 1204691830 not found in generated HDL');
% byte-path structure present in the generated netlist
top = fileread(fullfile(vdir,'TxRxComposite.v'));
for p = {'byte_data','byte_valid','byte_first','byte_ready','tx_data_source', ...
         'byte_rx_data','byte_rx_valid','byte_rx_last','byte_rx_user','byte_rx_ready','adc_forensic'}
    assert(contains(top, p{1}), 'HDL GATE FAIL: %s missing from TxRxComposite.v ports', p{1});
end
gEnc = ~isempty(dir(fullfile(vdir,'*ConvEncK5*.v'))) || contains(allv,'ConvEncK5');
gShf = ~isempty(dir(fullfile(vdir,'*ByteBitShifter*.v'))) || contains(allv,'ByteBitShifter');
gIlv = ~isempty(dir(fullfile(vdir,'*TxInterleaveK5*.v'))) || contains(allv,'TxInterleaveK5');
fprintf('HDL GREP: ConvEncK5=%d ByteBitShifter=%d TxInterleaveK5=%d\n', gEnc, gShf, gIlv);
assert(gEnc && gShf && gIlv, 'HDL GATE FAIL: byte/encoder modules missing from netlist');
diary off;
fprintf('CHECKHDL_GATE_240K5_BYTE_DONE nErr=%d nWarn=%d\n', nErr, nWarn);
