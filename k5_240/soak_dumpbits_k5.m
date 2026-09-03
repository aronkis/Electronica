function [res,DUMP]=soak_dumpbits_k5(capfile,varargin)
DUMP=struct("info",{{}},"coded",{{}},"cap",{{}});
% soak_decode_k5  Hardened, parameterized per-frame FEC decoder for the 240k/K5
% link captures (K=5 [35 23], 240 ksym at 8 sps / 1.92 MHz). Adapted from the
% proven /mnt/onetb/scratch/linkA_iq/soak_decode.m (K=7 / 480 ksym / 4 sps).
% Reads an int16 I,Q capture, decodes every 1133-sym frame (= 9064 samples at
% 8 sps) with a HARDENED per-frame demod (per-frame CFO estimate from the
% preamble, all-4-quadrant x I/Q-swap phase resolution picking the
% Viterbi-to-golden / lowest-info-error hypothesis, robust timing + per-frame
% start refinement), and reports the aggregate + steady-state coded BER.
% Saves per-frame results to <cap>_soakres_k5.mat and appends a CSV row.
%
% Usage:
%   soak_dumpbits_k5('/mnt/onetb/scratch/qpsk_variants/k5_240/air/linkA_k5_00.iq')
%   soak_dumpbits_k5(file, 'label','A', 'diag',true)  % diag=true -> failing-frame breakdown
%
% Fields in res: capfile,label,nFrames,nGolden,pctGolden,totInfoBits,totInfoErr,
%   codedBER (aggregate), codedBER_steady (excl <=1 worst acquisition frame),
%   frameStarts (symbol-domain start indices), sps,
%   perFrame (struct array: idx,capOut,infoErr,valid,cfoHz,rot,swap,goldenBER).

p=inputParser;
p.addParameter('label','',@(x)ischar(x)||isstring(x));
p.addParameter('diag',false,@islogical);
p.addParameter('csv','/mnt/onetb/scratch/qpsk_variants/k5_240/soak_results_k5.csv',@(x)ischar(x)||isstring(x));
p.parse(varargin{:});
label=char(p.Results.label); doDiag=p.Results.diag; csvfile=char(p.Results.csv);
if isempty(label)
  [~,bn]=fileparts(capfile);
  if contains(lower(bn),'linka'), label='A'; elseif contains(lower(bn),'linkb'), label='B'; else, label=bn; end
end

repo='/home/tcollins/dev/qpsk_ai/TransceiverToolbox';
if exist(fullfile(repo,'setup.m'),'file'), run(fullfile(repo,'setup.m')); addpath(repo); end
qdir=fullfile(repo,'trx_examples','targeting','QPSKTxRxHDLExample'); if exist(qdir,'dir'), addpath(qdir); end

%% ---- modem / FEC constants (K=5 / 240 ksym contract; see PACKET_K5.txt) ----
C=commhdlQPSKTxRxParameters();
preSyms=C.preambleSymbols(:);
DBPP=C.DataBitsPerPacket; paySyms=DBPP/2; nPre=numel(preSyms); frameLenSym=nPre+paySyms;
sps=8; RRC=rcosdesign(0.5,4,sps);          % K5 variant: 8 sps (legacy was C.SamplesPerSymbol=4)
Fs=1.92e6; Rsym=240e3;                     % 240 ksym, 8 sps -> 1.92 MHz (no resample)
% frame period: 1133 symbols = 9064 samples at 8 sps
G=load('/mnt/onetb/scratch/qpsk_variants/k5_240/golden_k5.mat');  % words,payload,coded,info,msgBits,capOut,trellis,TB,ROWS,COLS
trellis=G.trellis; TB=G.TB; ROWS=G.ROWS; COLS=G.COLS;             % poly2trellis(5,[35 23]), TB=25, 136x16
INFO=1084; TAIL=4; CODED=2*(INFO+TAIL); NPAIR=CODED/2;
assert(CODED==2176 && ROWS==136 && COLS==16 && TB==25,'K5 contract constants mismatch');
info120=double(G.msgBits(:)).';            % first 120 info bits = 'ADI Hello World'
txairMsg=double(G.payload(1:CODED));       % interleaved coded bits (filler = 64 ones at payload end, NOT decoded)
deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR);
decC=viterbiDecode(txairMsg,deintIdx,trellis,NPAIR,TB); capGolden=pack32(decC(TB+1:TB+32));
assert(capGolden==uint32(G.capOut),'golden CAP_OUT self-check failed: %08X vs %08X',capGolden,uint32(G.capOut));

%% ---- read capture ----
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); nn=min(numel(I),numel(Q));
iq=double(I(1:nn))+1i*double(Q(1:nn)); iq=iq(abs(iq)>0); iq=iq/(max(abs(iq))+eps);
fprintf('[soak] %s (label %s): %d complex samples (~%.0f frames)\n',capfile,label,numel(iq),numel(iq)/sps/frameLenSym);

%% ---- front-end: timing recovery, then a coarse whole-capture CFO removal ----
x=iq(:)/rms(abs(iq)); mf=conv(x,RRC,'same');
ssy=comm.SymbolSynchronizer('TimingErrorDetector','Gardner (non-data-aided)','SamplesPerSymbol',sps);
sy=ssy(mf); sy=sy(:)/rms(abs(sy)); sym0=sy*rms(abs(preSyms));
% robust whole-capture CFO: FFT-based 4th-power spectral estimate (wide range, ~+-Rsym/8),
% removes the LARGE offsets some captures carry; then refine from preambles.
f4=fourthPowerCFO(sym0,Rsym);
sym1=sym0.*exp(-1i*2*pi*f4/Rsym*(0:numel(sym0)-1).');
[psAll,~]=framePeaks(sym1,preSyms,nPre,frameLenSym);
fRef=coarseCFO(sym1,psAll,preSyms,nPre,Rsym);          % residual from preambles
% Trimmed LOs: the residual after the (masked) 4th-power stage is physically
% tiny. A large fRef means the preamble estimator latched onto structure that
% is not carrier offset -- distrust it rather than poison the derotation.
if abs(fRef)>5e3, fprintf('[soak] preamble-refine %.0f Hz IMPLAUSIBLE -> ignored\n',fRef); fRef=0; end
fCoarse=f4+fRef;
symCFO=sym0.*exp(-1i*2*pi*fCoarse/Rsym*(0:numel(sym0)-1).');
fprintf('[soak] coarse CFO=%.0f Hz (4th-power %.0f + preamble-refine %.0f; %d preambles)\n',fCoarse,f4,fRef,numel(psAll));

%% ---- carrier sync (residual), then final frame sync ----
csy=comm.CarrierSynchronizer('Modulation','QPSK','SamplesPerSymbol',1,'DampingFactor',1/sqrt(2),'NormalizedLoopBandwidth',0.01);
symC=csy(symCFO); symC=symC(:)/rms(abs(symC))*rms(abs(preSyms));
[ps0,~]=framePeaks(symC,preSyms,nPre,frameLenSym);
ps0=refineStarts(symC,ps0,preSyms,nPre,8);
nF=numel(ps0);
fprintf('[soak] framed %d candidates for decode\n',nF);

%% ---- HARDENED per-frame decode ----
% For each frame: (a) per-frame CFO from the preamble (fine, on symC around this frame),
% derotate the frame; (b) preamble derotation; (c) try all 4 rotations x I/Q-swap, run
% Viterbi, pick the hypothesis that yields golden CAP_OUT; if none golden, pick the one
% with the fewest info-bit errors vs 'ADI Hello World' (lowest effective path metric).
pf=struct('idx',{},'capOut',{},'infoErr',{},'valid',{},'cfoHz',{},'rot',{},'swap',{},'goldenBER',{},'preCorr',{});
totInfoErr=0; totInfoBits=0; nGolden=0;
diagCFO=[]; diagPhaseFixed=0; diagSyncFixed=0; diagGenuine=0; diagFrameCFO=[];
for k=1:nF
  s0=ps0(k);
  if s0<1 || s0+frameLenSym-1>numel(symC)
    pf(end+1)=frameRec(k,uint32(0),120,false,NaN,NaN,NaN,1,0); continue; %#ok<AGROW>
  end
  fr=symC(s0:s0+frameLenSym-1);
  pre=fr(1:nPre); preCorr=abs(sum(pre.*conj(preSyms)))/(sum(abs(preSyms))+eps);
  % per-frame CFO ESTIMATE (for diagnosis / drift only -- NOT applied; the closed-loop
  % CarrierSynchronizer already removed the CFO, so re-correcting with a noisy 13-symbol
  % preamble estimate spins the payload and destroys the frame. The proven path (matches
  % offline_noprbs 99%% golden) is: carrier sync -> per-frame preamble derotation (constant
  % phase) -> 4-quadrant resolution.)
  z=pre.*conj(preSyms); dz=z(2:end).*conj(z(1:end-1)); fFrame=angle(mean(dz))/(2*pi)*Rsym;
  diagFrameCFO(end+1)=fFrame; %#ok<AGROW>
  Zc=sum(pre.*conj(preSyms)); r0=1; if abs(Zc)>0, r0=conj(Zc)/abs(Zc); end
  payD=fr(nPre+1:end)*r0;                               % preamble-derotated payload (constant phase)
  % (b)+(c) all-4-quadrant x swap resolution
  bestBER=1; bestCap=uint32(0); bestRot=NaN; bestSwap=NaN; gotGolden=false; bestDec=[]; bestV=[];
  for rr=[0 90 180 270]
    b=double(pskdemod(payD*exp(-1i*deg2rad(rr)),4,pi/4,'gray','OutputType','bit'));
    for sw=[false true]
      v=b; if sw, t=reshape(v,2,[]); t=flipud(t); v=t(:); end
      dec=viterbiDecode(v(1:CODED),deintIdx,trellis,NPAIR,TB);   % first 2176 of 2240 payload bits (filler skipped)
      co=pack32(dec(TB+1:TB+32)); ber=mean(dec(TB+1:TB+120)~=info120');
      if co==capGolden, bestBER=ber; bestCap=co; bestRot=rr; bestSwap=sw; bestDec=dec; bestV=v; gotGolden=true; break; end
      if ber<bestBER, bestBER=ber; bestCap=co; bestRot=rr; bestSwap=sw; bestDec=dec; bestV=v; end
    end
    if gotGolden, break; end
  end
  ierr=round(bestBER*120); if ~isempty(bestDec), DUMP.info{end+1}=bestDec(:).'; DUMP.coded{end+1}=bestV(1:min(numel(bestV),2240)).'; DUMP.cap{end+1}=bestCap; end
  valid=preCorr>0.5;                                    % frame considered "clean" if preamble locked
  totInfoErr=totInfoErr+ierr; totInfoBits=totInfoBits+120;
  if gotGolden, nGolden=nGolden+1; end
  pf(end+1)=frameRec(k,bestCap,ierr,valid,fFrame,bestRot,bestSwap,bestBER,preCorr); %#ok<AGROW>
  % ---- diagnosis of failing frames ----
  if doDiag && ~gotGolden
    % was it recoverable by any of the 4 phases? (already tried -> if still not golden)
    % try a frame-sync +-2 sym nudge with per-frame CFO to see if it's a sync offset
    fixedBySync=false;
    for off=[-2 -1 1 2]
      s1=s0+off; if s1<1||s1+frameLenSym-1>numel(symC), continue; end
      fr2=symC(s1:s1+frameLenSym-1); pr2=fr2(1:nPre); Z2=sum(pr2.*conj(preSyms)); rr2=1; if abs(Z2)>0, rr2=conj(Z2)/abs(Z2); end
      pay2=fr2(nPre+1:end)*rr2;
      for rr=[0 90 180 270]
        b=double(pskdemod(pay2*exp(-1i*deg2rad(rr)),4,pi/4,'gray','OutputType','bit'));
        for sw=[false true]
          v=b; if sw, t=reshape(v,2,[]); t=flipud(t); v=t(:); end
          dec=viterbiDecode(v(1:CODED),deintIdx,trellis,NPAIR,TB);
          if pack32(dec(TB+1:TB+32))==capGolden, fixedBySync=true; break; end
        end
        if fixedBySync, break; end
      end
      if fixedBySync, break; end
    end
    if fixedBySync, diagSyncFixed=diagSyncFixed+1;
    elseif abs(fFrame-fCoarse)>2000, diagCFO(end+1)=fFrame; diagFrameCFO(end)=fFrame; %#ok<AGROW>
    else, diagGenuine=diagGenuine+1; end
  end
end

%% ---- aggregate + steady-state coded BER ----
codedBER=totInfoErr/max(totInfoBits,1);
% steady-state: drop at most 1 worst frame (acquisition)
[~,wi]=max([pf.infoErr]);
ssErr=totInfoErr - pf(wi).infoErr; ssBits=totInfoBits - 120;
codedBER_ss=ssErr/max(ssBits,1);
pctGolden=100*nGolden/max(nF,1);

fprintf('[soak] %s: frames=%d golden=%d (%.1f%%) infoBits=%d infoErr=%d\n',label,nF,nGolden,pctGolden,totInfoBits,totInfoErr);
fprintf('[soak] %s: aggregate coded BER=%.6f%% ; steady-state (drop 1)=%.6f%%\n',label,100*codedBER,100*codedBER_ss);
if doDiag
  fprintf('[soak] DIAG failing-frame breakdown: syncOffset=%d, CFO(|f-fc|>2k)=%d, genuine/other=%d\n',...
      diagSyncFixed,numel(diagCFO),diagGenuine);
  fprintf('[soak] DIAG per-frame CFO: median=%.0f Hz std=%.0f Hz min=%.0f max=%.0f (drift proxy)\n',...
      median(diagFrameCFO),std(diagFrameCFO),min(diagFrameCFO),max(diagFrameCFO));
end

%% ---- save per-frame .mat + CSV row ----
[cdir,cbn]=fileparts(capfile); matout=fullfile(cdir,[cbn '_soakres_k5.mat']);
res=struct('capfile',capfile,'label',label,'nFrames',nF,'nGolden',nGolden,'pctGolden',pctGolden,...
    'totInfoBits',totInfoBits,'totInfoErr',totInfoErr,'codedBER',codedBER,'codedBER_steady',codedBER_ss,...
    'capGolden',capGolden,'coarseCFO',fCoarse,'frameStarts',ps0(:).','sps',sps,'perFrame',pf);
save(matout,'res','-v7.3');
% CSV: label,capfile,nFrames,nGolden,pctGolden,totInfoBits,totInfoErr,codedBER,codedBER_steady
newcsv=~exist(csvfile,'file');
cf=fopen(csvfile,'a');
if newcsv, fprintf(cf,'label,capfile,nFrames,nGolden,pctGolden,totInfoBits,totInfoErr,codedBER,codedBER_steady\n'); end
fprintf(cf,'%s,%s,%d,%d,%.3f,%d,%d,%.8f,%.8f\n',label,capfile,nF,nGolden,pctGolden,totInfoBits,totInfoErr,codedBER,codedBER_ss);
fclose(cf);
fprintf('[soak] saved %s and appended CSV row to %s\n',matout,csvfile);
end

%% ====================== helpers ======================
function r=frameRec(idx,capOut,infoErr,valid,cfoHz,rot,swap,goldenBER,preCorr)
r=struct('idx',idx,'capOut',capOut,'infoErr',infoErr,'valid',valid,'cfoHz',cfoHz,'rot',rot,'swap',swap,'goldenBER',goldenBER,'preCorr',preCorr);
end
function [ps0,pkv]=framePeaks(sym,preSyms,nPre,frameLenSym)
sym=sym(:); dps=preSyms(2:end).*conj(preSyms(1:end-1)); dsy=sym(2:end).*conj(sym(1:end-1));
ccd=abs(conv(dsy,conj(flipud(dps)))); ccd=ccd/(max(ccd)+eps);
[pkv,pk]=findpeaks(ccd,'MinPeakHeight',0.4,'MinPeakDistance',round(0.6*frameLenSym));
ps0=pk-(nPre-2); keep=ps0>=1 & ps0+frameLenSym-1<=numel(sym); ps0=ps0(keep); pkv=pkv(keep);
end
function f=fourthPowerCFO(sym,Rsym)
% Wide-range coarse CFO via the 4th-power spectral line (QPSK): raise to ^4 (removes the
% pi/4-QPSK data modulation), find the spectral peak; CFO = peak_freq/4. Range +-Rsym/8.
s=sym(:); s=s./(abs(s)+eps); N=min(2^18,numel(s)); w=s(1:N).^4;  % hard-limit: kills AM spur products
W=fftshift(abs(fft(w.*hann(N)))); fax=linspace(-Rsym/2,Rsym/2,N);
% LOs are trimmed on this link: true CFO is guaranteed small. Constrain the
% search to +-5 kHz (4th-power line at +-20 kHz) so out-of-band spurs cannot win.
mask=abs(fax)<=4*5e3; W(~mask)=0;
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
% K5 grid 136x16 = 2176: fully gridded, exact inverse of Tx perm r*COLS+c
deintIdx=zeros(CODED,1); for p=0:NPAIR-1, for j=0:1, rc=2*p+j; c=mod(rc,COLS); r=floor(rc/COLS); deintIdx(2*p+j+1)=c*ROWS+r; end, end
end
function dec=viterbiDecode(coded,deintIdx,trellis,NPAIR,TB)
d=coded(deintIdx+1); vd=comm.ViterbiDecoder(trellis,'InputFormat','Hard','TracebackDepth',TB,'TerminationMethod','Continuous','ResetInputPort',true);
dec=zeros(NPAIR,1); for k=1:NPAIR, dec(k)=vd(d(2*k-1:2*k),double(k==1)); end
end
function r=pack32(bits), r=uint32(0); n=min(32,numel(bits)); for i=0:n-1, if bits(i+1)~=0, r=bitor(r,bitshift(uint32(1),i)); end, end, end
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
