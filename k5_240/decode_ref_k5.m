function res = decode_ref_k5(capfile, varargin)
% decode_ref_k5  IDEAL float receiver that decodes a K5/240k byte-link capture and
% scores the decoded info bits against the -B REFERENCE (first 1024 info bits =
% the 128-byte byte-RX packet), instead of the ROM golden. Adapted verbatim in the
% front-end from the proven soak_decode_k5.m (which scores 220/220 on clean golden
% captures). Purpose (Phase 1a of the error-source analysis): does an IDEAL receiver
% ALSO floor at ~1.9e-3 on the SAME captured samples that the hardware floored on?
%   BER ~ 1.9e-3  => impairment is in the captured samples (channel/LO), decode-independent.
%   BER << 1.9e-3 => the deployed fixed-point decode/loop is the bottleneck.
%
% HW-faithful quadrant handling: the QPSK 4-fold (x I/Q-swap = 8-fold) ambiguity is
% resolved ONCE, GLOBALLY, from the cleanest frames (the in-fabric HW resolver locks
% once and holds), then that fixed hypothesis is applied to EVERY frame. A per-frame
% best-quadrant BER is also reported (optimistic bound) so the phase-slip contribution
% is visible.
%
% Usage:
%   decode_ref_k5('/mnt/onetb/scratch/qpsk_variants/two_jup/floorcap/floor_148.iq')
%   decode_ref_k5(file,'label','floorA','bitorder','msb','perframebest',true)
%
% Self-validating: if the reference / byte-bit order is correct, a flooring -B capture
% decodes to roughly the HW CLEAN% (~71%); a wrong reference yields ~0% clean.

p=inputParser;
p.addParameter('label','',@(x)ischar(x)||isstring(x));
p.addParameter('bitorder','msb',@(x)ischar(x)||isstring(x));   % byte->infobit order
p.addParameter('perframebest',false,@islogical);               % also report optimistic per-frame-best quadrant BER
p.addParameter('ncleanresolve',24,@isnumeric);                 % #cleanest frames used for global quadrant resolve
p.addParameter('refwords',{},@iscell);                         % override 16 -B words (hex strings); default below
% --- stage-ablation flags: turn OFF a float stage the fixed-point HW may lack, to
%     find WHICH capability recovers the 20%-EVM capture (models the error source) ---
p.addParameter('nocfo',false,@islogical);                      % skip 4th-power/preamble block CFO
p.addParameter('nocarrier',false,@islogical);                  % skip the ideal carrier-sync PLL (continuous tracking)
p.addParameter('nopreamphase',false,@islogical);               % skip per-frame preamble phase re-derotation
p.addParameter('loopbw',0.01,@isnumeric);                      % carrier-sync normalized loop bandwidth
p.addParameter('cfomax',15e3,@isnumeric);                      % coarse-CFO search half-range, Hz. Quiet pair
                                                               % runs NOMINAL LOs (~4.7 kHz XO offset) -- the
                                                               % legacy hardwired 5e3 sat AT that edge and could
                                                               % silently zero the estimate (false channel-limited).
p.parse(varargin{:});
label=char(p.Results.label); bitorder=lower(char(p.Results.bitorder));
doPFB=p.Results.perframebest; nCleanRes=round(p.Results.ncleanresolve);
noCFO=p.Results.nocfo; noCarrier=p.Results.nocarrier; noPreamPhase=p.Results.nopreamphase;
loopBW=p.Results.loopbw; cfoMax=p.Results.cfomax;
if isempty(label), [~,label]=fileparts(capfile); end

%% ---- build the 1024-bit -B reference (info bits 0..1023) ----
% ref_dump output: 16 x uint64 LSB-byte-first; byte-RX packet = first 1024 info bits,
% MSB-first per byte (README_BYTE.md: golden 'ADI Hello World' MSB-first/char).
hw = p.Results.refwords;
if isempty(hw)
  hw = {'000001a500004b51','cb3a16fd6db8acfb','ea6bc16e6bd07d3c','d793ce81bbbc52a0', ...
        '0fefd06c2f9c2151','1eed942073f13df8','444c5c6d1ca9d87c','c84d6f58e5841102', ...
        '3335f92dc97e5aa1','96752cfa4ba38c01','d5d782ddd6a0fb78','ae279d037779a540', ...
        '1fdea1d95e3843a2','3cda2941e6e27bf0','8898b8da3852b1f9','919bdeb0ca092304'};
end
refbytes=zeros(128,1);
for w=1:16
  s=hw{w};                                  % 16 hex chars, big-endian; LSB byte = last pair
  for b=0:7, refbytes((w-1)*8+b+1)=hex2dec(s(15-2*b:16-2*b)); end
end
refbits=zeros(1024,1);
for i=1:128
  by=refbytes(i);
  for k=0:7
    if strcmp(bitorder,'msb'), refbits((i-1)*8+k+1)=bitget(by,8-k);   % MSB first
    else,                      refbits((i-1)*8+k+1)=bitget(by,k+1);   % LSB first
    end
  end
end
NREF=1024;

repo='/home/tcollins/dev/qpsk_ai/TransceiverToolbox';
if exist(fullfile(repo,'setup.m'),'file'), run(fullfile(repo,'setup.m')); addpath(repo); end
qdir=fullfile(repo,'trx_examples','targeting','QPSKTxRxHDLExample'); if exist(qdir,'dir'), addpath(qdir); end

%% ---- modem / FEC constants (identical to soak_decode_k5) ----
C=commhdlQPSKTxRxParameters();
preSyms=C.preambleSymbols(:);
DBPP=C.DataBitsPerPacket; paySyms=DBPP/2; nPre=numel(preSyms); frameLenSym=nPre+paySyms;
sps=8; RRC=rcosdesign(0.5,4,sps);
Fs=1.92e6; Rsym=240e3;
G=load(fullfile(fileparts(mfilename('fullpath')),'golden_k5.mat'));   % co-located in k5_240/
trellis=G.trellis; TB=G.TB; ROWS=G.ROWS; COLS=G.COLS;
INFO=1084; TAIL=4; CODED=2*(INFO+TAIL); NPAIR=CODED/2;
assert(CODED==2176 && ROWS==136 && COLS==16 && TB==25,'K5 contract constants mismatch');
deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR);

%% ---- read capture ----
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); nn=min(numel(I),numel(Q));
iq=double(I(1:nn))+1i*double(Q(1:nn)); iq=iq(abs(iq)>0); iq=iq/(max(abs(iq))+eps);
fprintf('[decref] %s (label %s): %d complex samples (~%.0f frames)\n',capfile,label,numel(iq),numel(iq)/sps/frameLenSym);

%% ---- front-end (verbatim from soak_decode_k5): timing, CFO, carrier sync, frame sync ----
x=iq(:)/rms(abs(iq)); mf=conv(x,RRC,'same');
ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
sy=ssy(mf); sy=sy(:)/rms(abs(sy)); sym0=sy*rms(abs(preSyms));
if noCFO
  fCoarse=0;
else
  f4=fourthPowerCFO(sym0,Rsym,cfoMax);
  if abs(f4)>0.9*cfoMax
    warning('decode_ref_k5:cfoEdge','4th-power CFO %.0f Hz is at the +-%.0f Hz mask edge -- raise ''cfomax''',f4,cfoMax);
  end
  sym1=sym0.*exp(-1i*2*pi*f4/Rsym*(0:numel(sym0)-1).');
  [psAll,~]=framePeaks(sym1,preSyms,nPre,frameLenSym);
  fRef=coarseCFO(sym1,psAll,preSyms,nPre,Rsym);
  % post-f4 preamble REFINE must be small; a big value means the estimator
  % latched non-carrier structure -- distrust it (and say so, never silently).
  if abs(fRef)>5e3, fprintf('[decref] preamble-refine %.0f Hz IMPLAUSIBLE -> ignored\n',fRef); fRef=0; end
  fCoarse=f4+fRef;
  fprintf('[decref] CFO breakdown: 4th-power=%.0f Hz + preamble-refine=%.0f Hz (search +-%.0f Hz)\n',f4,fRef,cfoMax);
end
symCFO=sym0.*exp(-1i*2*pi*fCoarse/Rsym*(0:numel(sym0)-1).');
if noCarrier
  symC=symCFO(:)/rms(abs(symCFO))*rms(abs(preSyms));
else
  csy=comm.CarrierSynchronizer('Modulation','QPSK','SamplesPerSymbol',1,'DampingFactor',1/sqrt(2),'NormalizedLoopBandwidth',loopBW);
  symC=csy(symCFO); symC=symC(:)/rms(abs(symC))*rms(abs(preSyms));
end
[ps0,~]=framePeaks(symC,preSyms,nPre,frameLenSym);
ps0=refineStarts(symC,ps0,preSyms,nPre,8);
nF=numel(ps0);
fprintf('[decref] coarse CFO=%.0f Hz ; framed %d candidates\n',fCoarse,nF);

%% ---- per-frame preamble derotation (constant phase) + preCorr ----
frInfo=struct('s0',{},'preCorr',{},'payD',{});
for k=1:nF
  s0=ps0(k);
  if s0<1 || s0+frameLenSym-1>numel(symC), continue; end
  fr=symC(s0:s0+frameLenSym-1); pre=fr(1:nPre);
  preCorr=abs(sum(pre.*conj(preSyms)))/(sum(abs(preSyms))+eps);
  Zc=sum(pre.*conj(preSyms)); r0=1; if ~noPreamPhase && abs(Zc)>0, r0=conj(Zc)/abs(Zc); end
  payD=fr(nPre+1:end)*r0;
  frInfo(end+1)=struct('s0',s0,'preCorr',preCorr,'payD',payD); %#ok<AGROW>
end
nF=numel(frInfo);
assert(nF>0,'no decodable frames');

%% ---- GLOBAL quadrant/swap resolution from the cleanest frames (lock once, hold) ----
% Model the HW resolver: choose the single (rot,swap) that minimises total ref error
% over the cleanest frames, then apply it to EVERY frame.
pc=[frInfo.preCorr]; [~,ord]=sort(pc,'descend');
useIdx=ord(1:min(nCleanRes,nF));
hyps=[]; for rr=[0 90 180 270], for sw=[false true], hyps=[hyps; rr sw]; end, end %#ok<AGROW>
htot=zeros(size(hyps,1),1);
for h=1:size(hyps,1)
  rr=hyps(h,1); sw=hyps(h,2); e=0;
  for j=useIdx
    dec=demodDecode(frInfo(j).payD,rr,sw,CODED,deintIdx,trellis,NPAIR,TB);
    e=e+sum(dec(TB+1:TB+NREF)~=refbits);
  end
  htot(h)=e;
end
[~,hb]=min(htot); gRot=hyps(hb,1); gSwap=logical(hyps(hb,2));
fprintf('[decref] GLOBAL hypothesis: rot=%d swap=%d (resolved on %d cleanest frames; err/hyp=[%s])\n',...
  gRot,gSwap,numel(useIdx),num2str(htot(:).',' %d'));

%% ---- score EVERY frame under the fixed global hypothesis ----
NOISY_FRAC=0.10; PHASE_FRAC=0.35;
per_bit=zeros(NREF,1); per_byte=zeros(128,1); burst_hist=zeros(65,1);
bucket=zeros(1,5);  % CLEAN NOISY PHASE ROTATED(n/a here) MISS
frameBER=zeros(nF,1); frameErr=zeros(nF,1); frameValid=false(nF,1);
totErr=0; totBits=0; nClean=0; totErrPFB=0; totBitsPFB=0; evm_acc=[];
for k=1:nF
  dec=demodDecode(frInfo(k).payD,gRot,gSwap,CODED,deintIdx,trellis,NPAIR,TB);
  db=dec(TB+1:TB+NREF); err=(db~=refbits); ne=sum(err); frac=ne/NREF;
  % residual payload EVM under the fixed global hypothesis (proves the capture
  % actually carries the impairment: a flooring capture reads ~20%, a clean ~7%)
  if frac<PHASE_FRAC
    sd=frInfo(k).payD*exp(-1i*deg2rad(gRot)); sd=sd(:); sd=sd/sqrt(mean(abs(sd).^2));
    qk=round((angle(sd)-pi/4)/(pi/2)); ide=exp(1i*(pi/4+qk*(pi/2)));
    evm_acc=[evm_acc; abs(sd-ide)]; %#ok<AGROW>
  end
  frameErr(k)=ne; frameBER(k)=frac; valid=frInfo(k).preCorr>0.5; frameValid(k)=valid;
  if ne==0, bucket(1)=bucket(1)+1; nClean=nClean+1;
  elseif frac<NOISY_FRAC, bucket(2)=bucket(2)+1;
  elseif frac>=PHASE_FRAC, bucket(3)=bucket(3)+1;
  else, bucket(5)=bucket(5)+1; end
  % BER numerator/denominator = CLEAN + NOISY frames (frac<PHASE_FRAC and not gross)
  if frac<PHASE_FRAC
    totErr=totErr+ne; totBits=totBits+NREF;
    per_bit=per_bit+err;
    for i=1:128, per_byte(i)=per_byte(i)+sum(err((i-1)*8+1:i*8)); end
    % burst run-length hist over the 1024-bit frame
    r=0; for b=1:NREF, if err(b), r=r+1; else, if r>0, bi=min(r,64); burst_hist(bi)=burst_hist(bi)+1; end, r=0; end, end
    if r>0, bi=min(r,64); burst_hist(bi)=burst_hist(bi)+1; end
  end
  % optional optimistic per-frame-best quadrant BER
  if doPFB
    be=ne;
    for h=1:size(hyps,1)
      d2=demodDecode(frInfo(k).payD,hyps(h,1),logical(hyps(h,2)),CODED,deintIdx,trellis,NPAIR,TB);
      e2=sum(d2(TB+1:TB+NREF)~=refbits); if e2<be, be=e2; end
    end
    totErrPFB=totErrPFB+be; totBitsPFB=totBitsPFB+NREF;
  end
end

%% ---- aggregate ----
BER=totErr/max(totBits,1);
[~,wi]=max(frameErr); ssErr=totErr; ssBits=totBits;
if frameBER(wi)<PHASE_FRAC, ssErr=totErr-frameErr(wi); ssBits=totBits-NREF; end
BER_ss=ssErr/max(ssBits,1);
pctClean=100*nClean/max(nF,1);
alignedFrames=bucket(1)+bucket(2);
payEVM=100*sqrt(mean(evm_acc.^2));   % residual payload EVM (%) over aligned frames

fprintf('[decref] %s: frames=%d  CLEAN=%d(%.1f%%) NOISY=%d(%.1f%%) PHASE=%d(%.1f%%) MISS=%d(%.1f%%)\n',...
  label,nF,bucket(1),100*bucket(1)/nF,bucket(2),100*bucket(2)/nF,bucket(3),100*bucket(3)/nF,bucket(5),100*bucket(5)/nF);
fprintf('[decref] %s: aligned(CLEAN+NOISY)=%d  totBits=%d  bitErr=%d  BER=%.3e  BER_ss=%.3e\n',...
  label,alignedFrames,totBits,totErr,BER,BER_ss);
if doPFB
  fprintf('[decref] %s: per-frame-best(optimistic) BER=%.3e over %d bits\n',label,totErrPFB/max(totBitsPFB,1),totBitsPFB);
end
% per-offset summary
[mxb, mxi]=max(per_byte);
fprintf('[decref] %s: per-byte map: max=%d @byte%d  mean=%.2f  std=%.2f  (uniform<->spiky)\n',...
  label,mxb,mxi-1,mean(per_byte),std(per_byte));
fprintf('[decref] %s: residual payload EVM=%.1f%% (aligned frames)  <- impairment actually present in capture\n',label,payEVM);

%% ---- save ----
[cdir,cbn]=fileparts(capfile); matout=fullfile(cdir,[cbn '_decref_k5.mat']);
res=struct('capfile',capfile,'label',label,'nFrames',nF,'bucket',bucket,'pctClean',pctClean,...
  'totBits',totBits,'totErr',totErr,'BER',BER,'BER_ss',BER_ss,'gRot',gRot,'gSwap',gSwap,...
  'per_bit',per_bit,'per_byte',per_byte,'burst_hist',burst_hist,'frameBER',frameBER,...
  'frameErr',frameErr,'frameValid',frameValid,'coarseCFO',fCoarse,'refbits',refbits,'bitorder',bitorder,'payEVM',payEVM);
if doPFB, res.BER_pfb=totErrPFB/max(totBitsPFB,1); end
save(matout,'res','-v7.3');
fprintf('[decref] saved %s\n',matout);
end

%% ====================== helpers ======================
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
mask=abs(fax)<=4*cfomax; W(~mask)=0;   % 4th-power line sits at 4x the CFO
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
