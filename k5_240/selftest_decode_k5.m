% selftest_decode_k5.m -- synthetic end-to-end selftest for soak_decode_k5.
%
% Generates synthetic air EXACTLY like the Tx (legacy contract conventions):
%   * frame bits = 26-bit preamble (13-bit Barker duplicated on I and Q,
%     interleaved I,Q -- commhdlQPSKTxRxParameters generatePreamble) followed
%     by the 2240 payload bits from golden_k5.mat
%   * QPSK map = pskmod(bI*2+bQ, 4, pi/4, 'gray') on interleaved bit pairs
%     (QPSKModulate convention, same as the HDL Tx / legacy decoders)
%   * sqrt-RRC rolloff 0.5 span 4 at 8 sps; 5 back-to-back frames
%   * impairments: +400 Hz CFO, 0.37-sample fractional timing offset,
%     137-sample integer offset (noise-only pad), AWGN at 20 dB SNR
%   * written as interleaved int16 I,Q (the format soak_decode_k5 reads)
% then runs soak_decode_k5 and gates:
%   >= 4 of 5 frames golden, 0 info-bit errors on golden frames,
%   CAP_OUT == 0x04922282, frame spacing == 9064 samples (1133 sym x 8 sps).
% Prints SELFTEST PASS / SELFTEST FAIL <reason>.

k5dir='/mnt/onetb/scratch/qpsk_variants/k5_240';
addpath(k5dir);
G=load(fullfile(k5dir,'golden_k5.mat'));
payload=double(G.payload(:)); assert(numel(payload)==2240,'payload must be 2240 bits');

%% ---- build frame symbols exactly per the legacy Tx contract ----
barker=[1 1 1 1 1 0 0 1 1 0 1 0 1];              % barkarCode13Bit
preBits=[barker;barker]; preBits=preBits(:);      % I/Q-interleaved, 26 bits
frameBits=[preBits; payload];                     % 2266 bits = 1133 symbols
bI=frameBits(1:2:end); bQ=frameBits(2:2:end);
frameSyms=pskmod(bI*2+bQ,4,pi/4,'gray');          % QPSKModulate convention
assert(numel(frameSyms)==1133);

NF=5; sps=8; Fs=1.92e6;
syms=repmat(frameSyms(:),NF,1);
rrc=rcosdesign(0.5,4,sps);
tx=upfirdn(syms,rrc,sps);                         % pulse-shaped, 8 sps

%% ---- impairments: fractional timing offset, integer offset, CFO, AWGN ----
fracDelay=0.37;                                   % fractional-sample timing offset
n=(0:numel(tx)-1).';
txd=interp1(n,tx,n-fracDelay,'spline',0);
padN=137;                                         % integer sample offset (noise-only pad)
x=[zeros(padN,1); txd; zeros(padN,1)];
cfoHz=400;                                        % small CFO to exercise the CFO path
x=x.*exp(1i*2*pi*cfoHz*(0:numel(x)-1).'/Fs);
rng(1234,'twister');
x=awgn(x,20,'measured');                          % 20 dB SNR

%% ---- write int16 interleaved I,Q ----
x=x/max(abs(x))*0.6*32767;
iw=zeros(2*numel(x),1,'int16');
iw(1:2:end)=int16(round(real(x))); iw(2:2:end)=int16(round(imag(x)));
capfile=fullfile(k5dir,'selftest_k5.iq');
fid=fopen(capfile,'w'); fwrite(fid,iw,'int16'); fclose(fid);
fprintf('[selftest] wrote %s: %d complex samples, %d frames, CFO=%+d Hz, fracDelay=%.2f, pad=%d\n',...
    capfile,numel(x),NF,cfoHz,fracDelay,padN);

%% ---- run the decoder under test ----
res=soak_decode_k5(capfile,'label','SELFTEST');

%% ---- gates ----
CAPG=uint32(hex2dec('04922282'));
fails={};

goldenMask=false(1,res.nFrames);
for k=1:res.nFrames
  goldenMask(k)=(res.perFrame(k).capOut==CAPG) && (res.perFrame(k).infoErr==0);
end

% gate 1: >= 4 of 5 frames decoded golden (first frame may be lost to acquisition)
if res.nGolden<NF-1
  fails{end+1}=sprintf('only %d of %d frames golden (need >= %d)',res.nGolden,NF,NF-1);
end
% gate 2: 0 info-bit errors on decoded (golden) frames
gErr=sum([res.perFrame(goldenMask).infoErr]);
if gErr~=0
  fails{end+1}=sprintf('%d info-bit errors on golden frames (need 0)',gErr);
end
% gate 3: CAP_OUT == 0x04922282 (decoder golden + every golden frame)
if res.capGolden~=CAPG
  fails{end+1}=sprintf('decoder capGolden 0x%08X != 0x04922282',res.capGolden);
end
if res.nGolden~=sum(goldenMask)
  fails{end+1}=sprintf('nGolden=%d but %d frames have capOut==golden with 0 errors',res.nGolden,sum(goldenMask));
end
% gate 4: detected frame spacing == 9064 samples (1133 sym * 8 sps)
spacingSamp=diff(res.frameStarts)*res.sps;
if isempty(spacingSamp)
  fails{end+1}='fewer than 2 frames detected; cannot check spacing';
elseif any(spacingSamp~=9064)
  fails{end+1}=sprintf('frame spacing [%s] samples != 9064',num2str(spacingSamp));
end

fprintf('[selftest] frames detected=%d golden=%d infoErrOnGolden=%d CAP_OUT=0x%08X spacing=[%s] samples\n',...
    res.nFrames,res.nGolden,gErr,res.capGolden,num2str(spacingSamp));

if isempty(fails)
  fprintf('SELFTEST PASS\n');
else
  fprintf('SELFTEST FAIL %s\n',strjoin(fails,' | '));
end
