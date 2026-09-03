addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
for c=1:3
  f=sprintf('/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkA_g34_%d.iq',c);
  if ~isfile(f)||dir(f).bytes<7e6, fprintf('c%d missing\n',c); continue; end
  try r=soak_decode_k5(f); fprintf('linkA g34 c%d: frames=%d golden=%d (%.1f%%) BER=%.5f%% CFO=%.0f\n',c,r.nFrames,r.nGolden,r.pctGolden,r.codedBER*100,r.coarseCFO);
  catch e, fprintf('c%d ERR %s\n',c,e.message); end
end
