% awgn_k5.m -- K=5 [35 23] rate-1/2 hard-decision Viterbi coded-BER vs Eb/N0 in AWGN.
% Matches the deployed decoder: poly2trellis(5,[35 23]), TB=25, hard decision, QPSK.
% (Interleaver omitted: transparent on a memoryless AWGN channel.)
trellis = poly2trellis(5,[35 23]); TB = 25;
EbN0 = 3:1:14;                 % dB (QPSK rate-1/2: Es/N0 = Eb/N0)
Ninfo = 3e6;
fprintf('K=5 [35 23] rate-1/2 hard-decision Viterbi, QPSK, AWGN\n');
fprintf('%6s  %12s  %10s\n','EbN0dB','codedBER','errs');
ber = zeros(size(EbN0));
for i = 1:numel(EbN0)
    info  = randi([0 1], Ninfo, 1);
    coded = convenc(info, trellis);                                  % rate 1/2
    sym   = pskmod(coded, 4, pi/4, 'gray', 'InputType','bit');       % 2 coded bits/QPSK sym
    rx    = awgn(sym, EbN0(i), 'measured');                          % Es/N0 = Eb/N0 for QPSK r=1/2
    rxb   = pskdemod(rx, 4, pi/4, 'gray', 'OutputType','bit');       % hard bits
    dec   = vitdec(rxb, trellis, TB, 'cont', 'hard');               % continuous hard Viterbi (delay=TB)
    err   = sum(dec(TB+1:end) ~= info(1:end-TB));
    ber(i)= err / (numel(info)-TB);
    fprintf('%6.1f  %12.3e  %10d\n', EbN0(i), ber(i), err);
end
% locate the Eb/N0 that gives ~1.9e-3 (the observed floor) and ~14 dB (the EVM-implied SNR)
fprintf('\n-- interpretation anchors --\n');
idx = find(ber>0);
if ~isempty(idx)
    fprintf('observed floor 1.9e-3 corresponds to an EFFECTIVE Eb/N0 ~ %.1f dB (interp)\n', ...
        interp1(log10(max(ber(idx),1e-9)), EbN0(idx), log10(1.9e-3), 'linear','extrap'));
end
fprintf('at 14 dB (EVM-implied SNR of the flooring capture): codedBER = %.3e\n', ber(end));
fprintf('DONE_AWGN\n');
