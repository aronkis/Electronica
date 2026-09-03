function c = seq_crc32_k5(by, zeroIdx)
% seq_crc32_k5  zlib CRC32 (poly 0xEDB88320, init/final 0xFFFFFFFF) over the
% byte vector; bytes at zeroIdx are read as 0 (the CRC-field convention of
% qpsk_frame). Matches host_app_k5 qpsk_crc32().
if nargin < 2, zeroIdx = []; end
persistent tbl
if isempty(tbl)
  tbl = zeros(256,1);
  for i = 0:255
    r = i;
    for k = 1:8
      if bitand(r,1), r = bitxor(floor(r/2), hex2dec('EDB88320'));
      else, r = floor(r/2); end
    end
    tbl(i+1) = r;
  end
end
c = hex2dec('FFFFFFFF');
for i = 1:numel(by)
  v = by(i);
  if any(i == zeroIdx), v = 0; end
  c = bitxor(floor(c/256), tbl(bitand(bitxor(c, v), 255) + 1));
end
c = bitxor(c, hex2dec('FFFFFFFF'));
end
