% packet_f1536.m -- F1536 large-frame bit contract for the 240k/K5 link.
%
% Same K=5 [35 23] rate-1/2 FEC and the SAME legacy interleave/ROM/CAP_OUT
% CONVENTIONS as packet_k5.m STEP B -- only the FRAME GEOMETRY scales up for
% the 1536-byte host frame (MTU 1524):
%
%   info/tail/coded = 12292 / 4 / 24592     (k5: 1084 / 4 / 2176)
%   interleave      = ROWS=1537 COLS=16 (=24592, fully gridded)
%   filler          = 48-bit PN9 (x^9+x^5+1, seed ones) -> payload 24640 bits
%   payload         = 24640 bits = 385 uint64 words = 770 uint32 ROM words
%
% INFO FIELD LAYOUT (12292 bits):
%   [ 'ADI Hello World' 120 msg bits (MSB-first/char) ;
%     12168 PN pad bits (rng(15360,'twister'), randi([0 1],12168,1)) ;
%     4 always-zero pad bits ]                       = 12288 usable + 4 pad
%   The 12288 usable bits = 192 * 64 = WordsPerPacketRx*64 (the byte-RX
%   serializer delivers exactly these 192 words/frame; the 4 zero pad bits are
%   dropped by the serializer start-reset, and the K-1=4 encoder tail is
%   appended AFTER the info field for the 'term' contract).
%
% CONVENTIONS reused verbatim from packet_k5.m (proven K=5 contract):
%   * message bits : dec2bin('ADI Hello World',8) row-reshape, MSB-first/char
%   * interleave   : read perm = r*COLS + c, r=mod(beat,ROWS), c=floor(beat/ROWS)
%   * deinterleave : perm = c*ROWS + r (exact inverse; fully gridded)
%   * ROM packing  : word w = bits[32w..32w+31], MSB-first; one-line uint32([...])
%   * CAP_OUT      : LSB-first 32-bit pack of the first 32 decoded info bits
%
% NO legacy K=7 gate (that lineage is k5-specific). A K=5 round-trip self-check
% (encode -> interleave -> deinterleave -> vitdec recovers 'ADI Hello World'
% and the full 12292-bit info field) runs before any output is emitted.
%
% Outputs are written to the REPO contract/ dir (fileparts(mfilename)) so the
% overlays consume them via fileparts(fileparts(mfilename('fullpath'))).

out = fileparts(mfilename('fullpath'));

% ============================================================================
% F1536 PACKET (K=5 [35 23], geometry scaled for the 1536-byte host frame)
% ============================================================================
trellis = poly2trellis(5,[35 23]); TB = 25;
COLS = 16; ROWS = 1537;
INFO = 12292; TAIL = 4; CODED = 2*(INFO+TAIL);   % 24592
NFILL = 48; PAYLOAD = CODED + NFILL;             % 24640
assert(CODED == ROWS*COLS, 'CODED ~= ROWS*COLS');
assert(PAYLOAD == 385*64,  'PAYLOAD ~= 385*64');

% ---- message bits: 'ADI Hello World', 8 bits/char, MSB-first (packet_k5 order) ----
msg = 'ADI Hello World';
msgBits = reshape(de2bi(uint8(msg),8,'left-msb').',[],1);   % 120x1
assert(numel(msgBits)==120);

% ---- PN pad + 4 zero tail-pad -> 12292-bit info field ----
NPAD = 12288 - 120;                              % 12168 PN pad bits
rng(15360,'twister'); pad = randi([0 1],NPAD,1); % deterministic PN pad (seed 15360)
info = [msgBits; pad; zeros(4,1)];               % 12288 usable + 4 zero pad = 12292
assert(numel(info)==INFO);
assert(all(info(INFO-3:INFO)==0), 'the 4 tail-pad info bits must be zero');

% ---- K=5 encode: [info; K-1 zero tail] -> convenc -> 24592 coded bits ----
encIn = [info; zeros(TAIL,1)];                   % 12296
coded = convenc(encIn, trellis);  assert(numel(coded)==CODED);

% ---- 1537x16 block interleave (legacy read perm r*COLS+c) ----
il = legacy_interleave(coded, ROWS, COLS, CODED);           % 24592x1

% ---- 48-bit PN9 filler (x^9+x^5+1, seed all-ones; no DC dwell) ----
% Same generator logic as packet_k5.m's 64-bit filler, truncated to 48 bits
% (the 48-bit prefix of the identical PN9 sequence).
lfsr = ones(9,1); filler = zeros(NFILL,1);
for fk = 1:NFILL
    fb = xor(lfsr(9), lfsr(5));
    filler(fk) = lfsr(9);
    lfsr = [fb; lfsr(1:8)];
end
assert(max(diff(find([1; diff(filler)~=0; 1]))) <= 9);   % no long constant runs (no DC dwell)

payload = [il; filler];  assert(numel(payload)==PAYLOAD);
words = legacy_packwords(payload);  assert(numel(words)==770);

% ---- round-trip self-check (host Viterbi) ----
rx = payload(1:CODED);
deil = legacy_deinterleave(rx, ROWS, COLS, CODED);
assert(isequal(deil(:), coded(:)), 'F1536 deinterleave does not invert interleave');
dec = vitdec(deil, trellis, TB, 'term', 'hard');
assert(isequal(dec(1:120), msgBits), 'round-trip FAILED on message');
assert(isequal(dec(1:INFO), info), 'round-trip FAILED on full info field');
capOut = legacy_pack32_lsb(dec(1:32));

% ---- emit outputs (repo contract/) ----
parts = arrayfun(@(x) sprintf('%u', x), words(:).', 'UniformOutput', false);
romLiteral = ['uint32([' strjoin(parts, ' ') '])'];
fidw = fopen(fullfile(out,'rom_words_770_f1536.txt'),'w');
fprintf(fidw, '%s\n', romLiteral); fclose(fidw);

save(fullfile(out,'golden_f1536.mat'), ...
     'words','payload','coded','info','msgBits','capOut','trellis','TB','ROWS','COLS');

fidt = fopen(fullfile(out,'PACKET_F1536.txt'),'w');
fprintf(fidt, '================================================================\n');
fprintf(fidt, ' PACKET_F1536 -- K=5 large-frame (1536-byte host) bit contract\n');
fprintf(fidt, '================================================================\n');
fprintf(fidt, ' trellis        = poly2trellis(5,[35 23])   TB=%d  (term, hard)\n', TB);
fprintf(fidt, ' message        = ''ADI Hello World'' (120 bits, MSB-first per char)\n');
fprintf(fidt, ' PN pad         = %d bits, rng(15360,''twister''), randi([0 1],%d,1)\n', NPAD, NPAD);
fprintf(fidt, ' info field     = 12288 usable (192*64) + 4 always-zero pad = %d\n', INFO);
fprintf(fidt, ' info/tail/coded= %d / %d / %d\n', INFO, TAIL, CODED);
fprintf(fidt, ' interleave     = ROWS=%d COLS=%d, read perm = r*COLS+c (legacy)\n', ROWS, COLS);
fprintf(fidt, ' deinterleave   = perm = c*ROWS+r (exact inverse; grid %dx%d=%d,\n', ROWS, COLS, CODED);
fprintf(fidt, '                  fully gridded -- no ungridded tail)\n');
fprintf(fidt, ' filler         = %d-bit PN9 (x^9+x^5+1, seed ones; no DC dwell) -> payload %d bits = 770 uint32 words\n', NFILL, PAYLOAD);
fprintf(fidt, ' word alignment = %d bits = 385 uint64 = 770 uint32 (exact)\n', PAYLOAD);
fprintf(fidt, ' ROM packing    = word w = bits[32w..32w+31], MSB-first (bit 32w ->\n');
fprintf(fidt, '                  word bit 31); one-line uint32([...]) literal\n');
fprintf(fidt, ' CAP_OUT pack   = LSB-first 32-bit pack of first 32 decoded info bits\n');
fprintf(fidt, ' CAP_OUT_GOLDEN=0x%08X\n', capOut);
fprintf(fidt, '----------------------------------------------------------------\n');
fprintf(fidt, ' DELIVERY CONTRACT (byte-RX, controller option b -- DELIVERY-SIDE ONLY;\n');
fprintf(fidt, '   the payload/coded/interleave/filler/ROM/golden ABOVE are UNCHANGED):\n');
fprintf(fidt, '   WordsPerPacketRx = 191  ->  191 x 64 = 12224 info bits delivered/frame.\n');
fprintf(fidt, '   Bound: RxAlign emits at most InfoBits-TailBits-RxPipelineSkip(41)=12247\n');
fprintf(fidt, '   info bits/frame before the frame boundary resets it; WPP*64=12224 fits\n');
fprintf(fidt, '   with a 23-bit margin (WPP=192 -> 12288 would truncate every frame).\n');
fprintf(fidt, '   Discarded/frame: 64 usable + 4 zero-pad = 68 info bits (12292-12224; 0.55%%), mirroring\n');
fprintf(fidt, '   k5''s 60-bit discard. Host frame 1528 B -> MTU 1516 (> 1500 target).\n');
fclose(fidt);

fprintf('PACKET_F1536 OK CAP_OUT=0x%08X word0=%u (0x%08X)\n', capOut, words(1), words(1));

% ===================== local functions (verbatim legacy expressions) ========
function txair = legacy_interleave(coded, ROWS, COLS, CODED)
  txair = zeros(CODED,1);
  for beat = 0:CODED-1
    r = mod(beat,ROWS); c = floor(beat/ROWS); perm = r*COLS+c;
    if perm < CODED, txair(beat+1) = coded(perm+1); end
  end
end

function deint = legacy_deinterleave(rxbits, ROWS, COLS, CODED)
  deint = zeros(CODED,1);
  for rc = 0:CODED-1
    c = mod(rc,COLS); r = floor(rc/COLS); perm = c*ROWS+r;
    if perm < CODED, deint(rc+1) = rxbits(perm+1); end
  end
end

function words = legacy_packwords(bits)
  W = numel(bits)/32;
  words = zeros(1, W, 'uint32');
  for w = 0:W-1
    v = uint32(0);
    for j = 0:31
      v = bitor(v, bitshift(uint32(bits(w*32+j+1)), 31-j));
    end
    words(w+1) = v;
  end
end

function r = legacy_pack32_lsb(bits)
  r = uint32(0);
  for i = 0:31
    if bits(i+1) ~= 0, r = bitor(r, bitshift(uint32(1), i)); end
  end
end
