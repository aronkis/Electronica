addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
for c = {{'A','/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkA_s4d.iq'},{'B','/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkB_s4d.iq'}}
  t=c{1}; tag=t{1}; r=soak_decode_k5(t{2});
  fs=r.frameStarts(:); sp=diff(fs);
  fprintf('LINK %s: nFrames=%d nGolden=%d (%.1f%%) totErr=%d codedBER=%.4f%% steady=%.4f%% CFO=%.0f sp1133=%d/%d std=%.2f\n', ...
    tag, r.nFrames, r.nGolden, r.pctGolden, r.totInfoErr, r.codedBER*100, r.codedBER_steady*100, r.coarseCFO, sum(sp==1133), numel(sp), std(double(sp)));
end
