% build_variant_fec_dbg.m -- full Jupiter FEC + DEBUG COUNTERS composite build.
%   base = jupiter_fir_cfc12 composite (FIR + tx/rx source MUX + integAvgLen
%   2^12) + board-agnostic FEC insertion overlay + the FEC-Rx debug COUNTERS
%   overlay (6 free-running 32-bit event counters on AXI 0x120..0x134).
%   checkhdl on TxRxComposite already PASSED (0 errors / 0 warnings) via
%   fec_dbg_checkhdl_gate.m.
% RXFIX build: run from the rxfix dir so the FIXED commhdlQPSKTxRxParameters.m
% (CFOChangeDetectThreshold=0.0125) shadows the repo/nodescr copy. addpath the
% rxfix dir AFTER setup.m so it takes precedence on the path.
RXFIXDIR='/mnt/onetb/scratch/qpsk_variants/fec_jupiter_rxfix';
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
cd(RXFIXDIR);
addpath(RXFIXDIR);   % LAST -> highest precedence: picks up the fixed params + overlays
% Hard-verify the fixed threshold IS the one that will be used:
Pchk = commhdlQPSKTxRxParameters();
assert(abs(Pchk.CFOChangeDetectThreshold-0.0125)<1e-9, ...
    sprintf('RXFIX params NOT active: CFOChangeDetectThreshold=%.7g (expected 0.0125). which=%s', ...
    Pchk.CFOChangeDetectThreshold, which('commhdlQPSKTxRxParameters')));
fprintf('RXFIX params ACTIVE: CFOChangeDetectThreshold=%.7g  (%s)\n', ...
    Pchk.CFOChangeDetectThreshold, which('commhdlQPSKTxRxParameters'));
fprintf('build_variant_fec_dbg cwd=%s\n', pwd);

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
loop = [sys '/TxRxComposite'];

% Phase 0: patch the workflow with the 6 new AXI mappings (idempotent).
patch_hdlworkflow_counters('hdlworkflow_loopback.m');

% Phase 1: composite topology
run('build_composite_local.m');
% Phase 2: verif (FIR+MUX) + integAvgLen 2^12 overlay
run('variant_pre.m');
% Phase 2.5: FEC insertion overlay into the SYNTHESIZED TxRxComposite DUT copy
fprintf('=== applying FEC insertion overlay (base=%s) ===\n', loop);
fec_insert_overlay(sys, loop);
% Phase 2.6: FEC-Rx debug COUNTERS overlay
fprintf('=== applying FEC counters overlay (base=%s) ===\n', loop);
fec_counters_overlay(sys, loop);
% Phase 2.7: dbg4 -- runtime RxAlign skip-count AXI register (0x138)
fprintf('=== applying FEC skip-count register overlay (base=%s) ===\n', loop);
fec_skipreg_overlay(sys, loop);
% Phase 2.8: dbg6 -- intermediate-stage bit capture (0x13C/0x140/0x144 + cap_cad 0x14C)
fprintf('=== applying FEC capture overlay (base=%s) ===\n', loop);
fec_capture_overlay(sys, loop);
% Phase 2.9: nodescr -- BYPASS+REMOVE the HDL Data Descrambler (no PN-phase
% overlay here; descrambler is gone so pn_phase is moot). demod -> decoder direct.
fprintf('=== applying NO-DESCRAMBLE bypass overlay (base=%s) ===\n', loop);
fec_nodescr_overlay(sys, loop);

% Bump Description so smart-build cannot claim "no functional changes".
set_param(sys,'Description', sprintf('variant=%s pre=%s+FEC+DBGCNT build=%s', ...
    'jupiter_fir_cfc12', 'variant_pre_composite_verif_fir24_cfc_a12', char(datetime('now'))));
save_system(sys,[],'OverwriteIfChangedOnDisk',true);

% Hard pre-synth gate: FEC + counters + intacts.
assert(~isempty(find_system(loop,'LookUnderMasks','all','FollowLinks','on', ...
    'BlockType','SubSystem','Name','FEC Encoder Wrapper')), 'FEC encoder missing in DUT');
assert(~isempty(find_system(loop,'LookUnderMasks','all','FollowLinks','on', ...
    'MaskType','Viterbi Decoder')), 'Viterbi missing in DUT');
assert(~isempty(find_system(loop,'LookUnderMasks','all','FollowLinks','on', ...
    'Name','FecCounters')), 'FecCounters missing in DUT');
cnt_names = {'cnt_descr_in','cnt_frame_start','cnt_vit_reset','cnt_deint_valid','cnt_dec_bits','cnt_bist_start'};
for k=1:6
    assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Outport','Name',cnt_names{k})), ...
        'counter outport %s missing on TxRxComposite', cnt_names{k});
end
% dbg6/dbg8 capture + cadence outports present on TxRxComposite (cap_raw dropped in dbg9)
for r = {'cap_in','cap_deint','cap_out','cap_cad'}
    assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Outport','Name',r{1})), ...
        'capture outport %s missing on TxRxComposite', r{1});
end
% nodescr: the HDL Data Descrambler must be GONE; the FEC Decoder Wrapper must
% be fed DIRECTLY by the QPSK Demodulator (no descramble in the datapath).
assert(isempty(find_system(loop,'LookUnderMasks','all','FollowLinks','on', ...
    'BlockType','SubSystem','Name','HDL Data Descrambler')), ...
    'HDL Data Descrambler still present -- nodescr bypass failed');
assert(isempty(find_system(loop,'LookUnderMasks','all','FollowLinks','on', ...
    'Name','DescramPnPhase')), 'DescramPnPhase present -- pn_phase overlay must NOT run in nodescr');
% skip_count (0x138) still present (RxAlign still needs it)
assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Inport','Name','skip_count')), ...
    'skip_count inport missing on TxRxComposite');
% original AXI regs intact
for r = {'count_out','packets_out','bit_errors_out'}
    assert(~isempty(find_system(loop,'SearchDepth',1,'Name',r{1})), '%s missing', r{1});
end
dq = find_system(loop,'LookUnderMasks','all','FollowLinks','on','BlockType','SubSystem','Name','QPSK Rx');
assert(contains(get_param(dq{1},'MaskInitialization'),'integAvgLen = 2^12;'), 'integAvgLen not 2^12');
fprintf('pre-synth gate OK: FEC+6 counters present, integAvgLen 2^12, 0x100-0x118 intact\n');

% Phase 3: synthesize + implement + bitgen.
run('hdlworkflow_loopback.m');
fprintf('VARIANT_BUILD_DONE: %s\n', 'fec_jupiter_nodescr');
