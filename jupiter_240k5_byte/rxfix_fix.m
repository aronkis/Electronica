function rxfix_fix(nframes, skips)
% rxfix_fix -- VERIFY the winning fix in-model on the CAPTURED real air.
% Runs the faithful on-chip Rx (FEC nodescr Receiver) on the captured link-A air
% for: (0) BASELINE, (B) reset-gating CFOChangeDetectThreshold 0.0015625->0.0125.
% Reports on-chip BIST BER + CAP_IN/CAP_OUT for each, at a skip sweep.
if nargin<1||isempty(nframes), nframes=120; end
if nargin<2||isempty(skips), skips=[30 34 38]; end
kit='/mnt/onetb/scratch/qpsk_variants/fec_jupiter_rxfix';
repo='/home/tcollins/dev/qpsk_ai/TransceiverToolbox';
diary(fullfile(kit,'rxfix_fix.log')); diary on;
cl=onCleanup(@() diary('off')); %#ok<NASGU>
run(fullfile(repo,'setup.m')); addpath(kit);
fprintf('==== RXFIX FIX (in-model on captured air) %s ====\n',datestr(now));

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
Nair=min(numel(iq), round(nframes*1133*4)); iq=iq(1:Nair);
iq4=resample(iq,4,1); iq4=iq4/rms(abs(iq4));          % x4 -> native 1.92Msym (norm-CFO preserved)
w2=reshape(repmat(iq4.',2,1),[],1);                    % ZOH x2 -> 15.36MHz
gI=int16(real(w2)*2^14); gQ=int16(imag(w2)*2^14);      % full-scale (proven amplitude)
fprintf('air feed: N=%d (x4-resample of %d air, ZOH x2, full-scale) rms=%.0f\n',numel(gI),Nair,rms(double(gI)));
S.gI=gI; S.gQ=gQ; S.N=numel(gI); S.rstPulseN=0;

cases={'none',[]; 'cfcthr',0.0125};
R=struct('name',{},'skip',{},'pk',{},'er',{},'ber',{},'capin',{},'capout',{},'fs',{});
for ci=1:size(cases,1)
  for si=1:numel(skips)
    S.skip=skips(si); build_rcv_harness(S);
    apply_rxfix('rcv_harness', cases{ci,1}, cases{ci,2});
    t0=tic; so=sim('rcv_harness'); dt=toc(t0);
    y=so.yout; gv=@(nm) getEl(y,nm);
    pk=lastu(gv('packets_out')); er=lastu(gv('bit_errors_out'));
    capout=lastu(gv('cap_out')); capin=lastu(gv('cap_in'));
    fs=lastu(gv('cnt_frame_start'));
    ber=100*er/max(pk*120,1);
    fprintf('[%-7s] skip=%2d: pkts=%d err=%d BER=%.3f%% CAP_IN=0x%08X CAP_OUT=0x%08X(g0x%08X) fS=%d (%.0fs)\n',...
        cases{ci,1},skips(si),pk,er,ber,capin,capout,capGolden,fs,dt);
    R(end+1)=struct('name',cases{ci,1},'skip',skips(si),'pk',pk,'er',er,'ber',ber,'capin',capin,'capout',capout,'fs',fs); %#ok<AGROW>
    close_system('rcv_harness',0);
  end
end
save(fullfile(kit,'rxfix_fix.mat'),'R','capGolden','capinGold','-v7.3');
fprintf('==== FIX DONE ====\n');
end
function v=lastu(ts), v=uint32(0); if ~isempty(ts), d=ts.Data; if isinteger(d), v=uint32(d(end)); else, v=uint32(round(double(d(end)))); end, end, v=double(v); end
function el=getEl(y,nm), el=[]; for i=1:numel(y.getElementNames), if strcmp(y{i}.Name,nm), el=y{i}.Values; return; end, end, end
function r=pack32(bits), r=uint32(0); n=min(32,numel(bits)); for i=0:n-1, if bits(i+1)~=0, r=bitor(r,bitshift(uint32(1),i)); end, end, end
function y=interleaveTx(coded,CODED,COLS,ROWS), y=zeros(CODED,1); for beat=0:CODED-1, r=mod(beat,ROWS); c=floor(beat/ROWS); perm=r*COLS+c; if perm<CODED, y(beat+1)=coded(perm+1); end, end, end
function deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR), deintIdx=zeros(CODED,1); for p=0:NPAIR-1, for j=0:1, rc=2*p+j; c=mod(rc,COLS); r=floor(rc/COLS); deintIdx(2*p+j+1)=c*ROWS+r; end, end, end
function dec=viterbiDecode(coded,deintIdx,trellis,NPAIR,TB), d=coded(deintIdx+1); vd=comm.ViterbiDecoder(trellis,'InputFormat','Hard','TracebackDepth',TB,'TerminationMethod','Continuous','ResetInputPort',true); dec=zeros(NPAIR,1); for k=1:NPAIR, dec(k)=vd(d(2*k-1:2*k),double(k==1)); end, end
