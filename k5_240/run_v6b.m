addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
r=soak_decode_k5('/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkB_v6b.iq');
fprintf('LINK B offline: nGolden=%d/%d (%.1f%%) codedBER=%.4f%% CFO=%.0f\n', r.nGolden,r.nFrames,r.pctGolden,r.codedBER*100,r.coarseCFO);
