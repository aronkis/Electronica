% fec_dbg_checkhdl_gate.m -- build composite + verif + FEC + DEBUG COUNTERS,
% then run checkhdl on TxRxComposite (THE GATE) before any synthesis.
% Writes CHECKHDL_DBG.txt the moment it passes. NO synthesis here.
cd('/mnt/onetb/scratch/qpsk_variants/fec_jupiter_nodescr');
addpath('/mnt/onetb/scratch/qpsk_variants/fec_jupiter_nodescr');   % copies of overlays
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
try, run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m'); catch e, fprintf('setup warn: %s\n', e.message); end

logf = 'fec_dbg_checkhdl_gate.log';
if exist(logf,'file'), delete(logf); end
diary(logf);
fprintf('=== FEC DBG checkhdl gate  %s ===\n', char(datetime('now')));
fprintf('Simulink_HDL_Coder license = %d\n', license('test','Simulink_HDL_Coder'));

% Clean stale project
try; rmdir(fullfile(pwd,'hdl_prj_jupiter_composite'),'s'); catch; end
try; rmdir(fullfile(pwd,'slprj'),'s'); catch; end
try; rmdir(fullfile(pwd,'hdlsrc'),'s'); catch; end

sys = 'commhdlQPSKTxRxLoopback';
loop = [sys '/TxRxComposite'];

% Phase 1: composite topology
run('build_composite_local.m');
% Phase 2: verif + integAvgLen 2^12 overlay (MUX + FIR + CFC)
run('variant_pre.m');
% Phase 2.5: FEC insertion overlay (shared artifact, copied into this dir)
fprintf('\n=== applying FEC insertion overlay (base=%s) ===\n', loop);
fec_insert_overlay(sys, loop);
% Phase 2.6: DEBUG COUNTERS overlay (the new instrumentation)
fprintf('\n=== applying FEC counters overlay (base=%s) ===\n', loop);
fec_counters_overlay(sys, loop);
% Phase 2.7: dbg4 -- runtime RxAlign skip-count AXI register (0x138)
fprintf('\n=== applying FEC skip-count register overlay (base=%s) ===\n', loop);
fec_skipreg_overlay(sys, loop);
% Phase 2.8: dbg6 -- intermediate-stage bit capture (0x13C/0x140/0x144)
fprintf('\n=== applying FEC capture overlay (base=%s) ===\n', loop);
fec_capture_overlay(sys, loop);
save_system(sys,[],'OverwriteIfChangedOnDisk',true);

% Confirm FEC + counter presence
decW = find_system(sys,'LookUnderMasks','all','FollowLinks','on','BlockType','SubSystem','Name','FEC Decoder Wrapper');
vd   = find_system(sys,'LookUnderMasks','all','FollowLinks','on','MaskType','Viterbi Decoder');
fc   = find_system(sys,'LookUnderMasks','all','FollowLinks','on','Name','FecCounters');
fprintf('FEC presence: DecWrapper=%d Viterbi=%d FecCounters=%d\n', numel(decW), numel(vd), numel(fc));

% Confirm the 6 new outports made it all the way to TxRxComposite
cnt_names = {'cnt_descr_in','cnt_frame_start','cnt_vit_reset','cnt_deint_valid','cnt_dec_bits','cnt_bist_start'};
nTop = 0;
for k=1:6
    if ~isempty(find_system(loop,'SearchDepth',1,'BlockType','Outport','Name',cnt_names{k}))
        nTop = nTop + 1;
    end
end
fprintf('Counter outports surfaced to TxRxComposite = %d/6\n', nTop);
assert(nTop==6, 'counter outports did not reach TxRxComposite');

% Confirm original AXI regs + integAvgLen intact
dut_qrx = find_system(loop,'LookUnderMasks','all','FollowLinks','on','BlockType','SubSystem','Name','QPSK Rx');
fprintf('integAvgLen 2^12 intact = %d\n', contains(get_param(dut_qrx{1},'MaskInitialization'),'integAvgLen = 2^12;'));
for r = {'count_out','packets_out','bit_errors_out','iq_debug_mux','rstCS','rx_input_select','tx_source_select'}
    present = ~isempty(find_system(loop,'SearchDepth',1,'Name',r{1}));
    fprintf('  reg port %-18s present=%d\n', r{1}, present);
end

% Phase 2.9: comment the sim-only FromFile root block
try, set_param([sys '/RxCaptureFromHW'],'Commented','on'); catch, end

% Update Diagram (compile) before checkhdl
fprintf('\n=== Update Diagram (compile) ===\n');
try
    set_param(sys,'SimulationCommand','update');
    fprintf('Update Diagram PASSED\n');
catch e
    fprintf('Update Diagram FAILED: %s\n', e.message);
    c = e.cause; for i=1:numel(c), try, fprintf('  UD CAUSE %d: %s\n', i, c{i}.message); catch, end; end
end
try, set_param(sys,'SimulationCommand','stop'); catch, end

% THE GATE: checkhdl on TxRxComposite
fprintf('\n=== checkhdl(%s) Verilog ===\n', loop);
nErr = -1; nWarn = -1;
try
    msg = evalc(sprintf("checkhdl('%s','TargetLanguage','Verilog')", loop));
    fprintf('%s\n', msg);
    tok = regexp(msg,'complete with (\d+) error','tokens','once');
    if ~isempty(tok), nErr = str2double(tok{1}); end
    tokw = regexp(msg,'(\d+) warning','tokens','once');
    if ~isempty(tokw), nWarn = str2double(tokw{1}); end
catch e
    fprintf('checkhdl threw: %s\n', e.message);
    c = e.cause; for i=1:numel(c), try, fprintf('  CHECKHDL CAUSE %d: %s\n', i, c{i}.message); catch, end; end
end
fprintf('CHECKHDL_ERRORS=%d CHECKHDL_WARNINGS=%d\n', nErr, nWarn);

if nErr == 0
    fid=fopen('CHECKHDL_DBG.txt','w');
    fprintf(fid,'CHECKHDL_DBG_PASS  %s\n', char(datetime('now')));
    fprintf(fid,'DUT=%s  errors=0 warnings=%d  (Simulink_HDL_Coder)\n', loop, nWarn);
    fprintf(fid,'FEC + 6 debug counters (AXI 0x120..0x134) on TxRxComposite.\n');
    fclose(fid);
    fprintf('WROTE CHECKHDL_DBG.txt (PASS marker)\n');
end

diary off;
fprintf('FEC_DBG_CHECKHDL_GATE_DONE nErr=%d\n', nErr);
