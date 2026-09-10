function fec_counters_overlay(sys, base)
% fec_counters_overlay -- add FEC-Rx datapath debug COUNTERS to the Jupiter
% FEC composite, exposed as new AXI read registers 0x120..0x134.
%
% Apply AFTER fec_insert_overlay(sys, base). HDL-only; the IP's 64KB AXI
% range already covers 0x120..0x134 so NO block-design / address change is
% needed. Idempotent: a 2nd call detects the marker and returns.
%
% Six free-running 32-bit counters tap the FEC Rx (Viterbi-decoder) datapath
% inside .../Receiver/QPSK Rx/FEC Decoder Wrapper. They count rising EVENT
% pulses (one increment per cycle the tapped boolean is high) and are reset
% by the HDL global reset, which on this IP is asserted by the modem
% soft-reset write to AXI 0x000. Counter -> AXI map (see FEC_DBG_BUILD.txt):
%
%   0x120 cnt_descr_in   validIn  (Wrapper inport4): descrambled data beats
%                        ENTERING the FEC decoder (does data reach decoder?)
%   0x124 cnt_frame_start startIn (Wrapper inport2): frame dataStart pulses
%                        the decoder sees (does it see frame boundaries?)
%   0x128 cnt_vit_reset   RxDeint vitReset: per-packet RESET pulses to the
%                        Viterbi (does the per-packet reset ever fire on HW?)
%   0x12C cnt_deint_valid RxDeint deintValid: coded-bit PAIRS the
%                        deinterleaver emits into the Viterbi (does deint emit?)
%   0x130 cnt_dec_bits    RxAlign validOut: decoded info bits reaching the
%                        BIST/msgdec (does any decoded bit reach the BIST?)
%   0x134 cnt_bist_start  RxAlign startOut: aligned start strobes reaching the
%                        BIST 120-bit window (does the BIST window ever arm?)
%
% Reading 0x120..0x134 with devmem localizes the stall: the first counter in
% the chain that stays 0 (when the one before it is nonzero) is the stalling
% stage.

NL = char(10); %#ok<NASGU>
if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end

dec = [base '/Receiver/QPSK Rx/FEC Decoder Wrapper'];
qrx = [base '/Receiver/QPSK Rx'];
rcv = [base '/Receiver'];
loop = base;

% Idempotency marker: the FecCounters block inside the Wrapper.
if ~isempty(find_system(dec,'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','Name','FecCounters'))
    fprintf('fec_counters_overlay: counters already present -- skipping\n');
    return;
end

assert(~isempty(find_system(dec,'SearchDepth',0)), 'FEC Decoder Wrapper not found at %s', dec);

% ============================================================================
% (1) Inside the FEC Decoder Wrapper: tap 6 event signals into one counter
%     MATLAB Function and add 6 new Outports (the 32-bit counts).
% ============================================================================
% Tap sources (already-existing wires inside the Wrapper):
%   e1 = validIn      (Wrapper Inport 'validIn'  , port4) -> descrambler data in
%   e2 = startIn      (Wrapper Inport 'startIn'  , port2) -> frame start in
%   e3 = RxDeint/2    (vitReset)                          -> Viterbi reset
%   e4 = RxDeint/3    (deintValid)                        -> deinterleaver pair
%   e5 = RxAlign/4    (validOut)                          -> decoded bit to BIST
%   e6 = RxAlign/2    (startOut)                          -> BIST window start
add_block('simulink/User-Defined Functions/MATLAB Function', [dec '/FecCounters'], ...
    'Position',[340 360 480 520]);
set_fcn_script([dec '/FecCounters'], fecCounters_src());

% New outports on the Wrapper. The Wrapper currently has 4 outputs
% (dataOut/startOut/endOut/validOut); count outports take the next 6 Port
% numbers. add_block sets the Outport 'Port' param = the child block's
% boundary output-port index, which we track explicitly for surfacing.
cnt_names = {'cnt_descr_in','cnt_frame_start','cnt_vit_reset', ...
             'cnt_deint_valid','cnt_dec_bits','cnt_bist_start'};
nWrapOut0 = numel(find_system(dec,'SearchDepth',1,'BlockType','Outport'));  % =4
childCntPorts = (nWrapOut0+1):(nWrapOut0+6);   % boundary out-port idx of the 6 counts
for k = 1:6
    add_block('built-in/Outport', [dec '/' cnt_names{k}], ...
        'Port', num2str(childCntPorts(k)), 'Position',[760 360+30*k 790 376+30*k]);
end

% Wire taps into FecCounters (inputs 1..6 in the order above)
add_line(dec, 'validIn/1',  'FecCounters/1', 'autorouting','on'); % e1 descr in
add_line(dec, 'startIn/1',  'FecCounters/2', 'autorouting','on'); % e2 frame start
add_line(dec, 'RxDeint/2',  'FecCounters/3', 'autorouting','on'); % e3 vit reset
add_line(dec, 'RxDeint/3',  'FecCounters/4', 'autorouting','on'); % e4 deint valid
add_line(dec, 'RxAlign/4',  'FecCounters/5', 'autorouting','on'); % e5 dec bit -> BIST
add_line(dec, 'RxAlign/2',  'FecCounters/6', 'autorouting','on'); % e6 BIST start
% FecCounters outs 1..6 -> the 6 new outports
for k = 1:6
    add_line(dec, sprintf('FecCounters/%d',k), [cnt_names{k} '/1'], 'autorouting','on');
end
fprintf('fec_counters_overlay: FecCounters + 6 outports added inside Wrapper\n');

% ============================================================================
% (2) Surface the 6 counts up the subsystem hierarchy:
%     FEC Decoder Wrapper -> QPSK Rx -> Receiver -> TxRxComposite.
%     At each level: add 6 Outports INSIDE the container, each wired from the
%     child block's KNOWN count output-port index (childCntPorts). The new
%     Outports' 'Port' numbers become the container's count output-port
%     indices for the next level up. We track childCntPorts explicitly --
%     "last N ports" is NOT reliable because QPSK Rx / Receiver have many
%     pre-existing outputs and renumber on edit.
% ============================================================================
% Each row: {container, childBlockName}. childCntPorts (set above for the
% Wrapper) are the boundary output-port indices on childBlockName that carry
% the counts; we update it after each level.
levels = { ...
  qrx,  'FEC Decoder Wrapper'; ...
  rcv,  'QPSK Rx'; ...
  loop, 'Receiver' };

for L = 1:size(levels,1)
    parent = levels{L,1};
    child  = levels{L,2};
    % container's current outport count -> new ones get the next Port numbers.
    % LookUnderMasks so masked subsystems (e.g. QPSK Rx) report their real
    % outports; otherwise the new ports would take Port 1.. and renumber the
    % originals (which still works via Simulink auto-rewire, but is confusing).
    nOut0 = numel(find_system(parent,'SearchDepth',1,'LookUnderMasks','all', ...
                  'BlockType','Outport'));
    newContainerPorts = zeros(1,6);
    for k = 1:6
        opName = cnt_names{k};
        if ~isempty(find_system(parent,'SearchDepth',1,'BlockType','Outport','Name',opName))
            opName = sprintf('%s_L%d', cnt_names{k}, L);
        end
        thisPort = nOut0 + k;
        add_block('built-in/Outport', [parent '/' opName], ...
            'Port', num2str(thisPort), ...
            'Position',[900 360+30*thisPort 930 376+30*thisPort]);
        % wire from the child block's count output port (childCntPorts(k)) to
        % this new container Outport.
        add_line(parent, sprintf('%s/%d', child, childCntPorts(k)), ...
                 [opName '/1'], 'autorouting','on');
        newContainerPorts(k) = thisPort;
    end
    % these container Outports are the child count ports for the next level up
    childCntPorts = newContainerPorts;
    fprintf('fec_counters_overlay: surfaced 6 counts through %s (container out-ports %s)\n', ...
            parent, mat2str(newContainerPorts));
end

% ============================================================================
% (3) Add a constant SENTINEL register at 0x11C (fills the gap between the
%     existing 0x118 block and the 0x120 counters). Reading 0x11C returns the
%     magic 0xFEC0DB60 so the host can confirm it is talking to the DEBUG
%     bitstream (the extended-AXI-map build) before trusting 0x120..0x134.
add_block('built-in/Constant', [loop '/DbgSentinelConst'], ...
    'Value','uint32(4274441056)', ...   % 0xFEC0DB60
    'OutDataTypeStr','uint32', 'SampleTime','1/15.36e6', ...
    'Position',[760 320 820 340]);
nOutNow = numel(find_system(loop,'SearchDepth',1,'BlockType','Outport'));
add_block('built-in/Outport', [loop '/dbg_sentinel'], ...
    'Port', num2str(nOutNow+1), 'Position',[900 320 930 340]);
add_line(loop, 'DbgSentinelConst/1', 'dbg_sentinel/1', 'autorouting','on');
fprintf('fec_counters_overlay: added 0x11C sentinel (0xFEC0DB60) to close AXI gap\n');

fprintf('fec_counters_overlay: DONE -- sentinel@0x11C + 6 counters on TxRxComposite outports for AXI 0x120..0x134\n');
end

% ===================== helpers =====================
function set_fcn_script(blk, src)
rt = sfroot;
chart = rt.find('-isa','Stateflow.EMChart','Path',blk);
chart.Script = src;
end

function src = fecCounters_src()
% Six free-running uint32 event counters. Each increments by 1 on every cycle
% its boolean input is high. Reset by the HDL global reset (modem soft-reset
% 0x000) via the persistent-init path -- HDL Coder ties persistent state to
% the synchronous reset, so a soft-reset zeroes all six. Saturating at
% 2^32-1 to avoid wrap ambiguity during a long run.
src = sprintf([ ...
'function [c1, c2, c3, c4, c5, c6] = fecCounters(e1, e2, e3, e4, e5, e6)\n' ...
'%%#codegen\n' ...
'%% Free-running FEC-Rx datapath event counters (reset by modem soft-reset 0x000).\n' ...
'persistent k1 k2 k3 k4 k5 k6;\n' ...
'if isempty(k1)\n' ...
'  k1=uint32(0); k2=uint32(0); k3=uint32(0); k4=uint32(0); k5=uint32(0); k6=uint32(0);\n' ...
'end\n' ...
'MAX=uint32(4294967295);\n' ...
'n1=k1; n2=k2; n3=k3; n4=k4; n5=k5; n6=k6;\n' ...  %% sync-semantics compliant (RXROOT E11c)
'if e1 && n1<MAX, n1=n1+uint32(1); end\n' ...
'if e2 && n2<MAX, n2=n2+uint32(1); end\n' ...
'if e3 && n3<MAX, n3=n3+uint32(1); end\n' ...
'if e4 && n4<MAX, n4=n4+uint32(1); end\n' ...
'if e5 && n5<MAX, n5=n5+uint32(1); end\n' ...
'if e6 && n6<MAX, n6=n6+uint32(1); end\n' ...
'c1=n1; c2=n2; c3=n3; c4=n4; c5=n5; c6=n6;\n' ...
'k1=n1; k2=n2; k3=n3; k4=n4; k5=n5; k6=n6;\n']);
end
