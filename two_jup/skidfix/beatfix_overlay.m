function beatfix_overlay(sys, base)
% beatfix_overlay -- THE BEAT FIX (env-gated QPSK_BEATFIX): explicit downstream
% phase contract (Model-7 sim-validated, silicon fault class) + two stacked
% runtime-selectable arms, all default-OFF (fixctl=0 -> legacy-identical):
%
%   fixctl (AXI 0x208, uint32 write):
%     bit0  CONTRACT FRAMING: FEC frame alignment derived from the 14-bit
%           bit-index tag (tag==0) instead of the legacy startOut chain.
%     bit1  SERIALIZER RE-ANCHOR (Model-1-validated class): re-anchor the
%           2->1 serializer phase at frame start.
%     bit2  ENB-GRID PACING (secondary arm, 6c analysis): Rate Handle pop
%           pacer counts every rail beat unconditionally (absolute grid).
%   viol_count (AXI 0x20C, read):  ALWAYS-ON tag-continuity violation counter.
%   viol_latch (AXI 0x210, read):  {delta[15:0], tag_prev[15:0]} at last violation.
%
% TAG (Model 7 semantics): 14-bit BIT-INDEX in frame (wraps at 12320), counted
% at the demod INPUT valid (F&TS output = post-Rate_Handle, the earliest point
% the frame decision exists in this generation), transported by 4 matched
% enb_1_2_0 delays (mirroring the legacy startIn->startOut chain) to the demod
% output alignment where the FEC consumes it.
%
% G0: entire body early-returns when QPSK_BEATFIX unset (framestat idiom).
% Every structural assumption is checked; ANY miss = hard error (no silent
% degradation). AXI mapping is applied by patch_hdlworkflow_beatfix.m.

if isempty(getenv('QPSK_BEATFIX')), return; end
if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
fprintf('=== beatfix_overlay: phase contract + runtime fix arms ===\n');

rcv = [base '/Receiver'];
qrx = [rcv '/QPSK Rx'];
dmd = [qrx '/QPSK Demodulator'];
ser = [dmd '/Serializer'];
fts = [qrx '/Frequency and Time Synchronizer'];
rh  = [qrx '/Frequency and Time Synchronizer/Symbol Synchronizer/Rate Handle'];
lo  = 'LookUnderMasks';
NBITS = 12320;   % coded bits per frame (Model 7 measured; 14-bit tag)

  function h = src_of(blockpath, port)
    % PortHandles of the line feeding <blockpath> input <port>: returns the
    % source block/port as 'name/portnum' relative to the parent graph.
    ph = get_param(blockpath, 'PortHandles');
    l  = get_param(ph.Inport(port), 'Line');
    if l == -1, error('beatfix: %s input %d unconnected', blockpath, port); end
    sp = get_param(l, 'SrcPortHandle');
    sb = get_param(sp, 'Parent');
    pn = get_param(sp, 'PortNumber');
    [~, nm] = fileparts(sb);
    h = sprintf('%s/%d', nm, pn);
  end
  function p = next_outport(ss)
    p = numel(find_system(ss,'SearchDepth',1,lo,'all','BlockType','Outport')) + 1;
  end
  function p = next_inport(ss)
    p = numel(find_system(ss,'SearchDepth',1,lo,'all','BlockType','Inport')) + 1;
  end

% ---- sanity ----------------------------------------------------------------
for c = {rcv, qrx, dmd, ser, fts, rh, [rh '/HDL Counter'], ...
         [qrx '/FEC Decoder Wrapper']}
  if ~numel(find_system(fileparts(c{1}),'SearchDepth',1,lo,'all','Name',...
      c{1}(find(c{1}=='/',1,'last')+1:end)))
    error('beatfix_overlay: missing block %s', c{1});
  end
end

% ---- (0) fixctl composite input, plumbed to QPSK Rx ------------------------
pC = next_inport(base);
add_block('built-in/Inport', [base '/fixctl'], 'Port', num2str(pC), ...
          'OutDataTypeStr','uint32');
pRvI = next_inport(rcv);
add_block('built-in/Inport', [rcv '/fixctl'], 'Port', num2str(pRvI), ...
          'OutDataTypeStr','uint32');
add_line(base, sprintf('fixctl/1'), sprintf('Receiver/%d', pRvI), 'autorouting','on');
pQxI = next_inport(qrx);
add_block('built-in/Inport', [qrx '/fixctl'], 'Port', num2str(pQxI), ...
          'OutDataTypeStr','uint32');
add_line(rcv, 'fixctl/1', sprintf('QPSK Rx/%d', pQxI), 'autorouting','on');
% bit decode
add_block('simulink/User-Defined Functions/MATLAB Function', [qrx '/FixCtlDec']);
S = sfroot; blk = S.find('Path', [qrx '/FixCtlDec'], '-isa', 'Stateflow.EMChart');
blk.Script = sprintf([ ...
'function [enContract, enSerAnchor, enGridPace] = fcn(ctl)\n' ...
'%%#codegen\n' ...
'enContract  = bitand(uint32(ctl), uint32(1)) ~= uint32(0);\n' ...
'enSerAnchor = bitand(uint32(ctl), uint32(2)) ~= uint32(0);\n' ...
'enGridPace  = bitand(uint32(ctl), uint32(4)) ~= uint32(0);\n']);
add_line(qrx, 'fixctl/1', 'FixCtlDec/1', 'autorouting','on');

% ---- (1) tag generator at the demod INPUT (F&TS output alignment) ----------
% name-agnostic taps: branch the exact lines the demod consumes.
srcStart = src_of(dmd, 2);   % startIn source at qrx graph
srcValid = src_of(dmd, 4);   % validIn source
add_block('simulink/User-Defined Functions/MATLAB Function', [qrx '/BfTagGen']);
blk = S.find('Path', [qrx '/BfTagGen'], '-isa', 'Stateflow.EMChart');
blk.Script = sprintf([ ...
'function tag = fcn(vin, sin)\n' ...
'%%#codegen\n' ...
'persistent t\n' ...
'if isempty(t), t = uint16(0); end\n' ...
'if vin\n' ...
'  if sin\n' ...
'    t = uint16(0);\n' ...
'  elseif t >= uint16(%d)\n' ...
'    t = uint16(0);\n' ...
'  else\n' ...
'    t = t + uint16(1);\n' ...
'  end\n' ...
'end\n' ...
'tag = t;\n'], NBITS-1);
add_line(qrx, srcValid, 'BfTagGen/1', 'autorouting','on');
add_line(qrx, srcStart, 'BfTagGen/2', 'autorouting','on');
% transport: 4 matched enb-domain unit delays (mirrors legacy start chain depth)
prev = 'BfTagGen/1';
for k = 1:4
  dn = sprintf('BfTagD%d', k);
  add_block('simulink/Discrete/Delay', [qrx '/' dn], 'DelayLength','1');
  add_line(qrx, prev, [dn '/1'], 'autorouting','on');
  prev = [dn '/1'];
end

% ---- (2) consumer: contract start + continuity check + counter -------------
fec = [qrx '/FEC Decoder Wrapper'];
% v2: resolve port indices BY INPORT NAME (v1's numeric port-4 assumption tapped a
% const-1 net -> the violation counter fired at rail rate; Simulink port order is
% not the HDL port order). Hard-error if the named inports are missing.
  function idx = port_by_name(ss, nm)
    b = find_system(ss,'SearchDepth',1,lo,'all','BlockType','Inport','Name',nm);
    if isempty(b), error('beatfix: %s has no inport named %s', ss, nm); end
    idx = str2double(get_param(b{1},'Port'));
  end
pFecStart = port_by_name(fec, 'startIn');
pFecValid = port_by_name(fec, 'validIn');
fprintf('beatfix v2: FEC startIn=port%d validIn=port%d (by name)\n', pFecStart, pFecValid);
srcFecStart = src_of(fec, pFecStart);
srcFecValid = src_of(fec, pFecValid);
add_block('simulink/User-Defined Functions/MATLAB Function', [qrx '/BfContract']);
blk = S.find('Path', [qrx '/BfContract'], '-isa', 'Stateflow.EMChart');
blk.Script = sprintf([ ...
'function [startSel, violCount, violLatch] = fcn(tagd, vout, legacyStart, enContract)\n' ...
'%%#codegen\n' ...
'persistent prev cnt lat started K kvalid enPrev voutPrev\n' ...
'if isempty(prev), prev = uint16(0); cnt = uint32(0); lat = uint32(0); started = false; K = uint16(0); kvalid = false; enPrev = false; voutPrev = false; end\n' ...
'%% v3 EDGE QUALIFIER (pcFirstBit): vout is a 2-beat LEVEL per coded bit; act only\n' ...
'%% on the first beat (tag-advance beat) -- fixes the 2-beat start pulse (the v1/v2\n' ...
'%% +1-bit framing shift = A90B79F1) AND the per-bit false violation counting.\n' ...
'vEdge = vout && ~voutPrev;\n' ...
'voutPrev = logical(vout);\n' ...
'%% v2 SELF-CALIBRATING ANCHOR: on enContract rising edge, forget K; latch K = tag\n' ...
'%% at the next LEGACY frame start (alignment known-good right after bring-up).\n' ...
'if enContract && ~enPrev, kvalid = false; end\n' ...
'enPrev = enContract;\n' ...
'if enContract && ~kvalid && (legacyStart ~= 0) && vEdge\n' ...
'  K = tagd; kvalid = true;\n' ...
'end\n' ...
'%% continuity check (ALWAYS ON, read-only)\n' ...
'if vEdge\n' ...
'  if started\n' ...
'    expd = prev + uint16(1);\n' ...
'    if expd >= uint16(%d), expd = uint16(0); end\n' ...
'    if tagd ~= expd\n' ...
'      cnt = cnt + uint32(1);\n' ...
'      d = int32(tagd) - int32(expd);\n' ...
'      lat = bitor(bitshift(bitand(uint32(d), uint32(65535)), 16), uint32(prev));\n' ...
'    end\n' ...
'  end\n' ...
'  started = true;\n' ...
'  prev = tagd;\n' ...
'end\n' ...
'%% contract frame start: tag==K (calibrated) on a valid beat; legacy until calibrated\n' ...
'cs = vEdge && kvalid && (tagd == K);\n' ...
'if enContract && kvalid\n' ...
'  startSel = cs;\n' ...
'else\n' ...
'  startSel = legacyStart ~= 0;\n' ...
'end\n' ...
'violCount = cnt;\n' ...
'violLatch = lat;\n'], NBITS);
add_line(qrx, prev, 'BfContract/1', 'autorouting','on');           % tagd
add_line(qrx, srcFecValid, 'BfContract/2', 'autorouting','on');    % vout
add_line(qrx, srcFecStart, 'BfContract/3', 'autorouting','on');    % legacy start
add_line(qrx, 'FixCtlDec/1', 'BfContract/4', 'autorouting','on');  % enContract
% re-drive the FEC wrapper's startIn from the contract mux
phF = get_param(fec, 'PortHandles');
lF = get_param(phF.Inport(pFecStart), 'Line');
delete_line(lF);
add_line(qrx, 'BfContract/1', sprintf('FEC Decoder Wrapper/%d', pFecStart), 'autorouting','on');
% violation outputs -> composite read ports
pQ1 = next_outport(qrx);
add_block('built-in/Outport', [qrx '/beatfix_viol_count'], 'Port', num2str(pQ1));
add_line(qrx, 'BfContract/2', 'beatfix_viol_count/1', 'autorouting','on');
pQ2 = next_outport(qrx);
add_block('built-in/Outport', [qrx '/beatfix_viol_latch'], 'Port', num2str(pQ2));
add_line(qrx, 'BfContract/3', 'beatfix_viol_latch/1', 'autorouting','on');
pR1 = next_outport(rcv);
add_block('built-in/Outport', [rcv '/beatfix_viol_count'], 'Port', num2str(pR1));
add_line(rcv, sprintf('QPSK Rx/%d', pQ1), 'beatfix_viol_count/1', 'autorouting','on');
pR2 = next_outport(rcv);
add_block('built-in/Outport', [rcv '/beatfix_viol_latch'], 'Port', num2str(pR2));
add_line(rcv, sprintf('QPSK Rx/%d', pQ2), 'beatfix_viol_latch/1', 'autorouting','on');
pB1 = next_outport(base);
add_block('built-in/Outport', [base '/beatfix_viol_count'], 'Port', num2str(pB1));
add_line(base, sprintf('Receiver/%d', pR1), 'beatfix_viol_count/1', 'autorouting','on');
pB2 = next_outport(base);
add_block('built-in/Outport', [base '/beatfix_viol_latch'], 'Port', num2str(pB2));
add_line(base, sprintf('Receiver/%d', pR2), 'beatfix_viol_latch/1', 'autorouting','on');

% ---- (3) serializer re-anchor arm (bit1) -----------------------------------
% Route (demod startIn AND enSerAnchor) into the Serializer as a phase reset.
% Serializer is a plain generated subsystem; add a reset input consumed by a
% small wrapper around its HDL Counter equivalent: we mux the counter output
% to 0 on the reset beat (functionally = re-anchor; avoids editing the HDL
% Counter block dialog).
serctr = [ser '/HDL Counter'];
if isempty(find_system(ser,'SearchDepth',1,lo,'all','Name','HDL Counter'))
  error('beatfix_overlay: Serializer/HDL Counter not found (re-anchor arm)');
end
pSerI = next_inport(ser);
add_block('built-in/Inport', [ser '/bfAnchor'], 'Port', num2str(pSerI), ...
          'OutDataTypeStr','boolean');
% counter output consumers: mux 0 when bfAnchor
ph = get_param(serctr, 'PortHandles');
lC = get_param(ph.Outport(1), 'Line');
dsts = get_param(lC, 'DstPortHandle');
add_block('simulink/User-Defined Functions/MATLAB Function', [ser '/BfSerMux']);
blk = S.find('Path', [ser '/BfSerMux'], '-isa', 'Stateflow.EMChart');
blk.Script = sprintf([ ...
'function y = fcn(c, anchor)\n' ...
'%%#codegen\n' ...
'if anchor\n' ...
'  y = uint8(0);\n' ...
'else\n' ...
'  y = uint8(c);\n' ...
'end\n']);
delete_line(lC);
add_line(ser, 'HDL Counter/1', 'BfSerMux/1', 'autorouting','on');
add_line(ser, 'bfAnchor/1', 'BfSerMux/2', 'autorouting','on');
for d = reshape(dsts,1,[])
  db = get_param(d, 'Parent'); dp = get_param(d, 'PortNumber');
  [~, dn] = fileparts(db);
  add_line(ser, 'BfSerMux/1', sprintf('%s/%d', dn, dp), 'autorouting','on');
end
% drive bfAnchor at the demod level: startIn (demod inport 2) AND enSerAnchor
pDmdI = next_inport(dmd);
add_block('built-in/Inport', [dmd '/bfSerEn'], 'Port', num2str(pDmdI), ...
          'OutDataTypeStr','boolean');
add_block('simulink/Logic and Bit Operations/Logical Operator', [dmd '/BfSerAnd'], ...
          'Operator','AND', 'Inputs','2');
add_line(dmd, 'startIn/1', 'BfSerAnd/1', 'autorouting','on');
add_line(dmd, 'bfSerEn/1', 'BfSerAnd/2', 'autorouting','on');
add_line(dmd, 'BfSerAnd/1', sprintf('Serializer/%d', pSerI), 'autorouting','on');
add_line(qrx, 'FixCtlDec/2', sprintf('QPSK Demodulator/%d', pDmdI), 'autorouting','on');

% ---- (4) enb-grid pacing arm (bit2) ----------------------------------------
rhctr = [rh '/HDL Counter'];
pRhI = next_inport(rh);
add_block('built-in/Inport', [rh '/bfGridEn'], 'Port', num2str(pRhI), ...
          'OutDataTypeStr','boolean');
add_block('simulink/User-Defined Functions/MATLAB Function', [rh '/BfGridPace']);
blk = S.find('Path', [rh '/BfGridPace'], '-isa', 'Stateflow.EMChart');
blk.Script = sprintf([ ...
'function y = fcn(c, en)\n' ...
'%%#codegen\n' ...
'persistent a\n' ...
'if isempty(a), a = uint8(0); end\n' ...
'%% absolute pacer: counts EVERY beat unconditionally\n' ...
'if a >= uint8(3), a = uint8(0); else, a = a + uint8(1); end\n' ...
'if en\n' ...
'  y = a;\n' ...
'else\n' ...
'  y = uint8(c);\n' ...
'end\n']);
phR = get_param(rhctr, 'PortHandles');
lR = get_param(phR.Outport(1), 'Line');
dstsR = get_param(lR, 'DstPortHandle');
delete_line(lR);
add_line(rh, 'HDL Counter/1', 'BfGridPace/1', 'autorouting','on');
add_line(rh, 'bfGridEn/1', 'BfGridPace/2', 'autorouting','on');
for d = reshape(dstsR,1,[])
  db = get_param(d, 'Parent'); dp = get_param(d, 'PortNumber');
  [~, dn] = fileparts(db);
  add_line(rh, 'BfGridPace/1', sprintf('%s/%d', dn, dp), 'autorouting','on');
end
% plumb enGridPace down: qrx -> FTS -> Symbol Synchronizer -> Rate Handle
ssy = [fts '/Symbol Synchronizer'];
pFtsI = next_inport(fts);
add_block('built-in/Inport', [fts '/bfGridEn'], 'Port', num2str(pFtsI), ...
          'OutDataTypeStr','boolean');
pSsyI = next_inport(ssy);
add_block('built-in/Inport', [ssy '/bfGridEn'], 'Port', num2str(pSsyI), ...
          'OutDataTypeStr','boolean');
add_line(fts, 'bfGridEn/1', sprintf('Symbol Synchronizer/%d', pSsyI), 'autorouting','on');
add_line(ssy, 'bfGridEn/1', sprintf('Rate Handle/%d', pRhI), 'autorouting','on');
add_line(qrx, 'FixCtlDec/3', sprintf('Frequency and Time Synchronizer/%d', pFtsI), 'autorouting','on');

fprintf(['BEATFIX_OVERLAY_OK v3-edgequal-selfcal: tag(14b/%d) + contract mux + viol counter/latch + ' ...
         'serializer-anchor arm + grid-pace arm (fixctl 0x208, count 0x20C, latch 0x210)\n'], NBITS);
end
