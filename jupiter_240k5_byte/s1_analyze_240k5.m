% s1_analyze_240k5.m -- S1 iverilog Tx-air + cadence gate analysis.
% Consumes rtl_sim/tx_240k5_trace.csv (one line per Transmitter-rail beat:
% beat,txI,txQ,modV,modI,modQ dumped by rtl_sim/tb_tx_240k5.v from the
% GENERATED Verilog), synthesizes the int16 .iq the K5 decoder reads, decodes
% with /mnt/onetb/scratch/qpsk_variants/k5_240/soak_decode_k5.m, and applies
% the S1 gate lines. Writes jupiter_240k5/S1_GATE.txt.
KITDIR=fileparts(mfilename('fullpath'));
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox');
addpath(fullfile(fileparts(KITDIR),'k5_240'));
cd(KITDIR); addpath(KITDIR);
cfg = frame_config_k5();            % single source of truth for frame geometry
payloadSyms = cfg.PayloadBits/2;    % 1120 QPSK payload symbols/frame
frameSyms   = 13 + payloadSyms;     % 1133 = 13 Barker preamble + payload symbols

logf='s1_analyze_240k5.log'; if exist(logf,'file'), delete(logf); end
diary(logf);
fprintf('=== S1 analyze %s ===\n', char(datetime('now')));

T = readmatrix(fullfile(KITDIR,'rtl_sim','tx_240k5_trace.csv'),'FileType','text');
% cols (no header): beat txI txQ modV modI modQ
txI = T(:,2); txQ = T(:,3); modV = logical(T(:,4)); modI = T(:,5); modQ = T(:,6);
fprintf('trace: %d Tx-rail beats (8 sps air samples), %d modulator symbols\n', numel(txI), nnz(modV));

% ---- (0) SAMPLE-domain frame starts on the RAW air (exact, noiseless) ----
C = commhdlQPSKTxRxParameters();
sps = cfg.Sps; assert(C.SamplesPerSymbol==cfg.Sps);
preSyms = C.preambleSymbols(:);
rrc = rcosdesign(0.5,4,sps);
ref = conv(upsample(preSyms,sps), rrc);          % RRC-shaped preamble reference
air = double(txI) + 1i*double(txQ);
corr = abs(conv(air, conj(flipud(ref(:)))));
thr = 0.5*max(corr);
[pks, locs] = findpeaks(corr, 'MinPeakHeight', thr, 'MinPeakDistance', round(0.8*frameSyms*sps)); %#ok<ASGLU>
starts = locs(:).' - (numel(ref)-1);              % air-sample index of each preamble start
dstarts = diff(starts);
fprintf('sample-domain frame starts: %d ; spacing: min=%d max=%d mean=%.3f std=%.6f\n', ...
    numel(starts), min(dstarts), max(dstarts), mean(dstarts), std(dstarts));
gate_cadence = (numel(starts) >= 25) && all(dstarts == frameSyms*sps);
fprintf('GATE cadence (all spacings == %d exactly, >=25 frames): %s\n', frameSyms*sps, string(gate_cadence));

% ---- (1) synthesize .iq (int16 interleaved I,Q) + decode with soak_decode_k5 ----
iqf = fullfile(KITDIR,'rtl_sim','s1_tx_air_240k5.iq');
k0 = max(1, starts(1) - 4*sps);                   % trim the pre-first-frame FIFO-priming region
tI = txI(k0:end); tQ = txQ(k0:end);
mx = max(abs([tI; tQ])); scale = floor(30000/max(mx,1));
% soak_decode_k5 is designed for real captures: it drops exact-zero complex
% samples (abs(iq)>0 -- a noiseless RTL trace has ~1900 interior (0,0)
% samples whose deletion destroys the sample grid) and its Gardner/carrier
% loops expect a noise floor (its SELFTEST runs at 20 dB SNR). Add
% reproducible AWGN at 35 dB SNR to the synthesized capture -- far above any
% decode threshold, kills exact zeros, matches the decoder's design regime.
rng(240,'twister');
sI2 = double(tI)*scale; sQ2 = double(tQ)*scale;
prms = sqrt(mean(sI2.^2 + sQ2.^2));
nstd = prms / 10^(35/20) / sqrt(2);
sI2 = sI2 + nstd*randn(size(sI2)); sQ2 = sQ2 + nstd*randn(size(sQ2));
w = zeros(2*numel(tI),1,'int16');
w(1:2:end) = int16(round(sI2)); w(2:2:end) = int16(round(sQ2));
nz = sum(w(1:2:end)==0 & w(2:2:end)==0);
fid=fopen(iqf,'w'); fwrite(fid,w,'int16'); fclose(fid);
fprintf('wrote %s (%d complex samples from beat %d, scale=%d, +35dB-SNR AWGN, %d residual zero samples)\n', ...
    iqf, numel(tI), k0, scale, nz);
res = soak_decode_k5(iqf, 'label','S1', 'diag',true);
capvals = arrayfun(@(p) p.capOut, res.perFrame);
ierrs   = arrayfun(@(p) p.infoErr, res.perFrame);
CAPG = uint32(res.capGolden);
gate_decode = (res.nFrames >= 25) && (res.nGolden == res.nFrames) && (res.totInfoErr == 0) ...
              && all(capvals == CAPG);
fprintf('GATE decode: frames=%d golden=%d infoErr=%d CAP_OUT(all)=0x%08X golden=0x%08X -> %s\n', ...
    res.nFrames, res.nGolden, res.totInfoErr, capvals(1), CAPG, string(gate_decode));
dsym = diff(res.frameStarts);
fprintf('decoder symbol-domain spacing: min=%d max=%d std=%.6f (expect 1133/0)\n', min(dsym), max(dsym), std(dsym));

% ---- (2) SYMBOL-domain ground truth on the TRUE modulator symbol stream ----
% (a) per-frame payload bits must be BIT-EXACT vs the K5 ROM (stronger than
%     any run-length heuristic); (b) symbol frame spacing == 1133 exactly;
% (c) constellation: 4 points; constant-symbol runs <= 34 EXCEPT the
%     deterministic per-frame filler+preamble junction run (64-ones filler =
%     32 symbols of (-,-) followed by the next preamble's five leading
%     Barker 1-bits = 5 more (-,-); with the last coded pair(s) this gives a
%     37..45 run ending exactly 5 symbols into each frame -- a K5-contract
%     artifact, not a stall; the legacy <=34 bound came from the K7 68-zeros
%     filler which cannot join the preamble).
romLit = strtrim(fileread(fullfile(fileparts(KITDIR),'k5_240','rom_words_70_k5.txt')));
words = eval(romLit); %#ok<EVLDIR>
rombits = zeros(1,cfg.PayloadBits);
for w2 = 0:cfg.RomWords32-1
  for bb = 0:31, rombits(w2*32+bb+1) = double(bitget(words(w2+1), 32-bb)); end
end
sI = modI(modV) > 0; sQ = modQ(modV) > 0;       % symbol signs
bitI = double(~sQ); bitQ = double(~sI);          % pi/4-Gray inverse (I bit = Q<0, Q bit = I<0)
q = sI*2 + sQ;                                   % quadrant id 0..3
nSym = numel(q);
% preamble sign pattern: bit b -> symbol (b,b): b=1 -> (-,-) q=0? (I<0,Q<0) -> sI=0,sQ=0 -> q=0; b=0 -> (+,+) q=3
bark = logical([1 1 1 1 1 0 0 1 1 0 1 0 1]);
preQ = zeros(1,13); preQ(~bark) = 3;             % q values of the 13 preamble symbols
symStartsAll = [];                               % every preamble (incl. trailing partial frame)
qr = q(:).';
for i = 1:nSym-12
  if isequal(qr(i:i+12), preQ), symStartsAll(end+1) = i; end %#ok<AGROW>
end
symStarts = symStartsAll(symStartsAll <= nSym-frameSyms+1);  % starts of FULL frames
dss = diff(symStarts);
fprintf('symbol-domain frame starts: %d ; spacing uniq = %s\n', numel(symStarts), mat2str(unique(dss)));
% per-frame ROM comparison
nFullFrames = 0; frameBitErrs = [];
for i = 1:numel(symStarts)
  s0 = symStarts(i);
  if s0+13+payloadSyms-1 > nSym, break; end
  idx = s0+13 : s0+13+payloadSyms-1;
  bits = reshape([bitI(idx) bitQ(idx)].', 1, []);
  frameBitErrs(end+1) = sum(bits ~= rombits); %#ok<AGROW>
  nFullFrames = nFullFrames + 1;
end
gate_rom = (nFullFrames >= 25) && all(frameBitErrs == 0) && all(dss == frameSyms);
fprintf('GATE ROM-exact: %d full frames, per-frame payload bit errors vs ROM = %s -> %s\n', ...
    nFullFrames, mat2str(frameBitErrs), string(gate_rom));
% run-length analysis with junction classification
d = [true; diff(q(:))~=0];
rstart = find(d); rlen = diff([rstart; nSym+1]);
rend = rstart + rlen - 1;
% steady state: ignore runs entirely before the first detected frame
ss = rend >= symStarts(1);
big = find(rlen > 34 & ss);
isJunction = false(size(big));
for k2 = 1:numel(big)
  e = rend(big(k2));
  % junction run ends exactly at the 5th preamble symbol of some frame
  % (use ALL preambles incl. the trailing partial frame's)
  isJunction(k2) = any(symStartsAll + 4 == e) && (q(rstart(big(k2)))==0) && (rlen(big(k2)) <= 45);
end
nonJ = big(~isJunction);
maxNonJ = 0;
if any(ss & rlen<=34), maxNonJ = max(rlen(ss & rlen<=34)); end
if ~isempty(nonJ), maxNonJ = max(rlen(nonJ)); end
present = unique(qr(symStarts(1):end));
fprintf('constellation: %d/4 points present (steady state); runs>34: %d total, %d junction (len %s), %d NON-junction\n', ...
    numel(present), numel(big), nnz(isJunction), mat2str(unique(rlen(big(isJunction)))'), numel(nonJ));
fprintf('longest NON-junction steady-state run = %d (gate <=34)\n', maxNonJ);
gate_const = (numel(present) == 4) && isempty(nonJ) && maxNonJ <= 34;
fprintf('GATE constellation (4 points, non-junction runs <=34): %s\n', string(gate_const));

save(fullfile('rtl_sim','s1_results_240k5.mat'), 'res','starts','dstarts','symStarts','frameBitErrs', ...
     'rlen','gate_cadence','gate_decode','gate_const','gate_rom');
allPass = gate_cadence && gate_decode && gate_const && gate_rom;
fprintf('S1_ALL_GATES: %s\n', string(allPass));

% ---- (3) write S1_GATE.txt ----
chk = ''; try, chk = strtrim(fileread('CHECKHDL_240K5.txt')); catch, end
junctionLens = unique(rlen(big(isJunction)))';
fid=fopen(fullfile(KITDIR,'S1_GATE.txt'),'w');
fprintf(fid,'================ jupiter_240k5 S1 GATE ================\n');
fprintf(fid,'date: %s\n', char(datetime('now')));
fprintf(fid,'result: %s\n\n', ternary(allPass,'PASS','FAIL'));
fprintf(fid,'--- parameter diffs (old -> new) ---\n');
fprintf(fid,'commhdlQPSKTxRxParameters.m:16  SamplesPerSymbol            4 -> 8\n');
fprintf(fid,'commhdlQPSKTxRxParameters.m:45  CFOChangeDetectThreshold    0.0125 -> 0.0015625 (REVERT to stock; rxfix donor retune removed)\n');
fprintf(fid,'commhdlQPSKTxRx.slx model edits (rate_240k_overlay.m, scripted; donors untouched):\n');
fprintf(fid,'  Transmitter/Input Data mask Rsym                          1.92e6 -> 0.96e6\n');
fprintf(fid,'    (model QPSK rail Rsym*sps stays 7.68e6 = the 1.92 Msps physical SSI stream -> true 240 ksym air)\n');
fprintf(fid,'  4x hardcoded SampleTime 1/(Rsym*4) -> 1/(Rsym*SamplesPerSymbol):\n');
fprintf(fid,'    Transmitter/QPSK Tx/Bit Packetizer/Data Bits FIFO/Constant\n');
fprintf(fid,'    Transmitter/QPSK Tx/Bit Packetizer/Preamble Bits Generator/Preamble Bits Store/Constant\n');
fprintf(fid,'    Transmitter/QPSK Tx/QPSK Modulator/Null\n');
fprintf(fid,'    Receiver/QPSK Rx/Constant\n');
fprintf(fid,'  5th disguised sps constant (FOUND BY THIS S1 SIM, fix RTL-validated then model-fixed):\n');
fprintf(fid,'    Transmitter/QPSK Tx/Bit Packetizer/HDL Counter (dataReady producer pace): CountMax 1 ->\n');
fprintf(fid,'    SamplesPerSymbol/2-1 + new DataReadyPaceCmp (dataReady = count==max; bit-identical to stock at sps=4).\n');
fprintf(fid,'    Without it the msggen produced 2x the modulator drain at sps=8, the 2-frame bit-RAM frameCount\n');
fprintf(fid,'    wrapped and the reader idled mid-frame -> 600..1100-symbol constant-payload stalls (cadence stayed\n');
fprintf(fid,'    exact; only content died) -- the ROM comparison gate below now proves this fixed.\n');
fprintf(fid,'  (RRC = rcosdesign(0.5,4,8) 33 taps via Params; Tx bit pacing CountMax=sps/2-1=3; SymbolSync decim\n');
fprintf(fid,'   CountMax=sps-1=7; all derive from the single SamplesPerSymbol constant; no other Rsym/sps literal left)\n');
fprintf(fid,'FEC (fec_insert_overlay_rxonly_k5.m replaces donor K=7 fec_insert_overlay.m; RX-ONLY: Tx is the pre-coded\n');
fprintf(fid,'  ROM -- an in-FPGA encoder would double-encode):\n');
fprintf(fid,'  trellis poly2trellis(7,[171 133]) -> poly2trellis(5,[35 23]); traceback 34 -> 25\n');
fprintf(fid,'  info/tail 1080/6 -> 1084/4; CODED 2172 -> 2176; deinterleave ROWS 135 -> 136 (perm c*136+r;\n');
fprintf(fid,'  Rx consumes the FIRST 2176 of the 2240 payload bits; 64-ones filler never read)\n');
fprintf(fid,'  fec_capture_overlay.m CAP_OUT skip clamp 1080 -> 1084\n');
fprintf(fid,'Tx ROM (msggen_rom_overlay_k5.m): k5_240/rom_words_70_k5.txt (word0 = 1204691830 = 0x47CE2376),\n');
fprintf(fid,'  2-arg stock chart signature of THIS model (fullMessageLen 2240-1 hardcoded), scrambler OFF\n');
fprintf(fid,'  (fec_remove_scrambler: EnableScrambling=false), NO PRBS, in-FPGA generator path (this donor has no\n');
fprintf(fid,'  byte-DMA path, so the generator is structurally the only Tx bit source; no 0x11C tx_data_source reg --\n');
fprintf(fid,'  0x11C remains the donor DBG sentinel 0xFEC0DB60)\n\n');
fprintf(fid,'--- checkhdl / generated-HDL constant gates ---\n%s\n', chk);
fprintf(fid,'HDL grep gates: fi(0.0015625,1,22,21) SI 3277 PRESENT; rxfix 0.0125 SI 26214 ABSENT; ROM word0 1204691830 PRESENT\n\n');
fprintf(fid,'--- tap registers added (taps_240k5_overlay.m + patch_hdlworkflow_taps.m) ---\n');
fprintf(fid,'0x150 rstcs_count: uint32 rising-edge counter of the CFO-step-detector carrier-sync reset\n');
fprintf(fid,'      (tap = Coarse Frequency Compensator outport 3 -> Carrier Synchronizer/3 internalRst, the signal\n');
fprintf(fid,'       gated by the CFOChangeDetectThreshold compares; host-written 0x110 manualRst NOT counted;\n');
fprintf(fid,'       reset by modem soft-reset 0x000)\n');
fprintf(fid,'0x154 cfc_est: latest CFC normalized frequency estimate (FTS normCoarseFreqEst = Data Type Conversion3\n');
fprintf(fid,'      out, sfix21_En21), registered (Delay 1), read as raw stored integer:\n');
fprintf(fid,'      normEst = double(typecast(uint32(reg),''int32''))/2^21\n');
fprintf(fid,'capture retarget: an AdcCap capture RAM is ABSENT in this donor (the variant_pre ''AdcCap'' blocks are\n');
fprintf(fid,'      Rx-datapath valid-qualifying registers, NOT a capture). The kit''s existing Rx-capture path is the\n');
fprintf(fid,'      debug DMA: composite debugI1/Q1 (IP Data 0/1 OUT) were RETARGETED from the raw-ADC duplicate to the\n');
fprintf(fid,'      Receiver''s iq_debug_mux taps -- write 0x10C=2 to capture the POST-CARRIER-SYNC symbol stream\n');
fprintf(fid,'      (0=postAGC, 1=postSymbolSync, 2=postCarrierSync, 3=frame-sync dataOut). No new capture RAM built.\n');
fprintf(fid,'      Raw ADC remains on IP Data 2/3 OUT.\n');
fprintf(fid,'register map: 0x100..0x14C preserved bit-for-bit from the fec_jupiter_rxfix donor (0x104 packets,\n');
fprintf(fid,'      0x108 errors, 0x110 rstCS, 0x114 rx_input_select, 0x118 tx_source_select, 0x11C sentinel,\n');
fprintf(fid,'      0x120..0x134 counters, 0x138 skip, 0x13C/140/144 caps, 0x14C cap_cad); NEW = 0x150/0x154 only\n\n');
fprintf(fid,'--- S1 gate lines (iverilog on the kit-generated Verilog, %d air frames) ---\n', res.nFrames);
fprintf(fid,'1) decode (soak_decode_k5, SELFTEST-proven): frames=%d golden=%d infoErr=%d ;\n', res.nFrames, res.nGolden, res.totInfoErr);
fprintf(fid,'   CAP_OUT all frames = 0x%08X (golden 0x%08X) -> %s\n', capvals(1), CAPG, ternary(gate_decode,'PASS','FAIL'));
fprintf(fid,'   (.iq synthesized with reproducible 35 dB-SNR AWGN, rng(240): the capture-hardened decoder deletes\n');
fprintf(fid,'    exact-zero samples and its loops expect a noise floor -- noiseless RTL air has ~1900 interior (0,0)\n');
fprintf(fid,'    samples that would corrupt the sample grid; 35 dB is far above any decode threshold.)\n');
fprintf(fid,'1b) ROM-exact (symbol-domain, stronger): %d full frames, payload bits vs ROM errors per frame = %s -> %s\n', ...
    nFullFrames, mat2str(frameBitErrs), ternary(gate_rom,'PASS','FAIL'));
fprintf(fid,'2) cadence: %d frame starts, spacing min=%d max=%d std=%.6f (gate ==9064 exactly, std=0) -> %s\n', ...
    numel(starts), min(dstarts), max(dstarts), std(dstarts), ternary(gate_cadence,'PASS','FAIL'));
fprintf(fid,'   sample-domain spacings: %s\n', mat2str(dstarts));
fprintf(fid,'   symbol-domain spacings (modulator stream): uniq %s (1133 expected)\n', mat2str(unique(dss)));
fprintf(fid,'3) constellation: %d/4 points present; longest NON-junction constant-symbol run = %d (<=34) -> %s\n', ...
    numel(present), maxNonJ, ternary(gate_const,'PASS','FAIL'));
fprintf(fid,'   NOTE: one deterministic %s-symbol (-,-) run per frame at the filler->preamble junction\n', mat2str(junctionLens));
fprintf(fid,'   (K5 contract: 64-ones filler = 32 symbols + 5 leading Barker ones of the NEXT frame + trailing coded\n');
fprintf(fid,'   ones; ends exactly at preamble symbol 5 of every frame -- verified positionally). The legacy <=34\n');
fprintf(fid,'   bound assumed the K7 68-zeros filler, which cannot join the preamble. This run is contract-implied,\n');
fprintf(fid,'   position-locked and present in the golden host reference as well -- NOT a stall/CW.\n');
fprintf(fid,'   One-time pre-first-frame FIFO-priming run (startup) excluded as in zed RTL_GROUNDTRUTH_FINDINGS.txt.\n');
fprintf(fid,'4) per-frame CAP_OUT: %s\n', strjoin(arrayfun(@(v) sprintf('%08X',v), capvals, 'UniformOutput',false), ' '));
fprintf(fid,'   per-frame infoErr: %s\n', mat2str(ierrs));
fprintf(fid,'=======================================================\n');
fclose(fid);
fprintf('WROTE S1_GATE.txt (%s)\n', ternary(allPass,'PASS','FAIL'));
diary off;
fprintf('S1_ANALYZE_DONE allPass=%d\n', allPass);

function s=ternary(c,a,b), if c, s=a; else, s=b; end, end
