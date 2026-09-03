% Robust golden Tx waveform gen: use the ACTUAL QPSK Tx (model transmitter) if available,
% else careful continuous RRC. Self-test must decode >90% golden to be usable.
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
C=commhdlQPSKTxRxParameters(); pre=C.preambleSymbols(:);
refpay=load('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt'); refpay=refpay(:,1)+1j*refpay(:,2);
frame=[pre; refpay]; sps=8; span=10; beta=0.5;
h=rcosdesign(beta,span,sps); h=h/max(abs(conv(ones(sps,1),h)));  % normalize
nrep=20; s=repmat(frame,nrep,1);                 % many contiguous frames
up=upsample(s,sps);
w=conv(up,h);                                     % FULL convolution (keep tails)
w=w(1:sps*numel(s));                              % trim to integer frames worth
w=w/max(abs([real(w);imag(w)]))*26000;
out=zeros(2*numel(w),1); out(1:2:end)=real(w); out(2:2:end)=imag(w);
fo=fopen('/mnt/onetb/scratch/qpsk_variants/two_jup/golden_tx.iq','w'); fwrite(fo,int16(round(out)),'int16'); fclose(fo);
r=soak_decode_k5('/mnt/onetb/scratch/qpsk_variants/two_jup/golden_tx.iq','label','selftest');
fprintf('SELFTEST v2: golden=%d/%d BER=%.3f%%  (need >90%% golden)\n', r.nGolden, r.nFrames, 100*r.codedBER);
