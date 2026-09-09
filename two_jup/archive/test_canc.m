addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
fid=fopen('/mnt/onetb/scratch/qpsk_variants/two_jup/la146.iq','r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); n=min(numel(I),numel(Q)); x=double(I(1:n))+1j*double(Q(1:n)); fs=1.92e6;
N=2^floor(log2(numel(x))); X=fftshift(fft(x(1:N).*hann(N))); fax=linspace(-fs/2,fs/2,N);
[~,k]=max(abs(X)); fcw=fax(k);
nn=(0:numel(x)-1).'; e=exp(1j*2*pi*fcw/fs*nn); a=(e'*x)/(e'*e);
xcanc = x - a*e;
fprintf('CW carrier at %.0f Hz |a|=%.0f ; rms sig(after cancel)=%.0f  carrier/sig=%.1f dB\n', ...
    fcw, abs(a), sqrt(mean(abs(xcanc).^2)), 20*log10(abs(a)/sqrt(mean(abs(xcanc).^2))));
xc=xcanc; sc=max(abs([real(xc);imag(xc)])); xc=xc/sc*20000;
out=zeros(2*numel(xc),1); out(1:2:end)=real(xc); out(2:2:end)=imag(xc);
fo=fopen('/mnt/onetb/scratch/qpsk_variants/two_jup/la146_canc.iq','w'); fwrite(fo,int16(round(out)),'int16'); fclose(fo);
r0=soak_decode_k5('/mnt/onetb/scratch/qpsk_variants/two_jup/la146.iq','label','orig');
r1=soak_decode_k5('/mnt/onetb/scratch/qpsk_variants/two_jup/la146_canc.iq','label','canc');
fprintf('\n>>> ORIG: golden=%d/%d BER=%.2f%%   CW-CANCELLED: golden=%d/%d BER=%.2f%%\n', ...
    r0.nGolden,r0.nFrames,100*r0.codedBER, r1.nGolden,r1.nFrames,100*r1.codedBER);
