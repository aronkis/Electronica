addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
r=soak_decode_k5('/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkA_v6.iq');
fs=r.frameStarts(:); sp=diff(fs);
fprintf('LINK A air: nFrames=%d nGolden=%d (%.1f%%) codedBER=%.4f%% CFO=%.0f sp1133=%d/%d\n', ...
  r.nFrames, r.nGolden, r.pctGolden, r.codedBER*100, r.coarseCFO, sum(sp==1133), numel(sp));
