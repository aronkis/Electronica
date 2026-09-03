function rxfix_air(zoh, targ, nframes, skips, tag)
% rxfix_air -- feed the CAPTURED real link-A air into the faithful on-chip DUT
% (TxRxComposite, FEC nodescr) using the calibrated feed recipe, report on-chip
% BIST + CAP_IN/CAP_OUT. Reproduces the ~45% failure. Args allow rate/scale sweep.
%   zoh     : ZOH factor from 1.92MHz air -> DUT ADC (8 nominal for 15.36MHz)
%   targ    : int16 amplitude target (fraction of full scale)
%   nframes : approximate frames to feed (bounds record length)
%   skips   : skip_count sweep vector
if nargin<1||isempty(zoh), zoh=2; end
if nargin<2||isempty(targ), targ=0.18; end
if nargin<3||isempty(nframes), nframes=120; end
if nargin<4||isempty(skips), skips=34; end
if nargin<5, tag=sprintf('zoh%d_t%03d',zoh,round(targ*1000)); end
kit='/mnt/onetb/scratch/qpsk_variants/fec_jupiter_rxfix';
repo='/home/tcollins/dev/qpsk_ai/TransceiverToolbox';
diary(fullfile(kit,sprintf('rxfix_air_%s.log',tag))); diary on;
cl=onCleanup(@() diary('off')); %#ok<NASGU>
run(fullfile(repo,'setup.m')); addpath(kit);
fprintf('==== RXFIX AIR tag=%s zoh=%d targ=%.3f nframes=%d %s ====\n',tag,zoh,targ,nframes,datestr(now));

C=commhdlQPSKTxRxParameters();
INFO=1080; TAIL=6; CODED=2*(INFO+TAIL); COLS=16; ROWS=135; NPAIR=CODED/2; TB=34;
strA=dec2bin('ADI Hello World',8); info=[double(reshape(strA.',1,[])-'0'), zeros(1,INFO-120)];
trellis=poly2trellis(7,[171 133]); codedMsg=convenc([info zeros(1,TAIL)]',trellis);
txairMsg=interleaveTx(codedMsg,CODED,COLS,ROWS); deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR);
decC=viterbiDecode(txairMsg,deintIdx,trellis,NPAIR,TB); capGolden=pack32(decC(TB+1:TB+32));
capinGold=pack32(txairMsg(1:32));
fprintf('golden CAP_OUT=0x%08X CAP_IN=0x%08X\n',capGolden,capinGold);

cap=load('/mnt/onetb/scratch/linkA_iq/offline_noprbs.mat','iq');
iq=cap.iq(:); iq=iq/rms(abs(iq));
% bound to nframes: 1133 sym/frame * 4 sps = 4532 samp/frame @1.92MHz
Nair=min(numel(iq), round(nframes*1133*4));
iq=iq(1:Nair);
% FAITHFUL RATE MAP: the DUT QPSK Rx is design-rate (native 1.92 Msym at 4 sps,
% dataIn @15.36MHz -> Downsample/2 -> 7.68 -> 4 sps). The real air is 480 ksym.
% Resample the air x4 -> present at the DUT native 1.92 Msym; resampling scales
% TIME AND FREQUENCY together so the -26kHz CFO -> -104kHz = SAME normalized CFO
% (-0.0542 cyc/sym) the deployed 480-ksym on-chip Rx sees. integAvgLen (symbols)
% and CFOChangeDetectThreshold (cyc/sym) are per-symbol => faithful. Then ZOH x2
% (the RT_Rx 15.36 rate) -> Receiver dataIn.
iq4=resample(iq,4,1); iq4=iq4/rms(abs(iq4));       % x4 -> native symbol rate, norm-CFO preserved
w2=reshape(repmat(iq4.',zoh,1),[],1);              % ZOH x2 -> Receiver dataIn @15.36MHz
gI=int16(round(real(w2)*targ*2^14)); gQ=int16(round(imag(w2)*targ*2^14));
fprintf('air feed: N=%d (x4-resample of %d air @1.92MHz -> native 1.92Msym, ZOH x%d) int16 rms=%.0f max=%d\n',...
    numel(gI),Nair,zoh,rms(double(gI)),max(abs([double(gI);double(gQ)])));

S.gI=gI; S.gQ=gQ; S.N=numel(gI); S.rstPulseN=0;
res=struct('skip',{},'pk',{},'er',{},'ber',{},'capin',{},'capd',{},'capout',{},'fs',{},'db',{},'bs',{});
for si=1:numel(skips)
  S.skip=skips(si); build_rcv_harness(S);
  t0=tic; so=sim('rcv_harness'); dt=toc(t0);
  y=so.yout; gv=@(nm) getEl(y,nm);
  pk=lastu(gv('packets_out')); er=lastu(gv('bit_errors_out'));
  capout=lastu(gv('cap_out')); capin=lastu(gv('cap_in')); capd=lastu(gv('cap_deint'));
  fs=lastu(gv('cnt_frame_start')); db=lastu(gv('cnt_dec_bits')); bs=lastu(gv('cnt_bist_start'));
  ber=100*er/max(pk*120,1);
  fprintf('skip=%2d: pkts=%d err=%d BER=%.3f%% CAP_IN=0x%08X(g0x%08X) CAP_DEINT=0x%08X CAP_OUT=0x%08X(g0x%08X) fS=%d dB=%d bS=%d (%.0fs)\n',...
      skips(si),pk,er,ber,capin,capinGold,capd,capout,capGolden,fs,db,bs,dt);
  res(si)=struct('skip',skips(si),'pk',pk,'er',er,'ber',ber,'capin',capin,'capd',capd,'capout',capout,'fs',fs,'db',db,'bs',bs);
  close_system('rcv_harness',0);
end
save(fullfile(kit,sprintf('rxfix_air_%s.mat',tag)),'res','capGolden','capinGold','zoh','targ','nframes','-v7.3');
fprintf('==== AIR DONE tag=%s ====\n',tag);
end
function v=lastu(ts), v=uint32(0); if ~isempty(ts), d=ts.Data; if isinteger(d), v=uint32(d(end)); else, v=uint32(round(double(d(end)))); end, end, v=double(v); end
function el=getEl(y,nm), el=[]; for i=1:numel(y.getElementNames), if strcmp(y{i}.Name,nm), el=y{i}.Values; return; end, end, end
function r=pack32(bits), r=uint32(0); n=min(32,numel(bits)); for i=0:n-1, if bits(i+1)~=0, r=bitor(r,bitshift(uint32(1),i)); end, end, end
function y=interleaveTx(coded,CODED,COLS,ROWS), y=zeros(CODED,1); for beat=0:CODED-1, r=mod(beat,ROWS); c=floor(beat/ROWS); perm=r*COLS+c; if perm<CODED, y(beat+1)=coded(perm+1); end, end, end
function deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR), deintIdx=zeros(CODED,1); for p=0:NPAIR-1, for j=0:1, rc=2*p+j; c=mod(rc,COLS); r=floor(rc/COLS); deintIdx(2*p+j+1)=c*ROWS+r; end, end, end
function dec=viterbiDecode(coded,deintIdx,trellis,NPAIR,TB), d=coded(deintIdx+1); vd=comm.ViterbiDecoder(trellis,'InputFormat','Hard','TracebackDepth',TB,'TerminationMethod','Continuous','ResetInputPort',true); dec=zeros(NPAIR,1); for k=1:NPAIR, dec(k)=vd(d(2*k-1:2*k),double(k==1)); end, end
