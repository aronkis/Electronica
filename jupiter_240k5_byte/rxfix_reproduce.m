function rxfix_reproduce(mode)
% rxfix_reproduce -- VERIFY-FIRST: run the DEPLOYED on-chip DUT (TxRxComposite,
% FEC nodescr) on the CAPTURED real link-A air and report on-chip BIST + CAP_OUT.
% Goal: reproduce the ~45%/bimodal on-chip failure that the offline decode (0%)
% does not show. mode: 'quick' (short, harness sanity) or 'full' (skip sweep).
if nargin<1, mode='quick'; end
kit='/mnt/onetb/scratch/qpsk_variants/fec_jupiter_rxfix';
repo='/home/tcollins/dev/qpsk_ai/TransceiverToolbox';
diary(fullfile(kit,sprintf('rxfix_reproduce_%s.log',mode))); diary on;
cl=onCleanup(@() diary('off')); %#ok<NASGU>
run(fullfile(repo,'setup.m')); addpath(kit);
fprintf('==== RXFIX REPRODUCE mode=%s %s ====\n',mode,datestr(now));

% ---- golden CAP_OUT (== coordinator 0x04922282) ----
C=commhdlQPSKTxRxParameters(); INFO=1080; TAIL=6; CODED=2*(INFO+TAIL); COLS=16; ROWS=135; NPAIR=CODED/2; TB=34;
strA=dec2bin('ADI Hello World',8); info=[double(reshape(strA.',1,[])-'0'), zeros(1,INFO-120)];
trellis=poly2trellis(7,[171 133]);
codedMsg=convenc([info zeros(1,TAIL)]',trellis);
txairMsg=interleaveTx(codedMsg,CODED,COLS,ROWS);
deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR);
decC=viterbiDecode(txairMsg,deintIdx,trellis,NPAIR,TB); capGolden=pack32(decC(TB+1:TB+32));
fprintf('golden CAP_OUT=0x%08X (coord 0x04922282)\n',capGolden);

% ---- captured real air ----
cap=load('/mnt/onetb/scratch/linkA_iq/offline_noprbs.mat','iq');
iq=cap.iq(:); iq=iq/rms(abs(iq));               % normalize to unit rms
% match the reference capture range (~0.6 rms-ish); ADC int16 = fixdt(1,16,14) SI
% target rms ~0.18 (the reference host capture ~0.19-0.21 per memory), scale to int16
targ=0.20; iqs=iq*targ;
gI=int16(round(real(iqs)*2^14)); gQ=int16(round(imag(iqs)*2^14));
fprintf('captured air: N=%d, |iq| rms(int16)=%.1f max=%d\n',numel(iq),rms(double(gI)),max(abs([double(gI);double(gQ)])));

Rsym=1.92e6; sps=C.SamplesPerSymbol; % model design-rate constants
% ADC/LVDS sample time that the composite RxCaptureFromHW path uses:
Ts = 1/(Rsym*sps);   % = 1/7.68MHz (model native; Repeat x2 -> 15.36MHz internally)

if strcmp(mode,'quick')
  Nkeep=round(30*1133*sps);   % ~30 frames
  skips=34;
else
  Nkeep=numel(gI);            % full record
  skips=[0 20 30 34 36 38 40 44 50];
end
Nkeep=min(Nkeep,numel(gI));
S0.gI=gI(1:Nkeep); S0.gQ=gQ(1:Nkeep); S0.N=Nkeep; S0.Ts=Ts;

res=[];
for si=1:numel(skips)
  S=S0; S.skip=skips(si); S.rstPulseN=8;
  build_composite_harness(S);
  t0=tic; so=sim('comp_harness'); dt=toc(t0);
  y=so.yout;
  gv=@(nm) getEl(y,nm);
  pk=lastval(gv('packets_out')); er=lastval(gv('bit_errors_out'));
  capout=lastval(gv('cap_out')); capin=lastval(gv('cap_in'));
  fs=lastval(gv('cnt_frame_start')); db=lastval(gv('cnt_dec_bits')); bs=lastval(gv('cnt_bist_start'));
  ber=100*er/max(pk*120,1);
  fprintf('skip=%2d : pkts=%d err=%d BER=%.3f%% | CAP_OUT=0x%08X CAP_IN=0x%08X | frameStart=%d decBits=%d bistStart=%d (%.0fs)\n',...
      skips(si),pk,er,ber,capout,capin,fs,db,bs,dt);
  res(end+1).skip=skips(si); res(end).pk=pk; res(end).er=er; res(end).ber=ber; %#ok<AGROW>
  res(end).capout=capout; res(end).capin=capin; res(end).fs=fs; res(end).db=db; res(end).bs=bs;
  close_system('comp_harness',0);
end
save(fullfile(kit,sprintf('rxfix_reproduce_%s.mat',mode)),'res','capGolden','skips','Nkeep','Ts','-v7.3');
fprintf('==== REPRODUCE DONE ====\n');
end

% ---- helpers (mirror the offline_noprbs decode chain) ----
function v=lastval(ts), v=0; if ~isempty(ts), d=ts.Data; v=double(d(end)); if isinteger(d), v=double(typecast(d(end),'uint32')); end, end, end
function el=getEl(y,nm)
el=[]; for i=1:numel(y.getElementNames), if strcmp(y{i}.Name,nm), el=y{i}.Values; return; end, end
end
function r=pack32(bits), r=uint32(0); n=min(32,numel(bits)); for i=0:n-1, if bits(i+1)~=0, r=bitor(r,bitshift(uint32(1),i)); end, end, end
function y=interleaveTx(coded,CODED,COLS,ROWS), y=zeros(CODED,1); for beat=0:CODED-1, r=mod(beat,ROWS); c=floor(beat/ROWS); perm=r*COLS+c; if perm<CODED, y(beat+1)=coded(perm+1); end, end, end
function deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR), deintIdx=zeros(CODED,1); for p=0:NPAIR-1, for j=0:1, rc=2*p+j; c=mod(rc,COLS); r=floor(rc/COLS); deintIdx(2*p+j+1)=c*ROWS+r; end, end, end
function dec=viterbiDecode(coded,deintIdx,trellis,NPAIR,TB), d=coded(deintIdx+1); vd=comm.ViterbiDecoder(trellis,'InputFormat','Hard','TracebackDepth',TB,'TerminationMethod','Continuous','ResetInputPort',true); dec=zeros(NPAIR,1); for k=1:NPAIR, dec(k)=vd(d(2*k-1:2*k),double(k==1)); end, end
