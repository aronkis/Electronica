function byte_rx_overlay_k5(sys, loop)
% byte_rx_overlay_k5 -- port of tools/add_byte_rx_path.m to the jupiter_240k5
% COMPOSITE copy: tap the Receiver's RECOVERED payload bit stream for the
% FPGA->host byte-RX path.
%
% In THIS kit the stream feeding 'Capture Data Bits' is the K=5 FEC-DECODED
% info stream (fec_insert_overlay_rxonly_k5.m + fec_nodescr_overlay.m rewired
% QPSK Rx internally; the Receiver-level wiring of Capture Data Bits is
% unchanged: dataOut <- 'QPSK Rx'/1, start/valid <- 'Bus Selector2'). The
% taps therefore carry exactly the 1084 decoded info bits/frame the BIST
% checks -- verified by introspection asserts below, including that the FEC
% Decoder Wrapper is present inside QPSK Rx (i.e. the tap IS post-Viterbi).
%
% Additions (Receiver decode path untouched -- pure signal branches):
%   Receiver outports <n+1..n+3>: recBit, recBitValid, recStart, wired off
%   the SAME sources that feed Capture Data Bits. (n introspected: the K5
%   composite Receiver has grown fec_counters/capture/taps outports, so the
%   donor's fixed 10..12 numbering does NOT hold here.)
%
% Idempotent: skips if recBit already present. Does NOT save.

if nargin < 1, sys = bdroot; end %#ok<NASGU>
if nargin < 2 || isempty(loop), loop = [bdroot '/TxRxComposite']; end
rx = [loop '/Receiver'];

if ~isempty(find_system(rx,'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','BlockType','Outport','Name','recBit'))
    fprintf('byte_rx_overlay_k5: byte-RX tap already present -- skipping\n');
    return;
end

% --- (0) the K5 decode chain must be in place (tap = DECODED info bits) ---
assert(~isempty(find_system([rx '/QPSK Rx'],'LookUnderMasks','all','FollowLinks','on', ...
    'BlockType','SubSystem','Name','FEC Decoder Wrapper')), ...
    'FEC Decoder Wrapper missing inside QPSK Rx -- run fec_insert_overlay_rxonly_k5 first');

% --- (1) introspect the Capture Data Bits sources (assert, don't assume) ---
cdb = [rx '/Capture Data Bits'];
pc = get_param(cdb, 'PortConnectivity');
src = struct('blk', {}, 'port', {});
for k = 1:4   % inputs come FIRST in PortConnectivity (then the outputs,
              % whose Type labels collide with the inputs' '1'..'3')
    p = pc(k);
    assert(strcmp(p.Type, num2str(k)) && ~isempty(p.SrcBlock) && ...
        all(p.SrcBlock ~= -1), 'Capture Data Bits port %d has no source', k);
    src(k).blk  = p.SrcBlock;            % numeric handle (names contain newlines)
    src(k).port = p.SrcPort + 1;
end
assert(contains(get_param(src(1).blk,'Name'), 'QPSK Rx'), ...
    'dataOut source is %s, expected QPSK Rx', get_param(src(1).blk,'Name'));
assert(contains(get_param(src(2).blk,'Name'), 'Selector2'), ...
    'dataSrt source is %s, expected Bus Selector2', get_param(src(2).blk,'Name'));
assert(contains(get_param(src(4).blk,'Name'), 'Selector2'), ...
    'valid source is %s, expected Bus Selector2', get_param(src(4).blk,'Name'));
fprintf('byte_rx_overlay_k5: Capture Data Bits sources verified (QPSK Rx/1 + Bus Selector2 -- the K5 decoded stream)\n');

% --- (2) Receiver outports <n+1..n+3> wired off the same sources ---
nOut = numel(get_param(rx,'PortHandles').Outport);
taps = { 'recBit', 1; 'recBitValid', 4; 'recStart', 2 };
for k = 1:size(taps,1)
    blk = [rx '/' taps{k,1}];
    add_block('built-in/Outport', blk, 'Port', num2str(nOut+k), ...
        'Position', [900 700+40*k 930 720+40*k]);
    s  = src(taps{k,2});
    sph = get_param(s.blk, 'PortHandles');
    dph = get_param(blk, 'PortHandles');
    add_line(rx, sph.Outport(s.port), dph.Inport(1), 'autorouting','on');
end
fprintf('byte_rx_overlay_k5: DONE (Receiver outports %d..%d = recBit/recBitValid/recStart)\n', ...
    nOut+1, nOut+3);
end
