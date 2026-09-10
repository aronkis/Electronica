function by = seq_frame_bytes_k5(seq, PKT)
% seq_frame_bytes_k5  The full expected -S WIRE frame (bytes, 1..PKT) for a
% sequence number: header (QK, len=64, seq LE) + xorshift32(seq) payload +
% CRC32(zlib; header+payload, CRC field zeroed) + PN9(x^9+x^5+1, seed
% seq&0x1FF) padding. Bit-exact vs host qpsk_seq_expected() --
% cross-validated against the C for seq {0,1,42} (2026-07-11).
% Whitener (QPSK_WHITEN) assumed OFF.
if nargin < 2, PKT = 128; end
LEN = 64;
by = zeros(PKT,1);
by(1)=hex2dec('51'); by(2)=hex2dec('4B');
by(3)=bitand(LEN,255); by(4)=bitshift(LEN,-8);
by(5)=bitand(seq,255); by(6)=bitand(bitshift(seq,-8),255);
by(7)=bitand(bitshift(seq,-16),255); by(8)=bitand(bitshift(seq,-24),255);
% xorshift32 payload
M=2^32; x=bitxor(seq,hex2dec('9E3779B9')); if x==0, x=hex2dec('DEADBEEF'); end
for i=1:LEN
  x=bitand(bitxor(x,bitand(x*2^13,M-1)),M-1);
  x=bitxor(x,floor(x/2^17));
  x=bitand(bitxor(x,bitand(x*2^5,M-1)),M-1);
  by(12+i)=bitand(x,255);
end
% PN9 pad
s=bitand(seq,511); if s==0, s=511; end
for i=12+LEN+1:PKT
  v=0;
  for k=1:8
    nb=bitand(bitxor(floor(s/256),floor(s/16)),1);
    s=bitand(s*2+nb,511);
    v=v*2+nb;
  end
  by(i)=v;
end
% CRC32 over header+payload with CRC field zeroed
c=seq_crc32_k5(by(1:12+LEN),[9 10 11 12]);
by(9)=bitand(c,255); by(10)=bitand(bitshift(c,-8),255);
by(11)=bitand(bitshift(c,-16),255); by(12)=bitand(bitshift(c,-24),255);
end
