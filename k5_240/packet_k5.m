% packet_k5.m -- K=5 bit contract for the 240k/K5 link.
%
% Payload stays 2240 bits (= 70 uint32) so frame geometry is unchanged
% (1120 payload symbols + 13-bit Barker = 1133 sym/frame).
%
% CONVENTIONS ARE REUSED VERBATIM FROM THE PROVEN K=7 CONTRACT (only
% ROWS 135 -> 136):
%   * message bits : 'ADI Hello World', 8 bits/char, MSB-first per char
%                    (approachb_bitcontract.m / approachb_pn_packet.m)
%   * interleave   : read perm = r*COLS + c, r=mod(beat,ROWS),
%                    c=floor(beat/ROWS)          (approachb_pn_packet.m L48-52)
%   * deinterleave : perm = c*ROWS + r, c=mod(rc,COLS), r=floor(rc/COLS)
%                    (exact inverse; for ROWS=136 the 136x16 grid = 2176 is
%                    fully gridded -- NO ungridded tail, unlike K=7)
%   * ROM packing  : payload bits -> 70 x uint32, word w = bits[32w..32w+31],
%                    MSB-first (bit 32w -> word bit 31); file is ONE line
%                    'uint32([w1 w2 ... w70])'    (msggen_rom_overlay.m L34-45)
%   * CAP_OUT      : LSB-first 32-bit pack of the first 32 decoded info bits
%                    (approachb_pn_packet.m L96-97; yielded 0x04922282)
%
% A LEGACY K=7 VALIDATION GATE runs FIRST: the same reused expressions must
% reproduce approachb_payload_pn.bin byte-for-byte, the zed_msggenrom
% rom_words_70.txt literal word-for-word, and CAP_OUT == 0x04922282.
% Only then are the K=5 outputs emitted. KEEP THIS BLOCK (guards future edits).

out = '/mnt/onetb/scratch/qpsk_variants/k5_240/';

% ============================================================================
% STEP A -- LEGACY K=7 VALIDATION GATE (must pass before any K=5 output)
% ============================================================================
trellis7 = poly2trellis(7,[171 133]);
INFO7 = 1080; TAIL7 = 6; CODED7 = 2*(INFO7+TAIL7); COLS = 16; ROWS7 = 135;
PAYLOAD = 2240;

% message bits, legacy construction (approachb_pn_packet.m L25-26)
strA = dec2bin('ADI Hello World',8);
msgbits7 = double(reshape(strA.',1,[]) - '0');            % 120 bits, MSB-first/char
assert(numel(msgbits7)==120);

% 960 PN pad bits, legacy LFSR x^10+x^7+1, fixed seed (approachb_pn_packet.m L33-40)
NPAD = INFO7-120;
lfsr = uint16(bin2dec('1101011001'));
pn7 = zeros(1,NPAD);
for k = 1:NPAD
  b = bitget(lfsr,10);
  pn7(k) = double(b);
  fb = bitxor(bitget(lfsr,10),bitget(lfsr,7));
  lfsr = bitand(bitor(bitshift(lfsr,1),fb),uint16(1023));
end

info7  = [msgbits7, pn7];                                 % 1080 info bits
encIn7 = [info7, zeros(1,TAIL7)];                         % 1086
coded7 = convenc(encIn7(:), trellis7);                    % 2172
assert(numel(coded7)==CODED7);

txair7 = legacy_interleave(coded7, ROWS7, COLS, CODED7);  % REUSED expression
payload7 = zeros(PAYLOAD,1); payload7(1:CODED7) = txair7; % legacy zero filler

% byte pack (REUSED expression) vs the shipped approachb_payload_pn.bin
bytes7 = legacy_packbytes(payload7);
fidb = fopen('/mnt/onetb/scratch/linkA_iq/approachb_payload_pn.bin','r');
assert(fidb>0, 'cannot open approachb_payload_pn.bin');
bytesRef = fread(fidb, Inf, 'uint8=>uint8'); fclose(fidb);
assert(isequal(bytes7(:), bytesRef(:)), 'legacy byte-pack mismatch vs approachb_payload_pn.bin');

% ROM word pack (REUSED expression) vs the shipped rom_words_70.txt literal
words7 = legacy_packwords(payload7);
litRef = strtrim(fileread('/mnt/onetb/scratch/qpsk_variants/zed_msggenrom/rom_words_70.txt'));
wordsRef = uint32(sscanf(regexprep(litRef,'uint32\(\[|\]\)',''), '%u'));
assert(numel(wordsRef)==70 && isequal(words7(:), wordsRef(:)), ...
  'legacy ROM word-pack mismatch vs rom_words_70.txt');

% CAP_OUT pack (REUSED expression) must yield the hardware-proven golden
capOut7 = legacy_pack32_lsb(info7(1:32));
GOLDEN7 = uint32(hex2dec('04922282'));
assert(isequal(capOut7, GOLDEN7), 'legacy CAP_OUT %08X != 04922282', capOut7);

fprintf('legacy check OK 0x%08X\n', capOut7);

% ============================================================================
% STEP B -- K=5 PACKET (identical conventions, ROWS 135 -> 136)
% ============================================================================
trellis = poly2trellis(5,[35 23]); TB = 25;
msg = 'ADI Hello World';
msgBits = reshape(de2bi(uint8(msg),8,'left-msb').',[],1);        % 120x1, MSB-first/char
assert(isequal(msgBits(:), msgbits7(:)), 'msgBits does not match legacy bit order');
rng(9002,'twister'); pad = randi([0 1],964,1);                   % deterministic PN pad
info = [msgBits; pad];                                           % 1084x1
encIn = [info; zeros(4,1)];                                      % + K-1 tail = 1088
coded = convenc(encIn, trellis);  assert(numel(coded)==2176);
ROWS = 136; COLS = 16;

il = legacy_interleave(coded, ROWS, COLS, numel(coded));         % 2176x1, REUSED
% PN9 filler (x^9+x^5+1, seed all-ones): the legacy 64-ones filler maps to a
% 32-symbol constant (+,+) run on air (DC dwell) that the ADRV9002 TX LOL
% tracking cal notches as LO leakage, killing ~24 coded bits every frame
% (T8 root cause). PN filler has max run ~9 -> no DC dwell. The Rx discards
% filler bits, so CAP_OUT stays golden.
lfsr = ones(9,1); filler = zeros(64,1);
for fk = 1:64
    fb = xor(lfsr(9), lfsr(5));
    filler(fk) = lfsr(9);
    lfsr = [fb; lfsr(1:8)];
end
assert(max(diff(find([1; diff(filler)~=0; 1]))) <= 9);  % no long constant runs
payload = [il; filler];  assert(numel(payload)==2240);
words = legacy_packwords(payload);  assert(numel(words)==70);    % REUSED

% ---- round-trip self-check (host Viterbi) ----
rx = payload(1:2176);
deil = legacy_deinterleave(rx, ROWS, COLS, numel(rx));           % exact inverse, REUSED
assert(isequal(deil(:), coded(:)), 'K=5 deinterleave does not invert interleave');
dec = vitdec(deil, trellis, TB, 'term', 'hard');
assert(isequal(dec(1:120), msgBits), 'round-trip FAILED');
assert(isequal(dec(1:1084), info), 'round-trip FAILED on full info+pad');
capOut = legacy_pack32_lsb(dec(1:32));                           % REUSED

% ---- emit outputs ----
% rom_words_70_k5.txt: SAME single-line 'uint32([...])' literal format as the
% legacy zed_msggenrom/rom_words_70.txt so msggen_rom_overlay-style scripts
% consume it unchanged.
parts = arrayfun(@(x) sprintf('%u', x), words(:).', 'UniformOutput', false);
romLiteral = ['uint32([' strjoin(parts, ' ') '])'];
fidw = fopen(fullfile(out,'rom_words_70_k5.txt'),'w');
fprintf(fidw, '%s\n', romLiteral); fclose(fidw);

save(fullfile(out,'golden_k5.mat'), ...
     'words','payload','coded','info','msgBits','capOut','trellis','TB','ROWS','COLS');

fidt = fopen(fullfile(out,'PACKET_K5.txt'),'w');
fprintf(fidt, '================================================================\n');
fprintf(fidt, ' PACKET_K5 -- K=5 bit contract for the 240k/K5 link\n');
fprintf(fidt, '================================================================\n');
fprintf(fidt, ' trellis        = poly2trellis(5,[35 23])   TB=%d  (term, hard)\n', TB);
fprintf(fidt, ' message        = ''ADI Hello World'' (120 bits, MSB-first per char)\n');
fprintf(fidt, ' PN pad         = 964 bits, rng(9002,''twister''), randi([0 1],964,1)\n');
fprintf(fidt, ' info/tail/coded= 1084 / 4 / 2176\n');
fprintf(fidt, ' interleave     = ROWS=%d COLS=%d, read perm = r*COLS+c (legacy)\n', ROWS, COLS);
fprintf(fidt, ' deinterleave   = perm = c*ROWS+r (exact inverse; grid 136x16=2176,\n');
fprintf(fidt, '                  fully gridded -- no ungridded tail)\n');
fprintf(fidt, ' filler         = 64-bit PN9 (x^9+x^5+1, seed ones; no DC dwell) -> payload 2240 bits = 70 uint32 words\n');
fprintf(fidt, ' frame geometry = 1120 payload sym + 13 Barker = 1133 sym (unchanged)\n');
fprintf(fidt, ' ROM packing    = word w = bits[32w..32w+31], MSB-first (bit 32w ->\n');
fprintf(fidt, '                  word bit 31); one-line uint32([...]) literal\n');
fprintf(fidt, ' CAP_OUT pack   = LSB-first 32-bit pack of first 32 decoded info bits\n');
fprintf(fidt, ' legacy gate    = K=7 bytes/words/CAP_OUT reproduced (0x04922282)\n');
fprintf(fidt, ' CAP_OUT_GOLDEN=0x%08X\n', capOut);
fclose(fidt);

fprintf('PACKET_K5 OK CAP_OUT=0x%08X\n', capOut);

% ===================== local functions (verbatim legacy expressions) ========
function txair = legacy_interleave(coded, ROWS, COLS, CODED)
  % VERBATIM from approachb_pn_packet.m L48-52 / approachb_bitcontract.m L56-60
  txair = zeros(CODED,1);
  for beat = 0:CODED-1
    r = mod(beat,ROWS); c = floor(beat/ROWS); perm = r*COLS+c;
    if perm < CODED, txair(beat+1) = coded(perm+1); end
  end
end

function deint = legacy_deinterleave(rxbits, ROWS, COLS, CODED)
  % VERBATIM inverse perm from approachb_bitcontract.m L158-168 (per-bit form
  % of the pairwise Rx deint): perm = c*ROWS + r.
  deint = zeros(CODED,1);
  for rc = 0:CODED-1
    c = mod(rc,COLS); r = floor(rc/COLS); perm = c*ROWS+r;
    if perm < CODED, deint(rc+1) = rxbits(perm+1); end
  end
end

function bytes = legacy_packbytes(payloadBits)
  % VERBATIM from approachb_pn_packet.m L56-57: byte0-first, MSB-first per byte
  B = reshape(payloadBits,8,numel(payloadBits)/8).';
  bytes = uint8(B*(2.^(7:-1:0)).');
end

function words = legacy_packwords(bits)
  % VERBATIM from msggen_rom_overlay.m L34-43: word w = bits[32w..32w+31],
  % MSB-first (bit 32w in word bit 31).
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
  % VERBATIM from approachb_pn_packet.m L96-97 / approachb_bitcontract.m pack32:
  % LSB-first 32-bit register pack (capture bit i -> reg bit i).
  r = uint32(0);
  for i = 0:31
    if bits(i+1) ~= 0, r = bitor(r, bitshift(uint32(1), i)); end
  end
end
