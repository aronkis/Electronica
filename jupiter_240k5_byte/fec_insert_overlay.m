function fec_insert_overlay(sys, base)
% base : OPTIONAL parent path that contains Transmitter and Receiver. For the
%        composite HDL DUT pass base = '<sys>/TxRxComposite' so the FEC lands in
%        the SYNTHESIZED copy (build_composite_local duplicates Transmitter/
%        Receiver into TxRxComposite, so the library-level copies are NOT the
%        DUT). Defaults to sys (the plain commhdlQPSKTxRx loopback model).
% fec_insert_overlay  Board-AGNOSTIC FEC insertion into the QPSK Tx/Rx DUT.
%
% Inserts Variant-A rate-1/2 convolutional FEC into commhdlQPSKTxRx / its
% composite clone, matching the sim-validated topology in
% /mnt/onetb/scratch/qpsk_variants/fec_modem/FEC_MODEM_SIM.txt :
%   * Tx: comm Convolutional Encoder poly2trellis(7,[171 133]), per-packet
%         reset (opMode='Reset on nonzero input via port', DelayedResetAction
%         ='on' -- the load-bearing HDL gate) + 16-col block interleaver,
%         realized between Bit Packetizer and HDL Data Scrambler. The
%         encoder ingests the first 1080 payload info bits + 6 tail bits ->
%         2172 coded bits, placed in the first 2172 of the 2240-bit payload
%         slot (FRAME SIZE UNCHANGED; preamble/scrambler/MUX/AXI untouched).
%   * Rx: 16-col block deinterleaver + comm Viterbi Decoder (Hard decision,
%         TracebackDepth=34, opmode=Continuous, delayedResetAction='on')
%         between HDL Data Descrambler and Capture Data Bits, with a matched
%         start/valid delay so the BIST 120-bit window realigns to the
%         decoded "ADI Hello World".
%
% IDENTICAL artifact is reused by BOTH the Jupiter and ZedBoard builds so the
% ZedBoard Tx encoder and Jupiter Rx decoder are bit-exactly compatible
% (same trellis, same interleaver depth/order, same per-packet-reset framing,
% same payload bit-mapping). Board-specific bits (IOInterface mappings, target
% device, integAvgLen, MUX) live in the per-board variant_pre.m / workflow, NOT
% here.
%
% Apply AFTER the model is loaded and BEFORE HDL codegen. Idempotent: a second
% call detects the marker and returns. Read commhdlQPSKTxRxParameters() for the
% framing constants.

NL = char(10);
if nargin < 1, sys = bdroot; end
if nargin < 2 || isempty(base), base = sys; end
P = commhdlQPSKTxRxParameters();
assert(P.DataBitsPerPacket == 2240, 'unexpected DataBitsPerPacket');

% -------- FEC params (MUST match the sim + the parallel board build) --------
TRELLIS_STR = 'poly2trellis(7, [171 133])';
INFO_BITS   = 1080;   % info bits protected per packet (first 1080 of 2240)
TAIL_BITS   = 6;      % K-1 flush bits
CODED_BITS  = 2*(INFO_BITS + TAIL_BITS);   % = 2172  (<= 2240, frame unchanged)
INTERLEAVE_COLS = 16; % 16-column block interleaver (sim Variant A choice)
TB_DEPTH    = 34;     % Viterbi traceback (hard)
assert(CODED_BITS <= P.DataBitsPerPacket, 'coded bits overflow payload slot');

% Marker: skip if already inserted under the target base
if ~isempty(find_system(base,'LookUnderMasks','all','FollowLinks','on', ...
        'BlockType','SubSystem','Name','FEC Encoder Wrapper'))
    fprintf('fec_insert_overlay: FEC already present under %s -- skipping\n', base);
    return;
end

load_system('commcnvcod2');     %#ok ensure lib loaded

% ============================================================================
% (A)  TX  --  insert FEC Encoder Wrapper between Bit Packetizer and Scrambler
% ============================================================================
% The wrapper is a self-contained subsystem that:
%   in : bitsOut, dataStart, dataEnd, bitsValid (from Bit Packetizer)
%   out: dataOut, startOut, endOut, validOut    (to HDL Data Scrambler)
% Internally a streaming FSM (HDL-friendly MATLAB Function) gates the first
% 1080 info bits + 6 tail into the comm Convolutional Encoder (per-packet
% reset), serializes the 2 coded bits/info bit into consecutive payload
% beats, runs them through the 16-col block interleaver, and re-emits the
% original start/end/valid framing so the Scrambler sees an unchanged
% 2240-bit/packet payload.
qtx = [base '/Transmitter/QPSK Tx'];
assert(~isempty(find_system(qtx,'SearchDepth',0)), 'QPSK Tx not found');

bp  = [qtx '/Bit Packetizer'];
scr = [qtx '/HDL Data Scrambler'];

% Remove the 4 Packetizer->Scrambler lines (data/start/end/valid)
% Packetizer outs: 1 bitsOut, 2 dataStart, 3 dataEnd, 4 bitsValid
% Scrambler  ins : 1 dataIn,  2 startIn,   3 endIn,    4 validIn
delete_line(qtx, 'Bit Packetizer/1', 'HDL Data Scrambler/1');
delete_line(qtx, 'Bit Packetizer/2', 'HDL Data Scrambler/2');
delete_line(qtx, 'Bit Packetizer/3', 'HDL Data Scrambler/3');
delete_line(qtx, 'Bit Packetizer/4', 'HDL Data Scrambler/4');

enc = [qtx '/FEC Encoder Wrapper'];
build_tx_encoder_wrapper(enc, TRELLIS_STR, INFO_BITS, TAIL_BITS, CODED_BITS, INTERLEAVE_COLS);

% Wire Packetizer -> Encoder Wrapper -> Scrambler
add_line(qtx, 'Bit Packetizer/1', 'FEC Encoder Wrapper/1', 'autorouting','on');
add_line(qtx, 'Bit Packetizer/2', 'FEC Encoder Wrapper/2', 'autorouting','on');
add_line(qtx, 'Bit Packetizer/3', 'FEC Encoder Wrapper/3', 'autorouting','on');
add_line(qtx, 'Bit Packetizer/4', 'FEC Encoder Wrapper/4', 'autorouting','on');
add_line(qtx, 'FEC Encoder Wrapper/1', 'HDL Data Scrambler/1', 'autorouting','on');
add_line(qtx, 'FEC Encoder Wrapper/2', 'HDL Data Scrambler/2', 'autorouting','on');
add_line(qtx, 'FEC Encoder Wrapper/3', 'HDL Data Scrambler/3', 'autorouting','on');
add_line(qtx, 'FEC Encoder Wrapper/4', 'HDL Data Scrambler/4', 'autorouting','on');
fprintf('fec_insert_overlay: Tx FEC Encoder Wrapper inserted\n');

% ============================================================================
% (B)  RX  --  insert FEC Decoder Wrapper between Descrambler and BIST
% ============================================================================
% In the QPSK Rx subsystem, the descrambled payload + start/end/valid leave
% via the QPSK Rx outports (dataOut, ctrlOut bus) that feed Capture Data Bits.
% We splice deinterleaver + Viterbi + matched start/valid delay right after
% the HDL Data Descrambler, before its outputs leave QPSK Rx.
qrx = [base '/Receiver/QPSK Rx'];
dscr = [qrx '/HDL Data Descrambler'];
% Descrambler outs: 1 dataOut, 2 startOut, 3 endOut, 4 validOut
% dataOut -> 'dataOut' outport ; start/end/valid -> Bus Creator1 -> ctrlOut
% We need: descrambled data+start+valid into decoder; decoder out replaces
% the data path to 'dataOut', and the matched-delayed start/valid replace the
% control going to the BIST.
dec = [qrx '/FEC Decoder Wrapper'];
build_rx_decoder_wrapper(dec, TRELLIS_STR, TB_DEPTH, INFO_BITS, CODED_BITS, INTERLEAVE_COLS);

% Re-route: Descrambler dataOut/startOut/endOut/validOut -> Decoder Wrapper
% Find current destinations of descrambler ports to rewire cleanly.
% dataOut (port1) currently -> 'dataOut' outport
delete_line(qrx, 'HDL Data Descrambler/1', 'dataOut/1');
% start/end/valid (2/3/4) -> Bus Creator1 ports 1/2/3
delete_line(qrx, 'HDL Data Descrambler/2', 'Bus Creator1/1');
delete_line(qrx, 'HDL Data Descrambler/3', 'Bus Creator1/2');
delete_line(qrx, 'HDL Data Descrambler/4', 'Bus Creator1/3');

add_line(qrx, 'HDL Data Descrambler/1', 'FEC Decoder Wrapper/1', 'autorouting','on');
add_line(qrx, 'HDL Data Descrambler/2', 'FEC Decoder Wrapper/2', 'autorouting','on');
add_line(qrx, 'HDL Data Descrambler/3', 'FEC Decoder Wrapper/3', 'autorouting','on');
add_line(qrx, 'HDL Data Descrambler/4', 'FEC Decoder Wrapper/4', 'autorouting','on');
% Decoder outs: 1 dataOut(decoded) 2 startOut 3 endOut 4 validOut
add_line(qrx, 'FEC Decoder Wrapper/1', 'dataOut/1', 'autorouting','on');
add_line(qrx, 'FEC Decoder Wrapper/2', 'Bus Creator1/1', 'autorouting','on');
add_line(qrx, 'FEC Decoder Wrapper/3', 'Bus Creator1/2', 'autorouting','on');
add_line(qrx, 'FEC Decoder Wrapper/4', 'Bus Creator1/3', 'autorouting','on');
fprintf('fec_insert_overlay: Rx FEC Decoder Wrapper inserted\n');

fprintf('fec_insert_overlay: DONE (trellis=%s, info=%d coded=%d cols=%d tb=%d)\n', ...
    TRELLIS_STR, INFO_BITS, CODED_BITS, INTERLEAVE_COLS, TB_DEPTH);
end

% ----------------------------------------------------------------------------
function build_tx_encoder_wrapper(enc, TRELLIS_STR, INFO_BITS, TAIL_BITS, CODED_BITS, COLS)
NL = char(10);
add_block('built-in/Subsystem', enc, 'Position',[300 380 420 480]);
% ports
for k=1:4, add_block('built-in/Inport',[enc '/' inn(k)],'Port',num2str(k),'Position',[20 40+40*k 50 60+40*k]); end
for k=1:4, add_block('built-in/Outport',[enc '/' onn(k)],'Port',num2str(k),'Position',[700 40+40*k 730 60+40*k]); end

% (1) Gating FSM: from {bitsOut,dataStart,dataEnd,bitsValid} produce the
%     encoder input bit + encoder enable + per-packet reset + a frame-phase
%     index used to schedule coded-bit serialization and interleaving.
add_block('simulink/User-Defined Functions/MATLAB Function',[enc '/TxGate'],'Position',[120 60 260 200]);
set_fcn_script([enc '/TxGate'], fecTxGate_src(INFO_BITS, TAIL_BITS));  % set BEFORE wiring so ports exist
% TxGate I/O: (bitsOut,dataStart,dataEnd,bitsValid) ->
%             (infoBit, encEnable, encReset, codedIdx, frameValid, frameStart, frameEnd)

% (2) comm Convolutional Encoder -- per-packet reset, HDL-supported config
add_block(['commcnvcod2/Convolutional' NL 'Encoder'],[enc '/Conv Encoder'],'Position',[320 70 420 140]);
set_param([enc '/Conv Encoder'],'trellis',TRELLIS_STR, ...
    'opMode','Reset on nonzero input via port','reset','On nonzero Rst input', ...
    'DelayedResetAction','on');   % <-- load-bearing HDL gate (checkhdl)

% (3) Serializer + 16-col block interleaver: take the 2-bit encoder output
%     (emitted as consecutive payload beats), write row-major to a per-packet
%     dual-port RAM, read column-major (16 cols), gated by codedIdx, reset by
%     frameStart. Realized as a MATLAB Function driving a Simple Dual-Port RAM.
add_block('simulink/User-Defined Functions/MATLAB Function',[enc '/TxInterleave'],'Position',[480 60 620 200]);
set_fcn_script([enc '/TxInterleave'], fecTxInterleave_src(CODED_BITS, COLS));  % set BEFORE wiring
% TxInterleave I/O: (codedBit, codedIdx, frameValid, frameStart, frameEnd) ->
%                   (dataOut, startOut, endOut, validOut)

% Wire: inports -> TxGate
add_line(enc, [inn(1) '/1'], 'TxGate/1', 'autorouting','on');  % bitsOut
add_line(enc, [inn(2) '/1'], 'TxGate/2', 'autorouting','on');  % dataStart
add_line(enc, [inn(3) '/1'], 'TxGate/3', 'autorouting','on');  % dataEnd
add_line(enc, [inn(4) '/1'], 'TxGate/4', 'autorouting','on');  % bitsValid
% TxGate outs: 1 infoBit 2 encReset 3 infoValid 4 beatIdx 5 frameValid 6 frameStart 7 frameEnd
add_line(enc, 'TxGate/1', 'Conv Encoder/1', 'autorouting','on');  % infoBit
add_line(enc, 'TxGate/2', 'Conv Encoder/2', 'autorouting','on');  % encReset
% encoder coded [2x1] pair -> interleaver port1
add_line(enc, 'Conv Encoder/1', 'TxInterleave/1', 'autorouting','on');  % codedPair[2x1]
add_line(enc, 'TxGate/3', 'TxInterleave/2', 'autorouting','on');  % infoValid
add_line(enc, 'TxGate/4', 'TxInterleave/3', 'autorouting','on');  % beatIdx
add_line(enc, 'TxGate/5', 'TxInterleave/4', 'autorouting','on');  % frameValid
add_line(enc, 'TxGate/6', 'TxInterleave/5', 'autorouting','on');  % frameStart
add_line(enc, 'TxGate/7', 'TxInterleave/6', 'autorouting','on');  % frameEnd
% interleaver outs -> outports
add_line(enc, 'TxInterleave/1', [onn(1) '/1'], 'autorouting','on');
add_line(enc, 'TxInterleave/2', [onn(2) '/1'], 'autorouting','on');
add_line(enc, 'TxInterleave/3', [onn(3) '/1'], 'autorouting','on');
add_line(enc, 'TxInterleave/4', [onn(4) '/1'], 'autorouting','on');
end

% ----------------------------------------------------------------------------
function build_rx_decoder_wrapper(dec, TRELLIS_STR, TB, INFO_BITS, CODED_BITS, COLS)
add_block('built-in/Subsystem', dec, 'Position',[700 380 820 480]);
for k=1:4, add_block('built-in/Inport',[dec '/' inn(k)],'Port',num2str(k),'Position',[20 40+40*k 50 60+40*k]); end
% dbg4: 5th inport = skipCount (runtime AXI 0x138 align offset), threaded down
% from TxRxComposite -> Receiver -> QPSK Rx -> here -> RxAlign.
add_block('built-in/Inport',[dec '/skipCount'],'Port','5','Position',[20 40+40*5 50 60+40*5]);
set_param([dec '/skipCount'],'OutDataTypeStr','uint32','SampleTime','-1');
for k=1:4, add_block('built-in/Outport',[dec '/' onn(k)],'Port',num2str(k),'Position',[760 40+40*k 790 60+40*k]); end

% (1) RxDeint FSM: from descrambled (dataIn,startIn,endIn,validIn) deinterleave
%     the first CODED_BITS payload bits (16-col block, per-packet reset) and
%     emit coded bits + a valid for the Viterbi.
add_block('simulink/User-Defined Functions/MATLAB Function',[dec '/RxDeint'],'Position',[120 60 260 200]);
set_fcn_script([dec '/RxDeint'],  fecRxDeint_src(CODED_BITS, COLS));  % set BEFORE wiring

% (2) Viterbi Decoder -- hard, tb=34, continuous, delayed reset (HDL gate).
%     FLAT (not in a conditional subsystem -> no delay-balancing failure).
%
% HW STALL FIX (dbg2): on hardware the FEC decoder is flattened to a single
% clock and the comm Viterbi is clock-enabled on EVERY cycle. The ORIGINAL
% deinterleaver emitted a real coded pair only every OTHER cycle (it
% accumulated b0 over 2 cycles) and drove codedPair=[0;0] in between, so the
% free-running Viterbi ingested [0;0] garbage between real pairs and its
% branch-metrics/traceback were destroyed -> ZERO decoded bits (HW counters:
% deint_valid>0 but dec_bits=0). The multirate SIM hid this because the
% scheduler clocked the Viterbi only on the deint-output sample.
% FIX (in fecRxDeint, see fecRxDeint_src): the deinterleaver now reads BOTH
% coded bits of each pair in ONE cycle and emits a VALID coded pair on EVERY
% validIn cycle (no [0;0] gaps). The free-running Viterbi therefore sees real
% pairs back-to-back -> correct decode. Bit-exact: the emitted pair SEQUENCE is
% identical to the original deint (verified, 0-error decode incl. first 120
% BIST bits). Trellis/tb/opmode/per-packet-reset UNCHANGED -> still bit-exact
% to the ZedBoard encoder. No conditional subsystem -> no delay-balancing error.
add_block('commcnvcod2/Viterbi Decoder',[dec '/Viterbi'],'Position',[320 70 430 140]);
set_param([dec '/Viterbi'],'trellis',TRELLIS_STR,'dectype','Hard decision', ...
    'tbdepth',num2str(TB),'opmode','Continuous','reset','on', ...
    'delayedResetAction','on', ...        % reset checkbox 'on' adds the Rst input port
    'outDataType','boolean');             % decoded bit as boolean -> matches msgdec/BIST

% (3) RxAlign FSM: realign decoded info bits to the BIST 120-bit window by
%     re-issuing start/end/valid delayed by the (deinterleave+traceback)
%     fixed latency, so msgdec compares decoded "ADI Hello World".
add_block('simulink/User-Defined Functions/MATLAB Function',[dec '/RxAlign'],'Position',[500 60 660 200]);
set_fcn_script([dec '/RxAlign'],  fecRxAlign_src(INFO_BITS, TB));  % set BEFORE wiring

% wiring
add_line(dec, [inn(1) '/1'], 'RxDeint/1', 'autorouting','on');
add_line(dec, [inn(2) '/1'], 'RxDeint/2', 'autorouting','on');
add_line(dec, [inn(3) '/1'], 'RxDeint/3', 'autorouting','on');
add_line(dec, [inn(4) '/1'], 'RxDeint/4', 'autorouting','on');
% RxDeint outs: 1 codedPair[2x1] 2 vitReset 3 deintValid 4 frameStart 5 frameEnd
add_line(dec, 'RxDeint/1', 'Viterbi/1', 'autorouting','on'); % coded pair (valid every cycle)
add_line(dec, 'RxDeint/2', 'Viterbi/2', 'autorouting','on'); % per-pkt reset
add_line(dec, 'Viterbi/1', 'RxAlign/1', 'autorouting','on'); % decoded bit
add_line(dec, 'RxDeint/3', 'RxAlign/2', 'autorouting','on'); % deintValid
add_line(dec, 'RxDeint/4', 'RxAlign/3', 'autorouting','on'); % frameStart
add_line(dec, 'RxDeint/5', 'RxAlign/4', 'autorouting','on'); % frameEnd
add_line(dec, 'skipCount/1', 'RxAlign/5', 'autorouting','on'); % runtime align offset (0x138)
% RxAlign outs: 1 dataOut 2 startOut 3 endOut 4 validOut
add_line(dec, 'RxAlign/1', [onn(1) '/1'], 'autorouting','on');
add_line(dec, 'RxAlign/2', [onn(2) '/1'], 'autorouting','on');
add_line(dec, 'RxAlign/3', [onn(3) '/1'], 'autorouting','on');
add_line(dec, 'RxAlign/4', [onn(4) '/1'], 'autorouting','on');
end

% ===================== helpers =====================
function s = inn(k), names={'bitsIn','startIn','endIn','validIn'}; s=names{k}; end
function s = onn(k), names={'dataOut','startOut','endOut','validOut'}; s=names{k}; end

function set_fcn_script(blk, src)
% set the body of a MATLAB Function block
rt = sfroot;
chart = rt.find('-isa','Stateflow.EMChart','Path',blk);
chart.Script = src;
end

% ---- MATLAB Function source generators (HDL-friendly: fixed-size, persistent) ----
function src = fecTxGate_src(INFO, TAIL)
% One info/tail bit per payload beat for the first INFO+TAIL (=1086) beats of
% the packet. The comm encoder consumes that scalar and emits a [2x1] coded
% pair every beat (rate-1/2). TxInterleave writes BOTH bits of the pair to its
% per-packet RAM (2 cells/beat) over the first 1086 beats, then reads out the
% interleaved 2172 coded bits across the full 2172-beat window. infoCnt tags
% which input beats are valid encoder advances.
src = sprintf([ ...
'function [infoBit, encReset, infoValid, beatIdx, frameValid, frameStart, frameEnd] = fecTxGate(bitsOut, dataStart, dataEnd, bitsValid)\n' ...
'%%#codegen\n' ...
'persistent inCnt outCnt;\n' ...
'if isempty(inCnt), inCnt=uint16(0); outCnt=uint16(0); end\n' ...
'INFO=uint16(%d); TAIL=uint16(%d); NIN=uint16(%d+%d); CODED=uint16(2*(%d+%d));\n' ...
'infoBit=false; encReset=false; infoValid=false; beatIdx=uint16(0);\n' ...
'frameValid=false; frameStart=false; frameEnd=false;\n' ...
'if bitsValid\n' ...
'  if dataStart, inCnt=uint16(0); outCnt=uint16(0); encReset=true; end\n' ...
'  if inCnt < INFO\n' ...
'    infoBit = bitsOut; infoValid=true; inCnt=inCnt+1;\n' ...
'  elseif inCnt < NIN\n' ...
'    infoBit = false;   infoValid=true; inCnt=inCnt+1;\n' ...
'  end\n' ...
'  beatIdx = outCnt;\n' ...
'  if outCnt < CODED, frameValid=true; outCnt=outCnt+1; end\n' ...
'  frameStart = dataStart; frameEnd = dataEnd;\n' ...
'end\n'], INFO, TAIL, INFO, TAIL, INFO, TAIL);
end

function src = fecTxInterleave_src(CODED, COLS)
% Ping-pong block interleaver: WRITE phase fills bank with the encoder pairs
% (2 cells/beat, infoValid) row-major; the OTHER bank (filled on the previous
% packet) is READ OUT column-major (16-col block) one bit per beat over the
% full 2172-beat window. Read lags write by one packet => no read-before-write
% hazard; per-packet self-contained (drop-robust). codedPair is the [2x1]
% encoder output. beatIdx 0..CODED-1 is the read index this packet.
src = sprintf([ ...
'function [dataOut, startOut, endOut, validOut] = fecTxInterleave(codedPair, infoValid, beatIdx, frameValid, frameStart, frameEnd)\n' ...
'%%#codegen\n' ...
'persistent ramA ramB rdBank wptr;\n' ...
'CODED=uint16(%d); COLS=uint16(%d); ROWS=uint16(idivide(uint16(%d),uint16(%d)));\n' ...
'if isempty(ramA), ramA=false(1,%d); ramB=false(1,%d); rdBank=false; wptr=uint16(0); end\n' ...
'dataOut=false; startOut=false; endOut=false; validOut=false;\n' ...
'if frameStart, wptr=uint16(0); rdBank=~rdBank; end\n' ...
'%% WRITE: two coded bits per encoder-advance beat into the WRITE bank\n' ...
'if infoValid\n' ...
'  if wptr < CODED\n' ...
'    if rdBank,  ramA(double(wptr)+1)=codedPair(1); else ramB(double(wptr)+1)=codedPair(1); end\n' ...
'    wptr=wptr+1;\n' ...
'  end\n' ...
'  if wptr < CODED\n' ...
'    if rdBank,  ramA(double(wptr)+1)=codedPair(2); else ramB(double(wptr)+1)=codedPair(2); end\n' ...
'    wptr=wptr+1;\n' ...
'  end\n' ...
'end\n'...
'%% READ: column-major permutation from the READ bank, one bit per beat\n' ...
'if frameValid\n' ...
'  ridx = beatIdx;\n' ...
'  if ridx < CODED\n' ...
'    r = mod(ridx, ROWS); c = idivide(ridx, ROWS);\n' ...
'    perm = r*COLS + c;\n' ...
'    if perm < CODED\n' ...
'      if rdBank, dataOut = ramB(double(perm)+1); else dataOut = ramA(double(perm)+1); end\n' ...
'    end\n' ...
'  end\n' ...
'  validOut=true; startOut=frameStart; endOut=frameEnd;\n' ...
'end\n'], CODED, COLS, CODED, COLS, CODED, CODED);
end

function src = fecRxDeint_src(CODED, COLS)
% Ping-pong block deinterleaver. WRITE phase stores the descrambled payload's
% first CODED bits into the WRITE bank (linear). The READ phase emits the
% inverse-permuted coded bits PAIRED [2x1] for the hard-decision Viterbi
% (rate-1/2 -> 2 coded bits per decoded bit).
%
% HW-STALL FIX (dbg2): read BOTH coded bits of each pair in ONE call and emit a
% VALID coded pair on EVERY validIn cycle (pair index pcnt -> read indices
% 2*pcnt and 2*pcnt+1). The ORIGINAL version emitted a pair only every OTHER
% cycle (half toggle) with codedPair=[0;0] in between; on the single-clock HW
% the free-running Viterbi ingested that [0;0] garbage and produced nothing.
% Emitting a real pair every cycle (no gaps) lets the free-running Viterbi
% decode correctly. The emitted pair SEQUENCE is identical to the original
% (verified bit-exact, 0-error decode incl. the first 120 BIST bits). vitReset
% pulses on the first pair (pcnt==0) of each packet; deintValid is true for the
% CODED/2 pair cycles, then the last pair is HELD (deintValid=0) until the next
% packet's startIn -- the held duplicate is flushed by the per-packet reset.
src = sprintf([ ...
'function [codedPair, vitReset, deintValid, frameStart, frameEnd] = fecRxDeint(dataIn, startIn, endIn, validIn)\n' ...
'%%#codegen\n' ...
'%% Viterbi hard-decision input REQUIRES ufix(1) (not boolean): emit codedPair\n' ...
'%% as a 2x1 ufix(1). Internal RAM/bits stay boolean; cast at the output.\n' ...
'persistent ramA ramB rdBank wptr pcnt hold0 hold1;\n' ...
'CODED=uint16(%d); COLS=uint16(%d); ROWS=uint16(idivide(uint16(%d),uint16(%d)));\n' ...
'NPAIR=uint16(idivide(uint16(%d),uint16(2)));\n' ...
'if isempty(ramA), ramA=false(1,%d); ramB=false(1,%d); rdBank=false; wptr=uint16(0); pcnt=uint16(0); hold0=false; hold1=false; end\n' ...
'pair0=hold0; pair1=hold1;\n' ...
'vitReset=false; deintValid=false; frameStart=false; frameEnd=false;\n' ...
'if validIn\n' ...
'  if startIn, wptr=uint16(0); pcnt=uint16(0); rdBank=~rdBank; end\n' ...
'  %% WRITE current packet payload into the WRITE bank (linear)\n' ...
'  if wptr < CODED\n' ...
'    if rdBank, ramA(double(wptr)+1)=dataIn; else ramB(double(wptr)+1)=dataIn; end\n' ...
'    wptr=wptr+1;\n' ...
'  end\n' ...
'  %% READ previous packet (READ bank): BOTH coded bits of pair pcnt this cycle\n' ...
'  if pcnt < NPAIR\n' ...
'    rc0 = pcnt+pcnt;            %% 2*pcnt\n' ...
'    rc1 = rc0 + uint16(1);      %% 2*pcnt+1\n' ...
'    c0 = mod(rc0, COLS); r0 = idivide(rc0, COLS); perm0 = c0*ROWS + r0;\n' ...
'    c1 = mod(rc1, COLS); r1 = idivide(rc1, COLS); perm1 = c1*ROWS + r1;\n' ...
'    b0v = false; b1v = false;\n' ...
'    if perm0 < CODED\n' ...
'      if rdBank, b0v = ramB(double(perm0)+1); else b0v = ramA(double(perm0)+1); end\n' ...
'    end\n' ...
'    if perm1 < CODED\n' ...
'      if rdBank, b1v = ramB(double(perm1)+1); else b1v = ramA(double(perm1)+1); end\n' ...
'    end\n' ...
'    pair0 = b0v; pair1 = b1v; hold0 = b0v; hold1 = b1v;\n' ...
'    deintValid = true;\n' ...
'    if pcnt == uint16(0), vitReset = true; end\n' ...
'    pcnt = pcnt + 1;\n' ...
'  end\n' ...
'  frameStart=startIn; frameEnd=endIn;\n' ...
'end\n' ...
'%% cast to ufix(1) 2x1 for the hard-decision Viterbi input\n' ...
'codedPair = fi([pair0; pair1], 0, 1, 0);\n'], CODED, COLS, CODED, COLS, CODED, CODED, CODED);
end

function src = fecRxAlign_src(INFO, TB) %#ok<INUSD>
% Re-issue start/end/valid aligned to the decoded info bits for the BIST window.
%
% ALIGNMENT: the continuous-mode Viterbi's decoded output LAGS its input by a
% fixed pipeline latency (traceback depth + deint + pipeline regs). At the
% cycle frameStart arrives (deint pair 0 of the new frame), the Viterbi's
% CURRENT decoded bit corresponds to a pair ~latency cycles in the PAST. So
% RxAlign must DISCARD the first 'skipCount' decoded bits after frameStart,
% THEN capture the INFO info bits (startOut on the first real one).
%
% dbg4: skipCount is a RUNTIME AXI register (TxRxComposite/skip_count @ 0x138,
% default 34) -- NOT a hardcoded constant -- so the exact pipeline latency can
% be swept on hardware without a rebuild (offset 0 was 52.86%, skip=34 moved it
% to 45.39%, i.e. the model tb=34 != the true flat-HW latency; sweep 0x138 to
% find the value that collapses BER to the coded floor). skipCount latches at
% frameStart. Cast to uint16 and clamp to INFO to keep the FSM bounded.
src = sprintf([ ...
'function [dataOut, startOut, endOut, validOut] = fecRxAlign(decBit, deintValid, frameStart, frameEnd, skipCount)\n' ...
'%%#codegen\n' ...
'persistent oc started skip;\n' ...
'INFO=uint16(%d);\n' ...
'if isempty(oc), oc=uint16(0); started=false; skip=uint16(0); end\n' ...
'dataOut=false; startOut=false; endOut=false; validOut=false;\n' ...
'%% latch the runtime skip count (0x138) at frame start; clamp to INFO\n' ...
'sc = uint16(skipCount);\n' ...
'if sc > INFO, sc = INFO; end\n' ...
'if deintValid\n' ...
'  if frameStart, oc=uint16(0); started=true; skip=sc; end\n' ...
'  if started\n' ...
'    if skip > uint16(0)\n' ...
'      skip = skip - uint16(1);   %% discard the pipeline-latency warmup bits\n' ...
'    elseif oc < INFO\n' ...
'      dataOut = decBit;\n' ...
'      startOut = (oc==uint16(0));\n' ...
'      endOut   = (oc==(INFO-1));\n' ...
'      validOut = true;\n' ...
'      oc = oc + uint16(1);\n' ...
'    end\n' ...
'  end\n' ...
'end\n'], INFO);
end
