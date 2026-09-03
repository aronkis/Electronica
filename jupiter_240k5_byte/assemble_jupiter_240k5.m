% assemble_jupiter_240k5.m -- assemble the FULL jupiter_240k5 DUT model
% (240-ksym design point, K=5 FEC-Rx, pre-coded-ROM Tx, observability taps).
% Shared by the checkhdl/S1 gate and the Vivado build driver. Run from the
% kit dir with the kit dir addpath'd LAST (its params file must win).
%
% Phases (donor flow = fec_jupiter_rxfix/build_variant_fec_dbg.m, plus the
% jupiter_msggenrom ROM/no-scramble phases and the new 240k5 overlays):
%   0  patch hdlworkflow (counters map -- already in donor file; taps 0x150/0x154)
%   0b rate_240k_overlay on the SOURCE commhdlQPSKTxRx.slx (Rsym 1.92e6->0.96e6
%      + the four 1/(Rsym*4) sample times -> 1/(Rsym*SamplesPerSymbol); pairs
%      with SamplesPerSymbol 4->8 in commhdlQPSKTxRxParameters.m)
%   1  build_composite_local (clone -> TxRxComposite)
%   1.5 msggen_rom_overlay_k5 (pre-coded K=5 packet ROM, in-FPGA generator)
%   2  variant_pre (verif FIR+MUX overlay + integAvgLen 2^12)
%   2.5 fec_insert_overlay_rxonly_k5 (K=5 [35 23] TB=25 deint 136x16; NO Tx encoder)
%   2.6 fec_counters_overlay (0x120..0x134 + 0x11C sentinel)
%   2.7 fec_skipreg_overlay (0x138)
%   2.8 fec_capture_overlay (0x13C/0x140/0x144 + 0x14C)
%   2.9 fec_nodescr_overlay (descrambler removed; demod -> decoder direct)
%   2.10 fec_remove_scrambler (Tx scrambler EnableScrambling=false; air unscrambled)
%   2.11 taps_240k5_overlay (0x150 rstCS-event counter, 0x154 CFC estimate,
%        capture DMA retargeted to iq_debug_mux taps incl. post-carrier-sync)
%   3  hard pre-synth gates, save.
%
% Register map preserved: 0x100..0x144 identical to the fec_jupiter_rxfix
% donor; ONLY 0x150/0x154 added. tx_data_source (byte path) does not exist in
% this donor -- the in-FPGA generator is the only Tx bit source (the runtime
% "tx_data_source=0" condition is structural).

KITDIR = '/mnt/onetb/scratch/qpsk_variants/jupiter_240k5_byte';
assert(strcmp(pwd, KITDIR), 'run from %s (pwd=%s)', KITDIR, pwd);

sys  = 'commhdlQPSKTxRxLoopback';
loop = [sys '/TxRxComposite'];

% Hard-verify the kit params are the active ones (sps=8, stock threshold)
Pchk = commhdlQPSKTxRxParameters();
assert(Pchk.SamplesPerSymbol == 8, 'kit params NOT active: sps=%d which=%s', ...
    Pchk.SamplesPerSymbol, which('commhdlQPSKTxRxParameters'));
assert(abs(Pchk.CFOChangeDetectThreshold - 0.0015625) < 1e-12, ...
    'threshold=%.7g (expected stock 0.0015625)', Pchk.CFOChangeDetectThreshold);
fprintf('240k5 params ACTIVE: sps=%d thr=%.7g (%s)\n', Pchk.SamplesPerSymbol, ...
    Pchk.CFOChangeDetectThreshold, which('commhdlQPSKTxRxParameters'));

% Phase 0: workflow AXI map patches (both idempotent)
patch_hdlworkflow_counters('hdlworkflow_loopback.m');
patch_hdlworkflow_taps('hdlworkflow_loopback.m');

% Phase 0b: rate restoration on the source model (idempotent, saves slx)
rate_240k_overlay();
% Phase 0b2: Symbol Synchronizer 8-sps fix (Interpolation Control W 1/4->1/8 +
% mu x4->x8; GTED taps z-4/z-4 -> z-8/z-6). Root cause of the on-chip Rx no-lock,
% proven by RTL replay of real air (k5_240/RXROOT.txt). Idempotent, saves slx.
ss8_fix_overlay();
% Phase 0b3: AGC gain-range fix for OTA levels (Phase B 2026-07-07). The AGC
% gain word was sfix16_En14 (range +-2.0, wrap slice gain[29:14]) -> wraps at
% OTA input levels (rms<4096) -> Rx collapse. Widen to fixdt(1,16,11) (+-16,
% slice gain[32:17]). Sim-proven on real OTA captures: golden at rms 580,
% no cable-level regression, lock floor rms~511. Idempotent, saves slx.
agc_gain_range_overlay();

% Phase 1: composite topology
run('build_composite_local.m');

% Phase 1.5: pre-coded K=5 msggen ROM
fprintf('=== applying K5 message-generator ROM overlay ===\n');
msggen_rom_overlay_k5(sys, loop);

% Phase 2: verif overlay (FIR + MUX + AdcCap front end) + integAvgLen 2^12
run('variant_pre.m');

% Phase 2.5..2.9: FEC-Rx chain (K=5) + debug regs + nodescr
fprintf('=== applying K5 RX-ONLY FEC insertion overlay ===\n');
fec_insert_overlay_rxonly_k5(sys, loop);
fprintf('=== applying FEC counters overlay ===\n');
fec_counters_overlay(sys, loop);
fprintf('=== applying FEC skip-count register overlay ===\n');
fec_skipreg_overlay(sys, loop);
fprintf('=== applying FEC capture overlay ===\n');
fec_capture_overlay(sys, loop);
fprintf('=== applying NO-DESCRAMBLE bypass overlay ===\n');
fec_nodescr_overlay(sys, loop);

% Phase 2.10: Tx scrambler OFF (matches the no-descramble Rx / on-air contract)
fprintf('=== applying scrambler bypass (no-scramble) ===\n');
fec_remove_scrambler(sys, loop);

% Phase 2.11: observability taps + capture retarget
fprintf('=== applying 240k5 observability taps overlay ===\n');
taps_240k5_overlay(sys, loop);

% Bump Description so smart-build cannot claim "no changes".
set_param(sys,'Description', sprintf('variant=%s pre=%s build=%s', ...
    'jupiter_240k5(sps8/Rsym0.96e6,K5[35 23]TB25 rxonly,ROMk5,noscr+nodescr,taps 0x150/0x154)', ...
    'variant_pre_composite_verif+cfc_a12', char(datetime('now'))));
save_system(sys,[],'OverwriteIfChangedOnDisk',true);

% ---------------- hard pre-synth gates ----------------
% (a) ROM literal in the DUT chart; stock ROM gone
romLit = strtrim(fileread('/mnt/onetb/scratch/qpsk_variants/k5_240/rom_words_70_k5.txt'));
ch = sfroot().find('-isa','Stateflow.EMChart','Path', ...
    [loop '/Transmitter/Input Data/Message Generator/MATLAB Function']);
assert(~isempty(ch), 'msggen chart not found for gate');
assert(contains(ch(1).Script, romLit), 'GATE FAIL: K5 ROM literal missing in chart');
assert(~contains(ch(1).Script, 'ADI Hello World'), 'GATE FAIL: stock ROM still in chart');
% (b) scrambler disabled
scrEn = get_param([loop '/Transmitter/QPSK Tx/HDL Data Scrambler/EnableScrambling'],'Value');
assert(strcmpi(strtrim(scrEn),'false'), 'GATE FAIL: EnableScrambling=%s', scrEn);
% (c) NO Tx FEC encoder; K=5 Viterbi present with TB=25
assert(isempty(find_system(loop,'LookUnderMasks','all','FollowLinks','on', ...
    'BlockType','SubSystem','Name','FEC Encoder Wrapper')), 'GATE FAIL: Tx FEC encoder present');
vit = find_system(loop,'LookUnderMasks','all','FollowLinks','on','MaskType','Viterbi Decoder');
assert(numel(vit) == 1, 'GATE FAIL: %d Viterbi decoders', numel(vit));
vtr = strrep(get_param(vit{1},'trellis'),' ','');
assert(contains(vtr,'poly2trellis(5,[3523])'), 'GATE FAIL: Viterbi trellis %s', get_param(vit{1},'trellis'));
assert(strcmp(strtrim(get_param(vit{1},'tbdepth')),'25'), 'GATE FAIL: tbdepth %s', get_param(vit{1},'tbdepth'));
% (d) descrambler gone; demod feeds decoder
assert(isempty(find_system(loop,'LookUnderMasks','all','FollowLinks','on', ...
    'BlockType','SubSystem','Name','HDL Data Descrambler')), 'GATE FAIL: descrambler present');
% (e) integAvgLen 2^12 on the DUT QPSK Rx
dq = find_system(loop,'LookUnderMasks','all','FollowLinks','on','BlockType','SubSystem','Name','QPSK Rx');
assert(contains(get_param(dq{1},'MaskInitialization'),'integAvgLen = 2^12;'), 'GATE FAIL: integAvgLen not 2^12');
% (f) threshold resolves to stock in the DUT mask ws (mask ws only exists after
%     a compile -- resolve here if available, else defer to the post-Update
%     assert in checkhdl_gate_240k5.m; the params-file value was hard-asserted
%     at the top of this script either way)
try
    thr = slResolve('CFOChangeDetectThreshold', dq{1});
    assert(abs(double(thr)-0.0015625) < 1e-12, 'GATE FAIL: DUT threshold %.7g', double(thr));
    fprintf('gate(f): DUT mask threshold resolved = %.7g\n', double(thr));
catch e
    if contains(e.message,'GATE FAIL'), rethrow(e); end
    fprintf('gate(f): slResolve deferred to post-Update check (%s)\n', strtrim(e.message));
end
% (g) register-map ports present (preserved donor set + new taps)
for r = {'count_out','packets_out','bit_errors_out','dbg_sentinel', ...
         'cnt_descr_in','cnt_frame_start','cnt_vit_reset','cnt_deint_valid', ...
         'cnt_dec_bits','cnt_bist_start','cap_in','cap_deint','cap_out','cap_cad', ...
         'rstcs_count','cfc_est'}
    assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Outport','Name',r{1})), ...
        'GATE FAIL: outport %s missing', r{1});
end
assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Inport','Name','skip_count')), ...
    'GATE FAIL: skip_count inport missing');
% (h) Rsym/sps pair took: base-ws Rsym (set by ModelInit from the Input Data
%     dialog) must be 0.96e6 so the QPSK rail Rsym*sps stays 7.68e6
rs = evalin('base','Rsym');
assert(abs(double(rs) - 0.96e6) < 1, 'GATE FAIL: Rsym=%g (expected 0.96e6)', double(rs));
fprintf('ASSEMBLE_240K5 PRE-SYNTH GATES OK (ROM k5, noscr, K5 rxonly TB25, nodescr, 2^12, thr 0.0015625, regs 0x100..0x154, Rsym 0.96e6 x sps 8)\n');
