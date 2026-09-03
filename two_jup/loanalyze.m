function loanalyze(f,lbl)
fs=1.92e6;
fid=fopen(f); raw=fread(fid,Inf,'int16'); fclose(fid); x=double(raw(1:2:end))+1j*double(raw(2:2:end)); x=x(abs(x)>0); x=x-mean(x);
[P,ff]=pwelch(x,hann(4096),2048,4096,fs,'centered');
% energy centroid of the occupied band (robust center)
Pn=P/sum(P); cen=sum(ff.*Pn);
[~,ix]=max(P); pk=ff(ix);
% occupied bw (-10dB)
Pd=10*log10(P/max(P)); ab=find(Pd>-10); bw=ff(ab(end))-ff(ab(1));
fprintf('%-20s signal peak=%+.0f kHz  centroid=%+.0f kHz  occBW=%.0f kHz  rms=%.0f\n',lbl,pk/1e3,cen/1e3,bw/1e3,rms(abs(x)));
end
