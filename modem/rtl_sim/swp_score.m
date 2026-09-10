% swp_score.m -- score the harness cold-start sweep of floor_148 vs the -B ref.
% Grid: vphase in {0,1} x skip in {0,1,2,3} x rstcs_end in {400,4400,8400,16400,40400},
% cadence=2 fixed. Question: does ANY cold-start setting decode floor_148 (which an
% ideal float receiver decodes to BER=0)? Any aligned (CLEAN/NOISY) frame => yes.
vs = [0 1]; ss = [0 1 2 3]; rs = [400 4400 8400 16400 40400];
fprintf('\n==== floor_148 HARNESS COLD-START SWEEP  (byte_rx vs -B, cadence=2) ====\n');
fprintf('vph skip rstcs | frames CLEAN NOISY PHASE ROT MISS |    BER   | note\n');
anyAligned = false; nrun = 0;
for v = vs
  for s = ss
    for r = rs
      pfx = sprintf('swp_v%d_s%d_r%d', v, s, r);
      f = [pfx '_rxw.txt'];
      if ~isfile(f), fprintf('%2d  %2d  %6d | (missing)\n', v,s,r); continue; end
      nrun = nrun + 1;
      T = evalc('res = score_rxw_ref(pfx);'); %#ok<NASGU>
      b = res.buckets;
      if res.ber_measurable, bs = sprintf('%.2e', res.ber); else, bs = '  N/A  '; end
      note = '';
      if (b(1)+b(2)) > 0, anyAligned = true; note = '<-- ALIGNED!'; end
      fprintf('%2d  %2d  %6d |  %3d   %3d   %3d   %3d  %3d  %3d | %s | %s\n', ...
        v, s, r, res.frames, b(1), b(2), b(3), b(4), b(5), bs, note);
    end
  end
end
fprintf('----\n');
fprintf('runs scored=%d ; ANY cold-start setting produced aligned (CLEAN/NOISY) frames: %d\n', ...
        nrun, anyAligned);
if ~anyAligned
    fprintf('=> NO harness cold-start setting makes the deployed RTL decode floor_148.\n');
end
