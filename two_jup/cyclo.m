function cyclo()
fs=1.92e6;
files={'hostgold_nearend.iq','GOLDEN(known-good)'; 'txfix_nearend.iq','MODEM(txfix)'};
for k=1:size(files,1)
 fid=fopen(files{k,1},'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
 x=double(raw(1:2:end))+1j*double(raw(2:2:end)); x=x(abs(x)>0); x=x-mean(x); x=x/rms(abs(x));
 % Welch PSD (occupied bandwidth / RRC shape)
 [P,f]=pwelch(x,hann(4096),2048,4096,fs,'centered');
 Pn=10*log10(P/max(P));
 bw20=f(find(Pn>-20,1,'last'))-f(find(Pn>-20,1,'first'));   % -20dB bandwidth
 % cyclostationary: symbol-rate line in PSD of |x|^2 (remove mean)
 m=abs(x).^2; m=m-mean(m);
 [Pm,fm]=pwelch(m,hann(8192),4096,8192,fs,'onesided');
 % search for a discrete line in [150k, 400k] (240k expected)
 band=fm>1.5e5 & fm<4.0e5; [pk,ix]=max(Pm.*band); fline=fm(ix);
 med=median(Pm(band)); prom=10*log10(pk/med);
 % also 4th power for a residual carrier/rate check
 fprintf('%-22s  occ-BW(-20dB)=%.0f kHz   |x|^2 symbol-line @ %.1f kHz (prom %.1f dB)\n', files{k,2}, bw20/1e3, fline/1e3, prom);
end
fprintf('(RRC beta=0.5, 240ksym -> occ-BW ~360kHz, symbol line @ 240kHz expected)\n');
end
