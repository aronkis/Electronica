addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
for f=[2410000000 2420000000 2430000000 2435000000]
  fn=sprintf('/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkA_freq_%d.iq',f);
  d=dir(fn); if isempty(d)||d.bytes<5e6, fprintf('freq %d MISSING\n',f); continue; end
  try
    r=soak_decode_k5(fn);
    fprintf('freq %d: golden=%.1f%% BER=%.4f%% CFO=%.0f\n',f,r.pctGolden,r.codedBER*100,r.coarseCFO);
  catch e
    fprintf('freq %d ERR %s\n',f,e.message);
  end
end
