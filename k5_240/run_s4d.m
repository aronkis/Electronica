for c = {{'A','/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkA_s4b_soakres_k5.mat'},{'B','/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkB_s4b_soakres_k5.mat'}}
  t=c{1}; tag=t{1}; S=load(t{2}); r=S.res;
  pf=r.perFrame; disp(['LINK ' tag ' perFrame fields: ' strjoin(fieldnames(pf).',' ')]);
  fs=r.frameStarts(:); sp=diff(fs);
  fprintf('LINK %s: nFrames=%d nGolden=%d (%.1f%%) totErr=%d codedBER=%.4f%% steady=%.4f%% CFO=%.0f\n', ...
    tag, r.nFrames, r.nGolden, r.pctGolden, r.totInfoErr, r.codedBER*100, r.codedBER_steady*100, r.coarseCFO);
  fprintf('  spacing(sym): min=%d med=%d max=%d std=%.2f ; ~=1133: %d of %d\n', min(sp), median(sp), max(sp), std(double(sp)), sum(sp~=1133), numel(sp));
end
