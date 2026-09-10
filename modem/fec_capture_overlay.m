function fec_capture_overlay(sys, base)
% fec_capture_overlay -- add INTERMEDIATE-STAGE 32-bit BIT CAPTURE to the
% Jupiter FEC Rx so the host can localize a decode-chain bug in ONE HW read.
% Exposes 3 new AXI read registers 0x13C / 0x140 / 0x144.
%
% Apply AFTER fec_insert_overlay + fec_counters_overlay + fec_skipreg_overlay.
% HDL-only; the IP 64KB AXI range covers these. Idempotent.
%
% Three capture registers, each packing the FIRST 32 relevant bits of a stage,
% latched at the frame's first relevant beat and HELD until the next soft-reset.
% BIT-PACKING CONVENTION (the same for all 3 -- document for the host):
%   the i-th captured bit (i=0..31) is stored in register BIT i (LSB-first):
%     reg = sum_i ( bit_i << i ).
%   So devmem reg & 1 = capture bit 0; (reg>>31)&1 = capture bit 31.
%
%   0x13C CAP_IN    : first 32 coded bits ENTERING the FEC decoder
%                     (Wrapper bitsIn = post-descrambler coded stream),
%                     gated by validIn, started at startIn (frameStart). Tells
%                     you if the ENCODED bits arriving over the cable are right
%                     (ZedBoard encoder + channel + descrambler), or if the
%                     corruption is already upstream of the Viterbi.
%   0x140 CAP_DEINT : first 32 DEINTERLEAVER-OUTPUT coded bits (the codedPair
%                     stream into the Viterbi), gated by deintValid; 2 bits per
%                     pair (pair0 then pair1), 16 pairs. Tells you if the
%                     deinterleaver inverse-permutation is correct.
%   0x144 CAP_OUT   : first 32 VITERBI-OUTPUT decoded info bits (raw Viterbi
%                     decoded bit), gated by deintValid (1 decoded bit/pair).
%                     Tells you if the Viterbi decode itself is right. Compare
%                     to the first 32 bits of 'ADI Hello World'.
%
% Compare each to the EXPECTED values (see fec_capture_expected.m output /
% FEC_DBG6_BUILD.txt). The FIRST stage that diverges from expected is the bug.

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
dec = [base '/Receiver/QPSK Rx/FEC Decoder Wrapper'];
qrx = [base '/Receiver/QPSK Rx'];
rcv = [base '/Receiver'];
loop = base;

% Idempotency marker
if ~isempty(find_system(dec,'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','Name','FecCapture'))
    fprintf('fec_capture_overlay: capture already present -- skipping\n');
    return;
end
assert(~isempty(find_system(dec,'SearchDepth',0)), 'FEC Decoder Wrapper not found at %s', dec);

% ============================================================================
% (1) FecCapture MATLAB Function inside the Wrapper. Taps:
%     i1 = bitsIn      (Wrapper inport1, post-descrambler coded bit)
%     i2 = validIn     (Wrapper inport4)
%     i3 = startIn     (Wrapper inport2, frame start)
%     i4 = codedPair   (RxDeint/1, [2x1] deint output)
%     i5 = deintValid  (RxDeint/3)
%     i6 = decBit      (Viterbi/1, decoded bit)
% Outputs: capIn, capDeint, capOut  (uint32 each).
add_block('simulink/User-Defined Functions/MATLAB Function', [dec '/FecCapture'], ...
    'Position',[340 560 480 700]);
set_fcn_script([dec '/FecCapture'], fecCapture_src());

% New outports on the Wrapper. Current wrapper outports: 4 (data/start/end/valid)
% + 6 counts (from fec_counters_overlay) = 10. Capture takes the next 3.
cap_names = {'cap_in','cap_deint','cap_out'};
nWrapOut0 = numel(find_system(dec,'SearchDepth',1,'BlockType','Outport'));  % 10
childCapPorts = (nWrapOut0+1):(nWrapOut0+3);
for k = 1:3
    add_block('built-in/Outport', [dec '/' cap_names{k}], ...
        'Port', num2str(childCapPorts(k)), 'Position',[760 560+30*k 790 576+30*k]);
end

% Wire taps into FecCapture (7th = skipCount so CAP_OUT is skip-aligned ->
% directly comparable to the first 32 bits of 'ADI Hello World').
add_line(dec, 'bitsIn/1',   'FecCapture/1', 'autorouting','on'); % i1 coded-in bit
add_line(dec, 'validIn/1',  'FecCapture/2', 'autorouting','on'); % i2 validIn
add_line(dec, 'startIn/1',  'FecCapture/3', 'autorouting','on'); % i3 frame start
add_line(dec, 'RxDeint/1',  'FecCapture/4', 'autorouting','on'); % i4 codedPair[2x1]
add_line(dec, 'RxDeint/3',  'FecCapture/5', 'autorouting','on'); % i5 deintValid
add_line(dec, 'RxAlign/1',  'FecCapture/6', 'autorouting','on'); % i6 = RxAlign dataOut (RXROOT E8: the exact BIST stream)
add_line(dec, 'skipCount/1','FecCapture/7', 'autorouting','on'); % i7 skip offset (unused by CAP_OUT since E8)
add_line(dec, 'RxAlign/4',  'FecCapture/8', 'autorouting','on'); % i8 = RxAlign validOut (RXROOT E8)
for k = 1:3
    add_line(dec, sprintf('FecCapture/%d',k), [cap_names{k} '/1'], 'autorouting','on');
end
fprintf('fec_capture_overlay: FecCapture + 3 outports added inside Wrapper\n');

% ============================================================================
% (2) Surface the 3 captures up: FEC Decoder Wrapper -> QPSK Rx -> Receiver ->
%     TxRxComposite. Same explicit-port-tracking method as the counters.
% ============================================================================
levels = { qrx, 'FEC Decoder Wrapper'; rcv, 'QPSK Rx'; loop, 'Receiver' };
childCapPorts = childCapPorts;  %#ok -- the wrapper boundary out-port idx for the 3 caps
for L = 1:size(levels,1)
    parent = levels{L,1};
    child  = levels{L,2};
    nOut0 = numel(find_system(parent,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
    newPorts = zeros(1,3);
    for k = 1:3
        opName = cap_names{k};
        if ~isempty(find_system(parent,'SearchDepth',1,'BlockType','Outport','Name',opName))
            opName = sprintf('%s_L%d', cap_names{k}, L);
        end
        thisPort = nOut0 + k;
        add_block('built-in/Outport', [parent '/' opName], ...
            'Port', num2str(thisPort), 'Position',[900 560+30*thisPort 930 576+30*thisPort]);
        add_line(parent, sprintf('%s/%d', child, childCapPorts(k)), [opName '/1'], 'autorouting','on');
        newPorts(k) = thisPort;
    end
    childCapPorts = newPorts;
    fprintf('fec_capture_overlay: surfaced 3 captures through %s (out-ports %s)\n', parent, mat2str(newPorts));
end

% ============================================================================
% (3) CAP_RAW dropped in dbg9: the pre-descrambler tap read 0 on HW across dbg7
%     (arm-inside-valid) and dbg8 (arm-on-start) and is not worth more effort
%     (per coordinator). The descrambler-input bits are otherwise inferable from
%     CAP_IN xor the known PN. CAP_CAD (below) is kept -- it gave the load-
%     bearing HW datum (startCount=217 ~= 1/frame, validRunLo=0xFF) proving the
%     descrambler input cadence is correct (PN resets once/frame, runs
%     continuously) -- so the failure is a PN-PHASE offset, fixed in dbg9 by the
%     tunable pn_phase register (fec_pnphasereg_overlay), NOT a cadence bug.

% ---------- CAP_CAD -- demod start/valid cadence diagnostic (kept) ----------
% Packs startCount / gapStartToValid / startNotValid / validRunLo into one reg
% so a single HW read reveals the demod start/valid cadence the descrambler
% sees (the model proves the descrambler PN cancels for both framings, so the
% HW break must be a start/valid cadence the sim doesn't show -- this measures
% it directly). Taps demod/2 (start), demod/4 (valid).
add_block('simulink/User-Defined Functions/MATLAB Function', [qrx '/FecCaptureCadence'], ...
    'Position',[340 900 480 1000]);
set_fcn_script([qrx '/FecCaptureCadence'], fecCaptureCadence_src());
nOutQ2 = numel(find_system(qrx,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
add_block('built-in/Outport', [qrx '/cap_cad'], 'Port', num2str(nOutQ2+1), ...
    'Position',[900 900 930 916]);
qrxCadPort = nOutQ2+1;
add_line(qrx, 'QPSK Demodulator/2', 'FecCaptureCadence/1', 'autorouting','on'); % startIn
add_line(qrx, 'QPSK Demodulator/4', 'FecCaptureCadence/2', 'autorouting','on'); % validIn
add_line(qrx, 'FecCaptureCadence/1', 'cap_cad/1', 'autorouting','on');
fprintf('fec_capture_overlay: CAP_CAD (demod cadence) added at QPSK Rx out-port %d\n', qrxCadPort);

% surface cap_cad up: QPSK Rx -> Receiver -> TxRxComposite
cadLevels = { rcv, 'QPSK Rx'; loop, 'Receiver' };
childCadPort = qrxCadPort;
for L = 1:size(cadLevels,1)
    parent = cadLevels{L,1};
    child  = cadLevels{L,2};
    nOut0 = numel(find_system(parent,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
    opName = 'cap_cad';
    if ~isempty(find_system(parent,'SearchDepth',1,'BlockType','Outport','Name',opName))
        opName = sprintf('cap_cad_L%d', L);
    end
    thisPort = nOut0 + 1;
    add_block('built-in/Outport', [parent '/' opName], 'Port', num2str(thisPort), ...
        'Position',[900 900+30*thisPort 930 916+30*thisPort]);
    add_line(parent, sprintf('%s/%d', child, childCadPort), [opName '/1'], 'autorouting','on');
    childCadPort = thisPort;
    fprintf('fec_capture_overlay: surfaced cap_cad through %s (out-port %d)\n', parent, thisPort);
end

fprintf('fec_capture_overlay: DONE -- cap_in/cap_deint/cap_out + cap_cad on TxRxComposite (AXI 0x13C/0x140/0x144/0x14C; cap_raw dropped in dbg9)\n');
end

% ===================== helpers =====================
function set_fcn_script(blk, src)
rt = sfroot;
chart = rt.find('-isa','Stateflow.EMChart','Path',blk);
chart.Script = src;
end

function src = fecCapture_src()
% Latch the first 32 bits of each stage into a uint32 (LSB-first: bit i of the
% capture -> register bit i). Capture windows are armed per-packet so the
% capture reflects ONE coherent packet; we re-arm on each frame start so a
% steady read shows the most recent packet's first 32 bits. Reset by the modem
% soft-reset 0x000 (persistent state -> synchronous reset).
%
% Taps: i1=bitsIn(coded-in), i2=validIn, i3=startIn, i4=codedPair[2x1],
%       i5=deintValid, i6=decBit(Viterbi out).
src = sprintf([ ...
'function [capIn, capDeint, capOut] = fecCapture(bitsIn, validIn, startIn, codedPair, deintValid, decBit, skipCount, outValid)\n' ...
'%%#codegen\n' ...
'persistent rIn rDe rOu nIn nDe nOu armIn skp;\n' ...
'if isempty(rIn)\n' ...
'  rIn=uint32(0); rDe=uint32(0); rOu=uint32(0);\n' ...
'  nIn=uint16(0); nDe=uint16(0); nOu=uint16(0); armIn=false; skp=uint16(0);\n' ...
'end\n' ...
'%% sync-semantics compliant (RXROOT E11c): locals, persist last.\n' ...
'a=rIn; b=rDe; c=rOu; xIn=nIn; xDe=nDe; xOu=nOu; arm=armIn; sk=skp; %%#ok<NASGU>\n' ...
'%% --- CAP_IN: first 32 coded-in bits, armed at startIn, gated by validIn ---\n' ...
'if validIn\n' ...
'  if startIn, xIn=uint16(0); a=uint32(0); arm=true; end\n' ...
'  if arm && xIn < uint16(32)\n' ...
'    if bitsIn, a = bitor(a, bitshift(uint32(1), double(xIn))); end\n' ...
'    xIn = xIn + uint16(1);\n' ...
'  end\n' ...
'end\n' ...
'%% --- CAP_DEINT: first 32 deint-output coded bits (2 per pair), gated by deintValid ---\n' ...
'if startIn, xDe=uint16(0); b=uint32(0); end\n' ...
'if deintValid && xDe < uint16(32)\n' ...
'  b0 = codedPair(1) ~= 0; b1 = codedPair(2) ~= 0;\n' ...
'  if b0, b = bitor(b, bitshift(uint32(1), double(xDe))); end\n' ...
'  xDe = xDe + uint16(1);\n' ...
'  if xDe < uint16(32)\n' ...
'    if b1, b = bitor(b, bitshift(uint32(1), double(xDe))); end\n' ...
'    xDe = xDe + uint16(1);\n' ...
'  end\n' ...
'end\n' ...
'%% --- CAP_OUT (RXROOT E8): first 32 bits of the WRAPPER OUTPUT stream ---\n' ...
'%% i6 = RxAlign dataOut gated by i8 = RxAlign validOut: exactly the bits the\n' ...
'%% BIST compares, alignment-independent. Golden expectation 0x04922282.\n' ...
'sc = uint16(skipCount); sk = uint16(0); %%#ok<NASGU>\n' ...
'if startIn, xOu=uint16(0); c=uint32(0); end\n' ...
'if outValid && xOu < uint16(32)\n' ...
'  if decBit, c = bitor(c, bitshift(uint32(1), double(xOu))); end\n' ...
'  xOu = xOu + uint16(1);\n' ...
'end\n' ...
'capIn = a; capDeint = b; capOut = c;\n' ...
'rIn=a; rDe=b; rOu=c; nIn=xIn; nDe=xDe; nOu=xOu; armIn=arm; skp=sk;\n']);
end

function src = fecCaptureCadence_src()
% dbg8 DIAGNOSTIC: measure the demod start/valid CADENCE that the descrambler
% actually receives on HW. The model PROVES the descrambler PN cancels the
% scrambler PN for both interleaver framings (descramble->0x00000C5E=txair), so
% the HW failure must be a start/valid CADENCE difference at the descrambler
% input that the model sim (continuous valid, single start) does not exhibit.
% This packs four 8-bit fields into one 32-bit register so ONE read reveals it:
%   bits  0..7  : startCount  -- # of startIn pulses seen (should be 1/frame; if
%                 >1 the PN is being RESET mid-frame -> exactly the "PN != Tx"
%                 symptom, since each reset re-zeros the descrambler PN phase).
%   bits  8..15 : gapStartToValid -- # of beats from the (first) startIn pulse
%                 until the first validIn beat (0 if co-asserted). A nonzero gap
%                 with arm-on-valid (dbg7 bug) is exactly why CAP_RAW was 0; it
%                 also tells whether the demod start leads the data.
%   bits 16..23 : startNotValid -- # of startIn pulses asserted while validIn=0
%                 (these are the pulses the dbg7 capture dropped).
%   bits 24..31 : validRunLo  -- low 8 bits of the validIn run length after the
%                 first start (saturates at 255), to confirm a contiguous frame.
src = sprintf([ ...
'function capCad = fecCaptureCadence(startIn, validIn)\n' ...
'%%#codegen\n' ...
'persistent sCnt gap snv vrun seenStart sawValid measuring;\n' ...
'if isempty(sCnt)\n' ...
'  sCnt=uint8(0); gap=uint8(0); snv=uint8(0); vrun=uint8(0);\n' ...
'  seenStart=false; sawValid=false; measuring=false;\n' ...
'end\n' ...
'%% sync-semantics compliant (RXROOT E11c): locals, persist last.\n' ...
'sC=sCnt; gp=gap; sv=snv; vr=vrun; seen=seenStart; saw=sawValid; mea=measuring;\n' ...
'if startIn\n' ...
'  if sC < uint8(255), sC = sC + uint8(1); end\n' ...
'  if ~validIn && sv < uint8(255), sv = sv + uint8(1); end\n' ...
'  if ~seen\n' ...
'    seen = true; mea = true; gp = uint8(0); saw=false; vr=uint8(0);\n' ...
'  end\n' ...
'end\n' ...
'if mea && ~saw\n' ...
'  if validIn\n' ...
'    saw = true;\n' ...
'  elseif gp < uint8(255)\n' ...
'    gp = gp + uint8(1);\n' ...
'  end\n' ...
'end\n' ...
'if seen && validIn && vr < uint8(255)\n' ...
'  vr = vr + uint8(1);\n' ...
'end\n' ...
'capCad = bitor(bitor(uint32(sC), bitshift(uint32(gp),8)), ' ...
'bitor(bitshift(uint32(sv),16), bitshift(uint32(vr),24)));\n' ...
'sCnt=sC; gap=gp; snv=sv; vrun=vr; seenStart=seen; sawValid=saw; measuring=mea;\n']);
end
