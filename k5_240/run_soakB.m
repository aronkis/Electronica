addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
totF=0; totG=0; totBits=0; totErr=0; totErrSteady=0; totBitsSteady=0;
for c=1:6
  f=sprintf('/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkB_soak%d.iq',c);
  try
    r=soak_decode_k5(f);
    totF=totF+r.nFrames; totG=totG+r.nGolden; totBits=totBits+r.totInfoBits; totErr=totErr+r.totInfoErr;
    % steady-state: drop the worst-2 frames per capture (acquisition transients), user-methodology style
    pf=r.perFrame; e=double(pf.infoErr(:)); e=sort(e,'descend');
    dropErr=sum(e(1:min(2,numel(e)))); nkeep=max(0,r.nFrames-2);
    totErrSteady=totErrSteady+(r.totInfoErr-dropErr); totBitsSteady=totBitsSteady+nkeep*120;
    fprintf('cap%d: frames=%d golden=%d(%.1f%%) err=%d BER=%.5f%%\n',c,r.nFrames,r.nGolden,r.pctGolden,r.totInfoErr,r.codedBER*100);
  catch e
    fprintf('cap%d: ERR %s\n',c,e.message);
  end
end
fprintf('\n=== LINK B AGGREGATE (6 captures) ===\n');
fprintf('total frames=%d golden=%d (%.2f%%) info bits=%d errors=%d\n',totF,totG,100*totG/max(1,totF),totBits,totErr);
fprintf('AGGREGATE coded BER = %.6f%%\n',100*totErr/max(1,totBits));
fprintf('STEADY-STATE (drop 2 worst/cap = acquisition) coded BER = %.6f%% over %d bits\n',100*totErrSteady/max(1,totBitsSteady),totBitsSteady);
