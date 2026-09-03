addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
C=commhdlQPSKTxRxParameters(); pre=C.preambleSymbols(:);
refpay=load('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt'); refpay=refpay(:,1)+1j*refpay(:,2);
syms=[pre; refpay];                          % one golden frame = 1133 symbols
sps=8; h=rcosdesign(0.5,4,sps); h=h/sqrt(sum(h.^2));
% repeat frame several times so the cyclic buffer holds whole frames + RRC continuity
nrep=8; s=[]; for k=1:nrep, s=[s; syms]; end
up=upsample(s,sps); w=conv(up,h,'same');
w=w/max(abs([real(w);imag(w)]))*28000;       % scale to int16, headroom
out=zeros(2*numel(w),1); out(1:2:end)=real(w); out(2:2:end)=imag(w);
fo=fopen('/mnt/onetb/scratch/qpsk_variants/two_jup/golden_tx.iq','w'); fwrite(fo,int16(round(out)),'int16'); fclose(fo);
fprintf('golden_tx.iq: %d frames, %d samples, %d bytes\n', nrep, numel(w), 2*numel(out)/2);
% sanity: decode our own generated waveform to confirm it IS golden
addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
r=soak_decode_k5('/mnt/onetb/scratch/qpsk_variants/two_jup/golden_tx.iq','label','selftest');
fprintf('SELFTEST golden_tx: golden=%d/%d BER=%.3f%%\n', r.nGolden, r.nFrames, 100*r.codedBER);
