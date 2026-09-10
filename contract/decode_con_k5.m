function res = decode_con_k5(capfile, varargin)
% decode_con_k5  Scorer for the LIVE FPGA CONSTELLATION tap stream (-S runs):
% mux mode 3 on the dual-DMA tap image (axi-adrv9002-rx2-lpc voltage0 =
% sample-held FTS constellation at rail rate).
%
% Stream anatomy (QPSK_Rx.v Delay4 + HW capture 20260712_052321_A): the tap
% latches the FTS dataOut WIRE on the rate enable, NOT on
% QPSKConstellationValid; the FTS consumes the Barker-13 preamble internally
% and ZEROES dataOut for ~110 rail beats per frame. The stream is therefore
% PAYLOAD-ONLY (1120 soft symbols/frame, ~8-beat holds) delimited by
% zero-gaps. Framing = zero-gap segmentation; symbol recovery = run-length
% extraction (genuine consecutive soft symbols always differ in noise LSBs;
% held beats repeat the exact stored-int word; LSB glitches mid-hold split a
% run -> value-adjacent merge); boundary transients absorbed by a leading-
% extras alignment scan verified by CRC (clean frames) or min-bitdiff (dirty).
% Quadrant/swap resolved GLOBALLY by CRC as in decode_seq_k5 (the FPGA CS
% grid offset is constant across a capture).
%
% This is the "live loops" leg of the three-way diff (ERROR_TAXONOMY Class-1
% discriminator): decode_seq_k5 on the rx-lpc window says what the AIR
% carried; decode_con_k5 on the rx2-lpc window says what the LIVE LOOPS
% delivered; replay_capture says what cold fixed-point numerics deliver.
%
% Wire format regenerated bit-exactly from host/{qpsk_frame.c,qpsk_seq.c}
% (see seqFrameBytes below). Whitener assumed OFF (QPSK_WHITEN unset in -S).
%
% res.perFrame: seq, errs, crcok, class(OK/BITERR/JUNK/DUP), s0 (run index of
% the segment start; res.symRailIdx(s0) = rail-sample offset in the capture).
%
% Usage: decode_con_k5('ev1_tap.iq')
%        decode_con_k5(f,'ncleanresolve',24,'label','hunt1')

p=inputParser;
p.addParameter('label','',@(x)ischar(x)||isstring(x));
p.addParameter('ncleanresolve',24,@isnumeric);
p.addParameter('hold',8,@isnumeric);   % rail samples per held symbol (1.92M/240k)
p.parse(varargin{:});
label=char(p.Results.label); nCleanRes=round(p.Results.ncleanresolve);
hold_=round(p.Results.hold);
if isempty(label), [~,label]=fileparts(capfile); end

repo='/home/tcollins/dev/qpsk_ai/TransceiverToolbox';
if exist(fullfile(repo,'setup.m'),'file'), run(fullfile(repo,'setup.m')); addpath(repo); end
qdir=fullfile(repo,'trx_examples','targeting','QPSKTxRxHDLExample'); if exist(qdir,'dir'), addpath(qdir); end

C=commhdlQPSKTxRxParameters();
DBPP=C.DataBitsPerPacket; paySyms=DBPP/2;
G=load(fullfile(fileparts(mfilename('fullpath')),'golden_k5.mat'));
trellis=G.trellis; TB=G.TB; ROWS=G.ROWS; COLS=G.COLS;
INFO=1084; TAIL=4; CODED=2*(INFO+TAIL); NPAIR=CODED/2; %#ok<NASGU>
assert(CODED==2176 && ROWS==136 && COLS==16 && TB==25,'K5 contract mismatch');
deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR);
PKT=128; NREF=PKT*8;
PAY=paySyms;                             % 1120-symbol payload contract
MAXDROP=4;                               % max leading boundary transients

%% ---- read capture + run-length extraction + zero-gap framing ----
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); nn=min(numel(I),numel(Q));
iq=double(I(1:nn))+1i*double(Q(1:nn));
fprintf('[deccon] %s (%s): %d rail samples (~%.0f frames)\n',capfile,label,numel(iq),numel(iq)/hold_/(PAY+14));
chg=[true; diff(iq)~=0];
sy=iq(chg);
ridx=find(chg);
rl=diff([ridx; numel(iq)+1]);
assert(numel(sy)>1000,'constellation stream has no symbol runs -- wrong mux mode or dead tap');
n0=rms(abs(sy(abs(sy)>0)));
isz=abs(sy)<0.05*n0;
gap=find(isz & rl>=hold_);               % substantial zero runs = frame delimiters
fprintf('[deccon] %d runs; %d zero-gaps (median %d beats)\n',...
  numel(sy),numel(gap),round(median(rl(gap))));
assert(numel(gap)>=2,'no zero-gap frame delimiters -- not a constellation tap stream?');
% Each inter-gap segment carries the 1120 payload symbols on a steady 8-beat
% grid EXCEPT for a short late-emergence transient at the segment START (the
% observed per-frame {2,7+1} oddments all sit in the first slots). Sample the
% RAW rail stream on an 8-beat grid anchored at the segment END, mid-slot;
% small end-offset candidates absorb residual cadence (CRC/bitdiff verifies).
OFFS=[0 -1 -2 1 2 -4 4];
frInfo=struct('s0',{},'t0',{},'t1',{});
for g=1:numel(gap)-1
  t0=ridx(gap(g))+rl(gap(g));            % first beat after the gap run
  t1=ridx(gap(g+1))-1;                   % last beat before the next gap
  if t1-t0+1 >= hold_*PAY-2*hold_, frInfo(end+1)=struct('s0',t0,'t0',t0,'t1',t1); end %#ok<AGROW>
end
nF=numel(frInfo);
assert(nF>0,'no complete payload segments');
fprintf('[deccon] framed %d payload segments (beats median %d, contract %d)\n',...
  nF,round(median(arrayfun(@(f)f.t1-f.t0+1,frInfo))),hold_*PAY);
gridpay=@(t1,off) iq(max(1,t1-3+off-hold_*(PAY-(1:PAY).')));   % end-anchored mid-slot grid

%% ---- global quadrant/swap resolve BY CRC (with alignment scan) ----
hyps=[]; for rr=[0 90 180 270], for sw=[false true], hyps=[hyps; rr sw]; end, end %#ok<AGROW>
hcrc=zeros(size(hyps,1),1);
useIdx=1:min(nCleanRes,nF);
for h=1:size(hyps,1)
  for j=useIdx
    for off=OFFS
      by=decodeBytes(gridpay(frInfo(j).t1,off),hyps(h,1),logical(hyps(h,2)),CODED,deintIdx,trellis,NPAIR,TB,PKT);
      if crcok(by), hcrc(h)=hcrc(h)+1; break; end
    end
  end
end
[nbest,hb]=max(hcrc); gRot=hyps(hb,1); gSwap=logical(hyps(hb,2));
fprintf('[deccon] hypothesis rot=%d swap=%d (CRC passes %d/%d resolve frames; all=[%s])\n',...
  gRot,gSwap,nbest,numel(useIdx),num2str(hcrc.'));
assert(nbest>0,'no hypothesis CRC-checks -- capture/decoder mismatch');

%% ---- per-frame score with regenerated references ----
perFrame=struct('seq',{},'errs',{},'crcok',{},'class',{},'s0',{});
ok=0; biterr=0; junk=0; dup=0; lost=0; lostev=0;
totBits=0; totErr=0; per_byte=zeros(PKT,1);
nextExpect=[]; firstSeq=[];
for f=1:nF
  s0=frInfo(f).s0;
  % alignment scan: CRC pass wins outright; else keep the min-bitdiff candidate
  by=[]; bestE=Inf; bestBy=[];
  for off=OFFS
    cand=decodeBytes(gridpay(frInfo(f).t1,off),gRot,gSwap,CODED,deintIdx,trellis,NPAIR,TB,PKT);
    if crcok(cand), by=cand; break; end
    if isempty(nextExpect), if isempty(bestBy), bestBy=cand; end, continue; end
    exp1=seqFrameBytes(nextExpect,PKT);
    e=sum(sum(dec2bin(bitxor(cand,exp1),8)=='1'));
    if e<bestE, bestE=e; bestBy=cand; end
  end
  if isempty(by), by=bestBy; end
  cls='JUNK'; errs=NaN; seq=NaN; cok=false;
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
fprintf('[deccon] %s: frames=%d OK=%d BITERR=%d LOST=%d(%d gaps) DUP=%d JUNK=%d\n',...
  label,nF,ok,biterr,lost,lostev,dup,junk);
fprintf('[deccon] %s: bits=%d errs=%d BER=%.3e ; span=%d accounted=%d\n',...
  label,totBits,totErr,BER,...
  double(~isempty(nextExpect))*(nextExpect-firstSeq),ok+biterr+lost);
[mx,mi]=maxk(per_byte,4);
if any(mx), fprintf('[deccon] hot bytes: %s\n',sprintf('%d@%d ',[mx.'; mi.'-1])); end

res=struct('capfile',capfile,'label',label,'nFrames',nF,'ok',ok,'biterr',biterr,...
  'lost',lost,'lost_events',lostev,'dup',dup,'junk',junk,'totBits',totBits,...
  'totErr',totErr,'BER',BER,'gRot',gRot,'gSwap',gSwap,...
  'per_byte',per_byte,'perFrame',perFrame,'firstSeq',firstSeq,'nextExpect',nextExpect);
% perFrame(k).s0 is the RAIL-SAMPLE offset of the frame's payload start in the capture
[cdir,cbn]=fileparts(capfile);
save(fullfile(cdir,[cbn '_deccon_k5.mat']),'res','-v7.3');
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

%% ============ demod/FEC helpers (verbatim decode_ref_k5) ============
function by=decodeBytes(payD,rr,sw,CODED,deintIdx,trellis,NPAIR,TB,PKT)
payD=payD(:)/max(rms(abs(payD)),eps);
b=double(pskdemod(payD*exp(-1i*deg2rad(rr)),4,pi/4,'gray','OutputType','bit'));
v=b; if sw, t=reshape(v,2,[]); t=flipud(t); v=t(:); end
dec=viterbiDecode(v(1:CODED),deintIdx,trellis,NPAIR,TB);
db=dec(TB+1:TB+PKT*8);
by=zeros(PKT,1);
for i=1:PKT
  for k=0:7, by(i)=by(i)+db((i-1)*8+k+1)*2^(7-k); end   % MSB-first per byte
end
end
function deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR)
deintIdx=zeros(CODED,1); for p=0:NPAIR-1, for j=0:1, rc=2*p+j; c=mod(rc,COLS); r=floor(rc/COLS); deintIdx(2*p+j+1)=c*ROWS+r; end, end
end
function dec=viterbiDecode(coded,deintIdx,trellis,NPAIR,TB)
d=coded(deintIdx+1); vd=comm.ViterbiDecoder(trellis,'InputFormat','Hard','TracebackDepth',TB,'TerminationMethod','Continuous','ResetInputPort',true);
dec=zeros(NPAIR,1); for k=1:NPAIR, dec(k)=vd(d(2*k-1:2*k),double(k==1)); end
end
