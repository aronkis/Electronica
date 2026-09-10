%% Input data generation script for commhdlQPSKTxRx.slx. 
% This script generates inputs to the transmitter. This script is called in
% Input Data subsystem Mask Initialization in the commhdlQPSKTxRx.slx

%   Copyright 2020-2023 The MathWorks, Inc. 

% Each message is 112 bits
% numOfMsgs = 2;
% [bits,info] = generateHelloworldMsgBits(numOfMsgs)
% size(bits)
%%
% a = reshape(repmat(randsrc(2240*1,1,[0,1],RandStream('mcg16807','Seed',0)), 59,1), [2240*59,1]);
% b = reshape(repmat(randsrc(2240*1,1,[0,1],RandStream('mcg16807','Seed',0)), 59,1), [2240*59,1]);
% 
% disp(isequal(a,b))

%%
dataBits = eval(get_param(qpskFindTxInputData(gcs),'dataBits'));
Rsym = eval(get_param(qpskFindTxInputData(gcs),'Rsym'));
validateattributes(dataBits,{'double'},{'binary','column','finite'},'','dataBits');
validateattributes(Rsym,{'double'},{'finite','scalar','positive'},'','Rsym');

Config = commhdlQPSKTxRxParameters;

% The Input Data mask 'dataBits' is a FIXED stimulus whose length is locked to
% a multiple of the k5 packet (2240). It is a mask DATA value, so A1's
% Config-driven geometry parameterization did not reach it; and it is vestigial
% in the composite byte build (the msggen ROM + byte DMA path drive the Tx, not
% this stimulus). For a large-frame geometry (f1536: DataBitsPerPacket=24640,
% and 24640=11*2240 so a k5-multiple is NOT a 24640-multiple) pad the stimulus
% up to a whole packet multiple with zeros. CONDITIONAL: for k5 the remainder
% is 0 so this is a no-op -> Nframes integer, downstream byte-identical (G0).
r = mod(length(dataBits), Config.DataBitsPerPacket);
if r ~= 0
    dataBits = [dataBits; zeros(Config.DataBitsPerPacket - r, 1)];
end
Nframes             = length(dataBits)/Config.DataBitsPerPacket;
if (Nframes - floor(Nframes)) ~= 0
    error('Number of dataBits must be integer multiple of %d', Config.DataBitsPerPacket);
end

dataIn              = dataBits;
validIn             = true(size(dataIn));

% Generate validIn according to effective bit rate
dataIn = [zeros(length(Config.Preamble),Nframes);reshape(dataIn,Config.DataBitsPerPacket,Nframes)];
validIn = [false(length(Config.Preamble),Nframes);reshape(validIn,Config.DataBitsPerPacket,Nframes)];
dataIn = dataIn(:);
validIn = validIn(:);

CSLatency              = 5;
SSLatency              = 17;
PDLatency              = 44;
PALatency              = 101;
FCLatency              = 2;
QPSKDemodLatency       = 3;
DescramblerLatency     = 2;

stopTime =  (CSLatency + SSLatency)/(Rsym) + (DescramblerLatency+12)/(Rsym) ...
    + (PDLatency + PALatency + FCLatency + QPSKDemodLatency + 8)/(Rsym) ...
    + ((Nframes+1+1+1) * Config.BitsPerPacket/2)/(Rsym);

% Set number of initial frames to remove from comparison which may involve
% in transient response. You can compare all the samples if transient response
% is also of interest by setting the below variable to 0.
initFramesNotToCompareInRx = 29;
save('init_data.mat');
