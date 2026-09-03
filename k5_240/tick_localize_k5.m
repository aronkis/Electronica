function R = tick_localize_k5(huntdir, evn)
% tick_localize_k5  Fine RF-trajectory analysis of one hunt event's INPUT
% window around its trigger: per-frame preamble phase, amplitude, and timing
% position, cross-referenced with which frames the LIVE constellation
% (tap window) lost/errored.
%   TX-side tick artifact  -> a step/transient in the INPUT phase/amp/timing
%                             trajectory at the episode instant
%   RX-fabric disturbance  -> live errors with NO feature in the input
%
% Usage: R = tick_localize_k5('/path/to/hunt/20260712_..._fwd', 1);

d=dir(fullfile(huntdir,sprintf('ev%d_seq*.iq',evn)));
names={d.name}; inp=names(~contains(names,'_tap'));
assert(~isempty(inp),'no ev%d input window',evn);
tok=regexp(inp{1},'ev\d+_seq(\d+)\.iq','tokens','once'); trig=str2double(tok{1});
capfile=fullfile(huntdir,inp{1});

repo='/home/tcollins/dev/qpsk_ai/TransceiverToolbox';
if exist(fullfile(repo,'setup.m'),'file'), run(fullfile(repo,'setup.m')); addpath(repo); end
addpath(fullfile(repo,'trx_examples','targeting','QPSKTxRxHDLExample'));
C=commhdlQPSKTxRxParameters(); preSyms=C.preambleSymbols(:);
nPre=numel(preSyms); paySyms=C.DataBitsPerPacket/2; frameLenSym=nPre+paySyms;
sps=8; RRC=rcosdesign(0.5,4,sps); Rsym=240e3;

fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); nn=min(numel(I),numel(Q));
iq=double(I(1:nn))+1i*double(Q(1:nn));
x=iq(:)/rms(abs(iq)); mf=conv(x,RRC,'same');

% coarse CFO (4th power) then locate frames by preamble in the SAMPLE domain
s=mf./(abs(mf)+eps); N=min(2^19,numel(s)); w=s(1:N).^4;
W=fftshift(abs(fft(w.*hann(N)))); fax=linspace(-sps*Rsym/2,sps*Rsym/2,N);
mask=abs(fax)<=4*15e3; W(~mask)=0; [~,k]=max(W); f4=fax(k)/4;
mfc=mf.*exp(-1i*2*pi*f4/(sps*Rsym)*(0:numel(mf)-1).');
% upsampled preamble template at sps
pt=zeros(nPre*sps,1); pt(1:sps:end)=preSyms;
cc=conv(mfc,conj(flipud(pt)));
frameLen=frameLenSym*sps;
[pk,loc]=findpeaks(abs(cc)/max(abs(cc)),'MinPeakHeight',0.4,'MinPeakDistance',round(0.9*frameLen));
st=loc-nPre*sps+1;
keep=st>=1 & st+frameLen-1<=numel(mfc); st=st(keep); pk=pk(keep);
nF=numel(st);
fprintf('[tick] ev%d trigger=%d: %d frames located, CFO=%.0f Hz\n',evn,trig,nF,f4);

% per-frame preamble metrics in the SAMPLE domain
ph=zeros(nF,1); am=zeros(nF,1); tres=zeros(nF,1);
for k2=1:nF
  seg=mfc(st(k2):sps:st(k2)+nPre*sps-1);
  Z=sum(seg.*conj(preSyms));
  ph(k2)=angle(Z); am(k2)=abs(Z)/nPre;
  % timing residual: parabolic interp of |cc| peak around loc
  L=loc(k2);
  if L>1 && L<numel(cc)
    y1=abs(cc(L-1)); y2=abs(cc(L)); y3=abs(cc(L+1));
    den=(y1-2*y2+y3); if den~=0, tres(k2)=0.5*(y1-y3)/den; end
  end
end
phu=unwrap(ph);
% frame-to-frame deltas (episode signature = outlier step)
dph=[0; diff(phu)]; dam=[0; diff(am)]; dst=[0; diff(st)]-frameLen; dtr=[0; diff(tres)];

% map frames to seqs via the AIR decode (must exist from hunt_verdict run)
[cdir,cbn]=fileparts(capfile);
mfile=fullfile(cdir,[cbn '_decseq_k5.mat']);
seqs=nan(nF,1);
if exist(mfile,'file')
  L2=load(mfile); pf=L2.res.perFrame;
  % align counts (framePeaks in symbol domain ~ same frame set)
  m=min(nF,numel(pf)); seqs(1:m)=[pf(1:m).seq];
end
ktr=find(seqs==trig,1);
if isempty(ktr), [~,ktr]=min(abs((1:nF).'-nF/2)); fprintf('[tick] trigger seq not mapped; using window center\n'); end
lo=max(1,ktr-12); hi=min(nF,ktr+12);
fprintf(' frame   seq      dPhase(rad)  dAmp     dTiming(samp)  spacing-err\n');
for k2=lo:hi
  mark=' '; if k2==ktr, mark='*'; end
  fprintf('%s %4d  %8.0f   %+8.4f  %+7.3f   %+8.3f      %+6.0f\n',mark,k2,seqs(k2),dph(k2),dam(k2),dtr(k2),dst(k2));
end
% robust outlier stats: episode step vs window baseline
base=setdiff(1:nF,lo:hi);
madn=@(v) median(abs(v-median(v)))*1.4826;
zs=@(v,idx) (v(idx)-median(v(base)))/max(madn(v(base)),eps);
fprintf('[tick] trigger z-scores: dPhase=%.1f dAmp=%.1f dTiming=%.1f\n',...
  zs(dph,ktr),zs(dam,ktr),zs(dtr,ktr));
R=struct('ev',evn,'trig',trig,'seqs',seqs,'ph',phu,'am',am,'tres',tres,'st',st,...
  'dph',dph,'dam',dam,'dtr',dtr,'ktr',ktr,'cfo',f4);
save(fullfile(huntdir,sprintf('ev%d_tickloc.mat',evn)),'R','-v7.3');
end
