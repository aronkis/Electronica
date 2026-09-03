function patch_hdlworkflow_loopgain(wfFile)
% patch_hdlworkflow_loopgain -- add the 6 loop-gain AXI INPUT register mappings
% (0x170-0x184) to hdlworkflow_loopback.m (Task C3).
%
% BLOCK-EXISTENCE guarded (self-syncs with loop_gain_axi_overlay's LEAN gating,
% like adc_forensic/state-pair). These offsets are the same the canary OUTPUT
% registers use in NON-LEAN builds -- but those are env-guarded off in LEAN and
% the loop-gain inports only exist in LEAN, so the two never both map (LEAN and
% non-LEAN are mutually exclusive at codegen). Idempotent. Inserted after the
% byte_rx_ready input mapping so all AXI inputs stay contiguous.

if nargin < 1, wfFile = 'hdlworkflow_loopback.m'; end
sys = 'commhdlQPSKTxRxLoopback';
txt = fileread(wfFile);
if contains(txt, 'loop-gain tuning mappings')
    fprintf('patch_hdlworkflow_loopgain: already patched -- skipping\n');
    return;
end
regs = { 'cs_prop_gain','170'; 'cs_integ_gain','174'; 'ss_prop_gain','178'; ...
         'ss_integ_gain','17C'; 'agc_loop_gain','180'; 'cfo_threshold','184' };
L = ['% --- loop-gain tuning mappings (Task C3: runtime-writable Rx loop' newline ...
     '%     constants; LEAN-only, reuse the canary 0x170-0x184 offsets which are' newline ...
     '%     env-guarded off in LEAN). Block-existence guard self-syncs with the' newline ...
     '%     loop_gain_axi_overlay gating. Inputs => AXI4-Lite WRITE registers. ---' newline];
L = [L 'if ~isempty(find_system(''' sys '/TxRxComposite'',''SearchDepth'',1,''BlockType'',''Inport'',''Name'',''cs_prop_gain''))' newline];
for i=1:size(regs,1)
    p = [sys '/TxRxComposite/' regs{i,1}];
    L = [L 'hdlset_param(''' p ''', ''IOInterface'', ''AXI4-Lite'');' newline]; %#ok<AGROW>
    L = [L 'hdlset_param(''' p ''', ''IOInterfaceMapping'', ''x"' regs{i,2} '"'');' newline]; %#ok<AGROW>
end
L = [L 'end' newline '% --- end loop-gain tuning mappings ---' newline];

anchor = ['hdlset_param(''' sys '/TxRxComposite/byte_rx_ready'', ''IOInterfaceMapping'', ''[0]'');'];
idx = strfind(txt, anchor);
assert(~isempty(idx), 'patch_hdlworkflow_loopgain: byte_rx_ready anchor not found in %s', wfFile);
at = idx(1) + numel(anchor);
if at <= numel(txt) && txt(at) == newline, at = at + 1; end
txt = [txt(1:at-1) newline L txt(at:end)];
fid = fopen(wfFile, 'w'); fwrite(fid, txt); fclose(fid);
fprintf('patch_hdlworkflow_loopgain: added 6 loop-gain AXI mappings 0x170-0x184 to %s\n', wfFile);
end
