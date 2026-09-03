function test_f1536_ref_bits()
%TEST_F1536_REF_BITS  f1536_ref_bits() must match packet_f1536.m's golden output.
% This is the ONLY thing standing between a silent change in packet_f1536.m and
% every downstream measurement being scored against the wrong reference.
R = f1536_ref_bits();
G = load(fullfile(fileparts(mfilename('fullpath')),'golden_f1536.mat'));
ok = isequal(R.info(:),G.info(:)) && isequal(R.coded(:),G.coded(:)) && ...
     isequal(R.payload(:),G.payload(:));
fprintf('info=%d coded=%d payload=%d\n', isequal(R.info(:),G.info(:)), ...
        isequal(R.coded(:),G.coded(:)), isequal(R.payload(:),G.payload(:)));
% AWGN independence: the pad RNG must not seed the global stream
a = synth_f1536_waveform(1, struct('esn0_db',10));
b = synth_f1536_waveform(1, struct('esn0_db',10));
indep = ~isequal(a,b);
fprintf('awgn_independent=%d\n', indep);
if ok && indep, fprintf('T1_TEST_PASS\n'); else, fprintf('T1_TEST_FAIL\n'); end
end
