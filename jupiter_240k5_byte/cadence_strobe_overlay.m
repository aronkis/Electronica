function cadence_strobe_overlay(sys)
% cadence_strobe_overlay -- make the Rx datapath CADENCE-AGNOSTIC (RXROOT E11).
%
% ROOT CAUSE (proven by RTL replay of real air at the true silicon cadences):
% the modem's QPSK rail is IPCORE_CLK/4 beats/s with Receiver validIn = const 1,
% but the physical ADC delivers 1.92 Msps: 4 rail-beats/sample on zed (adc_1_clk
% 30.72 MHz), 2 on jupiter (15.36 MHz). The Rx internals (Interp Control, Gardner
% taps, CFC window, CS pipelines) are RAIL-clocked, not valid-gated, so every loop
% rescaled per board. variant_pre's "regularized ADC stream is continuous" comment
% held only for the 15.36 Msps design profile.
%
% FIX: a 1-bit token toggles once per NEW ADC sample and rides register stages
% mirroring the data ingress; a change-detector on the QPSK rail yields
% newSample = exactly one rail beat per sample at ANY cadence (uniform or bursty,
% rail rate >= sample rate). 'QPSK Rx' + 'Capture Data Bits' move into an ENABLED
% subsystem RxCore gated by it. Loopback (rx_input_select=0) uses a free toggle
% -> gate=1 every beat -> internal BIST unchanged. At 1 beat/sample the gate is
% constantly 1 = the replay-proven configuration. Tx path untouched.
%
% Apply on the LOOPBACK model AFTER variant_pre (needs AdcCap/AdcRT/AdcStab and
% RxValidConst) -- assemble phase 2.12. Idempotent.

if nargin < 1, sys = 'commhdlQPSKTxRxLoopback'; end
loop = [sys '/TxRxComposite'];
rec  = [loop '/Receiver'];

if ~isempty(find_system(rec,'SearchDepth',1,'LookUnderMasks','all','FollowLinks','on', ...
        'BlockType','SubSystem','Name','RxCore'))
    fprintf('cadence_strobe_overlay: RxCore already present -- skipping\n');
    return;
end

% ---- (1) composite level: sample token, mirrored ingress, loopback mux ----
add_block('simulink/User-Defined Functions/MATLAB Function', [loop '/CadTog'], ...
    'Position',[300 640 360 680]);
set_fcn_script([loop '/CadTog'], sprintf([ ...
    'function t = cadTog(v)\n%%#codegen\n' ...
    'persistent p; if isempty(p), p = false; end\n' ...
    'if v, p = ~p; end\n' ...
    't = p;\n']));
add_line(loop, 'adc_validIn/1', 'CadTog/1', 'autorouting','on');

add_block('built-in/RateTransition', [loop '/AdcRTT'], ...
    'OutPortSampleTime','1/15.36e6', 'Position',[420 640 460 680]);
add_line(loop, 'CadTog/1', 'AdcRTT/1', 'autorouting','on');
add_block('built-in/Delay', [loop '/AdcStabT'], 'DelayLength','1', ...
    'Position',[500 640 540 680]);
add_line(loop, 'AdcRTT/1', 'AdcStabT/1', 'autorouting','on');

% loopback branch: toggles EVERY 15.36e6-rail step (internal Tx = 1 sample/beat)
add_block('simulink/User-Defined Functions/MATLAB Function', [loop '/LbTog'], ...
    'Position',[300 700 360 740]);
set_fcn_script([loop '/LbTog'], sprintf([ ...
    'function t = lbTog(v)\n%%#codegen\n' ...
    'persistent p; if isempty(p), p = false; end\n' ...
    'p = ~p; %% toggle every step; v (const true) only sets the rate\n' ...
    't = p;\n']));
add_line(loop, 'RxValidConst/1', 'LbTog/1', 'autorouting','on');

add_block('built-in/Switch', [loop '/MUX_RxT'], 'Criteria','u2 ~= 0', ...
    'Position',[560 690 590 720]);
add_line(loop, 'AdcStabT/1',        'MUX_RxT/1', 'autorouting','on');
add_line(loop, 'rx_input_select/1', 'MUX_RxT/2', 'autorouting','on');
add_line(loop, 'LbTog/1',           'MUX_RxT/3', 'autorouting','on');
add_block('built-in/RateTransition', [loop '/RT_RxT'], ...
    'OutPortSampleTime','1/15.36e6', 'Position',[610 690 640 720]);
add_line(loop, 'MUX_RxT/1', 'RT_RxT/1', 'autorouting','on');

% new Receiver inport (dynamic port number -- kits differ)
nin = numel(find_system(rec,'SearchDepth',1,'LookUnderMasks','all','FollowLinks','on', ...
        'BlockType','Inport'));
tport = nin + 1;
add_block('built-in/Inport', [rec '/dataInT'], 'Port', num2str(tport), ...
    'OutDataTypeStr','boolean', 'SampleTime','-1', 'Position',[40 900 70 920]);
add_line(loop, 'RT_RxT/1', sprintf('Receiver/%d', tport), 'autorouting','on');
fprintf('cadence_strobe_overlay: Receiver dataInT = inport %d\n', tport);

% ---- (2) Receiver level: rail-rate change detector ----
add_block('dspsigops/Downsample', [rec '/DS_T'], 'N','2', ...
    'InputProcessing','Elements as channels (sample based)', ...
    'RateOptions','Allow multirate processing', 'Position',[120 900 150 930]);
add_line(rec, 'dataInT/1', 'DS_T/1', 'autorouting','on');
add_block('built-in/Delay', [rec '/DelayT1'], 'DelayLength','1', 'Position',[180 900 210 930]);
add_line(rec, 'DS_T/1', 'DelayT1/1', 'autorouting','on');
add_block('built-in/Delay', [rec '/DelayT2'], 'DelayLength','1', 'Position',[240 900 270 930]);
add_line(rec, 'DelayT1/1', 'DelayT2/1', 'autorouting','on');
add_block('built-in/Delay', [rec '/DelayT3'], 'DelayLength','1', 'Position',[240 950 270 980]);
add_line(rec, 'DelayT2/1', 'DelayT3/1', 'autorouting','on');
add_block('built-in/Logic', [rec '/XorT'], 'Operator','XOR', 'Inputs','2', ...
    'Position',[320 920 350 950]);
add_line(rec, 'DelayT2/1', 'XorT/1', 'autorouting','on');
add_line(rec, 'DelayT3/1', 'XorT/2', 'autorouting','on');

% ---- (3) wrap the QPSK Rx + Capture Data Bits island into enabled RxCore ----
% Include the ctrl-bus plumbing between them so no signal exits and re-enters
% the (atomic, enabled) subsystem -- otherwise QPSK Rx's ctrlOut bus would
% leave RxCore, be split by a Receiver-level Bus Selector, and the start/end/
% valid elements would re-enter Capture Data Bits => nonvirtual self-loop.
sel = [get_param([rec '/QPSK Rx'],'Handle'); get_param([rec '/Capture Data Bits'],'Handle')];
bb = find_system(rec,'SearchDepth',1,'LookUnderMasks','all','FollowLinks','on', ...
        'BlockType','BusSelector');
bb = [bb; find_system(rec,'SearchDepth',1,'LookUnderMasks','all','FollowLinks','on', ...
        'BlockType','BusCreator')];
% keep only Bus blocks on the QPSK Rx <-> Capture Data Bits ctrl path (fed by
% QPSK Rx and feeding Capture Data Bits, in either direction)
for kB = 1:numel(bb)
    pc = get_param(bb{kB}, 'PortConnectivity');
    touches = false;
    for kk = 1:numel(pc)
        nb = [pc(kk).SrcBlock(:); pc(kk).DstBlock(:)];
        for kn = 1:numel(nb)
            if nb(kn) ~= -1 && ~isempty(nb(kn))
                nm = get_param(nb(kn), 'Name');
                if any(strcmp(nm, {'QPSK Rx','Capture Data Bits'})), touches = true; end
            end
        end
    end
    if touches, sel(end+1) = get_param(bb{kB},'Handle'); end %#ok<AGROW>
end
Simulink.BlockDiagram.createSubsystem(sel, 'Name','RxCore');
core = [rec '/RxCore'];
assert(~isempty(find_system(core,'SearchDepth',1,'LookUnderMasks','all', ...
    'FollowLinks','on','BlockType','SubSystem','Name','QPSK Rx')), 'RxCore wrap failed');
add_block('built-in/EnablePort', [core '/Enable'], 'Position',[200 20 220 40]);
% RxCore stays CLASSIC (the stock example's MATLAB Functions are not
% synchronous-semantics compliant). The stock leaf idioms ('Unit Delay Enabled
% [Resettable] Synchronous') each carry their own State Control block, which is
% illegal inside a classic conditional subsystem -- but the State Control only
% selects the semantics DOMAIN; the underlying enabled/resettable delays behave
% identically without it. Delete every State Control under RxCore (classic
% enabled subsystems are HDL-supported -- same mechanism as VitGate).
scs = find_system(core,'LookUnderMasks','all','FollowLinks','on','BlockType','StateControl');
for kSC = 1:numel(scs)
    % the sync idioms are LINKED library blocks: break every linked ancestor
    % between RxCore and the State Control before deleting it
    chain = {};
    anc = get_param(scs{kSC}, 'Parent');
    while ~strcmp(anc, core)
        chain{end+1} = anc; %#ok<AGROW>
        anc = get_param(anc, 'Parent');
    end
    for kA = numel(chain):-1:1   % break links TOP-DOWN (outermost first)
        try
            if ~strcmp(get_param(chain{kA},'LinkStatus'),'none')
                set_param(chain{kA}, 'LinkStatus', 'none');
            end
        catch
        end
    end
    delete_block(scs{kSC});
end
fprintf('cadence_strobe_overlay: removed %d State Control blocks under RxCore (classic domain)\n', numel(scs));
add_line(rec, 'XorT/1', 'RxCore/Enable', 'autorouting','on');
% RxAlign skip absorbs decoder latency; balancing across the conditional
% boundary is neither possible nor needed (same rationale as VitGate).
hdlset_param(core, 'BalanceDelays', 'off');
fprintf('cadence_strobe_overlay: RxCore enabled subsystem created (BalanceDelays off)\n');
end

function set_fcn_script(blk, src)
rt = sfroot; chart = rt.find('-isa','Stateflow.EMChart','Path',blk); chart.Script = src;
end
