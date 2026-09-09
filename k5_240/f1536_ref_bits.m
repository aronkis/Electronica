function R = f1536_ref_bits()
%F1536_REF_BITS  The f1536 ROM reference: what the transmitter actually sends.
%
% Bit-for-bit identical construction to packet_f1536.m -- deliberately duplicated
% rather than imported, because packet_f1536.m writes files as a side effect and
% this must be a pure function. NOTE: the asserts in this function are
% self-consistency checks only (sizes, tail-pad zeros) -- they do NOT catch a
% drift in packet_f1536.m's actual content (message string, PN seed, filler
% polynomial, etc). That drift is caught by test_f1536_ref_bits.m, which
% compares this function's output against the committed golden_f1536.mat.

R.trellis = poly2trellis(5,[35 23]);  R.TB = 25;
R.COLS = 16;  R.ROWS = 1537;
R.INFO = 12292;  R.TAIL = 4;  R.CODED = 2*(R.INFO + R.TAIL);   % 24592
R.NFILL = 48;    R.PAYLOAD = R.CODED + R.NFILL;                % 24640
assert(R.CODED == R.ROWS*R.COLS, 'CODED ~= ROWS*COLS');
assert(R.PAYLOAD == 385*64, 'PAYLOAD ~= 385*64');

% message bits: 'ADI Hello World', 8 bits/char, MSB-first
msg = 'ADI Hello World';
msgBits = reshape(de2bi(uint8(msg),8,'left-msb').',[],1);      % 120x1
assert(numel(msgBits)==120);

% PN pad (deterministic seed 15360) + 4 zero tail-pad -> 12292-bit info field
% Uses a LOCAL RandStream, not rng(...) (global stream) -- this function is
% called repeatedly by synth_f1536_waveform(), and seeding the global stream
% here would make every subsequent AWGN draw in the same process degenerate
% (identical noise on every call). See test_f1536_ref_bits.m for the check.
NPAD = 12288 - 120;                                            % 12168
s = RandStream('twister','Seed',15360);
pad = randi(s,[0 1],NPAD,1);
R.info = [msgBits; pad; zeros(4,1)];
assert(numel(R.info)==R.INFO);
assert(all(R.info(R.INFO-3:R.INFO)==0), 'the 4 tail-pad info bits must be zero');

% K=5 encode with K-1 zero tail
R.coded = convenc([R.info; zeros(R.TAIL,1)], R.trellis);
assert(numel(R.coded)==R.CODED);

% 1537x16 block interleave, legacy read perm r*COLS + c
il = zeros(R.CODED,1);
for beat = 0:R.CODED-1
    r = mod(beat, R.ROWS);  c = floor(beat / R.ROWS);
    il(beat+1) = R.coded(r*R.COLS + c + 1);
end

% 48-bit PN9 filler (x^9 + x^5 + 1, seed all-ones)
lfsr = ones(9,1);  filler = zeros(R.NFILL,1);
for k = 1:R.NFILL
    fb = xor(lfsr(9), lfsr(5));
    filler(k) = lfsr(9);
    lfsr = [fb; lfsr(1:8)];
end

R.payload = [il; filler];
assert(numel(R.payload)==R.PAYLOAD);
end
