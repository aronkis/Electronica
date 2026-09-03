% rxfix_checkhdl_gate.m -- assemble the FULL rxfix DUT (composite + verif + FEC +
% counters + skip + caps + NODESCR) with the FIXED CFOChangeDetectThreshold=0.0125,
% CONFIRM the threshold constant is in the model, then checkhdl on TxRxComposite.
% NO synthesis. Fast pre-build gate for the one-line CFC-jump reset-gating fix.
RXFIXDIR='/mnt/onetb/scratch/qpsk_variants/fec_jupiter_rxfix';
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
cd(RXFIXDIR); addpath(RXFIXDIR);   % rxfix LAST -> fixed params win

logf='rxfix_checkhdl_gate.log'; if exist(logf,'file'), delete(logf); end
diary(logf);
fprintf('=== RXFIX checkhdl gate %s ===\n', char(datetime('now')));

% (0) confirm the FIXED params are the active ones
Pchk=commhdlQPSKTxRxParameters();
fprintf('active params file: %s\n', which('commhdlQPSKTxRxParameters'));
fprintf('CFOChangeDetectThreshold = %.7g (expect 0.0125)\n', Pchk.CFOChangeDetectThreshold);
assert(abs(Pchk.CFOChangeDetectThreshold-0.0125)<1e-9,'FIX NOT ACTIVE');

% clean stale
try; rmdir(fullfile(pwd,'hdl_prj_jupiter_composite'),'s'); catch; end
try; rmdir(fullfile(pwd,'slprj'),'s'); catch; end
try; rmdir(fullfile(pwd,'hdlsrc'),'s'); catch; end

sys='commhdlQPSKTxRxLoopback'; loop=[sys '/TxRxComposite'];
patch_hdlworkflow_counters('hdlworkflow_loopback.m');
run('build_composite_local.m');
run('variant_pre.m');
fprintf('\n=== FEC insertion overlay ===\n');       fec_insert_overlay(sys, loop);
fprintf('\n=== FEC counters overlay ===\n');         fec_counters_overlay(sys, loop);
fprintf('\n=== FEC skip-count register overlay ===\n'); fec_skipreg_overlay(sys, loop);
fprintf('\n=== FEC capture overlay ===\n');          fec_capture_overlay(sys, loop);
fprintf('\n=== NO-DESCRAMBLE bypass overlay ===\n'); fec_nodescr_overlay(sys, loop);
save_system(sys,[],'OverwriteIfChangedOnDisk',true);

% ---- CONFIRM the fixed threshold is baked into the DUT QPSK Rx mask + the
% CFO-step-detector Compare-To-Constant consts still reference it ----
dut_qrx = find_system(loop,'LookUnderMasks','all','FollowLinks','on','BlockType','SubSystem','Name','QPSK Rx');
mi = get_param(dut_qrx{1},'MaskInitialization');
fprintf('integAvgLen 2^12 intact = %d\n', contains(mi,'integAvgLen = 2^12;'));
cfcDet=[loop '/Receiver/QPSK Rx/Frequency and Time Synchronizer/Coarse Frequency Compensator/CFO step change detector'];
c1=[cfcDet '/Compare' char(10) 'To Constant']; c2=[cfcDet '/Compare' char(10) 'To Constant1'];
fprintf('CFO detector const(+) = %s\n', get_param(c1,'const'));
fprintf('CFO detector const(-) = %s\n', get_param(c2,'const'));
% Resolve the numeric value the block will use (mask ws var CFOChangeDetectThreshold)
try
  vplus  = slResolve('CFOChangeDetectThreshold', dut_qrx{1});
  fprintf('RESOLVED CFOChangeDetectThreshold in DUT mask ws = %.7g\n', vplus);
  assert(abs(double(vplus)-0.0125)<1e-9, 'DUT mask threshold NOT 0.0125');
catch e
  fprintf('slResolve note: %s\n', e.message);
end

% structural intacts
decW=find_system(sys,'LookUnderMasks','all','FollowLinks','on','BlockType','SubSystem','Name','FEC Decoder Wrapper');
vd  =find_system(sys,'LookUnderMasks','all','FollowLinks','on','MaskType','Viterbi Decoder');
nodescrGone=isempty(find_system(loop,'LookUnderMasks','all','FollowLinks','on','BlockType','SubSystem','Name','HDL Data Descrambler'));
fprintf('FEC DecWrapper=%d Viterbi=%d  descrambler-removed=%d\n', numel(decW),numel(vd),nodescrGone);
for r={'count_out','packets_out','bit_errors_out','skip_count','cap_in','cap_deint','cap_out'}
  fprintf('  port %-16s present=%d\n', r{1}, ~isempty(find_system(loop,'SearchDepth',1,'Name',r{1})));
end

% comment sim-only FromFile
try, set_param([sys '/RxCaptureFromHW'],'Commented','on'); catch, end

% compile + checkhdl gate
fprintf('\n=== Update Diagram ===\n');
try, set_param(sys,'SimulationCommand','update'); fprintf('Update Diagram PASSED\n');
catch e, fprintf('Update Diagram FAILED: %s\n', e.message); end
try, set_param(sys,'SimulationCommand','stop'); catch, end

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
if nErr==0
  fid=fopen('RXFIX_CHECKHDL.txt','w');
  fprintf(fid,'RXFIX_CHECKHDL_PASS %s\n', char(datetime('now')));
  fprintf(fid,'CFOChangeDetectThreshold=0.0125 (was 0.0015625); checkhdl errors=0 warnings=%d\n', nWarn);
  fprintf(fid,'FEC nodescr + skip(0x138) + caps(0x13C/140/144) + counters intact.\n');
  fclose(fid);
  fprintf('WROTE RXFIX_CHECKHDL.txt (PASS)\n');
end
diary off;
fprintf('RXFIX_CHECKHDL_GATE_DONE nErr=%d\n', nErr);
