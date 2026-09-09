% fir_verify.m -- element-wise diff of the k5 netlist REP_Tx FIR output against
% an integer-exact MATLAB reference: upsample-by-2 through round(2*fir1(24,0.45)*2^15),
% products sfix..En15, output rounded to int16 (Nearest) + saturated -- exactly the
% arithmetic the generated HDL performs.
csv = '/mnt/onetb/scratch/qpsk-jupiter-modem/.claude/worktrees/firpipe-imageB/jupiter_240k5_byte/rtl_sim/fir_probe_fir.csv';
D = readmatrix(csv);              % cols: repInI repOutI repInQ repOutQ (per enb cycle)

h  = 2*fir1(24,0.45);            % 25-tap interpolation FIR (same as variant_pre.m)
hq = round(h*2^15);             % sfix16_En15 quantized coeffs (integer)

% sanity: HDL constants coeffphaseSig1 = -132 (phase0 tap0), coeffphaseSig2 = 28 (phase1 tap0)
p0 = hq(1:2:end); p1 = hq(2:2:end);
fprintf('coeff sanity: hq(1)=%d (HDL coeffphaseSig1=-132)  hq(2)=%d (HDL coeffphaseSig2=28)\n', p0(1), p1(1));
assert(all(abs(hq) <= 32767), 'coeff overflow En15');

[eI,lI,nI] = fir_check(D(:,1), D(:,2), hq, 'REP_TxI');
[eQ,lQ,nQ] = fir_check(D(:,3), D(:,4), hq, 'REP_TxQ');
fprintf('FIR_VERIFY_RESULT maxerrI=%d maxerrQ=%d nI=%d nQ=%d lagI=%d lagQ=%d\n', eI, eQ, nI, nQ, lI, lQ);
if eI==0 && eQ==0
    fprintf('FIR_VERIFY: PASS (element-wise max error 0 on both I and Q)\n');
else
    fprintf('FIR_VERIFY: NONZERO\n');
end

function [maxerr, lag, nchk] = fir_check(repIn, repOut, hq, tag)
    xin = repIn(1:2:end);                 % input held 2x -> input-rate sequence
    xup = zeros(2*numel(xin),1); xup(1:2:end) = xin;   % upsample-by-2 (zero stuff)
    acc = conv(xup, hq(:));               % integer En15 accumulate (full precision)
    yref = round(acc/2^15);               % round to En0 (Nearest, ties away)
    yref = max(min(yref,32767),-32768);   % saturate to int16
    yout = double(repOut);
    n = min(numel(yref), numel(yout));
    s0 = 200; best = inf; blag = 0;
    for d = 0:60
        a = yref(s0:n-d); b = yout(s0+d:n); m = min(numel(a),numel(b));
        e = max(abs(a(1:m)-b(1:m)));
        if e < best, best = e; blag = d; end
    end
    a = yref(s0:n-blag); b = yout(s0+blag:n); m = min(numel(a),numel(b));
    maxerr = max(abs(a(1:m)-b(1:m))); lag = blag; nchk = m;
    fprintf('%s: lag=%d nchk=%d MAXERR=%d\n', tag, lag, nchk, maxerr);
end
