addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
for c=1:3
  f=sprintf('/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkA_quad_%d.iq',c);
  if ~isfile(f)||dir(f).bytes<7e6, continue; end
  try r=soak_decode_k5(f); fprintf('linkA quad-ON c%d: frames=%d golden=%d (%.1f%%) BER=%.4f%% CFO=%.0f\n',c,r.nFrames,r.nGolden,r.pctGolden,r.codedBER*100,r.coarseCFO); catch e, fprintf('c%d ERR %s\n',c,e.message); end
end
