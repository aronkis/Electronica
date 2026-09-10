function beatobs_overlay(sys, base)
% beatobs_overlay -- BEAT OBSERVABILITY: repurpose the debugI1/debugQ1 pair
% (composite outports -> rx DMA voltage0 / beat-ILA probes 8/9) as a packed
% cycle-resolved internal-state vector for the 119.75 s beat hunt
% (BEATILA3_DESIGN.md readout rule; Travis's Rate-Handle rate-boundary
% hypothesis, STAGE_LOCALIZED.md UPDATE 4).
%
% G0 PRESERVATION: entire body env-gated on QPSK_BEATOBS (framestat idiom) --
% unset => EARLY RETURN, zero blocks touched, assembled model byte-identical.
%
% WHY debugI1/Q1: during BIST/digital-loopback beat captures the receiver
% input IQ they normally carry is redundant (raw SSI is on ILA probes 12/13
% and the input is the known ROM pattern). Rewiring them costs no new IP
% ports (closed-catalog safe), no debug-core insertion (Vivado 12-727 safe),
% and rides the PROVEN XVC/beat-ILA capture path.
%
% PACKING (int16 pair, sampled every rail beat by the ILA):
%   debugI1[0]    demod dataOut   (serial coded bit into FEC)
%   debugI1[1]    demod startOut
%   debugI1[2]    demod validOut
%   debugI1[4:3]  decision pair (QPSK Demodulator Baseband out, pre-serializer)
%   debugI1[6:5]  Rate Handle HDL Counter (the mod-4 pop-phase pointer)
%   debugI1[15:8] FIFO fill proxy: push_cnt - pop_cnt (low 8)
%   debugQ1[7:0]  FIFO Push Counter low 8
%   debugQ1[15:8] FIFO Pop  Counter low 8
%
% All taps are READ-ONLY parent-graph branches + added outports (p1b idiom);
% MLFB inputs DTC-SI isolated (double-probe/back-prop lessons). Fails LOUDLY
% (error) if any expected block/port is missing -- never silently degrades.

if isempty(getenv('QPSK_BEATOBS')), return; end
if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
fprintf('=== beatobs_overlay: packed state vector -> debugI1/Q1 ===\n');

rcv = [base '/Receiver'];
qrx = [rcv '/QPSK Rx'];
fts = [qrx '/Frequency and Time Synchronizer'];
dmd = [qrx '/QPSK Demodulator'];
ssy = [fts '/Symbol Synchronizer'];
rh  = [ssy '/Rate Handle'];
ff  = [rh  '/FIFO'];
lo  = 'LookUnderMasks';

  function assert_block(pth)
    if isempty(find_system(fileparts(pth),'SearchDepth',1,lo,'all','Name',get_leaf(pth)))
      error('beatobs_overlay: missing block %s', pth);
    end
  end
  function n = get_leaf(pth)
    [~,n] = fileparts(pth); % Simulink paths: fileparts splits on '/'
  end
  function p = next_outport(ss)
    p = numel(find_system(ss,'SearchDepth',1,lo,'all','BlockType','Outport')) + 1;
  end

% ---- sanity: every block we touch must exist (fail loudly up front) --------
for c = {dmd, [dmd '/QPSK Demodulator Baseband'], rh, [rh '/HDL Counter'], ...
         ff, [ff '/Push Counter'], [ff '/Pop Counter'], ssy}
  assert_block(c{1});
end

% ---- (1) decision pair out of QPSK Demodulator (1 level) -------------------
pD = next_outport(dmd);
add_block('built-in/Outport', [dmd '/beatobsDecis'], 'Port', num2str(pD));
add_line(dmd, 'QPSK Demodulator Baseband/1', 'beatobsDecis/1', 'autorouting','on');

% ---- (2) Rate Handle mod-4 counter + FIFO push/pop, plumbed up -------------
% FIFO level: push/pop counters
pF1 = next_outport(ff);
add_block('built-in/Outport', [ff '/beatobsPush'], 'Port', num2str(pF1));
add_line(ff, 'Push Counter/1', 'beatobsPush/1', 'autorouting','on');
pF2 = next_outport(ff);
add_block('built-in/Outport', [ff '/beatobsPop'], 'Port', num2str(pF2));
add_line(ff, 'Pop Counter/1', 'beatobsPop/1', 'autorouting','on');
% Rate Handle level: counter + FIFO passthroughs
pR1 = next_outport(rh);
add_block('built-in/Outport', [rh '/beatobsRhCtr'], 'Port', num2str(pR1));
add_line(rh, 'HDL Counter/1', 'beatobsRhCtr/1', 'autorouting','on');
pR2 = next_outport(rh);
add_block('built-in/Outport', [rh '/beatobsPush'], 'Port', num2str(pR2));
add_line(rh, sprintf('FIFO/%d', pF1), 'beatobsPush/1', 'autorouting','on');
pR3 = next_outport(rh);
add_block('built-in/Outport', [rh '/beatobsPop'], 'Port', num2str(pR3));
add_line(rh, sprintf('FIFO/%d', pF2), 'beatobsPop/1', 'autorouting','on');
% Symbol Synchronizer level
pS = zeros(1,3); rhp = [pR1 pR2 pR3];
snm = {'beatobsRhCtr','beatobsPush','beatobsPop'};
for k = 1:3
  pS(k) = next_outport(ssy);
  add_block('built-in/Outport', [ssy '/' snm{k}], 'Port', num2str(pS(k)));
  add_line(ssy, sprintf('Rate Handle/%d', rhp(k)), [snm{k} '/1'], 'autorouting','on');
end
% FTS level
pT = zeros(1,3);
for k = 1:3
  pT(k) = next_outport(fts);
  add_block('built-in/Outport', [fts '/' snm{k}], 'Port', num2str(pT(k)));
  add_line(fts, sprintf('Symbol Synchronizer/%d', pS(k)), [snm{k} '/1'], 'autorouting','on');
end

% ---- (3) BeatObs packer MLFB in QPSK Rx ------------------------------------
% Demod outputs at qrx level: dataOut/startOut/endOut/validOut = ports 1..4
% (HDL port order, QPSK_Demodulator.v). DTC-SI isolate every MLFB input.
add_block('simulink/User-Defined Functions/MATLAB Function', [qrx '/BeatObs']);
S = sfroot; blk = S.find('Path', [qrx '/BeatObs'], '-isa', 'Stateflow.EMChart');
blk.Script = sprintf([ ...
'function [dbgI1, dbgQ1] = fcn(dOut, sOut, vOut, decis, rhc, pushc, popc)\n' ...
'%%#codegen\n' ...
'fill8 = bitand(uint32(pushc) - uint32(popc), uint32(255));\n' ...
'acc = uint32(dOut ~= 0);\n' ...
'acc = acc + uint32(2)  * uint32(sOut ~= 0);\n' ...
'acc = acc + uint32(4)  * uint32(vOut ~= 0);\n' ...
'acc = acc + uint32(8)  * uint32(decis(1) ~= 0);\n' ...
'acc = acc + uint32(16) * uint32(decis(2) ~= 0);\n' ...
'acc = acc + uint32(32) * bitand(uint32(rhc), uint32(3));\n' ...
'acc = acc + uint32(256) * fill8;\n' ...
'qcc = bitand(uint32(pushc), uint32(255)) + uint32(256) * bitand(uint32(popc), uint32(255));\n' ...
'dbgI1 = uint16(bitand(acc, uint32(65535)));\n' ...
'dbgQ1 = uint16(bitand(qcc, uint32(65535)));\n']);

dtc = {'BoDtc1','BoDtc2','BoDtc3','BoDtc4','BoDtc5','BoDtc6','BoDtc7'};
srcs = {'QPSK Demodulator/1','QPSK Demodulator/2','QPSK Demodulator/4', ...
        sprintf('QPSK Demodulator/%d', pD), ...
        sprintf('Frequency and Time Synchronizer/%d', pT(1)), ...
        sprintf('Frequency and Time Synchronizer/%d', pT(2)), ...
        sprintf('Frequency and Time Synchronizer/%d', pT(3))};
otyp = {'uint16','uint16','uint16','uint16','uint16','uint16','uint16'};
for k = 1:7
  add_block('simulink/Signal Attributes/Data Type Conversion', [qrx '/' dtc{k}], ...
            'OutDataTypeStr', otyp{k}, 'ConvertRealWorld', 'Stored Integer (SI)');
  add_line(qrx, srcs{k}, [dtc{k} '/1'], 'autorouting','on');
  add_line(qrx, [dtc{k} '/1'], sprintf('BeatObs/%d', k), 'autorouting','on');
end

% qrx outports for the packed pair (uint16 -> int16 stored-integer reinterp,
% matching the composite debugI1/Q1 port type; DTC-SI = zero logic)
add_block('simulink/Signal Attributes/Data Type Conversion', [qrx '/BoOutDtcI'], ...
          'OutDataTypeStr','int16', 'ConvertRealWorld','Stored Integer (SI)');
add_block('simulink/Signal Attributes/Data Type Conversion', [qrx '/BoOutDtcQ'], ...
          'OutDataTypeStr','int16', 'ConvertRealWorld','Stored Integer (SI)');
add_line(qrx, 'BeatObs/1', 'BoOutDtcI/1', 'autorouting','on');
add_line(qrx, 'BeatObs/2', 'BoOutDtcQ/1', 'autorouting','on');
pQ1 = next_outport(qrx);
add_block('built-in/Outport', [qrx '/beatobsI1'], 'Port', num2str(pQ1));
add_line(qrx, 'BoOutDtcI/1', 'beatobsI1/1', 'autorouting','on');
pQ2 = next_outport(qrx);
add_block('built-in/Outport', [qrx '/beatobsQ1'], 'Port', num2str(pQ2));
add_line(qrx, 'BoOutDtcQ/1', 'beatobsQ1/1', 'autorouting','on');

% ---- (4) Receiver level: route up + REWIRE composite debugI1/Q1 ------------
pRv1 = next_outport(rcv);
add_block('built-in/Outport', [rcv '/beatobsI1'], 'Port', num2str(pRv1));
add_line(rcv, sprintf('QPSK Rx/%d', pQ1), 'beatobsI1/1', 'autorouting','on');
pRv2 = next_outport(rcv);
add_block('built-in/Outport', [rcv '/beatobsQ1'], 'Port', num2str(pRv2));
add_line(rcv, sprintf('QPSK Rx/%d', pQ2), 'beatobsQ1/1', 'autorouting','on');

% composite: find the debugI1/debugQ1 outport blocks and re-drive them.
for pair = {{'debugI1', pRv1}, {'debugQ1', pRv2}}
  nm = pair{1}{1}; rp = pair{1}{2};
  ob = find_system(base,'SearchDepth',1,lo,'all','BlockType','Outport','Name',nm);
  if isempty(ob), error('beatobs_overlay: composite outport %s not found', nm); end
  ph = get_param(ob{1},'PortHandles');
  lh = get_param(ph.Inport,'Line');
  if lh ~= -1, delete_line(lh); end
  add_line(base, sprintf('Receiver/%d', rp), [nm '/1'], 'autorouting','on');
end

fprintf('BEATOBS_OVERLAY_OK: debugI1/Q1 now carry the packed beat state vector\n');
end
