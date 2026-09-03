addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
best=struct('ber',1e9);
for tg={'L1','L2','L3'}
  f=sprintf('/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkB_long%s.iq',tg{1});
  if ~isfile(f)||dir(f).bytes<7e6, continue; end
  try, r=soak_decode_k5(f); catch, continue; end
  fprintf('%s: frames=%d golden=%d (%.1f%%) err=%d BER=%.6f%% (steady drop1=%.6f%%)\n',tg{1},r.nFrames,r.nGolden,r.pctGolden,r.totInfoErr,r.codedBER*100,r.codedBER_steady*100);
  if r.codedBER<best.ber, best.ber=r.codedBER; best.tag=tg{1}; best.r=r; end
end
if isfield(best,'r')
  r=best.r; fprintf('\nBEST LONG capture %s: %d frames, %d golden, BER=%.6f%%, steady-state=%.6f%%\n',best.tag,r.nFrames,r.nGolden,r.codedBER*100,r.codedBER_steady*100);
end
