addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
r=soak_decode_k5('/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkA_jrxnotrack.iq');
fs=r.frameStarts(:); sp=diff(fs);
fprintf('LINK A: nFrames=%d nGolden=%d (%.1f%%) totErr=%d codedBER=%.4f%% steady=%.4f%% CFO=%.0f sp1133=%d/%d std=%.2f\n', ...
  r.nFrames, r.nGolden, r.pctGolden, r.totInfoErr, r.codedBER*100, r.codedBER_steady*100, r.coarseCFO, sum(sp==1133), numel(sp), std(double(sp)));
pf=r.perFrame; bad=find(~pf.valid | pf.infoErr>0);
fprintf('  bad frame indices: %s\n', mat2str(bad(1:min(12,end)).'));
