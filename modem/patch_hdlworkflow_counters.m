function patch_hdlworkflow_counters(wfFile)
% Add AXI4-Lite IOInterface mappings for the 6 FEC debug counter outports
% (0x120..0x134) into hdlworkflow_loopback.m. Idempotent. Inserts right after
% the bit_errors_out x"108" mapping (the same anchor variant_pre.m uses).
if nargin < 1, wfFile = 'hdlworkflow_loopback.m'; end
wfTxt = fileread(wfFile);
sys = 'commhdlQPSKTxRxLoopback';
if contains(wfTxt, 'fec_counters_overlay mappings')
    fprintf('patch_hdlworkflow_counters: already patched -- skipping\n');
    return;
end
% 0x11C sentinel FIRST so AXI addresses stay contiguous from the existing
% 0x100..0x118 block (HDL Coder's allocator needs no gap), then the 6 counters.
cnt = { 'dbg_sentinel','x"11C"'; ...
        'cnt_descr_in','x"120"'; 'cnt_frame_start','x"124"'; 'cnt_vit_reset','x"128"'; ...
        'cnt_deint_valid','x"12C"'; 'cnt_dec_bits','x"130"'; 'cnt_bist_start','x"134"'; ...
        'skip_count','x"138"'; ...        % dbg4: RUNTIME RxAlign align offset (writable)
        'cap_in','x"13C"'; 'cap_deint','x"140"'; 'cap_out','x"144"'; ...  % dbg6: stage bit-captures (read)
        'cap_cad','x"14C"' };             % dbg8: demod start/valid cadence diagnostic (read)
% NOTE (nodescr): cap_raw (0x148) and pn_phase (0x150) are BOTH absent in this
% variant (no descrambler -> no PN-phase register). 0x148/0x150 unused/reserved.
% (This array is unused at build time -- the workflow is already patched and the
%  idempotent patcher skips; the authoritative mappings live in the workflow.)
patch = sprintf('%% --- fec_counters_overlay mappings (FEC-Rx debug counters + skip_count) ---\n');
for k = 1:size(cnt,1)
    patch = [patch sprintf( ...
        'hdlset_param(''%s/TxRxComposite/%s'', ''IOInterface'', ''AXI4-Lite'');\n', sys, cnt{k,1})];
    patch = [patch sprintf( ...
        'hdlset_param(''%s/TxRxComposite/%s'', ''IOInterfaceMapping'', ''%s'');\n', sys, cnt{k,1}, cnt{k,2})];
end
patch = [patch sprintf('%% --- end fec_counters_overlay mappings ---\n')];

anchor = sprintf('hdlset_param(''%s/TxRxComposite/bit_errors_out'', ''IOInterfaceMapping'', ''x"108"'');', sys);
idx = strfind(wfTxt, anchor);
assert(~isempty(idx), 'anchor (bit_errors_out x"108") not found in %s', wfFile);
at = idx(1) + numel(anchor);
if at <= numel(wfTxt) && wfTxt(at) == newline, at = at + 1; end
fid = fopen(wfFile,'w');
fwrite(fid, [wfTxt(1:at-1) newline patch wfTxt(at:end)]);
fclose(fid);
fprintf('patch_hdlworkflow_counters: added 6 AXI mappings (0x120..0x134) to %s\n', wfFile);
end
