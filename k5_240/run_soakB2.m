addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
totF=0;totErr=0;totBits=0; cleanPk=0;cleanErr=0; goldPk=0;
for c=1:20
  f=sprintf('/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkB_soak%d.iq',c);
  if ~isfile(f), continue; end
  try
    r=soak_decode_k5(f);
  catch, continue; end
  totF=totF+r.nFrames; totErr=totErr+r.totInfoErr; totBits=totBits+r.totInfoBits;
  goldPk=goldPk+r.nGolden;
  % user-methodology: a capture is a "clean window" if SSI was stable (>=95% golden). accumulate it; else skip.
  if r.pctGolden>=95
    cleanPk=cleanPk+r.nFrames; cleanErr=cleanErr+r.totInfoErr;
  end
  fprintf('cap%2d: frames=%3d golden=%3d (%.0f%%) err=%d\n',c,r.nFrames,r.nGolden,r.pctGolden,r.totInfoErr);
end
fprintf('\n=== LINK B RESULTS (20 captures) ===\n');
fprintf('ALL frames: %d, aggregate BER=%.5f%% (incl SSI-corrupted windows)\n',totF,100*totErr/max(1,totBits));
fprintf('GOLDEN packets (0-err frames): %d -> BER over golden = 0%% (%d info bits)\n',goldPk,goldPk*120);
fprintf('CLEAN-WINDOW (SSI-stable captures >=95%% golden, user soak2.py methodology):\n');
fprintf('  clean packets=%d, errors=%d, BER=%.6f%% over %d info bits\n',cleanPk,cleanErr,100*cleanErr/max(1,cleanPk*120),cleanPk*120);
fprintf('  availability=%.1f%% (clean-window frames / total)\n',100*cleanPk/max(1,totF));
if cleanPk*120>0
  ub=100*(cleanErr+3)/(cleanPk*120); fprintf('  95%% upper CI on clean BER ~= %.6f%%\n',ub);
end
