% assemble_jupiter_240k5_byte.m -- assemble the FULL jupiter_240k5_byte DUT
% model: the jupiter_240k5 kit (240-ksym, K=5 FEC-Rx, pre-coded-ROM BIST Tx,
% observability taps) PLUS the byte-DMA data plane with IN-FABRIC K=5 FEC Tx
% ENCODING. Shared by the checkhdl/S1 gates and the (future, post-T8) Vivado
% build driver. Run from the kit dir with the kit dir addpath'd LAST.
%
% Phases 0..2.11 are the donor assemble_jupiter_240k5.m verbatim; NEW:
%   2.12 byte_tx_overlay_k5      (Transmitter ext* ports + ByteBitShifter + BitMux)
%   2.13 fec_tx_encoder_overlay_k5 (infoValid-GATED K=5 [35 23] encoder ->
%        136x16 ping-pong interleaver -> +64 filler ones, spliced between the
%        shifter and BitMux u1; ROM branch untouched on BitMux u3)
%   2.14 byte_rx_overlay_k5      (recBit/recBitValid/recStart taps off the
%        Capture Data Bits sources = the DECODED 1084-bit info stream)
%   2.15 byte_plumbing_overlay_k5 (composite byte ports + ByteWordBuffer +
%        ByteSerializer WPP=16 + hdlworkflow byte maps, tx_data_source x"158",
%        RD -> 'JUPITER (RX & TX, BYTE DMA)')
%
% Register map: 0x100..0x154 preserved from jupiter_240k5 (0x11C = sentinel);
% NEW: 0x158 = tx_data_source (0 = ROM pre-coded BIST, 1 = byte-encoded).
%
% Gate (c) is INVERTED vs the donor: the in-fabric Tx FEC encoder is REQUIRED
% and must be infoValid-gated (the qpsk-fec-zed-encoder-fix failure class).

KITDIR = fileparts(mfilename('fullpath'));
assert(strcmp(pwd, KITDIR), 'run from %s (pwd=%s)', KITDIR, pwd);

sys  = 'commhdlQPSKTxRxLoopback';
loop = [sys '/TxRxComposite'];

% Hard-verify the kit params are the active ones (sps=8, stock threshold)
Pchk = commhdlQPSKTxRxParameters();
assert(Pchk.SamplesPerSymbol == 8, 'kit params NOT active: sps=%d which=%s', ...
    Pchk.SamplesPerSymbol, which('commhdlQPSKTxRxParameters'));
assert(abs(Pchk.CFOChangeDetectThreshold - 0.0125) < 1e-12, ...
    'threshold=%.7g (expected RXFIX 0.0125)', Pchk.CFOChangeDetectThreshold);
fprintf('240k5_byte params ACTIVE: sps=%d thr=%.7g (%s)\n', Pchk.SamplesPerSymbol, ...
    Pchk.CFOChangeDetectThreshold, which('commhdlQPSKTxRxParameters'));

% Phase 0: workflow AXI map patches (all idempotent)
patch_hdlworkflow_counters('hdlworkflow_loopback.m');
patch_hdlworkflow_taps('hdlworkflow_loopback.m');
patch_hdlworkflow_forensic('hdlworkflow_loopback.m');   % T8.3: adc_forensic x"15C"

% Phase 0b: rate restoration on the source model (idempotent, saves slx)
rate_240k_overlay();
% Phase 0b2: Symbol Synchronizer 8-sps fix (see donor header; idempotent)
ss8_fix_overlay();
% Phase 0b2b: T8.4 symbol-timing anti-wedge hardening (IC Delta clamp +
% Loop Filter IntegClamp + DTC17 saturation; idempotent; see tb_timing_wedge.v)
timing_hardening_overlay();
% Phase 0b3: AGC gain-range fix for OTA levels (Phase B 2026-07-07; T8.3 rev).
% Default fixdt(1,16,10) (+-32, slice gain[33:18]) WITH the loop-filter
% accumulator widened to fixdt(1,34,28). Same-version file as the
% jupiter_240k5 master (commit 3a6d320). Idempotent, saves slx.
agc_gain_range_overlay();   % default fracBits=10 (+-32); pass 11 for +-16

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

% Phase 2.12: T8.3 ADC ingest forensic register (0x15C) -- same-version file
% as the jupiter_240k5 master (commit 3a6d320)
fprintf('=== applying ADC forensic overlay ===\n');
adc_forensic_overlay(sys, loop);

% Phase 2.12b: activate the runtime debug tap mux (0x10C) + boundary state-pair
% registers (0x160-0x16C) -- error-hunt campaign B1 (see iq_debug_tap_overlay.m)
fprintf('=== applying IQ debug tap + state-pair overlay ===\n');
iq_debug_tap_overlay(sys, loop);

% LEAN mode (QPSK_LEAN=1): production images skip the debug shadow/telemetry
% overlays -- their verdicts are delivered (loops RTL-faithful, corruption in
% the DMA plane) and the full stack + FIFO exceeds the ZU3EG (placer 102%,
% 2026-07-15). The instrumented lineage lives on in jupiter_byte_canary4_build.
LEAN = ~isempty(getenv('QPSK_LEAN'));
if LEAN, fprintf('=== LEAN build: skipping canary/canary2/canary3/cfc-tap ===\n'); end

if ~LEAN
% Phase 2.12d: T8.5 shadow timing loop + fabric canaries (0x170-0x188) --
% direct on-chip live-vs-deterministic divergence measurement (Class 1/4)
fprintf('=== applying canary instrumentation overlay ===\n');
canary_instrumentation_overlay(sys, loop);

% Phase 2.12e: T8.6 path canary + IC/carrier shadow extension (0x18C-0x1A0)
fprintf('=== applying canary2 overlay ===\n');
canary2_overlay(sys, loop);

% Phase 2.12f: T8.7 state telemetry (24-slot broadcast on mux mode 4).
% RE-ENABLED after the type triage: the original failure was Simulink's
% double-probe of the MLFB body during propagation (NOT a real type
% mismatch -- probe4 proved all 17 compiled types match the reinterpret
% widths). Fixed by pinning explicit port types on the chart data and a
% bitsliceget body (no lambdas / uint64(fi), HDL-safe). Harness-proven at
% the exact compiled types (telharness arms A+B).
fprintf('=== applying canary3 telemetry overlay ===\n');
canary3_telemetry_overlay(sys, loop);

% Phase 2.12g: debug-mux mode 5 = CFC output (SS->CFC->CS bisect; must
% follow canary3 so mode numbering stays 4=telemetry, 5=CFC).
fprintf('=== applying cfc tap overlay ===\n');
cfc_tap_overlay(sys, loop);
end   % ~LEAN

% ---------------- NEW byte + in-fabric-FEC-Tx phases ----------------
% Phase 2.13: byte-TX path into the Transmitter (composite copy)
fprintf('=== applying byte TX path overlay (K5) ===\n');
byte_tx_overlay_k5(sys, loop);
% Phase 2.14: IN-FABRIC K=5 FEC Tx encoder chain (infoValid-gated)
fprintf('=== applying in-fabric FEC Tx encoder overlay (K5) ===\n');
fec_tx_encoder_overlay_k5(sys, loop);
% Phase 2.15: byte-RX taps off the Capture Data Bits sources
fprintf('=== applying byte RX tap overlay (K5) ===\n');
byte_rx_overlay_k5(sys, loop);
% Phase 2.16: composite byte plumbing + hdlworkflow byte maps + byte RD
fprintf('=== applying byte plumbing overlay (K5) ===\n');
byte_plumbing_overlay_k5(sys, loop);

% Phase 2.16b: THE FIX -- elastic byte-rx FIFO (256 deep, ovf 0x1B0). The
% single-held-word presentation drops ~50 words per tick-induced DMA stall
% (= the dominant ~3 lost frames/episode + the junk class). BEFORE canary4
% so ByteCensus taps the FIFO's valid.
fprintf('=== applying byte rx FIFO overlay ===\n');
byte_rxfifo_overlay(sys, loop);

% Phase 2.16c: canary4 valid-census counters (CS validIn / LF valid / CS
% validOut -> 0x1A0/0x1A4/0x1A8) + byte-DMA census (0x1AC).
fprintf('=== applying canary4 valid census overlay ===\n');
canary4_validcensus_overlay(sys, loop);

% Phase 2.16d: P1B decision-stage census (Peak Search / Timing Adjust / PD
% FIFO / Packet Controller / Phase Ambiguity -> 0x1B4-0x1C8) -- the last
% un-instrumented corner; names the stage whose decision cadence breaks at
% device ticks.
fprintf('=== applying P1B decision taps overlay ===\n');
p1b_decision_taps_overlay(sys, loop);

% Phase 2.16e: THE CLASS-1 FIX -- Timing Adjust tracks the freshest peak
% report (offset hold + armed set := timingOffsetValid; stale-offset fires
% and report-discard-while-armed eliminated). Healthy-path bit-identical.
fprintf('=== applying Timing Adjust fix overlay ===\n');
timing_adjust_fix_overlay(sys, loop);

% Phase 2.16f: P1C -- full beat-exact Preamble Detector state+input
% telemetry (8-word snapshot per symbol on the debug-mux stream; lands as
% mode 4 in LEAN builds). The sim-mirroring instrument.
fprintf('=== applying P1C PD telemetry overlay ===\n');
p1d_pd_telemetry_overlay(sys, loop);

% Phase 2.16g: P1E -- tick-displacement compensation (newPk-armed RxDeint
% 64-bit head skip; recovers the stale-grid frame at each +32 insert
% transition). Splice-testbench proven (hdlD2 bit-true netlist). Depends on
% the p1d-surfaced Peak Search ports and the FEC RxDeint MLFB.
fprintf('=== applying P1E tick-compensation overlay ===\n');
p1e_comp_overlay(sys, loop);

% Phase 2.17: PHASE-AMBIGUITY RESOLVER FIX (arbitrary-data 4-fold quadrant).
% The T8 rate fix (enb_1_4_0 -> enb_1_2_0, 8 samp/sym) halved the estimator's
% fixed 40-sample look-back so its 8-symbol correlation window slid off the
% Barker preamble onto payload -> payload-dependent phase estimate -> constant
% +90deg for non-golden data. Restore the look-back (+40 samples on the
% estimator dataIn/validIn only). Verilator-proven: golden 04922282, qk
% 002ed28a, rand af0666a8; cap_in==tx_air, cap_deint==enc_coded, byte_rx OK.
fprintf('=== applying phase-ambiguity resolver look-back fix ===\n');
resolver_lookback_fix(sys, loop);

% Bump Description so smart-build cannot claim "no changes".
set_param(sys,'Description', sprintf('variant=%s pre=%s build=%s', ...
    'jupiter_240k5_byte(sps8/Rsym1.92e6-T8ratefix,K5[35 23]TB25 rx+GATED-txenc,ROMk5+byteDMA,noscr+nodescr,taps 0x150/0x154/0x15C,agcEn10,txds 0x158,WPP16)', ...
    'variant_pre_composite_verif+cfc_a12+bytek5', char(datetime('now'))));
save_system(sys,[],'OverwriteIfChangedOnDisk',true);

% ---------------- hard pre-synth gates ----------------
% (a) ROM literal in the DUT chart; stock ROM gone
romLit = strtrim(fileread(fullfile(fileparts(KITDIR),'k5_240','rom_words_70_k5.txt')));
ch = sfroot().find('-isa','Stateflow.EMChart','Path', ...
    [loop '/Transmitter/Input Data/Message Generator/MATLAB Function']);
assert(~isempty(ch), 'msggen chart not found for gate');
assert(contains(ch(1).Script, romLit), 'GATE FAIL: K5 ROM literal missing in chart');
assert(~contains(ch(1).Script, 'ADI Hello World'), 'GATE FAIL: stock ROM still in chart');
% (b) scrambler disabled
scrEn = get_param([loop '/Transmitter/QPSK Tx/HDL Data Scrambler/EnableScrambling'],'Value');
assert(strcmpi(strtrim(scrEn),'false'), 'GATE FAIL: EnableScrambling=%s', scrEn);
% (c) INVERTED vs donor: in-fabric Tx FEC encoder REQUIRED + infoValid-GATED.
%     (donor asserted NO encoder; this kit's byte branch encodes in fabric.)
encSub = find_system(loop,'LookUnderMasks','all','FollowLinks','on', ...
    'BlockType','SubSystem','Name','FEC Tx Encoder K5');
assert(numel(encSub)==1, 'GATE FAIL: FEC Tx Encoder K5 missing (found %d)', numel(encSub));
ceCh = sfroot().find('-isa','Stateflow.EMChart','Path', ...
    [loop '/Transmitter/Input Data/FEC Tx Encoder K5/ConvEncK5']);
assert(~isempty(ceCh), 'GATE FAIL: ConvEncK5 chart missing');
ceS = ceCh(1).Script;
assert(contains(ceS,'advance ONLY on infoValid') && contains(ceS,'if infoValid') ...
    && contains(ceS,'sr = [in, srUse(1:3)];') && contains(ceS,'poly 35 oct') ...
    && contains(ceS,'poly 23 oct'), ...
    'GATE FAIL: ConvEncK5 is NOT the infoValid-gated K=5 [35 23] encoder');
% the shift-register advance must be reachable ONLY through the infoValid guard
idxGuard = strfind(ceS,'if infoValid'); idxShift = strfind(ceS,'sr = [in, srUse(1:3)];');
assert(~isempty(idxGuard) && ~isempty(idxShift) && idxGuard(1) < idxShift(1), ...
    'GATE FAIL: encoder advance not guarded by infoValid');
% interleaver + PN9 filler markers (T8 fix 6bcaa62: filler = PN9 x^9+x^5+1
% seed all-ones = golden payload(2177:2240); the legacy 64-ones filler's DC
% dwell was notched by the TX LOL tracking cal)
gFill = load(fullfile(fileparts(KITDIR),'k5_240','golden_k5.mat'),'payload');
fillBits = double(gFill.payload(2177:2240));
lfsrG = ones(9,1); fillRef = zeros(64,1);
for fk = 1:64
    fbG = xor(lfsrG(9), lfsrG(5));
    fillRef(fk) = lfsrG(9);
    lfsrG = [fbG; lfsrG(1:8)]; %#ok<AGROW>
end
assert(isequal(fillBits(:), fillRef(:)), ...
    'GATE FAIL: golden filler != PN9 spec (stale golden_k5.mat?)');
fillLitG = strjoin(arrayfun(@(b) sprintf('%d',b), fillBits(:).', 'UniformOutput', false), ' ');
tiCh = sfroot().find('-isa','Stateflow.EMChart','Path', ...
    [loop '/Transmitter/Input Data/FEC Tx Encoder K5/TxInterleaveK5']);
assert(~isempty(tiCh) && contains(tiCh(1).Script,'CODED=uint16(2176)') ...
    && contains(tiCh(1).Script,'ROWS=uint16(136)') ...
    && contains(tiCh(1).Script,'perm = r*COLS + c') ...
    && contains(tiCh(1).Script,['FILL = logical([' fillLitG ']);']) ...
    && contains(tiCh(1).Script,'dataOut = FILL('), ...
    'GATE FAIL: TxInterleaveK5 does not carry the K5 2176/136x16/PN9-filler contract');
% K=5 Viterbi still present with TB=25 (Rx chain untouched)
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
% (e2) resolver look-back fix present on the DUT Phase Ambiguity block(s)
paefix = find_system(loop,'LookUnderMasks','all','FollowLinks','on', ...
    'BlockType','SubSystem','Name','Phase Ambiguity Estimation and Correction');
assert(~isempty(paefix), 'GATE FAIL: Phase Ambiguity Estimation and Correction subsystem missing');
% NOTE: loop variable MUST NOT be named 'pi'. This is a SCRIPT: a 'for pi=...'
% here leaves pi==numel(paefix)==1 in the base workspace, and the later
% in-session makehdl then evaluates bare-pi mask expressions with pi==1:
%   QPSK Demodulator 'Ph'=pi/4 -> 0.25 rad  => derotation 30.68deg, decision
%     margin 45deg->14.3deg = THE deterministic ~2-3e-3 OTA BER floor;
%   Carrier Sync loop-filter 'Gain'=fi(g/(2*pi)) -> 3.14x hot loop (307 vs 98).
% Found 2026-07-11 by the float-vs-fixed capture-replay campaign.
for pk = 1:numel(paefix)
    assert(~isempty(find_system(paefix{pk},'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','BlockType','Delay','Name','EstDataLookback')) && ...
        ~isempty(find_system(paefix{pk},'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','BlockType','Delay','Name','EstVldLookback')), ...
        'GATE FAIL: resolver look-back fix (EstDataLookback/EstVldLookback) missing in %s', paefix{pk});
    assert(strcmp(strtrim(get_param([paefix{pk} '/EstDataLookback'],'DelayLength')),'40'), ...
        'GATE FAIL: EstDataLookback length != 40 in %s', paefix{pk});
end
clear pk
% pi-integrity gate: bare-pi mask expressions (demod Ph, CS loop gains) compile
% against the workspace -- if ANY variable shadows the builtin, fail loudly here.
assert(abs(pi - 3.141592653589793) < 1e-12, ...
    'GATE FAIL: pi is SHADOWED by a workspace variable (pi=%.9g) -- mask expressions would mis-evaluate', pi);
% (e3) debug tap mux + state pairs present (iq_debug_tap_overlay)
dbgsrc = get_param(get_param(getfield(get_param([loop '/debugI'],'LineHandles'),'Inport'), ...
    'SrcBlockHandle'),'Name');
assert(strcmp(dbgsrc,'Receiver'), ...
    'GATE FAIL: composite debugI not driven by Receiver muxed diag (src=%s)', dbgsrc);
assert(~isempty(find_system([loop '/Receiver/QPSK Rx'],'SearchDepth',1,'LookUnderMasks','all', ...
    'FollowLinks','on','Name','StatePairProbe')), 'GATE FAIL: StatePairProbe missing');
for spn = {'state_agc_in','state_agc_out','state_cs_in','state_cs_out'}
    assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Outport','Name',spn{1})), ...
        'GATE FAIL: composite outport %s missing', spn{1});
end
fprintf('gate(e3): debug tap mux wired + StatePairProbe + 4 state-pair outports present\n');
fprintf('gate(e2): resolver look-back fix present (EstDataLookback/EstVldLookback len=40) on %d block(s)\n', numel(paefix));
% (f) threshold resolves to stock in the DUT mask ws (mask ws only exists after
%     a compile -- resolve here if available, else defer to the post-Update
%     assert in checkhdl_gate_240k5_byte.m)
try
    thr = slResolve('CFOChangeDetectThreshold', dq{1});
    assert(abs(double(thr)-0.0125) < 1e-12, 'GATE FAIL: DUT threshold %.7g (expected RXFIX 0.0125)', double(thr));
    fprintf('gate(f): DUT mask threshold resolved = %.7g\n', double(thr));
catch e
    if contains(e.message,'GATE FAIL'), rethrow(e); end
    fprintf('gate(f): slResolve deferred to post-Update check (%s)\n', strtrim(e.message));
end
% (f2) T8.3 forensic: AdcForensic block present + workflow AXI mapping x"15C"
assert(~isempty(find_system(loop,'SearchDepth',1,'Name','AdcForensic')), ...
    'GATE FAIL: AdcForensic block missing');
wfT8 = fileread('hdlworkflow_loopback.m');
assert(contains(wfT8, 'adc_forensic') && contains(wfT8, 'x"15C"'), ...
    'GATE FAIL: adc_forensic x"15C" mapping missing from hdlworkflow_loopback.m');
% (f3) T8.3 AGC gain-range types took on the DUT copy (composite clone)
agcB = [loop '/Receiver/QPSK Rx/Automatic Gain Control'];
assert(strcmp(strtrim(get_param([agcB '/Data Type Conversion'],'OutDataTypeStr')), ...
    'fixdt(1,16,10)'), 'GATE FAIL: AGC gain DTC not fixdt(1,16,10)');
assert(strcmp(strtrim(get_param([agcB '/Loop Filter/Gain1'],'OutDataTypeStr')), ...
    'fixdt(1,34,28)'), 'GATE FAIL: AGC Loop Filter Gain1 not fixdt(1,34,28)');
assert(isempty(find_system(agcB,'SearchDepth',1,'LookUnderMasks','all', ...
    'FollowLinks','on','BlockType','DataTypeDuplicate')), ...
    'GATE FAIL: AGC-level Data Type Duplicate still present');
% (g) register-map ports present (preserved donor set + taps + forensic + BYTE ports)
for r = {'count_out','packets_out','bit_errors_out','dbg_sentinel', ...
         'cnt_descr_in','cnt_frame_start','cnt_vit_reset','cnt_deint_valid', ...
         'cnt_dec_bits','cnt_bist_start','cap_in','cap_deint','cap_out','cap_cad', ...
         'rstcs_count','cfc_est','adc_forensic', ...
         'byte_ready','byte_rx_data','byte_rx_valid','byte_rx_last','byte_rx_user'}
    assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Outport','Name',r{1})), ...
        'GATE FAIL: outport %s missing', r{1});
end
for r = {'skip_count','byte_data','byte_valid','tx_data_source','byte_first','byte_rx_ready'}
    assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Inport','Name',r{1})), ...
        'GATE FAIL: inport %s missing', r{1});
end
% (g2) Transmitter byte boundary + shifter/mux structure present
txph = get_param([loop '/Transmitter'],'PortHandles');
assert(numel(txph.Inport)==8 && numel(txph.Outport)==9, ...
    'GATE FAIL: Transmitter ports %d/%d (expected 8/9)', numel(txph.Inport), numel(txph.Outport));
for n = {'ByteBitShifter','BitMux'}
    assert(~isempty(find_system([loop '/Transmitter/Input Data'],'SearchDepth',1, ...
        'LookUnderMasks','all','FollowLinks','on','Name',n{1})), 'GATE FAIL: %s missing', n{1});
end
for n = {'ByteWordBuffer','ByteSerializer','ByteRxFifo'}   % BeatGate replaced by the elastic FIFO (2.16b)
    assert(~isempty(find_system(loop,'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','Name',n{1})), 'GATE FAIL: %s missing', n{1});
end
% (g3) serializer WORDS_PER_PACKET=16 literal (128 B/frame of the 1084 info bits)
bsCh = sfroot().find('-isa','Stateflow.EMChart','Path',[loop '/ByteSerializer']);
assert(~isempty(bsCh) && contains(bsCh(1).Script,'uint8(16)'), ...
    'GATE FAIL: ByteSerializer WORDS_PER_PACKET literal is not 16');
% (g4) hdlworkflow: byte maps present, tx_data_source at x"158", sentinel x"11C"
wfTxt = fileread('hdlworkflow_loopback.m');
assert(contains(wfTxt,'composite-byte mappings'), 'GATE FAIL: workflow byte mappings missing');
assert(contains(wfTxt, sprintf('hdlset_param(''%s/TxRxComposite/tx_data_source'', ''IOInterfaceMapping'', ''x"158"'');', sys)), ...
    'GATE FAIL: tx_data_source not mapped to x"158"');
assert(contains(wfTxt, sprintf('hdlset_param(''%s/TxRxComposite/dbg_sentinel'', ''IOInterfaceMapping'', ''x"11C"'');', sys)), ...
    'GATE FAIL: dbg_sentinel x"11C" mapping lost');
assert(~contains(wfTxt, '''JUPITER (RX & TX - RX IS FASTER OR HAS PRIORITY)'''), ...
    'GATE FAIL: ReferenceDesign not retargeted');
assert(contains(wfTxt, '''JUPITER (RX & TX, BYTE DMA)'''), 'GATE FAIL: byte RD missing');
assert(contains(wfTxt, '''multiple'',''2'''), 'GATE FAIL: ReferenceDesignParameter multiple=2 lost');
% (h) Rsym/sps pair took (T8 RATE FIX): base-ws Rsym must be 1.92e6 so the
%     QPSK rail Rsym*sps = 15.36e6 model = 1.92M physical -> TRUE 240 ksym Tx
%     (the S1-era 0.96e6 put the Tx rail on the 0.96M rung = 120 ksym air)
rs = evalin('base','Rsym');
assert(abs(double(rs) - 1.92e6) < 1, 'GATE FAIL: Rsym=%g (expected 1.92e6, T8 rate fix)', double(rs));
fprintf(['ASSEMBLE_240K5_BYTE PRE-SYNTH GATES OK (ROM k5 BIST + byte-DMA, GATED in-fabric K5 Tx encoder,\n' ...
         '  noscr, K5 rx TB25, nodescr, 2^12, thr 0.0125, agc En10 +-32, regs 0x100..0x15C + txds 0x158,\n' ...
         '  WPP16, byte RD, Rsym 1.92e6 x sps 8 -- T8 rate fix)\n']);
