function rate_240k_overlay()
% rate_240k_overlay -- jupiter_240k5 rate restoration edits on the SOURCE model
% commhdlQPSKTxRx.slx (this kit's copy; donors untouched). PAIRED with the
% SamplesPerSymbol 4 -> 8 edit in commhdlQPSKTxRxParameters.m.
%
% WHY (T8 REVISION 2026-07-08 -- the S1 rationale below was HALF WRONG):
%   S1 kept the model rail Rsym*sps at 7.68e6 believing that rail = the 1.92M
%   SSI stream. T8 rate forensics (PHASEB_AGC_REPORT.txt, t8stock air:
%   sps16/120ksym, distinct samples; netlist cadence: tx_dataOut changes every
%   2 clks) PROVED the 7.68e6 model rail sits on the enb_1_4 rung = 0.96 Msps
%   physical, so sps8 content there = 120 ksym on air -- HALF the design rate,
%   while the Rx (v6-retimed) correctly consumes 1.92M/sps8/240k. The fix:
%   the rail must sit ONE RUNG UP (15.36e6 model = 1.92M physical):
%     SamplesPerSymbol = 8  AND  Rsym = 1.92e6   (rail 15.36e6)
%   Then: Transmitter rail = enb_1_2 (1.92M, sps8 = TRUE 240 ksym), the REP
%   x2-interp output = enb (3.84M, sps16), the stock BD sync_output forwards
%   one sample per 1.92M dac beat = sps8@1.92M on air; the Rx rail natively
%   generates at enb_1_2 (what CADENCE FIX v6 hand-patched) -- so the fixed
%   build must SKIP/RE-VALIDATE cadence_patch_ipcore (v6) and the loopback
%   consumes the REP stream at /2 = the same sps8@1.92M contract as air.
%   Netlist-emulation PROOF (rtl_sim/hdl_txfix + obj_txrate_*/obj_txfix_*):
%   fixed TX air = 240ksym sps8, decodes 12/12 GOLDEN offline; loopback BIST
%   capout=04922282 (biterr startup-only, rstcs=0); air->Rx GOLDEN steady.
%
% ORIGINAL S1 RATIONALE (kept for history; its rail->SSI mapping was wrong):
%   The QPSK-domain full rail of the model is Rsym*SamplesPerSymbol, and the
%   composite (build_composite_local + variant_pre) pins that rail to the
%   1/7.68e6 model rate (physical: the 1.92 Msps SSI stream). Restoring the
%   240-ksym design point means 8 samples/symbol ON THAT SAME RAIL, i.e.
%     SamplesPerSymbol 4 -> 8   AND   Rsym 1.92e6 -> 0.96e6
%   so Rsym*SamplesPerSymbol == 7.68e6 stays put.
%
%   FOUR block sample times hardcode the old sps as '1/(Rsym*4)' (duplicated
%   constants -- the "find and fix ALL of them" case). They are rewritten to
%   the derived form '1/(Rsym*SamplesPerSymbol)' (SamplesPerSymbol is defined
%   in both the QPSK Tx and QPSK Rx mask workspaces):
%     Transmitter/QPSK Tx/Bit Packetizer/Data Bits FIFO/Constant
%     Transmitter/QPSK Tx/Bit Packetizer/Preamble Bits Generator/Preamble Bits Store/Constant
%     Transmitter/QPSK Tx/QPSK Modulator/Null
%     Receiver/QPSK Rx/Constant
%
%   Everything else derives: RRC coeffs rcosdesign(0.5,4,sps) via Params;
%   Tx bit pacing CountMax = Config.SamplesPerSymbol/2-1; Symbol Synchronizer
%   decimation CountMax = SamplesPerSymbol-1; Gardner/PED constants at
%   1/(Rsym*SamplesPerSymbol); Receiver bridge Downsample/Repeat = UpsamplesRx
%   (rail-fixed, InitFcn). Verified: NO other dialog value in the model
%   references Rsym or an absolute rate literal.
%
% Idempotent. Apply BEFORE build_composite_local (which clones the slx).

sys = 'commhdlQPSKTxRx';
load_system(sys);

% (1) T8 REVISION: Rsym = 1.92e6 on the Input Data mask (rail 15.36e6 model =
%     1.92M physical -> TRUE 240 ksym at sps 8; see header). Handles both the
%     stock model (already 1.92e6) and an S1-era model carrying 0.96e6.
idb = [sys '/Transmitter/Input Data'];
oldR = strtrim(get_param(idb, 'Rsym'));
if strcmp(oldR, '1.92e6')
    fprintf('rate_240k_overlay: Rsym already 1.92e6 -- (1) skipped\n');
else
    assert(strcmp(oldR, '0.96e6'), 'unexpected Rsym dialog "%s"', oldR);
    set_param(idb, 'Rsym', '1.92e6');
    fprintf('rate_240k_overlay: Input Data Rsym 0.96e6 -> 1.92e6 (T8 rate fix: rail 15.36e6)\n');
end

% (2) the four hardcoded 1/(Rsym*4) sample times -> 1/(Rsym*SamplesPerSymbol)
fixes = { ...
  [sys '/Transmitter/QPSK Tx/Bit Packetizer/Data Bits FIFO/Constant']; ...
  [sys '/Transmitter/QPSK Tx/Bit Packetizer/Preamble Bits Generator/Preamble Bits Store/Constant']; ...
  [sys '/Transmitter/QPSK Tx/QPSK Modulator/Null']; ...
  [sys '/Receiver/QPSK Rx/Constant']};
nfix = 0;
for k = 1:numel(fixes)
    st = strtrim(get_param(fixes{k}, 'SampleTime'));
    if strcmp(st, '1/(Rsym*SamplesPerSymbol)')
        fprintf('rate_240k_overlay: %s already derived -- skip\n', fixes{k});
        continue;
    end
    assert(strcmp(st, '1/(Rsym*4)'), 'unexpected SampleTime "%s" on %s', st, fixes{k});
    set_param(fixes{k}, 'SampleTime', '1/(Rsym*SamplesPerSymbol)');
    nfix = nfix + 1;
    fprintf('rate_240k_overlay: %s SampleTime 1/(Rsym*4) -> 1/(Rsym*SamplesPerSymbol)\n', fixes{k});
end

% (2b) Bit Packetizer dataReady PACE counter -- the FIFTH disguised sps
%      constant, found by the S1 RTL sim (constant-symbol payload stalls):
%      the producer handshake 'dataReady' is an HDL Counter with HARDCODED
%      CountMax=1 (a free toggle gated by ~fullRAM) whose raw value feeds the
%      dataReady output => the Message Generator produces 1 bit per 2 beats.
%      That equals the modulator drain (1 bit per sps/2 beats) ONLY at sps=4.
%      At sps=8 production is 2x drain: the 2-frame bit RAM rides its full
%      boundary every frame, the 1-beat-delayed handshake leaks pushes, the
%      2-bit frameCount eventually WRAPS and the reader idles mid-frame ->
%      the 600..1100-symbol constant-payload stalls seen in the S1 trace
%      (cadence stays exact -- only the payload content dies).
%      FIX (RTL-validated by hand-patching the generated Verilog before this
%      model edit): count 0..sps/2-1 and emit dataReady = (count == sps/2-1),
%      which is bit-identical to stock at sps=4 (1-bit counter's value ==
%      (count==1)) and restores the matched-rate producer at any sps.
bp  = [sys '/Transmitter/QPSK Tx/Bit Packetizer'];
cnt = [bp '/HDL Counter'];
if ~isempty(find_system(bp,'SearchDepth',1,'Name','DataReadyPaceCmp'))
    fprintf('rate_240k_overlay: dataReady pace fix already applied -- skip\n');
else
    assert(strcmp(strtrim(get_param(cnt,'CountMax')),'1'), ...
        'unexpected Bit Packetizer HDL Counter CountMax "%s"', get_param(cnt,'CountMax'));
    set_param(cnt, 'CountMax', 'SamplesPerSymbol/2 - 1', ...
                   'CountWordLen', 'nextpow2(SamplesPerSymbol/2)');
    delete_line(bp, 'HDL Counter/1', 'Data Type Conversion/1');
    add_block('simulink/Logic and Bit Operations/Compare To Constant', ...
        [bp '/DataReadyPaceCmp'], 'relop', '==', 'const', 'SamplesPerSymbol/2 - 1', ...
        'OutDataTypeStr', 'boolean', 'Position', [560 380 610 410]);
    add_line(bp, 'HDL Counter/1', 'DataReadyPaceCmp/1', 'autorouting','on');
    add_line(bp, 'DataReadyPaceCmp/1', 'Data Type Conversion/1', 'autorouting','on');
    fprintf('rate_240k_overlay: Bit Packetizer dataReady pace: CountMax 1 -> SamplesPerSymbol/2-1, dataReady = (count==max)\n');
end

% (3) hard gate: no remaining '(Rsym*4)' dialog values anywhere in the model
blks = find_system(sys, 'LookUnderMasks', 'all', 'FollowLinks', 'on');
for i = 1:numel(blks)
    try, dp = get_param(blks{i}, 'DialogParameters'); catch, continue; end
    if isempty(dp), continue; end
    fn = fieldnames(dp);
    for j = 1:numel(fn)
        try, v = get_param(blks{i}, fn{j}); catch, continue; end
        if ischar(v) && contains(v, '(Rsym*4)')
            error('rate_240k_overlay: STALE (Rsym*4) left at %s | %s = %s', blks{i}, fn{j}, v);
        end
    end
end

% (3b) T8 RATE FIX: with the rail raised to 15.36e6 the Receiver's ADC-bus
%      bridge must NOT decimate: InitFcn UpsamplesRx 2 -> 1 (the Receiver
%      Downsample~1..4 blocks are parameterized N=UpsamplesRx). This is the
%      model-level form of the v6 'ingress no longer decimates' RTL patch,
%      which is retired by this fix.
ifc = get_param(sys, 'InitFcn');
if contains(ifc, 'UpsamplesRx = 1;')
    fprintf('rate_240k_overlay: InitFcn UpsamplesRx already 1 -- skip\n');
else
    assert(contains(ifc, 'UpsamplesRx = 2;'), 'InitFcn: UpsamplesRx = 2 not found');
    ifc = strrep(ifc, 'UpsamplesRx = 2;', ...
        ['UpsamplesRx = 1;   %% T8 RATE FIX: rail 15.36e6 == ADC bus rate,' newline ...
         '%% no ingress decimation (was 2 when the rail sat on the 7.68e6 rung)']);
    set_param(sys, 'InitFcn', ifc);
    fprintf('rate_240k_overlay: InitFcn UpsamplesRx 2 -> 1 (T8 rate fix)\n');
end

% (4) confirm the params file pair (sps=8) is the active one
P = commhdlQPSKTxRxParameters();
assert(P.SamplesPerSymbol == 8, ...
    'commhdlQPSKTxRxParameters SamplesPerSymbol=%d (expected 8); which=%s', ...
    P.SamplesPerSymbol, which('commhdlQPSKTxRxParameters'));
assert(abs(P.CFOChangeDetectThreshold - 0.0125) < 1e-12, ...
    'CFOChangeDetectThreshold=%.7g (expected RXFIX 0.0125)', P.CFOChangeDetectThreshold);
assert(numel(P.RRCCoef) == 4*8+1, 'RRC length %d != 33 (span 4, 8 sps)', numel(P.RRCCoef));

save_system(sys, [], 'OverwriteIfChangedOnDisk', true);
fprintf('rate_240k_overlay: DONE (%d sample-time fixes; Rsym*sps rail = %g, sps = %d)\n', ...
    nfix, 1.92e6 * 8, P.SamplesPerSymbol);
end
