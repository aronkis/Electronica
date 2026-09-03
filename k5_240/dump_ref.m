% dump reference preamble symbols + payload bits + payload symbols as text
G=load('/mnt/onetb/scratch/qpsk_variants/k5_240/golden_k5.mat');
run_params=false;
% reconstruct preamble + mapping exactly as selftest_decode_k5 does
st=fileread('/mnt/onetb/scratch/qpsk_variants/k5_240/selftest_decode_k5.m');
% just reuse: extract generatePreamble + QPSKModulate by running selftest's helpers is complex;
% instead: replicate from the documented convention
barker=[1 1 1 1 1 -1 -1 1 1 -1 1 -1 1]>0;              % 13 chips
pre_bits=zeros(26,1); pre_bits(1:2:end)=barker; pre_bits(2:2:end)=barker;  % dup I/Q interleaved
bI=pre_bits(1:2:end); bQ=pre_bits(2:2:end);
preSym=pskmod(bI*2+bQ,4,pi/4,'gray');
pl=G.payload(:); pI=pl(1:2:end); pQ=pl(2:2:end);
paySym=pskmod(pI*2+pQ,4,pi/4,'gray');
writematrix([real(preSym) imag(preSym)],'/mnt/onetb/scratch/qpsk_variants/k5_240/ref_presym.txt');
writematrix([real(paySym) imag(paySym)],'/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt');
fprintf('dumped %d preamble syms, %d payload syms\n',numel(preSym),numel(paySym));
