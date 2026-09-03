cfgs = {'qr_r0_s0','qr_r90_s0','qr_r180_s0','qr_r270_s0','qr_r0_s1','qr_r90_s1','qr_r180_s1','qr_r270_s1'};
rots = [0 90 180 270 0 90 180 270];
sws  = [0 0 0 0 1 1 1 1];
fprintf('\n==== floor_148 INPUT-QUADRANT SWEEP  (byte_rx vs -B reference) ====\n');
fprintf('rot swap | frames CLEAN NOISY PHASE ROT MISS |      BER\n');
bestber = inf; besti = 0; R = cell(8,1);
for i = 1:8
    T = evalc('r = score_rxw_ref(cfgs{i});'); %#ok<NASGU>
    R{i} = r; b = r.buckets;
    if r.ber_measurable, bs = sprintf('%.3e', r.ber); else, bs = '   N/A  '; end
    fprintf('%3d   %d  |  %3d   %3d   %3d   %3d  %3d  %3d | %s\n', ...
        rots(i), sws(i), r.frames, b(1), b(2), b(3), b(4), b(5), bs);
    if (b(1)+b(2)) > 0 && r.ber < bestber, bestber = r.ber; besti = i; end
end
fprintf('----\n');
if besti > 0
    fprintf('BEST aligned config = %s (rot=%d swap=%d): aligned=%d/%d  BER=%.3e\n', ...
        cfgs{besti}, rots(besti), sws(besti), R{besti}.aligned, R{besti}.frames, R{besti}.ber);
    fprintf('\n--- full report for best config ---\n');
    score_rxw_ref(cfgs{besti});
else
    fprintf('NO config produced any aligned (CLEAN/NOISY) frames -- every quadrant PHASE.\n');
end
