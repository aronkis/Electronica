% test_byte_helpers_k5.m -- fast host-side unit test of the kit's byte
% packing contract against the VERBATIM helper single-sources:
%   (1) pack_bits64(frameBits) fed word-by-word through qpskByteBitShifter
%       must reproduce frameBits (the shifter IS the on-chip consumer);
%   (2) the info bit stream through qpskByteSerializer (WPP=16) must emit
%       exactly pack_bits64(info(1:1024)) -- the byte-RX golden packet.
% No Simulink; pure MATLAB. Errors out on mismatch.
KITDIR='/mnt/onetb/scratch/qpsk_variants/jupiter_240k5_byte';
cd(KITDIR); addpath(KITDIR);
G = load('/mnt/onetb/scratch/qpsk_variants/k5_240/golden_k5.mat');
info = double(G.info(:)); assert(numel(info)==1084);
frameBits = [info; zeros(2240-1084,1)];
w = pack_local(frameBits); assert(numel(w)==35);

% (1) shifter replay: aligned stream, one enabled step per bit, start at bit 0
st = qpskByteBitShifter();
widx = 1; avail = true;
out = zeros(2240,1);
for k = 1:2240
    start = (k==1);
    wordFirst = (widx==1);
    [bit, pop, st] = qpskByteBitShifter(st, true, start, w(widx), avail, wordFirst);
    out(k) = double(bit);
    if pop, widx = widx + 1; if widx > 35, widx = 1; end, end
end
assert(isequal(out, frameBits), 'shifter replay != frame bits (packing convention broken)');
fprintf('helper test (1) OK: pack_bits64 -> qpskByteBitShifter reproduces the 2240-bit frame\n');

% (2) serializer: decoded info stream (1084 bits + start) -> 16 words
st = qpskByteSerializer();
words = {}; lasts = [];
for rep = 1:2   % two frames to exercise the start-reset partial-word discard
    for k = 1:1084
        [wv, v, l, ~, st] = qpskByteSerializer(st, info(k)~=0, true, k==1, true, uint8(16));
        if v, words{end+1} = wv; lasts(end+1) = l; end %#ok<AGROW>
    end
end
rxGold = pack_local(info(1:1024));
assert(numel(words)==32, 'expected 32 words over 2 frames, got %d', numel(words));
w1 = [words{1:16}].'; w2 = [words{17:32}].';
assert(isequal(w1, rxGold) && isequal(w2, rxGold), 'serializer words != golden rx packet');
assert(isequal(find(lasts), [16 32]), 'wordLast not on word 16 of each frame');
fprintf('helper test (2) OK: qpskByteSerializer (WPP=16) emits the 16 golden info words/frame\n');
fprintf('TEST_BYTE_HELPERS_K5 PASS\n');

function w = pack_local(bits)
n = ceil(numel(bits)/64)*64;
b = zeros(n,1); b(1:numel(bits)) = double(bits(:));
B = reshape(b,8,[]).';
bytes = uint64(B * (2.^(7:-1:0)).');
nw = n/64; w = zeros(nw,1,'uint64');
for k=1:nw
    v = uint64(0);
    for j=0:7, v = bitor(v, bitshift(bytes((k-1)*8+j+1), 8*j)); end
    w(k) = v;
end
end
