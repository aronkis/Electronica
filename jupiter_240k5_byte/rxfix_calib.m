function rxfix_calib()
% rxfix_calib -- calibrate the faithful on-chip DUT harness rate+scaling by
% feeding a SYNTHETIC golden txair packet (the exact ZedBoard ROM contents) at
% 480 ksym, ZOH x8 to the 15.36 MHz DUT ADC input. If the DUT locks + decodes
% (CAP_IN=0x00000C5E, CAP_OUT=golden, low BER) the harness is faithful; then the
% SAME feed recipe is trusted for the captured real air.
kit='/mnt/onetb/scratch/qpsk_variants/fec_jupiter_rxfix';
repo='/home/tcollins/dev/qpsk_ai/TransceiverToolbox';
diary(fullfile(kit,'rxfix_calib.log')); diary on;
cl=onCleanup(@() diary('off')); %#ok<NASGU>
run(fullfile(repo,'setup.m')); addpath(kit);
fprintf('==== RXFIX CALIB %s ====\n',datestr(now));

C=commhdlQPSKTxRxParameters(); sps=C.SamplesPerSymbol; RRC=C.RRCCoef; preSyms=C.preambleSymbols(:);
INFO=1080; TAIL=6; CODED=2*(INFO+TAIL); COLS=16; ROWS=135; NPAIR=CODED/2; TB=34;
strA=dec2bin('ADI Hello World',8); info=[double(reshape(strA.',1,[])-'0'), zeros(1,INFO-120)];
trellis=poly2trellis(7,[171 133]);
codedMsg=convenc([info zeros(1,TAIL)]',trellis);
txairMsg=interleaveTx(codedMsg,CODED,COLS,ROWS);
deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR);
decC=viterbiDecode(txairMsg,deintIdx,trellis,NPAIR,TB); capGolden=pack32(decC(TB+1:TB+32));
capinGold=pack32(txairMsg(1:32));
fprintf('golden CAP_OUT=0x%08X  CAP_IN(txair[0:31])=0x%08X\n',capGolden,capinGold);

% ---- build the on-air frame: 13-Barker preamble + 1086 payload symbols (2172 coded bits) ----
% payload bits = txairMsg (2172), QPSK gray pi/4, I=first bit of pair
paySyms = pskmod(txairMsg(1:2:end)*2+txairMsg(2:2:end),4,pi/4,'gray');  % 1086 syms
Nframes=20;
frameSyms=[preSyms; paySyms];               % 13+1086 = 1099 sym  (NOTE: not 1133)
% pad payload to full DataBitsPerPacket/2 to match the on-chip 1120-sym payload window
paySymFull=[paySyms; zeros(C.DataBitsPerPacket/2 - numel(paySyms),1)]; % 1120
frameSyms=[preSyms; paySymFull];            % 13+1120 = 1133 sym
syms=repmat(frameSyms,Nframes,1);
% DUT is design-rate: QPSK Rx native = 1.92 Msym at 4 sps (7.68MHz), Receiver
% ADC input at 15.36MHz (ZOH x2, UpsamplesRx=2 downsamples back to 7.68). To
% present the packet at the DUT's native symbol rate, modulate at 4 sps ->
% 7.68MHz complex, then ZOH x2 -> 15.36MHz. (This is gen_stim's proven recipe.)
sps2=sps; % 4
w=zeros(numel(syms)*sps2,1); w(1:sps2:end)=syms; w=filter(RRC,1,w); w=w/rms(w); % 7.68MHz, rms=1
w2=reshape(repmat(w.',2,1),[],1);   % ZOH x2 -> 15.36 MHz (gen_stim recipe)
gI=int16(real(w2)*2^14); gQ=int16(imag(w2)*2^14);   % EXACT gen_stim scaling (rms~2^14)
fprintf('synthetic feed: N=%d @15.36MHz (ZOH x2 of %d @7.68MHz, native 1.92Msym), int16 rms=%.0f max=%d\n',...
    numel(gI),numel(w),rms(double(gI)),max(abs([double(gI);double(gQ)])));

S.gI=gI; S.gQ=gQ; S.N=numel(gI); S.rstPulseN=0;
skips=[34];
res=struct('skip',{},'pk',{},'er',{},'ber',{},'capin',{},'capout',{},'fs',{},'db',{},'bs',{});
for ii=1:numel(skips)
  S.skip=skips(ii); build_rcv_harness(S);
  t0=tic; so=sim('rcv_harness'); dt=toc(t0);
  y=so.yout; gv=@(nm) getEl(y,nm);
  pk=lastu(gv('packets_out')); er=lastu(gv('bit_errors_out'));
  capout=lastu(gv('cap_out')); capin=lastu(gv('cap_in'));
  fs=lastu(gv('cnt_frame_start')); db=lastu(gv('cnt_dec_bits')); bs=lastu(gv('cnt_bist_start'));
  ber=100*er/max(pk*120,1);
  fprintf('skip=%2d: pkts=%d err=%d BER=%.3f%% CAP_IN=0x%08X(gold 0x%08X) CAP_OUT=0x%08X(gold 0x%08X) fS=%d dB=%d bS=%d (%.0fs)\n',...
      skips(ii),pk,er,ber,capin,capinGold,capout,capGolden,fs,db,bs,dt);
  res(ii)=struct('skip',skips(ii),'pk',pk,'er',er,'ber',ber,'capin',capin,'capout',capout,'fs',fs,'db',db,'bs',bs);
  close_system('rcv_harness',0);
end
save(fullfile(kit,'rxfix_calib.mat'),'res','capGolden','capinGold','-v7.3');
fprintf('==== CALIB DONE ====\n');
end
function v=lastu(ts), v=uint32(0); if ~isempty(ts), d=ts.Data; if isinteger(d), v=uint32(d(end)); else, v=uint32(round(double(d(end)))); end, end, v=double(v); end
function el=getEl(y,nm), el=[]; for i=1:numel(y.getElementNames), if strcmp(y{i}.Name,nm), el=y{i}.Values; return; end, end, end
function r=pack32(bits), r=uint32(0); n=min(32,numel(bits)); for i=0:n-1, if bits(i+1)~=0, r=bitor(r,bitshift(uint32(1),i)); end, end, end
function y=interleaveTx(coded,CODED,COLS,ROWS), y=zeros(CODED,1); for beat=0:CODED-1, r=mod(beat,ROWS); c=floor(beat/ROWS); perm=r*COLS+c; if perm<CODED, y(beat+1)=coded(perm+1); end, end, end
function deintIdx=deintIndex(CODED,COLS,ROWS,NPAIR), deintIdx=zeros(CODED,1); for p=0:NPAIR-1, for j=0:1, rc=2*p+j; c=mod(rc,COLS); r=floor(rc/COLS); deintIdx(2*p+j+1)=c*ROWS+r; end, end, end
function dec=viterbiDecode(coded,deintIdx,trellis,NPAIR,TB), d=coded(deintIdx+1); vd=comm.ViterbiDecoder(trellis,'InputFormat','Hard','TracebackDepth',TB,'TerminationMethod','Continuous','ResetInputPort',true); dec=zeros(NPAIR,1); for k=1:NPAIR, dec(k)=vd(d(2*k-1:2*k),double(k==1)); end, end
