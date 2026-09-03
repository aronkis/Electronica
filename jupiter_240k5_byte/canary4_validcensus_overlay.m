function canary4_validcensus_overlay(sys, base)
% canary4_validcensus_overlay -- valid-census counters bracketing the CS hop.
%
% Mode-2/mode-5 bisect (2026-07-14): at each device tick EXACTLY 2 symbol
% strobes vanish strictly inside the CFC->CS hop (CS-out census 1133->1131
% twice per ring at tick spacing; CFC-out cadence intact; rstcs=1/session so
% the reset path is exonerated). These counters name the eater: free-running
% uint32 counts of (1) CS validIn, (2) Loop Filter valid out (= DDS validIn),
% (3) the signal driving CS validOut. Poll deltas at 5 Hz: at an episode the
% first pair that disagrees by 2 localizes the suppression to input-pipe/LF
% vs LF->DDS->retime chain.
%
% AXI: 0x1A0 cs_vin_cnt / 0x1A4 cs_vlf_cnt / 0x1A8 cs_vout_cnt (read-only).
% Apply AFTER canary2 (Loop Filter Shadow must exist so outport counts are
% final). Read-only tap: datapath untouched.

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end

rcv = [base '/Receiver'];
qrx = [rcv '/QPSK Rx'];
fts = [qrx '/Frequency and Time Synchronizer'];
cs  = [fts '/Carrier Synchronizer'];

if ~isempty(find_system(cs,'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','Name','ValidCensus'))
    fprintf('canary4_validcensus_overlay: already present -- skipping\n');
    return;
end

% ---- the census MLFB ----
add_block('simulink/User-Defined Functions/MATLAB Function',[cs '/ValidCensus'], ...
    'Position',[1000 1000 1120 1100]);
set_fcn_script([cs '/ValidCensus'], sprintf([ ...
'function [cvin, cvlf, cvout] = validCensus(vin, vlf, vout)\n' ...
'%%#codegen\n' ...
'persistent a b c\n' ...
'if isempty(a), a = uint32(0); b = uint32(0); c = uint32(0); end\n' ...
'if vin,  a = a + uint32(1); end\n' ...
'if vlf,  b = b + uint32(1); end\n' ...
'if vout, c = c + uint32(1); end\n' ...
'cvin = a; cvlf = b; cvout = c;\n']));
% pin port types (MLFB double-probe lesson: never leave Inherit on fi/bool taps)
ch = sfroot().find('-isa','Stateflow.EMChart','Path',[cs '/ValidCensus']);
for d = ch.getChildren()'
    if ~isa(d,'Stateflow.Data'), continue; end
    if any(strcmp(d.Name,{'vin','vlf','vout'})), d.DataType = 'boolean';
    else, d.DataType = 'uint32'; end
end

% (1) CS validIn: branch from the Inport block named validIn
assert(~isempty(find_system(cs,'SearchDepth',1,'BlockType','Inport','Name','validIn')), ...
    'canary4: CS validIn inport not found');
add_line(cs, 'validIn/1', 'ValidCensus/1', 'autorouting','on');
% (2) Loop Filter valid out -- wire by OUTPORT NAME (port order trap)
pnLf = str2double(get_param([cs '/Loop Filter/valid'],'Port'));
add_line(cs, sprintf('Loop Filter/%d', pnLf), 'ValidCensus/2', 'autorouting','on');
% (3) the signal driving CS validOut -- traced-input branch
lhVo = get_param([cs '/validOut'],'LineHandles');
srcVo = get_param(lhVo.Inport(1),'SrcPortHandle');
phC = get_param([cs '/ValidCensus'],'PortHandles');
add_line(cs, srcVo, phC.Inport(3), 'autorouting','on');

% ---- surface the three counters CS -> FTS -> QRX -> Receiver -> composite ----
nCs = numel(find_system(cs,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
gnames = {'cs_vin_cnt','cs_vlf_cnt','cs_vout_cnt'};
ports = zeros(1,3);
for k = 1:3
    add_block('built-in/Outport',[cs '/' gnames{k}],'Port',num2str(nCs+k), ...
        'Position',[1160 1000+30*k 1190 1016+30*k]);
    add_line(cs, sprintf('ValidCensus/%d',k), [gnames{k} '/1'], 'autorouting','on');
    ports(k) = nCs + k;
end
levels = { fts, 'Carrier Synchronizer'; qrx, 'Frequency and Time Synchronizer'; ...
           rcv, 'QPSK Rx'; base, 'Receiver' };
childPorts = ports;
for L = 1:size(levels,1)
    parent = levels{L,1};
    child  = levels{L,2};
    nOut0 = numel(find_system(parent,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
    newPorts = zeros(1,3);
    for k = 1:3
        thisPort = nOut0 + k;
        add_block('built-in/Outport',[parent '/' gnames{k}], ...
            'Port',num2str(thisPort),'Position',[1200 1400+26*thisPort 1230 1416+26*thisPort]);
        add_line(parent, sprintf('%s/%d', child, childPorts(k)), ...
            [gnames{k} '/1'], 'autorouting','on');
        newPorts(k) = thisPort;
    end
    childPorts = newPorts;
end
% ---- byte-plane census: words offered to the rx byte DMA (0x1AC) ----
% Fabric-vs-host discriminator (session 20260714_125638): ~2.5 lost/episode
% at frame-sync level but ~7/episode at the host -- the missing ~4.5 die in
% decode->byte->DMA->host. This counter splits decoder/byte-plane vs DMA/host.
if isempty(find_system(base,'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','Name','ByteCensus'))
    add_block('simulink/User-Defined Functions/MATLAB Function',[base '/ByteCensus'], ...
        'Position',[1050 1600 1150 1660]);
    set_fcn_script([base '/ByteCensus'], sprintf([ ...
    'function cnt = byteCensus(v)\n' ...
    '%%%%#codegen\n' ...
    'persistent a\n' ...
    'if isempty(a), a = uint32(0); end\n' ...
    'if v, a = a + uint32(1); end\n' ...
    'cnt = a;\n']));
    chB = sfroot().find('-isa','Stateflow.EMChart','Path',[base '/ByteCensus']);
    for d = chB.getChildren()'
        if ~isa(d,'Stateflow.Data'), continue; end
        if strcmp(d.Name,'v'), d.DataType = 'boolean';
        else, d.DataType = 'uint32'; end
    end
    lhBv = get_param([base '/byte_rx_valid'],'LineHandles');
    srcBv = get_param(lhBv.Inport(1),'SrcPortHandle');
    phB = get_param([base '/ByteCensus'],'PortHandles');
    add_line(base, srcBv, phB.Inport(1), 'autorouting','on');
    nB = numel(find_system(base,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
    add_block('built-in/Outport',[base '/cnt_rxwords'],'Port',num2str(nB+1), ...
        'Position',[1200 1630 1230 1646]);
    add_line(base,'ByteCensus/1','cnt_rxwords/1','autorouting','on');
end
fprintf('canary4_validcensus_overlay: DONE (cs_vin/vlf/vout 0x1A0/4/8 + cnt_rxwords 0x1AC)\n');
end

% ===================== helpers =====================
function set_fcn_script(blk, src)
rt = sfroot;
chart = rt.find('-isa','Stateflow.EMChart','Path',blk);
chart.Script = src;
end
