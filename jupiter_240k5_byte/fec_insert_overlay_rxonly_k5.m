function fec_insert_overlay_rxonly_k5(sys, base)
% fec_insert_overlay_rxonly_k5 -- RX-ONLY K=5 FEC insertion (jupiter_240k5).
%
% Copy of zed_fecrx/fec_insert_overlay_rxonly.m with the FEC constants migrated
% K=7 -> K=5 per the 240k/K5 contract (k5_240/PACKET_K5.txt):
%   trellis poly2trellis(7,[171 133]) -> poly2trellis(5,[35 23])
%   traceback 34 -> 25
%   info/tail 1080/6 -> 1084/4  =>  CODED 2172 -> 2176 (= 16 cols x 136 ROWS;
%   ROWS/NPAIR are folded to compile-time literals by fecRxDeint_src (no idivide
%   emitted), and the deinterleave read address perm = c*ROWS+r is produced by
%   divisionless incremental row/col counters (cc/rr) in the FSM)
%
% Inserts ONLY the Rx-side decode chain (16-col deinterleaver + K=5 hard
% Viterbi TB=25 + RxAlign + FEC Decoder Wrapper) and OMITS the Tx-side FEC
% Encoder Wrapper: the jupiter_240k5 Tx bit source is the PRE-CODED msggen
% ROM (msggen_rom_overlay_k5.m) -- an in-FPGA encoder would double-encode the
% already-coded ROM payload (and is the proven-buggy path class).
%
% The Rx deinterleaver consumes the FIRST CODED(=2176) bits of the 2240-bit
% payload; the 64 filler bits at the end are never read (RxDeint reads pairs
% 0..NPAIR-1 = coded bits only; the write side stores the first 2176).
%
% Apply AFTER the model is loaded and BEFORE HDL codegen. Idempotent.

NL = char(10); %#ok<NASGU>
if nargin < 1, sys = bdroot; end
if nargin < 2 || isempty(base), base = sys; end
P = commhdlQPSKTxRxParameters();
cfg = frame_config_k5();   % single source of truth for frame geometry
assert(P.DataBitsPerPacket == cfg.PayloadBits, 'unexpected DataBitsPerPacket');

TRELLIS_STR = 'poly2trellis(5, [35 23])';   % K=5 (was poly2trellis(7,[171 133]))
INFO_BITS   = cfg.InfoBits;                  % 1084 (was 1080)
TAIL_BITS   = cfg.TailBits;                  % 4 = K-1 (was 6)
CODED_BITS  = cfg.CodedBits;                 % 2176 (was 2172) = 2*(INFO_BITS+TAIL_BITS); ROWS = 2176/16 = 136
INTERLEAVE_COLS = cfg.InterleaveCols;        % 16
TB_DEPTH    = 25;                            % was 34 (traceback depth, not frame geometry)
% Now a cfg-vs-cfg consistency check (values come from frame_config_k5); the
% independent literal pinning of these fields lives in frame_config_k5.m's
% per-frame golden-anchor block.
assert(CODED_BITS == 2*(INFO_BITS+TAIL_BITS) && CODED_BITS/INTERLEAVE_COLS == cfg.InterleaveRows, ...
    'K5 contract mismatch');

% Marker: skip if the Rx decoder is already present.
if ~isempty(find_system(base,'LookUnderMasks','all','FollowLinks','on', ...
        'BlockType','SubSystem','Name','FEC Decoder Wrapper'))
    fprintf('fec_insert_overlay_rxonly_k5: FEC Decoder already present -- skipping\n');
    return;
end

load_system('commcnvcod2');

% ============================================================================
% (A) TX -- DELIBERATELY OMITTED (Rx-only, LUT-lean). The Tx path keeps its stock
%     Bit Packetizer -> HDL Data Scrambler wiring UNCHANGED (no FEC encoder).
% ============================================================================
fprintf('fec_insert_overlay_rxonly_k5: Tx FEC encoder OMITTED (Rx-only LUT-lean)\n');

% ============================================================================
% (B) RX -- insert FEC Decoder Wrapper between Descrambler and BIST (identical
%     to the shared overlay).
% ============================================================================
qrx = [base '/Receiver/QPSK Rx'];
dec = [qrx '/FEC Decoder Wrapper'];
% useRam=true (f1536) types the ping-pong deint banks as ufix1 so HDL Coder's
% RAM read port (back-inferred as ufix1 from codedPair=fi(...,0,1,0)) agrees
% with the write port; k5 keeps boolean banks -> byte-identical HDL.
useRam = strcmp(cfg.Frame,'f1536');
build_rx_decoder_wrapper(dec, TRELLIS_STR, TB_DEPTH, INFO_BITS, CODED_BITS, INTERLEAVE_COLS, useRam);

delete_line(qrx, 'HDL Data Descrambler/1', 'dataOut/1');
delete_line(qrx, 'HDL Data Descrambler/2', 'Bus Creator1/1');
delete_line(qrx, 'HDL Data Descrambler/3', 'Bus Creator1/2');
delete_line(qrx, 'HDL Data Descrambler/4', 'Bus Creator1/3');
add_line(qrx, 'HDL Data Descrambler/1', 'FEC Decoder Wrapper/1', 'autorouting','on');
add_line(qrx, 'HDL Data Descrambler/2', 'FEC Decoder Wrapper/2', 'autorouting','on');
add_line(qrx, 'HDL Data Descrambler/3', 'FEC Decoder Wrapper/3', 'autorouting','on');
add_line(qrx, 'HDL Data Descrambler/4', 'FEC Decoder Wrapper/4', 'autorouting','on');
add_line(qrx, 'FEC Decoder Wrapper/1', 'dataOut/1', 'autorouting','on');
add_line(qrx, 'FEC Decoder Wrapper/2', 'Bus Creator1/1', 'autorouting','on');
add_line(qrx, 'FEC Decoder Wrapper/3', 'Bus Creator1/2', 'autorouting','on');
add_line(qrx, 'FEC Decoder Wrapper/4', 'Bus Creator1/3', 'autorouting','on');
fprintf('fec_insert_overlay_rxonly_k5: Rx FEC Decoder Wrapper inserted (deint+Viterbi+RxAlign)\n');

% RAM mapping for the ping-pong deinterleaver banks (f1536 ONLY). At f1536
% scale the two persistent banks are CODED_BITS=24592 bits each; request BRAM
% inference. MapPersistentVarsToRAM is CODEGEN-only (no sim effect -> the G1
% sim gate cannot verify it; BRAM fit is an HDL-build check, see the
% assemble-time present-check + task-A2-report). Gated on f1536 so k5 HDL is
% byte-identical (k5 banks = 2176 flops, left as registers). RISK: fecRxDeint
% reads the read-bank TWICE per step (perm0 & perm1) -- the documented
% multi-access pattern that may force RAM duplication or refuse mapping;
% resolved by the HDL codegen probe, NOT by the sim gate.
if strcmp(cfg.Frame,'f1536')
    hdlset_param([dec '/RxDeint'], 'MapPersistentVarsToRAM', 'on');
    fprintf('fec_insert_overlay_rxonly_k5: RxDeint MapPersistentVarsToRAM=on (f1536 BRAM request)\n');
end
fprintf('fec_insert_overlay_rxonly_k5: DONE (trellis=%s, coded=%d cols=%d tb=%d)\n', ...
    TRELLIS_STR, CODED_BITS, INTERLEAVE_COLS, TB_DEPTH);
end

% ---- Rx decoder wrapper builder (copied bit-for-bit from fec_insert_overlay.m) ----
function build_rx_decoder_wrapper(dec, TRELLIS_STR, TB, INFO_BITS, CODED_BITS, COLS, useRam)
add_block('built-in/Subsystem', dec, 'Position',[700 380 820 480]);
for k=1:4, add_block('built-in/Inport',[dec '/' inn(k)],'Port',num2str(k),'Position',[20 40+40*k 50 60+40*k]); end
add_block('built-in/Inport',[dec '/skipCount'],'Port','5','Position',[20 40+40*5 50 60+40*5]);
set_param([dec '/skipCount'],'OutDataTypeStr','uint32','SampleTime','-1');
for k=1:4, add_block('built-in/Outport',[dec '/' onn(k)],'Port',num2str(k),'Position',[760 40+40*k 790 60+40*k]); end

add_block('simulink/User-Defined Functions/MATLAB Function',[dec '/RxDeint'],'Position',[120 60 260 200]);
set_fcn_script([dec '/RxDeint'],  fecRxDeint_src(CODED_BITS, COLS, useRam));

% RXROOT fix (2026-07-02): the Viterbi block MUST only advance one trellis step
% per valid deinterleaved pair. The deint holds codedPair between deintValid
% beats; an ungated Viterbi consumes each held pair ~5-6x and decodes garbage
% (proven in RTL replay of real air + iverilog unit bench, see k5_240/RXROOT.txt
% ROOT CAUSE #3). Wrap it in an ENABLED subsystem driven by deintValid.
vg = [dec '/VitGate'];
add_block('built-in/Subsystem', vg, 'Position',[320 60 440 160]);
add_block('built-in/Inport',[vg '/pairIn'],'Port','1','Position',[20 60 50 80]);
add_block('built-in/Inport',[vg '/rstIn'],'Port','2','Position',[20 120 50 140]);
add_block('built-in/EnablePort',[vg '/Enable'],'Position',[200 20 220 40]);
add_block('commcnvcod2/Viterbi Decoder',[vg '/Viterbi'],'Position',[120 70 230 140]);
set_param([vg '/Viterbi'],'trellis',TRELLIS_STR,'dectype','Hard decision', ...
    'tbdepth',num2str(TB),'opmode','Continuous','reset','on', ...
    'delayedResetAction','on','outDataType','boolean');
add_block('built-in/Outport',[vg '/decOut'],'Port','1','Position',[300 95 330 115]);
% Delay balancing cannot absorb the Viterbi's internal pipeline (16 cy) inside a
% conditional subsystem; it does not need to -- RxAlign's skip alignment absorbs
% ALL decoder latency (measured end-to-end: 37 deintValid beats, baked below).
hdlset_param(vg, 'BalanceDelays', 'off');
add_line(vg,'pairIn/1','Viterbi/1','autorouting','on');
add_line(vg,'rstIn/1','Viterbi/2','autorouting','on');
add_line(vg,'Viterbi/1','decOut/1','autorouting','on');

add_block('simulink/User-Defined Functions/MATLAB Function',[dec '/RxAlign'],'Position',[500 60 660 200]);
set_fcn_script([dec '/RxAlign'],  fecRxAlign_src(INFO_BITS, TB));

add_line(dec, [inn(1) '/1'], 'RxDeint/1', 'autorouting','on');
add_line(dec, [inn(2) '/1'], 'RxDeint/2', 'autorouting','on');
add_line(dec, [inn(3) '/1'], 'RxDeint/3', 'autorouting','on');
add_line(dec, [inn(4) '/1'], 'RxDeint/4', 'autorouting','on');
add_line(dec, 'RxDeint/1', 'VitGate/1', 'autorouting','on');
add_line(dec, 'RxDeint/2', 'VitGate/2', 'autorouting','on');
add_line(dec, 'RxDeint/3', 'VitGate/Enable', 'autorouting','on');
add_line(dec, 'VitGate/1', 'RxAlign/1', 'autorouting','on');
add_line(dec, 'RxDeint/3', 'RxAlign/2', 'autorouting','on');
add_line(dec, 'RxDeint/4', 'RxAlign/3', 'autorouting','on');
add_line(dec, 'RxDeint/5', 'RxAlign/4', 'autorouting','on');
add_line(dec, 'skipCount/1', 'RxAlign/5', 'autorouting','on');
add_line(dec, 'RxAlign/1', [onn(1) '/1'], 'autorouting','on');
add_line(dec, 'RxAlign/2', [onn(2) '/1'], 'autorouting','on');
add_line(dec, 'RxAlign/3', [onn(3) '/1'], 'autorouting','on');
add_line(dec, 'RxAlign/4', [onn(4) '/1'], 'autorouting','on');
end

function s = inn(k), names={'bitsIn','startIn','endIn','validIn'}; s=names{k}; end
function s = onn(k), names={'dataOut','startOut','endOut','validOut'}; s=names{k}; end
function set_fcn_script(blk, src)
rt = sfroot; chart = rt.find('-isa','Stateflow.EMChart','Path',blk); chart.Script = src;
end

function src = fecRxDeint_src(CODED, COLS, useRam)
% Sync-semantics compliant (RXROOT E11c): persistents are read into locals at
% the top, ALL reads precede ALL writes, outputs come from locals, persistents
% are written last. Bit-identical to the classic version (the read bank is
% always the opposite of the write bank).
%
% useRam (f1536): type the ping-pong banks + their read/write locals as ufix1
% (fi(.,0,1,0)) instead of boolean, so MapPersistentVarsToRAM's inferred RAM
% read port (ufix1, back-propagated from codedPair=fi(..,0,1,0)) AGREES with the
% write port -- otherwise makehdl fails "read and write data types do not agree
% for RAM block". Values are IDENTICAL (ufix1 stores 0/1 exactly as boolean);
% only the storage type changes. k5 (useRam=false) keeps boolean -> byte-
% identical generated HDL.
if nargin < 3, useRam = false; end
if useRam
    bInit = 'fi(zeros(1,%d),0,1,0)';   % bank init (contains one %%d)
    zBit  = 'fi(0,0,1,0)';             % 1-bit zero value
    wCast = 'fi(dataIn,0,1,0)';        % write-bit cast
else
    bInit = 'false(1,%d)';
    zBit  = 'false';
    wCast = 'logical(dataIn)';
end
ROWS  = CODED / COLS;   % emit as a literal (geometry from cfg) -- no idivide in the per-beat path
NPAIR = CODED / 2;       % emit as a literal -- no idivide in the per-beat path
assert(ROWS == floor(ROWS) && NPAIR == floor(NPAIR), 'fecRxDeint_src: non-integer ROWS/NPAIR geometry');
src = sprintf([ ...
'function [codedPair, vitReset, deintValid, frameStart, frameEnd] = fecRxDeint(dataIn, startIn, endIn, validIn)\n' ...
'%%#codegen\n' ...
'persistent ramA ramB rdBank wptr pcnt hold0 hold1 rdGate rcol rrow;\n' ...
'CODED=uint16(%d); COLS=uint16(%d); ROWS=uint16(%d);\n' ...
'NPAIR=uint16(%d);\n' ...
'if isempty(ramA), ramA=' bInit '; ramB=' bInit '; rdBank=false; wptr=uint16(0); pcnt=uint16(0); hold0=' zBit '; hold1=' zBit '; rdGate=false; rcol=uint16(0); rrow=uint16(0); end\n' ...
'rb=rdBank; w=wptr; pc=pcnt; g=rdGate; h0=hold0; h1=hold1; cc=rcol; rr=rrow;\n' ...
'pair0=h0; pair1=h1;\n' ...
'vitReset=false; deintValid=false; frameStart=false; frameEnd=false;\n' ...
'wrPos=uint16(65535); wrBit=' zBit '; wrBankA=false; doWr=false;\n' ...
'if validIn\n' ...
'  if startIn, w=uint16(0); pc=uint16(0); rb=~rb; g=true; cc=uint16(0); rr=uint16(0); end %% rdGate=TRUE: frame pair0 read COINCIDES with frameStart (RxAlign arms on that beat); read-counters reset in lockstep with pc\n' ...
'  %% ---- READ side first (opposite bank; RXROOT E8 isolated reads: 1 pair per 2 validIn beats) ----\n' ...
'  if g && (pc < NPAIR)\n' ...
'    %% divisionless read address: cc (even col) / rr (row) are incremental counters.\n' ...
'    %% rc0=2*pc is even so rc1=rc0+1 keeps the same row -> perm1 = perm0 + ROWS (one add).\n' ...
'    perm0 = cc*ROWS + rr;\n' ...
'    perm1 = perm0 + ROWS;\n' ...
'    b0v = ' zBit '; b1v = ' zBit ';\n' ...
'    if perm0 < CODED\n' ...
'      if rb, b0v = ramB(double(perm0)+1); else b0v = ramA(double(perm0)+1); end\n' ...
'    end\n' ...
'    if perm1 < CODED\n' ...
'      if rb, b1v = ramB(double(perm1)+1); else b1v = ramA(double(perm1)+1); end\n' ...
'    end\n' ...
'    pair0 = b0v; pair1 = b1v; h0 = b0v; h1 = b1v;\n' ...
'    deintValid = true;\n' ...
'    if pc == uint16(0), vitReset = true; end\n' ...
'    pc = pc + 1;\n' ...
'    cc = cc + uint16(2);\n' ...
'    if cc == COLS, cc = uint16(0); rr = rr + uint16(1); end\n' ...
'  end\n' ...
'  %% ---- WRITE side after all reads ----\n' ...
'  if w < CODED\n' ...
'    wrPos = w; wrBit = ' wCast '; wrBankA = rb; doWr = true;\n' ...
'    w = w + 1;\n' ...
'  end\n' ...
'  g = ~g;\n' ...
'  frameStart=startIn; frameEnd=endIn;\n' ...
'end\n' ...
'codedPair = fi([pair0; pair1], 0, 1, 0);\n' ...
'%% ---- persist state last ----\n' ...
'if doWr\n' ...
'  if wrBankA, ramA(double(wrPos)+1)=wrBit; else ramB(double(wrPos)+1)=wrBit; end\n' ...
'end\n' ...
'rdBank=rb; wptr=w; pcnt=pc; rdGate=g; hold0=h0; hold1=h1; rcol=cc; rrow=rr;\n'], ...
    CODED, COLS, ROWS, NPAIR, CODED, CODED);
end

function src = fecRxAlign_src(INFO, TB) %#ok<INUSD>
% Sync-semantics compliant: locals in, outputs from locals, persist last.
src = sprintf([ ...
'function [dataOut, startOut, endOut, validOut] = fecRxAlign(decBit, deintValid, frameStart, frameEnd, skipCount)\n' ...
'%%#codegen\n' ...
'persistent oc started skip;\n' ...
'INFO=uint16(%d);\n' ...
'if isempty(oc), oc=uint16(0); started=false; skip=uint16(0); end\n' ...
'o=oc; st=started; sk=skip;\n' ...
'dataOut=false; startOut=false; endOut=false; validOut=false;\n' ...
'sc = uint16(skipCount);\n' ...
'if sc > INFO, sc = INFO; end\n' ...
'if deintValid\n' ...
'  if frameStart, o=uint16(0); st=true; sk=sc+uint16(41); end %% +41 = gated-Viterbi latency in deintValid beats incl. VitGate hold reg (RXROOT E8)\n' ...
'  if st\n' ...
'    if sk > uint16(0)\n' ...
'      sk = sk - uint16(1);\n' ...
'    elseif o < INFO\n' ...
'      dataOut = decBit;\n' ...
'      startOut = (o==uint16(0));\n' ...
'      endOut   = (o==(INFO-1));\n' ...
'      validOut = true;\n' ...
'      o = o + uint16(1);\n' ...
'    end\n' ...
'  end\n' ...
'end\n' ...
'oc=o; started=st; skip=sk;\n'], INFO);
end
