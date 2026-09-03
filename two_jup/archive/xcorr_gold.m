function xcorr_gold(capfile)
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
C=commhdlQPSKTxRxParameters(); pre=C.preambleSymbols(:);
rp=load('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt'); rp=rp(:,1)+1j*rp(:,2);
gold=[pre;rp]; sps=8; fs=1.92e6; h=rcosdesign(0.5,6,sps); h=h/sqrt(sum(h.^2));
gw=conv(upsample(gold,sps),h); gw=gw/rms(abs(gw));       % one golden frame waveform (RRC)
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end);Q=raw(2:2:end);n=min(numel(I),numel(Q));x=double(I(1:n))+1j*double(Q(1:n)); x=x(abs(x)>0); x=x/rms(abs(x));
% sweep CFO, cross-correlate the known golden frame waveform against the capture
bestpk=0; bestf=0;
for cf=-8000:250:8000
  gwc=gw.*exp(1j*2*pi*cf/fs*(0:numel(gw)-1).');
  c=abs(conv(x,conj(flipud(gwc))));
  pk=max(c)/(median(c)+1e-9);
  if pk>bestpk, bestpk=pk; bestf=cf; end
end
fprintf('%-22s : KNOWN-golden-frame xcorr peak/median=%.1f at CFO=%+dHz   [>~8 = golden frame PRESENT -> sync issue, not channel]\n',regexprep(capfile,'.*/',''),bestpk,bestf);
