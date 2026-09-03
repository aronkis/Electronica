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
G = load(fullfile(fileparts(KITDIR),'k5_240','golden_k5.mat'));
info = double(G.info(:)); assert(numel(info)==1084);
assert(uint32(G.capOut)==uint32(hex2dec('04922282')), 'golden capOut drift');
txw = pack_bits64_local([info; zeros(2240-1084,1)]); assert(numel(txw)==35);
rxw = pack_bits64_local(info(1:1024));               assert(numel(rxw)==16);
fid=fopen(fullfile('rtl_sim','tx_words_golden.hex'),'w');
fprintf(fid,'%016x\n', txw); fclose(fid);
fid=fopen(fullfile('rtl_sim','rx_words_golden.hex'),'w');
fprintf(fid,'%016x\n', rxw); fclose(fid);
fprintf('GEN_BYTE_VECTORS_OK tx=35 rx=16 (word0=%016x)\n', txw(1));

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
