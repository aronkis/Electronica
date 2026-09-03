function tone_verify(capfile, delta_hz, fs)
% tone_verify  FFT a captured int16 IQ file, find the peak, compare to predicted bin LO+delta.
% fs = the capturing board's actual Rx sampling_frequency (Hz).
if nargin<3, fs=1.92e6; end
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); n=min(numel(I),numel(Q));
x=double(I(1:n))+1i*double(Q(1:n));
sat = mean(abs([real(x);imag(x)])>32000);            % saturation check
N=2^floor(log2(numel(x))); w=hann(N);
X=fftshift(abs(fft(x(1:N).*w)));
f=linspace(-fs/2,fs/2,N);
[pk,ki]=max(X); fpeak=f(ki);
noise=median(X(X<pk/10)+eps); snr_db=20*log10(pk/noise);
binhz=fs/N;
fprintf('[tone] fs=%.3f MHz predicted=%+.0f Hz measured=%+.0f Hz err=%.0f Hz (bin=%.0f Hz)  SNR=%.1f dB  sat=%.3f%%\n',...
    fs/1e6, delta_hz, fpeak, fpeak-delta_hz, binhz, snr_db, 100*sat);
pass = abs(fpeak-delta_hz) < 3*binhz && snr_db>20 && sat<0.001;
if pass, fprintf('[tone] PASS\n'); else, fprintf('[tone] FAIL\n'); end
figure('visible','off'); plot(f/1e3, 20*log10(X/max(X))); grid on;
xlabel('kHz from LO'); ylabel('dBc'); ylim([-80 2]);
title(sprintf('tone %+.0f Hz (meas %+.0f, SNR %.0f dB, fs %.2f MHz)',delta_hz,fpeak,snr_db,fs/1e6));
[d,b]=fileparts(capfile); print(fullfile(d,[b '_spectrum.png']),'-dpng');
end
