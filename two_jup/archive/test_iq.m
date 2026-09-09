function test_iq(capfile)
% Test IQ-imbalance as the payload-corruption cause. Analog Tx/Rx quadrature mismatch adds a
% conjugate image (loopback bypasses it -> loopback golden; air corrupted). Estimate+remove
% the widely-linear image (s = r - a*conj(r), LS a), then decode. Also try blind compensator.
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); n=min(numel(I),numel(Q)); x=double(I(1:n))+1j*double(Q(1:n));
x=x(abs(x)>0);
% image-rejection ratio (spectrum asymmetry) BEFORE
fs=1.92e6; N=2^floor(log2(numel(x))); X=abs(fftshift(fft((x(1:N)-mean(x(1:N))).*hann(N))));
fax=linspace(-fs/2,fs/2,N); pos=mean(X((fax>20e3)&(fax<150e3))); neg=mean(X((fax<-20e3)&(fax>-150e3)));
fprintf('\n=== %s ===\n',capfile);
fprintf('spectrum asymmetry (pos/neg sideband) = %.1f dB\n',20*log10(pos/neg));
% --- LS widely-linear image removal: find a minimizing |x - a*conj(x)| structure ---
xc=x-mean(x); a=(xc.'*xc)/(xc'*xc);            % a = E[x^2]/E[|x|^2] (image coeff)
% correct: standard IQ-imbalance inverse (widely-linear)
g=1/sqrt(1-abs(a)^2); xcorr1=g*(xc - a*conj(xc));
X2=abs(fftshift(fft((xcorr1(1:N)-mean(xcorr1(1:N))).*hann(N))));
pos2=mean(X2((fax>20e3)&(fax<150e3))); neg2=mean(X2((fax<-20e3)&(fax>-150e3)));
fprintf('after image removal (a=%.3f): asymmetry = %.1f dB\n',abs(a),20*log10(pos2/neg2));
% write corrected + decode both
wr=@(fn,z) fwrite(fopen(fn,'w'),int16(round([real(z(:)) imag(z(:))].'/max(abs([real(z);imag(z)]))*20000)),'int16');
wr('/tmp/iq_orig.iq',xc); wr('/tmp/iq_corr.iq',xcorr1);
r0=soak_decode_k5('/tmp/iq_orig.iq','label','orig');
r1=soak_decode_k5('/tmp/iq_corr.iq','label','iqcorr');
fprintf('\n>>> ORIG BER=%.2f%% golden=%d  |  IQ-CORRECTED BER=%.2f%% golden=%d\n',...
    100*r0.codedBER,r0.nGolden,100*r1.codedBER,r1.nGolden);
end
