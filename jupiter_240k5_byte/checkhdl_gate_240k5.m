% checkhdl_gate_240k5.m -- assemble the FULL jupiter_240k5 DUT, checkhdl it
% (expect 0 errors / 0 warnings), then makehdl the DUT Verilog for the S1
% iverilog Tx-air gate. NO Vivado synthesis. Pattern: rxfix_checkhdl_gate.m.
KITDIR='/mnt/onetb/scratch/qpsk_variants/jupiter_240k5_byte';
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
cd(KITDIR); addpath(KITDIR);   % kit LAST -> its params win

logf='checkhdl_gate_240k5.log'; if exist(logf,'file'), delete(logf); end
diary(logf);
fprintf('=== jupiter_240k5 checkhdl+makehdl gate %s ===\n', char(datetime('now')));

% clean stale
try; rmdir(fullfile(pwd,'hdl_prj_jupiter_composite'),'s'); catch; end
try; rmdir(fullfile(pwd,'slprj'),'s'); catch; end
try; rmdir(fullfile(pwd,'hdlsrc'),'s'); catch; end
try; rmdir(fullfile(pwd,'s1_rtl'),'s'); catch; end

sys='commhdlQPSKTxRxLoopback'; loop=[sys '/TxRxComposite'];
run('assemble_jupiter_240k5.m');

% comment sim-only FromFile (harness remnant)
try, set_param([sys '/RxCaptureFromHW'],'Commented','on'); catch, end

% compile gate
fprintf('\n=== Update Diagram ===\n');
updOK = false;
try, set_param(sys,'SimulationCommand','update'); updOK = true; fprintf('Update Diagram PASSED\n');
catch e, fprintf('Update Diagram FAILED: %s\n', e.message); end
try, set_param(sys,'SimulationCommand','stop'); catch, end
assert(updOK, 'Update Diagram failed -- aborting before checkhdl');

% post-Update note: slResolve cannot see the QPSK Rx mask ws outside a live
% compile (donor rxfix gate hit the same; it try/caught it). The DUT threshold
% is instead HARD-GATED on the generated Verilog below (fi(0.0015625,1,22,21)
% stored integer 3277 present / rxfix 26214 absent) -- stronger than slResolve.
dqchk = find_system(loop,'LookUnderMasks','all','FollowLinks','on','BlockType','SubSystem','Name','QPSK Rx');
cfcDet=[loop '/Receiver/QPSK Rx/Frequency and Time Synchronizer/Coarse Frequency Compensator/CFO step change detector'];
fprintf('CFO detector const(+) = %s\n', get_param([cfcDet '/Compare' char(10) 'To Constant'],'const'));
fprintf('CFO detector const(-) = %s\n', get_param([cfcDet '/Compare' char(10) 'To Constant1'],'const'));
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
assert(nErr==0, 'checkhdl errors=%d -- fix before S1 sim', nErr);

fid=fopen('CHECKHDL_240K5.txt','w');
fprintf(fid,'JUPITER_240K5_CHECKHDL %s\nerrors=%d warnings=%d\n', char(datetime('now')), nErr, nWarn);
fprintf(fid,'sps=8 Rsym=0.96e6 thr=0.0015625 K5[35 23]TB25 ROWS136 CODED2176 ROMk5 noscr nodescr taps 0x150/0x154\n');
fclose(fid);
fprintf('WROTE CHECKHDL_240K5.txt\n');

% ---- makehdl for the S1 iverilog gate (plain RTL codegen, no IP core flow) ----
fprintf('\n=== makehdl(%s) -> s1_rtl/hdlsrc ===\n', loop);
hdlset_param(sys, 'TargetLanguage','Verilog');
hdlset_param(sys, 'TargetDirectory','s1_rtl/hdlsrc');
makehdl(loop);
vdir = fullfile('s1_rtl','hdlsrc','commhdlQPSKTxRxLoopback');
% RXROOT E11: cadence-agnostic Rx gating on the generated HDL (proven golden in
% Verilator replay of real air at every silicon beats-per-sample cadence).
cadence_rtl_patch(vdir, 'jupiter');
d = dir(fullfile(vdir,'*.v'));
fprintf('MAKEHDL_DONE: %d Verilog files in %s\n', numel(d), vdir);

% ---- generated-HDL constant gates (the authoritative param proof) ----
allv = '';
for k=1:numel(d), allv = [allv fileread(fullfile(vdir,d(k).name))]; end %#ok<AGROW>
gThrNew  = contains(allv,'3277');          % fi(0.0015625,1,22,21) SI
gThrOld  = contains(allv,'26214');         % fi(0.0125,1,22,21) SI (rxfix -- must be GONE)
gRom     = contains(allv,'1204691830');    % K5 ROM word[0]
fprintf('HDL GREP: thr3277(present)=%d thr26214(ABSENT expected)=%d romword0(present)=%d\n', gThrNew, gThrOld, gRom);
assert(gThrNew && ~gThrOld, 'HDL GATE FAIL: threshold constants wrong (3277=%d, 26214=%d)', gThrNew, gThrOld);
assert(gRom, 'HDL GATE FAIL: K5 ROM word[0] 1204691830 not found in generated HDL');
diary off;
fprintf('CHECKHDL_GATE_240K5_DONE nErr=%d nWarn=%d\n', nErr, nWarn);
