function res = decode_seq_k5(capfile, varargin)
% decode_seq_k5  Ideal FLOAT receiver + scorer for -S sequence-streaming
% captures (the -S analog of decode_ref_k5): every frame's reference is
% REGENERATED from its sequence number, so the decoder both scores bit errors
% AND identifies every frame (seq) -- the offline half of the loss-proof
% accounting and the frame locator for error-triggered ring saves.
%
% Front-end identical to decode_ref_k5 (RRC MF, Gardner comm.SymbolSynchronizer,
% 4th-power CFO [cfomax], comm.CarrierSynchronizer, Barker frame sync, per-frame
% preamble derotation). Quadrant/swap resolved GLOBALLY by CRC: the hypothesis
% under which decoded frames CRC-check is the right one.
%
% Wire format regenerated bit-exactly from host/{qpsk_frame.c,qpsk_seq.c}:
%   [0..1] magic 'QK'  [2..3] len=64 LE  [4..7] seq LE  [8..11] CRC32(zlib,
%   header+payload, CRC field zeroed)  [12..75] xorshift32(seq) payload
%   [76..127] PN9(x^9+x^5+1, seed=seq&0x1FF) padding (not CRC'd, still scored
%   as wire bits). Whitener assumed OFF (QPSK_WHITEN unset in -S runs).
%
% res.perFrame: seq, errs, crcok, class(OK/BITERR/JUNK/DUP), s0 (symbol-domain
% frame start; raw-sample offset ~ (s0-1)*8), for locate-by-seq.
%
% Usage: decode_seq_k5('win.iq')
%        decode_seq_k5(f,'cfomax',15e3,'ncleanresolve',24,'label','hunt1')

p=inputParser;
p.addParameter('label','',@(x)ischar(x)||isstring(x));
p.addParameter('ncleanresolve',24,@isnumeric);
p.addParameter('loopbw',0.01,@isnumeric);
p.addParameter('cfomax',15e3,@isnumeric);
p.parse(varargin{:});
label=char(p.Results.label); nCleanRes=round(p.Results.ncleanresolve);
loopBW=p.Results.loopbw; cfoMax=p.Results.cfomax;
if isempty(label), [~,label]=fileparts(capfile); end

repo='/home/tcollins/dev/qpsk_ai/TransceiverToolbox';
if exist(fullfile(repo,'setup.m'),'file'), run(fullfile(repo,'setup.m')); addpath(repo); end
qdir=fullfile(repo,'trx_examples','targeting','QPSKTxRxHDLExample'); if exist(qdir,'dir'), addpath(qdir); end

C=commhdlQPSKTxRxParameters();
preSyms=C.preambleSymbols(:);
DBPP=C.DataBitsPerPacket; paySyms=DBPP/2; nPre=numel(preSyms); frameLenSym=nPre+paySyms;
sps=8; RRC=rcosdesign(0.5,4,sps); Rsym=240e3;
G=load(fullfile(fileparts(mfilename('fullpath')),'golden_k5.mat'));
trellis=G.trellis; TB=G.TB; ROWS=G.ROWS; COLS=G.COLS;
INFO=1084; TAIL=4; CODED=2*(INFO+TAIL); NPAIR=CODED/2; %#ok<NASGU>
assert(CODED==2176 && ROWS==136 && COLS==16 && TB==25,'K5 contract mismatch');
deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR);
PKT=128; NREF=PKT*8;

%% ---- read capture + front-end (verbatim decode_ref_k5) ----
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); nn=min(numel(I),numel(Q));
iq=double(I(1:nn))+1i*double(Q(1:nn)); iq=iq(abs(iq)>0); iq=iq/(max(abs(iq))+eps);
fprintf('[decseq] %s (%s): %d complex samples (~%.0f frames)\n',capfile,label,numel(iq),numel(iq)/sps/frameLenSym);
x=iq(:)/rms(abs(iq)); mf=conv(x,RRC,'same');
ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
sy=ssy(mf); sy=sy(:)/rms(abs(sy)); sym0=sy*rms(abs(preSyms));
f4=fourthPowerCFO(sym0,Rsym,cfoMax);
sym1=sym0.*exp(-1i*2*pi*f4/Rsym*(0:numel(sym0)-1).');
[psAll,~]=framePeaks(sym1,preSyms,nPre,frameLenSym);
fRef=coarseCFO(sym1,psAll,preSyms,nPre,Rsym);
if abs(fRef)>5e3, fprintf('[decseq] refine %.0f Hz implausible -> 0\n',fRef); fRef=0; end
fCoarse=f4+fRef;
symCFO=sym0.*exp(-1i*2*pi*fCoarse/Rsym*(0:numel(sym0)-1).');
csy=comm.CarrierSynchronizer('Modulation','QPSK','SamplesPerSymbol',1,'DampingFactor',1/sqrt(2),'NormalizedLoopBandwidth',loopBW);
symC=csy(symCFO); symC=symC(:)/rms(abs(symC))*rms(abs(preSyms));
[ps0,~]=framePeaks(symC,preSyms,nPre,frameLenSym);
ps0=refineStarts(symC,ps0,preSyms,nPre,8);
frInfo=struct('s0',{},'preCorr',{},'payD',{});
for k=1:numel(ps0)
  s0=ps0(k);
  if s0<1 || s0+frameLenSym-1>numel(symC), continue; end
  fr=symC(s0:s0+frameLenSym-1); pre=fr(1:nPre);
  preCorr=abs(sum(pre.*conj(preSyms)))/(sum(abs(preSyms))+eps);
  Zc=sum(pre.*conj(preSyms)); r0=1; if abs(Zc)>0, r0=conj(Zc)/abs(Zc); end
  frInfo(end+1)=struct('s0',s0,'preCorr',preCorr,'payD',fr(nPre+1:end)*r0); %#ok<AGROW>
end
nF=numel(frInfo);
assert(nF>0,'no frames');
fprintf('[decseq] CFO=%.0f Hz, framed %d\n',fCoarse,nF);

%% ---- global quadrant/swap resolve BY CRC on the cleanest frames ----
pc=[frInfo.preCorr]; [~,ord]=sort(pc,'descend');
useIdx=ord(1:min(nCleanRes,nF));
hyps=[]; for rr=[0 90 180 270], for sw=[false true], hyps=[hyps; rr sw]; end, end %#ok<AGROW>
hcrc=zeros(size(hyps,1),1);
for h=1:size(hyps,1)
  for j=useIdx
    by=decodeBytes(frInfo(j).payD,hyps(h,1),logical(hyps(h,2)),CODED,deintIdx,trellis,NPAIR,TB,PKT);
    if crcok(by), hcrc(h)=hcrc(h)+1; end
  end
end
[nbest,hb]=max(hcrc); gRot=hyps(hb,1); gSwap=logical(hyps(hb,2));
fprintf('[decseq] hypothesis rot=%d swap=%d (CRC passes %d/%d resolve frames; all=[%s])\n',...
  gRot,gSwap,nbest,numel(useIdx),num2str(hcrc.'));
assert(nbest>0,'no hypothesis CRC-checks -- capture/decoder mismatch');

%% ---- per-frame score with regenerated references ----
perFrame=struct('seq',{},'errs',{},'crcok',{},'class',{},'s0',{});
ok=0; biterr=0; junk=0; dup=0; lost=0; lostev=0;
totBits=0; totErr=0; per_byte=zeros(PKT,1);
nextExpect=[]; firstSeq=[];
for k=1:nF
  by=decodeBytes(frInfo(k).payD,gRot,gSwap,CODED,deintIdx,trellis,NPAIR,TB,PKT);
  s0=frInfo(k).s0; cls='JUNK'; errs=NaN; seq=NaN; cok=false;
  if crcok(by)
    cok=true; seq=double(by(5))+256*double(by(6))+65536*double(by(7))+16777216*double(by(8));
    errs=0;
  else
    seqr=double(by(5))+256*double(by(6))+65536*double(by(7))+16777216*double(by(8));
    cand=[];
    if ~isempty(nextExpect)
      d=seqr-nextExpect;
      if d>=0 && d<64, cand=seqr; end
      if isempty(cand), cand=nextExpect; end
    end
    if ~isempty(cand)
      exp1=seqFrameBytes(cand,PKT);
      e=sum(sum(dec2bin(bitxor(by,exp1),8)=='1'));
      if e < 0.35*NREF, seq=cand; errs=e; end
    end
  end
  if ~isnan(seq)
    if isempty(nextExpect), firstSeq=seq; nextExpect=seq; end
    if seq<nextExpect
      dup=dup+1; cls='DUP';
    else
      if seq>nextExpect, lost=lost+seq-nextExpect; lostev=lostev+1; end
      totBits=totBits+NREF; totErr=totErr+errs;
      if errs>0
        biterr=biterr+1; cls='BITERR';
        exp1=seqFrameBytes(seq,PKT);
        eb=bitxor(by,exp1);
        for i=1:PKT, per_byte(i)=per_byte(i)+sum(dec2bin(eb(i),8)=='1'); end
      else
        ok=ok+1; cls='OK';
      end
      nextExpect=seq+1;
    end
  else
    junk=junk+1;
  end
  perFrame(end+1)=struct('seq',seq,'errs',errs,'crcok',cok,'class',cls,'s0',s0); %#ok<AGROW>
end
BER=totErr/max(totBits,1);
fprintf('[decseq] %s: frames=%d OK=%d BITERR=%d LOST=%d(%d gaps) DUP=%d JUNK=%d\n',...
  label,nF,ok,biterr,lost,lostev,dup,junk);
fprintf('[decseq] %s: bits=%d errs=%d BER=%.3e ; span=%d accounted=%d\n',...
  label,totBits,totErr,BER,...
  double(~isempty(nextExpect))*(nextExpect-firstSeq),ok+biterr+lost);
[mx,mi]=maxk(per_byte,4);
if any(mx), fprintf('[decseq] hot bytes: %s\n',sprintf('%d@%d ',[mx.'; mi.'-1])); end

res=struct('capfile',capfile,'label',label,'nFrames',nF,'ok',ok,'biterr',biterr,...
  'lost',lost,'lost_events',lostev,'dup',dup,'junk',junk,'totBits',totBits,...
  'totErr',totErr,'BER',BER,'gRot',gRot,'gSwap',gSwap,'coarseCFO',fCoarse,...
  'per_byte',per_byte,'perFrame',perFrame,'firstSeq',firstSeq,'nextExpect',nextExpect);
[cdir,cbn]=fileparts(capfile);
save(fullfile(cdir,[cbn '_decseq_k5.mat']),'res','-v7.3');
end

%% ============ wire-format regeneration (bit-exact vs host) ============
function by=seqFrameBytes(seq,PKT)
% full 128-byte wire frame for seq: header + xorshift32 payload + CRC + PN9 pad
LEN=64;
by=zeros(PKT,1);
by(1)=hex2dec('51'); by(2)=hex2dec('4B');
by(3)=bitand(LEN,255); by(4)=bitshift(LEN,-8);
by(5)=bitand(seq,255); by(6)=bitand(bitshift(seq,-8),255);
by(7)=bitand(bitshift(seq,-16),255); by(8)=bitand(bitshift(seq,-24),255);
by(13:12+LEN)=seqPayload(LEN,seq);
by(12+LEN+1:PKT)=pn9(PKT-12-LEN,bitand(seq,511));
c=crc32z(by(1:12+LEN),[9 10 11 12]);
by(9)=bitand(c,255); by(10)=bitand(bitshift(c,-8),255);
by(11)=bitand(bitshift(c,-16),255); by(12)=bitand(bitshift(c,-24),255);
end

function pl=seqPayload(len,seq)
% xorshift32 keyed on seq (qpsk_seq_payload)
M=2^32;
x=bitxor(seq,hex2dec('9E3779B9')); if x==0, x=hex2dec('DEADBEEF'); end
pl=zeros(len,1);
for i=1:len
  x=bitand(bitxor(x,bitand(x*2^13,M-1)),M-1);
  x=bitxor(x,floor(x/2^17));
  x=bitand(bitxor(x,bitand(x*2^5,M-1)),M-1);
  pl(i)=bitand(x,255);
end
end

function b=pn9(n,seed)
% PN9 x^9+x^5+1 byte generator (qpsk_pn_fill)
s=bitand(seed,511); if s==0, s=511; end
b=zeros(n,1);
for i=1:n
  v=0;
  for k=1:8
    nb=bitand(bitxor(floor(s/256),floor(s/16)),1);
    s=bitand(s*2+nb,511);
    v=v*2+nb;
  end
  b(i)=v;
end
end

function c=crc32z(by,zeroIdx)
% zlib CRC32 (poly 0xEDB88320, init/final 0xFFFFFFFF); zeroIdx bytes read as 0
persistent tbl
if isempty(tbl)
  tbl=zeros(256,1);
  for i=0:255
    r=i;
    for k=1:8
      if bitand(r,1), r=bitxor(floor(r/2),hex2dec('EDB88320')); else, r=floor(r/2); end
    end
    tbl(i+1)=r;
  end
end
c=hex2dec('FFFFFFFF');
for i=1:numel(by)
  v=by(i); if any(i==zeroIdx), v=0; end
  c=bitxor(floor(c/256),tbl(bitand(bitxor(c,v),255)+1));
end
c=bitxor(c,hex2dec('FFFFFFFF'));
end

function tf=crcok(by)
c=crc32z(by(1:12+64),[9 10 11 12]);
rx=double(by(9))+256*double(by(10))+65536*double(by(11))+16777216*double(by(12));
tf=(c==rx) && by(1)==hex2dec('51') && by(2)==hex2dec('4B');
end

%% ============ demod/FEC + front-end helpers (verbatim decode_ref_k5) ============
function by=decodeBytes(payD,rr,sw,CODED,deintIdx,trellis,NPAIR,TB,PKT)
b=double(pskdemod(payD*exp(-1i*deg2rad(rr)),4,pi/4,'gray','OutputType','bit'));
v=b; if sw, t=reshape(v,2,[]); t=flipud(t); v=t(:); end
dec=viterbiDecode(v(1:CODED),deintIdx,trellis,NPAIR,TB);
db=dec(TB+1:TB+PKT*8);
by=zeros(PKT,1);
for i=1:PKT
  for k=0:7, by(i)=by(i)+db((i-1)*8+k+1)*2^(7-k); end   % MSB-first per byte
end
end
function [ps0,pkv]=framePeaks(sym,preSyms,nPre,frameLenSym)
sym=sym(:); dps=preSyms(2:end).*conj(preSyms(1:end-1)); dsy=sym(2:end).*conj(sym(1:end-1));
ccd=abs(conv(dsy,conj(flipud(dps)))); ccd=ccd/(max(ccd)+eps);
[pkv,pk]=findpeaks(ccd,'MinPeakHeight',0.4,'MinPeakDistance',round(0.6*frameLenSym));
ps0=pk-(nPre-2); keep=ps0>=1 & ps0+frameLenSym-1<=numel(sym); ps0=ps0(keep); pkv=pkv(keep);
end
function f=fourthPowerCFO(sym,Rsym,cfomax)
s=sym(:); s=s./(abs(s)+eps); N=min(2^18,numel(s)); w=s(1:N).^4;
W=fftshift(abs(fft(w.*hann(N)))); fax=linspace(-Rsym/2,Rsym/2,N);
mask=abs(fax)<=4*cfomax; W(~mask)=0;
[~,k]=max(W); f=fax(k)/4;
end
function f=coarseCFO(sym,ps0,preSyms,nPre,Rsym)
fs=[];
for ii=1:numel(ps0)
  s0=ps0(ii); if s0+nPre-1>numel(sym), continue; end
  z=sym(s0:s0+nPre-1).*conj(preSyms); dz=z(2:end).*conj(z(1:end-1)); fs(end+1)=angle(mean(dz))/(2*pi)*Rsym; %#ok<AGROW>
end
if isempty(fs), f=0; else, f=median(fs); end
end
function deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR)
deintIdx=zeros(CODED,1); for p=0:NPAIR-1, for j=0:1, rc=2*p+j; c=mod(rc,COLS); r=floor(rc/COLS); deintIdx(2*p+j+1)=c*ROWS+r; end, end
end
function dec=viterbiDecode(coded,deintIdx,trellis,NPAIR,TB)
d=coded(deintIdx+1); vd=comm.ViterbiDecoder(trellis,'InputFormat','Hard','TracebackDepth',TB,'TerminationMethod','Continuous','ResetInputPort',true);
dec=zeros(NPAIR,1); for k=1:NPAIR, dec(k)=vd(d(2*k-1:2*k),double(k==1)); end
end
function ps2=refineStarts(symC,starts,ps,nPre,win)
ps2=starts(:);
for i=1:numel(ps2), best=-1; bb=ps2(i);
  for o=-win:win, s=ps2(i)+o; if s<1||s+nPre-1>numel(symC),continue;end
    v=abs(sum(symC(s:s+nPre-1).*conj(ps))); if v>best,best=v;bb=s;end
  end
  ps2(i)=bb;
end
ps2=unique(ps2);
end
