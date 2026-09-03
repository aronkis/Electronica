addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
for c = {{'A','/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkA_s4b.iq'},{'B','/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkB_s4b.iq'}}
  t=c{1}; tag=t{1};
  try
    r = soak_decode_k5(t{2});
    fs=r.frameStarts(:); sp=diff(fs);
    fprintf('LINK %s: frames=%d golden=%d infoErr=%d spacing[min med max std]=[%d %d %d %.3f]\n', ...
      tag, numel(fs), sum(r.perFrameGolden), sum(r.perFrameInfoErr), min(sp), median(sp), max(sp), std(double(sp)));
  catch e
    fprintf('LINK %s: DECODE ERROR %s\n', tag, e.message);
  end
end
