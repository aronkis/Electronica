addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
rA = soak_decode_k5('/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkA_s4.iq');
rB = soak_decode_k5('/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkB_s4.iq');
for p = {{'A',rA},{'B',rB}}
  t=p{1}; tag=t{1}; r=t{2};
  fs = r.frameStarts(:); sp = diff(fs);
  fprintf('LINK %s: frames=%d golden=%d infoErr=%d spacing[min med max std]=[%d %d %d %.3f]\n', ...
    tag, numel(fs), sum(r.perFrameGolden), sum(r.perFrameInfoErr), min(sp), median(sp), max(sp), std(double(sp)));
end
