addpath('/mnt/onetb/scratch/qpsk_variants/k5_240'); tg=0;tf=0;
for c=1:5
  f=sprintf('/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkB_calsoff_%d.iq',c);
  if ~isfile(f)||dir(f).bytes<7e6, continue; end
  try r=soak_decode_k5(f); tg=tg+r.nGolden; tf=tf+r.nFrames; fprintf('calsoff c%d: golden=%d/%d (%.1f%%) BER=%.4f%%\n',c,r.nGolden,r.nFrames,r.pctGolden,r.codedBER*100); catch, end
end
fprintf('AGGREGATE cals-off: %d/%d golden (%.1f%%)\n',tg,tf,100*tg/max(1,tf));
