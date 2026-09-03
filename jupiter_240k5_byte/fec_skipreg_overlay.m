function fec_skipreg_overlay(sys, base)
% fec_skipreg_overlay -- thread the runtime RxAlign SKIP COUNT (AXI 0x138)
% DOWN the subsystem hierarchy from the TxRxComposite top into the FEC Decoder
% Wrapper's skipCount input (port 5, already added by fec_insert_overlay).
%
% Apply AFTER fec_insert_overlay + fec_counters_overlay. HDL-only; the IP's
% 64KB AXI range already covers 0x138. Idempotent.
%
%   TxRxComposite/skip_count (new inport) -> Receiver (new inport) ->
%   QPSK Rx (new inport) -> FEC Decoder Wrapper/skipCount (port 5) -> RxAlign
%
% skip_count is a uint32 AXI4-Lite input register, default 34 (set on the host
% side after soft-reset). Sweep it on hardware to find the pipeline-latency
% offset that collapses BER to the coded floor.

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
loop = base;
rcv  = [loop '/Receiver'];
qrx  = [loop '/Receiver/QPSK Rx'];
dec  = [qrx '/FEC Decoder Wrapper'];

% Idempotency: skip if TxRxComposite already has skip_count.
if ~isempty(find_system(loop,'SearchDepth',1,'BlockType','Inport','Name','skip_count'))
    fprintf('fec_skipreg_overlay: skip_count already present -- skipping\n');
    return;
end

% Confirm the wrapper has the skipCount input port (port 5) from fec_insert_overlay.
assert(~isempty(find_system(dec,'SearchDepth',1,'LookUnderMasks','all', ...
    'BlockType','Inport','Name','skipCount')), ...
    'FEC Decoder Wrapper has no skipCount inport -- run the dbg4 fec_insert_overlay first');

% RATE-MATCHING (load-bearing): the new skip_count ports inside the masked
% QPSK Rx and at the FEC Decoder Wrapper boundary MUST carry the same sample
% rate + dtype as the existing iq_debug_mux carrier (QPSK Rx 'debugMuxCtrl'),
% else Simulink rate propagation through the masked QPSK Rx fails with a
% "Data integrity issue between RRC Receive Filter and AGC" error. Mirror
% debugMuxCtrl (uint32 @ 1/(Rsym*SamplesPerSymbol)).
dm = [qrx '/debugMuxCtrl'];
assert(~isempty(find_system(qrx,'SearchDepth',1,'LookUnderMasks','all', ...
    'BlockType','Inport','Name','debugMuxCtrl')), 'debugMuxCtrl not found in QPSK Rx');
dmST = get_param(dm,'SampleTime');     % e.g. '1/(Rsym*SamplesPerSymbol)'
dmDT = get_param(dm,'OutDataTypeStr'); % 'uint32'
% match the FEC Decoder Wrapper skipCount port to debugMuxCtrl's rate/dtype
set_param([dec '/skipCount'],'OutDataTypeStr',dmDT,'SampleTime',dmST);

% ---- helper: add an inport to a container and wire it to a child block input ----
% Returns the new child-block input-port index (= the new inport's Port number
% inside the child after we add it there) for the next level down.
%
% We thread from the OUTERMOST container inward. At each level L:
%   * add an Inport to the container 'parent' (named 'skip_count' or unique)
%   * the child block (childName) gets a NEW input port: we add an Inport INSIDE
%     the child subsystem (so the child block grows one boundary input port),
%     and wire parent's new inport -> child block's new boundary input port.
% For QPSK Rx (masked) the new inport lands after the existing ones.

cn = 'skip_count';

% LEVEL 1: TxRxComposite inport -> Receiver block.
% The Receiver INPUT boundary runs at the composite BUS rate (1/15.36e6) -- the
% same as rstCS/iq_debug_mux enter on. Inside the Receiver the iq_debug_mux
% carrier is downsampled to the symbol rate before QPSK Rx; we mirror that with
% a RateTransition for skip_count (a slow config value -> rate-safe in HDL).
busST = '1/15.36e6';
nIn_rcv = numel(find_system(rcv,'SearchDepth',1,'LookUnderMasks','all','BlockType','Inport'));
add_block('built-in/Inport',[rcv '/' cn],'Port',num2str(nIn_rcv+1), ...
    'Position',[30 30+40*(nIn_rcv+1) 60 50+40*(nIn_rcv+1)]);
set_param([rcv '/' cn],'OutDataTypeStr',dmDT,'SampleTime',busST);  % BUS rate in
rcvPort = nIn_rcv+1;   % Receiver block's new boundary input-port index

% Add the TxRxComposite inport (top-level AXI input; composite bus rate).
nIn_top = numel(find_system(loop,'SearchDepth',1,'BlockType','Inport'));
add_block('built-in/Inport',[loop '/' cn],'Port',num2str(nIn_top+1), ...
    'Position',[40 40+40*(nIn_top+1) 70 60+40*(nIn_top+1)]);
set_param([loop '/' cn],'OutDataTypeStr',dmDT,'SampleTime',busST);
% wire TxRxComposite/skip_count -> Receiver block port rcvPort
add_line(loop, [cn '/1'], sprintf('Receiver/%d', rcvPort), 'autorouting','on');

% Inside Receiver: cross bus(1/15.36e6) -> symbol rate via a holding Delay +
% Downsample (the SAME construct the working iq_debug_mux carrier uses), NOT a
% generic RateTransition. dbg4's RateTransition (SkipRT) delivered a value that
% had NO effect on hardware -- the bus->symbol crossing zeroed/froze it on the
% flat single clock. Mirror the proven iq_debug_mux path: a unit Delay (holds
% the static AXI value, registered on the bus clock) then a Downsample to the
% symbol rate. For a static config value this is bit-trivially correct and uses
% only the exact primitives that already work for iq_debug_mux on this board.
add_block('built-in/Delay',[rcv '/SkipHold'],'DelayLength','1', ...
    'Position',[120 30+40*(nIn_rcv+1) 150 50+40*(nIn_rcv+1)]);
add_block('dspsigops/Downsample',[rcv '/SkipDS'], 'N','1', ...  % T8 RATE FIX: bus 15.36e6 == raised rail; passthrough (was N=2 to the old 7.68e6 rail)
    'InputProcessing','Elements as channels (sample based)', ...
    'RateOptions','Allow multirate processing', ...
    'Position',[170 30+40*(nIn_rcv+1) 200 50+40*(nIn_rcv+1)]);
add_line(rcv, [cn '/1'], 'SkipHold/1', 'autorouting','on');
add_line(rcv, 'SkipHold/1', 'SkipDS/1', 'autorouting','on');

% LEVEL 2: RateTransition -> QPSK Rx block (symbol rate, mirrors debugMuxCtrl).
nIn_qrx = numel(find_system(qrx,'SearchDepth',1,'LookUnderMasks','all','BlockType','Inport'));
add_block('built-in/Inport',[qrx '/' cn],'Port',num2str(nIn_qrx+1), ...
    'Position',[30 30+40*(nIn_qrx+1) 60 50+40*(nIn_qrx+1)]);
set_param([qrx '/' cn],'OutDataTypeStr',dmDT,'SampleTime',dmST);  % SYMBOL rate
qrxPort = nIn_qrx+1;   % QPSK Rx block's new boundary input-port index
% wire Receiver SkipDS (symbol rate) -> QPSK Rx block port qrxPort
add_line(rcv, 'SkipDS/1', sprintf('QPSK Rx/%d', qrxPort), 'autorouting','on');

% LEVEL 3: QPSK Rx inport -> FEC Decoder Wrapper/skipCount (port 5).
% The Wrapper's skipCount inport is Port 5; its boundary input-port index = 5.
decSkipPort = str2double(get_param([dec '/skipCount'],'Port'));
add_line(qrx, [cn '/1'], sprintf('FEC Decoder Wrapper/%d', decSkipPort), 'autorouting','on');

fprintf('fec_skipreg_overlay: threaded skip_count -> Receiver(%d) -> QPSK Rx(%d) -> Wrapper(%d)\n', ...
        rcvPort, qrxPort, decSkipPort);
fprintf('fec_skipreg_overlay: TxRxComposite/skip_count added (AXI 0x138 mapping in workflow)\n');
end
