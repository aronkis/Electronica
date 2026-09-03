addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
G=load('/mnt/onetb/scratch/qpsk_variants/k5_240/golden_k5.mat'); info120=double(G.msgBits(:)).';
[r,D]=soak_dumpbits_k5('ne_failing_d2.iq','label','ne');
for k=1:numel(D.info)
  b=D.info{k}(1:120); fprintf('  f%d: err=%3d zeros=%3d bits(1:24)=%s\n',k,sum(b~=info120),sum(b==0),sprintf('%d',b(1:24)));
end
