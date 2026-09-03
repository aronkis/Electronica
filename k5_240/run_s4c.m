for c = {{'A','/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkA_s4b_soakres_k5.mat'},{'B','/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkB_s4b_soakres_k5.mat'}}
  t=c{1}; tag=t{1}; S=load(t{2}); r=S.res;
  disp(['LINK ' tag ' fields: ' strjoin(fieldnames(r).',' ')]);
  fs=r.frameStarts(:); sp=diff(fs);
  g = r.golden(:); ie = r.infoErr(:);
  fprintf('LINK %s: frames=%d golden=%d (%.1f%%) infoErrTot=%d infoErrOnGolden=%d\n', tag, numel(g), sum(g), 100*mean(g), sum(ie), sum(ie(g>0)));
  fprintf('  spacing: min=%d med=%d max=%d std=%.2f ; nonconforming(~=1133): %d\n', min(sp), median(sp), max(sp), std(double(sp)), sum(sp~=1133));
  bad = find(~g); fprintf('  first bad frames idx: %s\n', mat2str(bad(1:min(8,end)).'));
end
