function res = hybrid_ladder_k5(tapsprefix, varargin)
% hybrid_ladder_k5  P3 localization: the HYBRID DECODE LADDER.
%
% Each rung decodes a FIXED-POINT stage tap stream (from sim_byte_taps /
% wrap_byte_taps) with the FLOAT remainder of the receive chain, scoring the
% decoded info bits against the known -B reference. Rungs, ordered by how much
% of the fixed chain is kept:
%
%   agc  fixed AGC out           -> float RRC MF + sym-sync + CFO + PLL + frame + FEC
%   rrc  fixed AGC+RRC out       -> float        sym-sync + CFO + PLL + frame + FEC
%   ss   fixed ...sym-sync out   -> float                   CFO + PLL + frame + FEC
%   cfc  fixed ...CFC out        -> float                         PLL + frame + FEC
%   cs   fixed ...carrier out    -> float                               frame + FEC
%   pa   fixed ...resolver out   -> float                               frame + FEC
%   con  fixed constellation     -> float demod+FEC only (stream is payload-only,
%                                   1120 sym/frame, framed by construction)
%
% BER is ~monotone along the ladder; the first rung where errors appear
% brackets the stage that destroys the margin (float full-chain = BER 0 on the
% campaign captures; fixed full-chain = the replayed BER). Per-rung per-byte
% error maps localize WHICH payload content fails (live hotspot = bytes 21-22).
%
% Usage:
%   hybrid_ladder_k5('<...>/replay/floor_148/taps/t')
%   hybrid_ladder_k5(prefix,'rungs',{'con','cs'},'loopbw',0.01)
%
% Front-end/scoring is functionally identical to decode_ref_k5.m (same helpers,
% same global-quadrant resolution, same CLEAN/NOISY/PHASE/MISS thresholds).

p=inputParser;
p.addParameter('rungs',{'con','pa','cs','cfc','ss','rrc','agc'},@iscell);
p.addParameter('bitorder','msb',@(x)ischar(x)||isstring(x));
p.addParameter('ncleanresolve',24,@isnumeric);
p.addParameter('refwords',{},@iscell);
p.addParameter('loopbw',0.01,@isnumeric);
p.addParameter('cfomax',15e3,@isnumeric);
p.parse(varargin{:});
rungs=p.Results.rungs; bitorder=lower(char(p.Results.bitorder));
nCleanRes=round(p.Results.ncleanresolve); loopBW=p.Results.loopbw; cfoMax=p.Results.cfomax;

%% ---- -B reference bits (identical to decode_ref_k5) ----
hw = p.Results.refwords;
if isempty(hw)
  hw = {'000001a500004b51','cb3a16fd6db8acfb','ea6bc16e6bd07d3c','d793ce81bbbc52a0', ...
        '0fefd06c2f9c2151','1eed942073f13df8','444c5c6d1ca9d87c','c84d6f58e5841102', ...
        '3335f92dc97e5aa1','96752cfa4ba38c01','d5d782ddd6a0fb78','ae279d037779a540', ...
        '1fdea1d95e3843a2','3cda2941e6e27bf0','8898b8da3852b1f9','919bdeb0ca092304'};
end
refbytes=zeros(128,1);
for w=1:16
  s=hw{w};
  for b=0:7, refbytes((w-1)*8+b+1)=hex2dec(s(15-2*b:16-2*b)); end
end
refbits=zeros(1024,1);
for i=1:128
  by=refbytes(i);
  for k=0:7
    if strcmp(bitorder,'msb'), refbits((i-1)*8+k+1)=bitget(by,8-k);
    else,                      refbits((i-1)*8+k+1)=bitget(by,k+1);
    end
  end
end
NREF=1024;

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
assert(CODED==2176 && ROWS==136 && COLS==16 && TB==25,'K5 contract constants mismatch');
deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR);

%% ---- rung configs: which float stages run on top of the fixed prefix ----
% file, columns, domain: samp (8 sps) | sym (symbol stream) | framed (1120/frame)
cfgs = struct( ...
  'agc', struct('file','agc','dom','samp','mf',true, 'cfo',true, 'pll',true ), ...
  'rrc', struct('file','rrc','dom','samp','mf',false,'cfo',true, 'pll',true ), ...
  'ss',  struct('file','ss', 'dom','sym', 'mf',false,'cfo',true, 'pll',true ), ...
  'cfc', struct('file','cfc','dom','sym', 'mf',false,'cfo',false,'pll',true ), ...
  'cs',  struct('file','cs', 'dom','sym', 'mf',false,'cfo',false,'pll',false), ...
  'pa',  struct('file','pa', 'dom','sym', 'mf',false,'cfo',false,'pll',false), ...
  'con', struct('file','con','dom','framed','mf',false,'cfo',false,'pll',false));

fprintf('=== hybrid ladder: %s ===\n', tapsprefix);
res=struct('rung',{},'BER',{},'bitErr',{},'totBits',{},'nFrames',{},'bucket',{},'per_byte',{},'gRot',{},'gSwap',{},'fCoarse',{});
for r=1:numel(rungs)
  rg=rungs{r}; cfg=cfgs.(rg);
  fn=sprintf('%s_%s.txt',tapsprefix,cfg.file);
  if ~exist(fn,'file'), fprintf('[%-3s] SKIP (no %s)\n',rg,fn); continue; end
  M=readmatrix(fn);
  z=complex(M(:,1),M(:,2));

  if strcmp(cfg.dom,'framed')
    % constellation tap: payload-only, contiguous 1120-symbol frames
    nF=floor(numel(z)/paySyms);
    payD=reshape(z(1:nF*paySyms),paySyms,nF);
    frInfo=struct('payD',{},'preCorr',{});
    for k=1:nF, frInfo(k)=struct('payD',payD(:,k)/ (rms(abs(payD(:,k)))+eps)*rms(abs(preSyms)),'preCorr',1); end
    fCoarse=0;
  else
    if strcmp(cfg.dom,'samp')
      x=z/(max(abs(z))+eps); x=x(:)/rms(abs(x));
      if cfg.mf, x=conv(x,RRC,'same'); end
      ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
      sy=ssy(x);
    else
      sy=z;
    end
    sy=sy(:)/rms(abs(sy)); sym0=sy*rms(abs(preSyms));
    if cfg.cfo
      f4=fourthPowerCFO(sym0,Rsym,cfoMax);
      sym1=sym0.*exp(-1i*2*pi*f4/Rsym*(0:numel(sym0)-1).');
      [psAll,~]=framePeaks(sym1,preSyms,nPre,frameLenSym);
      fRef=coarseCFO(sym1,psAll,preSyms,nPre,Rsym);
      if abs(fRef)>5e3, fRef=0; end
      fCoarse=f4+fRef;
    else
      fCoarse=0;
    end
    symCFO=sym0.*exp(-1i*2*pi*fCoarse/Rsym*(0:numel(sym0)-1).');
    if cfg.pll
      csy=comm.CarrierSynchronizer('Modulation','QPSK','SamplesPerSymbol',1,'DampingFactor',1/sqrt(2),'NormalizedLoopBandwidth',loopBW);
      symC=csy(symCFO); symC=symC(:)/rms(abs(symC))*rms(abs(preSyms));
    else
      symC=symCFO(:)/rms(abs(symCFO))*rms(abs(preSyms));
    end
    [ps0,~]=framePeaks(symC,preSyms,nPre,frameLenSym);
    ps0=refineStarts(symC,ps0,preSyms,nPre,8);
    frInfo=struct('payD',{},'preCorr',{});
    for k=1:numel(ps0)
      s0=ps0(k);
      if s0<1 || s0+frameLenSym-1>numel(symC), continue; end
      fr=symC(s0:s0+frameLenSym-1); pre=fr(1:nPre);
      preCorr=abs(sum(pre.*conj(preSyms)))/(sum(abs(preSyms))+eps);
      Zc=sum(pre.*conj(preSyms)); r0=1; if abs(Zc)>0, r0=conj(Zc)/abs(Zc); end
      frInfo(end+1)=struct('payD',fr(nPre+1:end)*r0,'preCorr',preCorr); %#ok<AGROW>
    end
  end
  nF=numel(frInfo);
  if nF==0, fprintf('[%-3s] NO FRAMES\n',rg); continue; end

  % global quadrant/swap resolve on the cleanest frames (as decode_ref_k5)
  pc=[frInfo.preCorr]; [~,ord]=sort(pc,'descend');
  useIdx=ord(1:min(nCleanRes,nF));
  hyps=[]; for rr=[0 90 180 270], for sw=[false true], hyps=[hyps; rr sw]; end, end %#ok<AGROW>
  htot=zeros(size(hyps,1),1);
  for h=1:size(hyps,1)
    e=0;
    for j=useIdx
      dec=demodDecode(frInfo(j).payD,hyps(h,1),logical(hyps(h,2)),CODED,deintIdx,trellis,NPAIR,TB);
      e=e+sum(dec(TB+1:TB+NREF)~=refbits);
    end
    htot(h)=e;
  end
  [~,hb]=min(htot); gRot=hyps(hb,1); gSwap=logical(hyps(hb,2));

  % score every frame under the global hypothesis
  NOISY_FRAC=0.10; PHASE_FRAC=0.35;
  per_byte=zeros(128,1); bucket=zeros(1,5);
  totErr=0; totBits=0;
  for k=1:nF
    dec=demodDecode(frInfo(k).payD,gRot,gSwap,CODED,deintIdx,trellis,NPAIR,TB);
    db=dec(TB+1:TB+NREF); err=(db~=refbits); ne=sum(err); frac=ne/NREF;
    if ne==0, bucket(1)=bucket(1)+1;
    elseif frac<NOISY_FRAC, bucket(2)=bucket(2)+1;
    elseif frac>=PHASE_FRAC, bucket(3)=bucket(3)+1;
    else, bucket(5)=bucket(5)+1; end
    if frac<PHASE_FRAC
      totErr=totErr+ne; totBits=totBits+NREF;
      for i=1:128, per_byte(i)=per_byte(i)+sum(err((i-1)*8+1:i*8)); end
    end
  end
  BER=totErr/max(totBits,1);
  [mx,mi]=maxk(per_byte,4);
  hot=sprintf('%d@%d ',[mx.'; mi.'-1]);
  fprintf('[%-3s] frames=%-3d CLEAN=%-3d NOISY=%-3d PHASE=%-3d MISS=%-3d  BER=%.3e  errs=%-4d  rot=%d swap=%d cfo=%.0f  hot(byte): %s\n', ...
    rg,nF,bucket(1),bucket(2),bucket(3),bucket(5),BER,totErr,gRot,gSwap,fCoarse,hot);
  res(end+1)=struct('rung',rg,'BER',BER,'bitErr',totErr,'totBits',totBits,'nFrames',nF, ...
    'bucket',bucket,'per_byte',per_byte,'gRot',gRot,'gSwap',gSwap,'fCoarse',fCoarse); %#ok<AGROW>
end
save([tapsprefix '_ladder.mat'],'res');
fprintf('saved %s_ladder.mat\n',tapsprefix);
end

%% ====================== helpers (verbatim from decode_ref_k5) ======================
function dec=demodDecode(payD,rr,sw,CODED,deintIdx,trellis,NPAIR,TB)
b=double(pskdemod(payD*exp(-1i*deg2rad(rr)),4,pi/4,'gray','OutputType','bit'));
v=b; if sw, t=reshape(v,2,[]); t=flipud(t); v=t(:); end
dec=viterbiDecode(v(1:CODED),deintIdx,trellis,NPAIR,TB);
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
