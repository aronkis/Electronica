addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
for lo=[2399975000 2399976000 2399977000 2399978000 2399979000]
  f=sprintf('/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkA_fs_%d.iq',lo);
  if ~isfile(f)||dir(f).bytes<7e6, continue; end
  try r=soak_decode_k5(f); fprintf('LO %d: golden=%.1f%% BER=%.4f%% CFO=%.0f\n',lo,r.pctGolden,r.codedBER*100,r.coarseCFO); catch, fprintf('%d ERR\n',lo); end
end
