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

% frame geometry + sps single source of truth (Task A1/A3); pre-synth gates
% assert emitted chart text against these instead of hardcoded literals.
cfg = frame_config_k5();

% Hard-verify the kit params are the active ones (sps matches frame_config,
% stock threshold). sps=8 default; sps=4 is the A3 2x-rate rung.
Pchk = commhdlQPSKTxRxParameters();
assert(Pchk.SamplesPerSymbol == cfg.Sps, 'kit params NOT active: params sps=%d != cfg sps=%d which=%s', ...
    Pchk.SamplesPerSymbol, cfg.Sps, which('commhdlQPSKTxRxParameters'));
assert(abs(Pchk.CFOChangeDetectThreshold - 0.0125) < 1e-12, ...
    'threshold=%.7g (expected RXFIX 0.0125)', Pchk.CFOChangeDetectThreshold);
fprintf('240k5_byte params ACTIVE: sps=%d thr=%.7g (%s)\n', Pchk.SamplesPerSymbol, ...
    Pchk.CFOChangeDetectThreshold, which('commhdlQPSKTxRxParameters'));

% Phase 0: workflow AXI map patches (all idempotent)
patch_hdlworkflow_counters('hdlworkflow_loopback.m');
patch_hdlworkflow_taps('hdlworkflow_loopback.m');
patch_hdlworkflow_forensic('hdlworkflow_loopback.m');   % T8.3: adc_forensic x"15C"
patch_hdlworkflow_loopgain('hdlworkflow_loopback.m');   % C3: loop-gain regs 0x170-0x184 (block-guarded)

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

% Phase 2.11b: RX framing span scale (Task A2 f1536 RX-decode fix). The
% base-model RX Packet Controller/End Generator hardcoded the k5 payload span
% (1120 = DataBitsPerPacket/2 symbols) in its Compare To Constant + HDL Counter,
% so at f1536 it ended each frame after 2240 bits and the deinterleaver read a
% mostly-empty bank (cap_deint garbage). This overlay derives the span from the
% QPSK Rx mask var dataBitsPerPacket (single-sourced from frame_config_k5), like
% the proven TX Data Bits FIFO counter. k5 -> identical (1120-1, 11-bit); f1536
% -> 12320-1, 14-bit. See rx_framing_overlay_k5.m header + task-A2-report.
fprintf('=== applying RX framing span overlay (K5) ===\n');
rx_framing_overlay_k5(sys, loop);

% LEAN mode (QPSK_LEAN=1): production images STRIP the debug shadow/telemetry
% overlays -- adc_forensic (0x15C), iq_debug state-pairs (0x160-0x16C),
% canary/canary2/canary3/cfc, canary4 valid-census (0x1A0-0x1AC), p1b decision
% taps (0x1B4-0x1C8). Their verdicts are delivered and the full stack + FIFO
% exceeds the ZU3EG (placer 102%, 2026-07-15). KEPT in LEAN: the 0x10C tap mux
% + dual-DMA, p1d telemetry, p1e comp, taps 0x150/0x154, fec_capture BIST
% golden, byte FIFO fix (0x1B0). Instrumented lineage: jupiter_byte_canary4_build.
LEAN = ~isempty(getenv('QPSK_LEAN'));
if LEAN, fprintf('=== LEAN build: stripping adc_forensic/state-pairs/canary*/p1b ===\n'); end

% Phase 2.12: T8.3 ADC ingest forensic register (0x15C) -- STRIP in LEAN.
% EXCEPTION (burst-hunt instrument): QPSK_ADC_FORENSIC=1 re-adds JUST this overlay
% to a LEAN build (small: one packed status register + counters; fits where the
% full debug set does not). Used to catch SSI valid-cadence glitches (maxGap/
% maxBurst) during the reverse 5-100-frame live-only bursts. The 0x15C mapping in
% hdlworkflow is block-existence-guarded, so it self-syncs.
if ~LEAN || ~isempty(getenv('QPSK_ADC_FORENSIC'))
fprintf('=== applying ADC forensic overlay (LEAN=%d, QPSK_ADC_FORENSIC=%s) ===\n', LEAN, getenv('QPSK_ADC_FORENSIC'));
adc_forensic_overlay(sys, loop);
end

% Phase 2.12b: runtime debug tap mux (0x10C) + boundary state-pairs (0x160-0x16C).
% iq_debug_tap_overlay drops the state-pairs internally under QPSK_LEAN and
% KEEPS the 0x10C mux + dual-DMA tap (the verification instrument).
fprintf('=== applying IQ debug tap overlay ===\n');
iq_debug_tap_overlay(sys, loop);

% Phase 2.12d: T8.5 shadow timing loop + fabric canaries (0x170-0x188) --
% direct on-chip live-vs-deterministic divergence measurement (Class 1/4).
% T8.9 STALL FIX (task #15): non-recursive preamble threshold sum -- removes the
% Delay14 recursive-accumulator vulnerability (confirmed live stall mechanism,
% FROZEN-class mutes). Env-gated for staged rollout; datapath-only, bit-exact
% in uncorrupted operation (netlist A/B gated in the harness).
if ~isempty(getenv('QPSK_MOVSUM_HARDEN'))
fprintf('=== applying movsum hardening overlay (LEAN=%d) ===\n', LEAN);
movsum_hardening_overlay(sys, loop);
end

% T9.0 LOOP-TUNE AXI REGISTERS (task #14): 6 runtime-writable receiver loop
% constants at 0x1F0-0x204, each CLAMPED in fabric to a safe band around its
% compiled default (a bad live write can mistune but cannot unlock the loop).
% Zero-default = compiled constant, so an unwritten image is bit-identical.
% Relocated off 0x170-0x184 (permanently held by the T8.5 canaries), so unlike
% the old loop_gain overlay this coexists with the full instrument set.
if ~isempty(getenv('QPSK_LOOP_TUNE'))
fprintf('=== applying loop-tune AXI overlay (LEAN=%d) ===\n', LEAN);
loop_tune_axi_overlay(sys, loop);
end

% T8.9 TMR stall fix (CHOSEN VARIANT, task #15): triplicated preamble-threshold
% accumulator + bitwise majority voter with write-back reconverge. A single
% upset of any copy is outvoted and corrected on the next enabled beat instead
% of persisting forever (the confirmed live FROZEN-class stall mechanism).
% REQUIRES tmr_keep.xdc in the Vivado flow (complete_byte_t8.tcl adds it when
% QPSK_MOVSUM_TMR is set) or synthesis merges the copies and deletes the fix.
if ~isempty(getenv('QPSK_MOVSUM_TMR'))
fprintf('=== applying movsum TMR overlay (LEAN=%d) ===\n', LEAN);
movsum_tmr_overlay(sys, loop);
end

% EXCEPTION (stall-catch instrument): QPSK_CANARY_T85=1 re-adds JUST this overlay to a
% LEAN build. COLLIDES with the LEAN loop_gain regs (0x170-0x184) -- build with
% QPSK_LOOP_GAIN_AXI=0. Purpose: shadow pdiv/idiv = state-TEAR detector; 0x184
% strobe forensic {maxStrobeGap|skip} = enable-tree starvation detector -- the two
% candidate physical mechanisms for the 5-100-frame delivery stall (the netlist
% injection campaign proved the algorithmic core self-heals every coherent upset).
if ~LEAN || ~isempty(getenv('QPSK_CANARY_T85'))
if ~isempty(getenv('QPSK_CANARY_T85')) && LEAN
    assert(strcmp(getenv('QPSK_LOOP_GAIN_AXI'),'0'), ...
        'QPSK_CANARY_T85 on LEAN requires QPSK_LOOP_GAIN_AXI=0 (0x170-0x184 collision)');
end
fprintf('=== applying canary instrumentation overlay (LEAN=%d) ===\n', LEAN);
canary_instrumentation_overlay(sys, loop);
end

% EXCEPTION (T8.8 stall finisher): QPSK_CANARY_TAOPS=1 exposes the SyncPulse
% equality operands (TA timing_Reference / Unit_Delay_En_Sync3 / PS tref) at
% 0x1E0-0x1E4 -- no address collision with loop_gain or T8.5. One mid-freeze
% read identifies WHICH operand is wrong. Allowed on LEAN.
if ~isempty(getenv('QPSK_CANARY_TAOPS'))
fprintf('=== applying canary5 taops overlay (LEAN=%d) ===\n', LEAN);
canary5_taops_overlay(sys, loop);
end

if ~LEAN
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
% validOut -> 0x1A0/0x1A4/0x1A8) + byte-DMA census (0x1AC). STRIP in LEAN.
% NB byte_rxfifo_overlay above is the shipped FIFO fix and is NOT gated.
if ~LEAN
fprintf('=== applying canary4 valid census overlay ===\n');
canary4_validcensus_overlay(sys, loop);
end

% Phase 2.16d: P1B decision-stage census (Peak Search / Timing Adjust / PD
% FIFO / Packet Controller / Phase Ambiguity -> 0x1B4-0x1C8) -- the last
% un-instrumented corner; names the stage whose decision cadence breaks at
% device ticks. STRIP in LEAN.
if ~LEAN
fprintf('=== applying P1B decision taps overlay ===\n');
p1b_decision_taps_overlay(sys, loop);
end

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

% Phase 2.18: C3 runtime-tunable loop-gain AXI registers (0x170-0x184).
% LEAN-ONLY (the offsets are the canary telemetry registers' in non-LEAN; those
% are env-guarded off in LEAN, freeing 0x170-0x184). Default ON in LEAN; set
% QPSK_LOOP_GAIN_AXI=0 to disable. Zero-default is bit-identical (the original
% Gain/Compare blocks stay on each mux's register==0 path) -- proven by the
% sim_byte_gate zero-default gate + loop_gain_poke_test_k5.m.
LOOPGAIN = LEAN && ~strcmp(getenv('QPSK_LOOP_GAIN_AXI'),'0');
if LOOPGAIN
    fprintf('=== applying loop-gain AXI overlay (C3, 0x170-0x184) ===\n');
    loop_gain_axi_overlay(sys, loop);
elseif ~LEAN
    fprintf('=== loop-gain AXI overlay SKIPPED (non-LEAN: 0x170-0x184 = canaries) ===\n');
end

% Phase 2.19: per-frame status telemetry FIFO (0x1D0-0x1DC). ENV-GATED on
% QPSK_FRAMESTAT with an EARLY RETURN inside the overlay -> byte-identical HDL
% when unset (G0). Orthogonal to LEAN/debug: 0x1D0-0x1DC are free in both, and
% do NOT collide with loop_gain (0x170-0x184). Applied AFTER byte_rxfifo AND
% loop_gain so the composite port set + the p1d runningMax tap are stable.
if ~isempty(getenv('QPSK_FRAMESTAT'))
    fprintf('=== applying framestat per-frame telemetry overlay (0x1D0-0x1DC) ===\n');
    framestat_overlay(sys, loop);
end

% Bump Description so smart-build cannot claim "no changes". The frame= token
% lets the sim gate detect a stale slx built for the OTHER frame geometry (A2);
% the sps%d/Rsym tag lets it tell an sps4 build from an sps8 one (A3). Both the
% ROM (frame-driven) and WPP tokens are config-driven.
RsymStr = evalin('base','num2str(Rsym)');   % base-ws Rsym set by the model InitFcn
set_param(sys,'Description', sprintf('frame=%s variant=%s pre=%s build=%s', ...
    cfg.Frame, ...
    sprintf(['jupiter_240k5_byte(sps%d/Rsym%s-T8ratefix,K5[35 23]TB25 rx+GATED-txenc,' ...
             'ROM%s+byteDMA,noscr+nodescr,taps 0x150/0x154/0x15C,agcEn10,txds 0x158,WPP%d)'], ...
             cfg.Sps, RsymStr, cfg.Frame, cfg.WordsPerPacketRx), ...
    'variant_pre_composite_verif+cfc_a12+bytek5', char(datetime('now'))));
save_system(sys,[],'OverwriteIfChangedOnDisk',true);

% ---------------- hard pre-synth gates ----------------
% (a) ROM literal in the DUT chart; stock ROM gone (per-frame ROM word file)
romLit = strtrim(fileread(fullfile(fileparts(KITDIR),'k5_240', ...
    sprintf('rom_words_%d_%s.txt', cfg.RomWords32, cfg.Frame))));
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
gFill = load(fullfile(fileparts(KITDIR),'k5_240', ...
    sprintf('golden_%s.mat',cfg.Frame)),'payload');
fillBits = double(gFill.payload(cfg.CodedBits+1:cfg.PayloadBits));   % filler tail
% The FILLREF_LEN literal below is INTENTIONAL: the independent PN9 reference
% length anchor (NOT derived from cfg), so a wrong cfg.CodedBits/PayloadBits
% makes this length check fire rather than slide silently. Each frame supplies
% its own PN reference length here (k5=64, f1536=48).
FILLREF_LEN = 64;                                     % k5 PN9 filler length
if strcmp(cfg.Frame,'f1536'), FILLREF_LEN = 48; end   % f1536 PN9 filler length
assert(numel(fillBits)==FILLREF_LEN, 'GATE FAIL: golden filler length %d != %d', numel(fillBits), FILLREF_LEN);
lfsrG = ones(9,1); fillRef = zeros(FILLREF_LEN,1);
for fk = 1:FILLREF_LEN
    fbG = xor(lfsrG(9), lfsrG(5));
    fillRef(fk) = lfsrG(9);
    lfsrG = [fbG; lfsrG(1:8)]; %#ok<AGROW>
end
assert(isequal(fillBits(:), fillRef(:)), ...
    'GATE FAIL: golden filler != PN9 spec (stale golden_k5.mat?)');
fillLitG = strjoin(arrayfun(@(b) sprintf('%d',b), fillBits(:).', 'UniformOutput', false), ' ');
tiCh = sfroot().find('-isa','Stateflow.EMChart','Path', ...
    [loop '/Transmitter/Input Data/FEC Tx Encoder K5/TxInterleaveK5']);
assert(~isempty(tiCh) && contains(tiCh(1).Script,sprintf('CODED=uint16(%d)',cfg.CodedBits)) ...
    && contains(tiCh(1).Script,sprintf('ROWS=uint16(%d)',cfg.InterleaveRows)) ...
    && contains(tiCh(1).Script,'perm = rr*COLS + cc') ...          % divisionless incremental counters (was mod/idivide by ROWS)
    && ~contains(tiCh(1).Script,'idivide') ...                     % NO division/modulo in the per-beat path
    && ~contains(tiCh(1).Script,'mod(') ...
    && contains(tiCh(1).Script,['FILL = logical([' fillLitG ']);']) ...
    && contains(tiCh(1).Script,'dataOut = FILL('), ...
    'GATE FAIL: TxInterleaveK5 does not carry the K5 2176/136x16/PN9-filler contract (divisionless counters)');
% (c-rx) symmetric divisionless gate on the RX deinterleaver. The merge recipe's
% lazy-union hazard is a surviving ROWS=uint16(idivide(...)) / mod() on the RX
% read-address path; assert the counter rewrite is present AND that no division or
% modulo leaked back in (mirror of the TX ~idivide/~mod gate above -- this catches
% exactly the reintroduced-idivide regression the merge recipe warns about).
rdCh = sfroot().find('-isa','Stateflow.EMChart','Path', ...
    [loop '/Receiver/QPSK Rx/FEC Decoder Wrapper/RxDeint']);
assert(~isempty(rdCh) && contains(rdCh(1).Script,sprintf('CODED=uint16(%d)',cfg.CodedBits)) ...
    && contains(rdCh(1).Script,sprintf('ROWS=uint16(%d)',cfg.InterleaveRows)) ...  % literal-fold, NOT uint16(idivide(...))
    && contains(rdCh(1).Script,'perm0 = cc*ROWS + rr') ...          % divisionless incremental counters (was mod/idivide)
    && ~contains(rdCh(1).Script,'idivide') ...                      % NO division/modulo in the per-beat read path
    && ~contains(rdCh(1).Script,'mod('), ...
    'GATE FAIL: RxDeint does not carry the divisionless counter read-address (idivide/mod leaked back?)');
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
% LB = extra look-back sample-delays = max(0, 10*sps-40): 40@sps8, 0@sps4.
% At sps=4 the native 40-sample window already spans 10 symbols, so the fix
% is a no-op and the EstDataLookback/EstVldLookback blocks must be ABSENT.
LBexp = max(0, 10*cfg.Sps - 40);
for pk = 1:numel(paefix)
    hasLB = ~isempty(find_system(paefix{pk},'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','BlockType','Delay','Name','EstDataLookback')) && ...
        ~isempty(find_system(paefix{pk},'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','BlockType','Delay','Name','EstVldLookback'));
    if LBexp > 0
        assert(hasLB, 'GATE FAIL: resolver look-back fix (EstDataLookback/EstVldLookback) missing in %s', paefix{pk});
        assert(strcmp(strtrim(get_param([paefix{pk} '/EstDataLookback'],'DelayLength')),num2str(LBexp)), ...
            'GATE FAIL: EstDataLookback length != %d in %s', LBexp, paefix{pk});
    else
        assert(~hasLB, 'GATE FAIL: sps=%d expects native look-back (LB=0) but EstDataLookback present in %s', cfg.Sps, paefix{pk});
    end
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
% state-pairs (0x160-0x16C) are STRIPPED in LEAN; the 0x10C mux above stays.
if isempty(getenv('QPSK_LEAN'))
assert(~isempty(find_system([loop '/Receiver/QPSK Rx'],'SearchDepth',1,'LookUnderMasks','all', ...
    'FollowLinks','on','Name','StatePairProbe')), 'GATE FAIL: StatePairProbe missing');
for spn = {'state_agc_in','state_agc_out','state_cs_in','state_cs_out'}
    assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Outport','Name',spn{1})), ...
        'GATE FAIL: composite outport %s missing', spn{1});
end
fprintf('gate(e3): debug tap mux wired + StatePairProbe + 4 state-pair outports present\n');
else
fprintf('gate(e3): debug tap mux wired (LEAN: state-pairs stripped)\n');
end
if LBexp > 0
    fprintf('gate(e2): resolver look-back fix present (EstDataLookback/EstVldLookback len=%d) on %d block(s)\n', LBexp, numel(paefix));
else
    fprintf('gate(e2): resolver look-back NATIVE (sps=%d, LB=0, no EstDataLookback) on %d block(s)\n', cfg.Sps, numel(paefix));
end
% (e4) RX framing span (Task A2 f1536 fix): the Packet Controller/End Generator
% frame-length elements must be DERIVED from dataBitsPerPacket, not a stale k5
% literal. Assert both the Compare To Constant and HDL Counter (max + width) are
% the config-driven expressions on EVERY End Generator in the DUT. This is what
% makes the RX payload span scale to f1536 (12320 symbols) instead of 1120.
egPCs = find_system(loop,'LookUnderMasks','all','FollowLinks','on', ...
    'BlockType','SubSystem','Name','Packet Controller');
nEG = 0;
for ii = 1:numel(egPCs)
    egs = find_system(egPCs{ii},'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','BlockType','SubSystem','Name','End Generator');
    for jj = 1:numel(egs)
        eg = egs{jj};
        [cmpB, cntB] = deal({}, {});
        for b = reshape(find_system(eg,'SearchDepth',1,'LookUnderMasks','all','FollowLinks','on','Type','block'),1,[])
            pn = fieldnames(get_param(b{1},'ObjectParameters'));
            if any(strcmp(pn,'const')) && any(strcmp(pn,'relop')), cmpB{end+1} = b{1}; end %#ok<AGROW>
            if any(strcmp(pn,'CountMax')), cntB{end+1} = b{1}; end %#ok<AGROW>
        end
        assert(numel(cmpB)==1 && numel(cntB)==1, 'GATE FAIL: End Generator %s missing Compare/Counter', eg);
        cst = strrep(get_param(cmpB{1},'const'),' ','');
        cmx = strrep(get_param(cntB{1},'CountMax'),' ','');
        cwl = strrep(get_param(cntB{1},'CountWordLen'),' ','');
        assert(strcmp(cst,'dataBitsPerPacket/2-1'), 'GATE FAIL: End Generator const not config-driven (=%s)', get_param(cmpB{1},'const'));
        assert(strcmp(cmx,'dataBitsPerPacket/2-1'), 'GATE FAIL: End Generator CountMax not config-driven (=%s)', get_param(cntB{1},'CountMax'));
        assert(strcmp(cwl,'nextpow2(dataBitsPerPacket/2-1)'), 'GATE FAIL: End Generator CountWordLen not config-driven (=%s)', get_param(cntB{1},'CountWordLen'));
        nEG = nEG + 1;
    end
end
assert(nEG >= 1, 'GATE FAIL: no RX Packet Controller/End Generator found in DUT');
fprintf('gate(e4): RX framing span config-driven (dataBitsPerPacket/2) on %d End Generator(s); f1536 span=%d symbols\n', ...
    nEG, cfg.PayloadBits/2);
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
% (f2) T8.3 forensic: AdcForensic block present + workflow AXI mapping x"15C".
% STRIP in LEAN (the mapping is block-existence-guarded in hdlworkflow).
if isempty(getenv('QPSK_LEAN'))
assert(~isempty(find_system(loop,'SearchDepth',1,'Name','AdcForensic')), ...
    'GATE FAIL: AdcForensic block missing');
wfT8 = fileread('hdlworkflow_loopback.m');
assert(contains(wfT8, 'adc_forensic') && contains(wfT8, 'x"15C"'), ...
    'GATE FAIL: adc_forensic x"15C" mapping missing from hdlworkflow_loopback.m');
end
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
         'rstcs_count','cfc_est', ...
         'byte_ready','byte_rx_data','byte_rx_valid','byte_rx_last','byte_rx_user'}
    assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Outport','Name',r{1})), ...
        'GATE FAIL: outport %s missing', r{1});
end
if ~LEAN   % adc_forensic (0x15C) stripped in LEAN
    assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Outport','Name','adc_forensic')), ...
        'GATE FAIL: outport adc_forensic missing');
end
for r = {'skip_count','byte_data','byte_valid','tx_data_source','byte_first','byte_rx_ready'}
    assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Inport','Name',r{1})), ...
        'GATE FAIL: inport %s missing', r{1});
end
% (g2) Transmitter byte boundary + shifter/mux structure present.
% framestat (phase 2.19, env-gated) adds ONE Transmitter outport (fs_txur, the
% TX-underrun witness) -- account for it instead of hard-coding 9.
txph = get_param([loop '/Transmitter'],'PortHandles');
nFsTx = double(~isempty(find_system([loop '/Transmitter'],'SearchDepth',1, ...
    'BlockType','Outport','Name','fs_txur')));
assert(numel(txph.Inport)==8 && numel(txph.Outport)==9+nFsTx, ...
    'GATE FAIL: Transmitter ports %d/%d (expected 8/%d)', ...
    numel(txph.Inport), numel(txph.Outport), 9+nFsTx);
for n = {'ByteBitShifter','BitMux'}
    assert(~isempty(find_system([loop '/Transmitter/Input Data'],'SearchDepth',1, ...
        'LookUnderMasks','all','FollowLinks','on','Name',n{1})), 'GATE FAIL: %s missing', n{1});
end
for n = {'ByteWordBuffer','ByteSerializer','ByteRxFifo'}   % BeatGate replaced by the elastic FIFO (2.16b)
    assert(~isempty(find_system(loop,'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','Name',n{1})), 'GATE FAIL: %s missing', n{1});
end
% (g3) serializer WORDS_PER_PACKET literal (128 B/frame k5 / 1536 B f1536 of
%      the decoded info bits); counter widened uint8 -> uint16 (f1536 385>255)
bsCh = sfroot().find('-isa','Stateflow.EMChart','Path',[loop '/ByteSerializer']);
assert(~isempty(bsCh) && contains(bsCh(1).Script,sprintf('uint16(%d)',cfg.WordsPerPacketRx)), ...
    'GATE FAIL: ByteSerializer WORDS_PER_PACKET literal is not uint16(%d)', cfg.WordsPerPacketRx);
% (g3b) f1536 ONLY: ping-pong interleaver banks requested as BRAM. This is a
% CODEGEN property the sim gate cannot exercise, so pin its PRESENCE here at
% assemble time (BRAM-fit itself is verified at HDL build -- see task-A2-report).
if strcmp(cfg.Frame,'f1536')
    for ramBlk = { [loop '/Transmitter/Input Data/FEC Tx Encoder K5/TxInterleaveK5'], ...
                   [loop '/Receiver/QPSK Rx/FEC Decoder Wrapper/RxDeint'] }
        m = hdlget_param(ramBlk{1}, 'MapPersistentVarsToRAM');
        assert(strcmpi(char(string(m)),'on'), ...
            'GATE FAIL: %s MapPersistentVarsToRAM not on (f1536 BRAM request missing)', ramBlk{1});
    end
    fprintf('gate(g3b): f1536 TxInterleaveK5 + RxDeint MapPersistentVarsToRAM=on (BRAM requested)\n');
end
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
% (h) Rsym/sps pair took (T8 RATE FIX + A3 rung): the QPSK rail Rsym*sps is
%     PINNED to the ADC bus 15.36e6 (UpsamplesRx=1), so base-ws Rsym must equal
%     15.36e6/sps (1.92e6 @ sps8 = 240 ksym; 3.84e6 @ sps4 = 480 ksym, 2x rung).
rs = evalin('base','Rsym');
% Rsym/sps pinned to the ADC bus (A3 sps-aware): rail = Rsym*sps = 15.36e6.
RsymExp = 15.36e6 / cfg.Sps;
assert(abs(double(rs) - RsymExp) < 1, 'GATE FAIL: Rsym=%g (expected %g = 15.36e6/sps%d)', double(rs), RsymExp, cfg.Sps);
assert(abs(double(rs)*cfg.Sps - 15.36e6) < 1, 'GATE FAIL: rail Rsym*sps=%g != 15.36e6 (ADC bus)', double(rs)*cfg.Sps);
% (i) C3 loop-gain AXI regs present + mapped (LEAN + enabled only)
if LOOPGAIN
    for r = {'cs_prop_gain','cs_integ_gain','ss_prop_gain','ss_integ_gain','agc_loop_gain','cfo_threshold'}
        assert(~isempty(find_system(loop,'SearchDepth',1,'BlockType','Inport','Name',r{1})), ...
            'GATE FAIL: loop-gain inport %s missing', r{1});
    end
    wfLG = fileread('hdlworkflow_loopback.m');
    assert(contains(wfLG,'loop-gain tuning mappings'), 'GATE FAIL: loop-gain workflow mappings missing');
    for a = {'x"170"','x"174"','x"178"','x"17C"','x"180"','x"184"'}
        assert(contains(wfLG, a{1}), 'GATE FAIL: loop-gain AXI address %s missing in workflow', a{1});
    end
    % zero-default structural proof: every original Gain/Compare is still the
    % default (register==0) driver via its Switch third data port.
    ud = get_param(loop,'UserData');
    assert(isstruct(ud) && isfield(ud,'loopGainAxi'), 'GATE FAIL: loopGainAxi UserData not stashed');
    fprintf('gate(i): C3 loop-gain regs 0x170-0x184 present + mapped + refs stashed\n');
end
fprintf(['ASSEMBLE_240K5_BYTE PRE-SYNTH GATES OK (frame=%s ROM BIST + byte-DMA, GATED in-fabric K5 Tx encoder,\n' ...
         '  noscr, K5 rx TB25, nodescr, 2^12, thr 0.0125, agc En10 +-32, regs 0x100..0x15C + txds 0x158,\n' ...
         '  WPP%d, byte RD, Rsym %g x sps %d = rail 15.36e6 -- T8 rate fix + A3 rung)\n'], ...
         cfg.Frame, cfg.WordsPerPacketRx, double(rs), cfg.Sps);
