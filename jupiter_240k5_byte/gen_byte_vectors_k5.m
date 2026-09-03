% gen_byte_vectors_k5.m -- emit the netlist-gate byte vectors from the K5
% golden contract (k5_240/golden_k5.mat):
%   rtl_sim/tx_words_golden.hex : 35 x uint64 (one 16-hex line each) = one
%       2240-bit frame, info (1084 bits) first then zero fill; byte-0-first,
%       MSB-first per byte, LSB byte first in the word (qpskByteBitShifter /
%       ByteDmaRegisters.pack convention)
%   rtl_sim/rx_words_golden.hex : 16 x uint64 = the expected byte-RX packet
%       (first 1024 of the 1084 decoded info bits, same packing)
KITDIR=fileparts(mfilename('fullpath'));
cd(KITDIR);
cfg = frame_config_k5();   % single source of truth for frame geometry
G = load(fullfile(fileparts(KITDIR),'k5_240',sprintf('golden_%s.mat',cfg.Frame)));
info = double(G.info(:)); assert(numel(info)==cfg.InfoBits);
assert(uint32(G.capOut)==cfg.CapGolden, 'golden capOut drift (got 0x%08X, expected 0x%08X)', ...
    uint32(G.capOut), cfg.CapGolden);
txw = pack_bits64_local([info; zeros(cfg.PayloadBits-cfg.InfoBits,1)]); assert(numel(txw)==cfg.PayloadWords64);
rxw = pack_bits64_local(info(1:cfg.WordsPerPacketRx*64));               assert(numel(rxw)==cfg.WordsPerPacketRx);
fid=fopen(fullfile('rtl_sim','tx_words_golden.hex'),'w');
fprintf(fid,'%016x\n', txw); fclose(fid);
fid=fopen(fullfile('rtl_sim','rx_words_golden.hex'),'w');
fprintf(fid,'%016x\n', rxw); fclose(fid);
fprintf('GEN_BYTE_VECTORS_OK tx=%d rx=%d (word0=%016x)\n', cfg.PayloadWords64, cfg.WordsPerPacketRx, txw(1));

function w = pack_bits64_local(bits)
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
