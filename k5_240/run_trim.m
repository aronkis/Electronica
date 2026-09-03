addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
for lo=[2399974000 2399975000 2399980000 2399990000]
  f=sprintf('/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkA_trim_%d.iq',lo);
  if ~isfile(f)||dir(f).bytes<7e6, fprintf('%d missing\n',lo); continue; end
  try r=soak_decode_k5(f); fprintf('LO %d: golden=%d/%d (%.1f%%) BER=%.4f%% CFO=%.0f\n',lo,r.nGolden,r.nFrames,r.pctGolden,r.codedBER*100,r.coarseCFO); catch e, fprintf('%d ERR\n',lo); end
end
