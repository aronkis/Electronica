function cyclo3(capfile,lbl,fs)
if nargin<3, fs=1.92e6; end
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
x=double(raw(1:2:end))+1j*double(raw(2:2:end)); x=x(abs(x)>0); x=x-mean(x); x=x/rms(abs(x));
[P,ff]=pwelch(x,hann(4096),2048,4096,fs,'centered'); Pn=10*log10(P/max(P)); ab=find(Pn>-20); bw=ff(ab(end))-ff(ab(1));
m=abs(x).^2-mean(abs(x).^2); [Pm,fm]=pwelch(m,hann(8192),4096,8192,fs,'onesided'); rng=fm>4e4&fm<9e5; [~,ix]=max(Pm.*rng);
fprintf('%-28s occ-BW=%.0f kHz  symbol-line=%.1f kHz\n',lbl,bw/1e3,fm(ix)/1e3);
end
