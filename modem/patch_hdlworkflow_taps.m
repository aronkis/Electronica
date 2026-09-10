function patch_hdlworkflow_taps(wfFile)
% patch_hdlworkflow_taps -- add the two jupiter_240k5 observability-tap AXI
% mappings (rstcs_count x"150", cfc_est x"154") to hdlworkflow_loopback.m.
% Pattern-clone of patch_hdlworkflow_counters.m. Idempotent. Inserts right
% after the cap_cad x"14C" mapping so the read map stays contiguous.
% Register-map preservation: 0x100..0x144 untouched; ONLY 0x150/0x154 added.

if nargin < 1, wfFile = 'hdlworkflow_loopback.m'; end
sys = 'commhdlQPSKTxRxLoopback';
txt = fileread(wfFile);
if contains(txt, 'taps_240k5 mappings')
    fprintf('patch_hdlworkflow_taps: already patched -- skipping\n');
    return;
end
maps = { 'rstcs_count','x"150"'; 'cfc_est','x"154"' };
L = ['% --- taps_240k5 mappings (rstCS event counter + CFC estimate) ---' newline];
for k = 1:size(maps,1)
    L = [L 'hdlset_param(''' sys '/TxRxComposite/' maps{k,1} ...
         ''', ''IOInterface'', ''AXI4-Lite'');' newline]; %#ok<AGROW>
    L = [L 'hdlset_param(''' sys '/TxRxComposite/' maps{k,1} ...
         ''', ''IOInterfaceMapping'', ''' maps{k,2} ''');' newline]; %#ok<AGROW>
end
L = [L '% --- end taps_240k5 mappings ---' newline];
anchor = ['hdlset_param(''' sys '/TxRxComposite/cap_cad'', ''IOInterfaceMapping'', ''x"14C"'');'];
idx = strfind(txt, anchor);
assert(~isempty(idx), 'patch_hdlworkflow_taps: cap_cad anchor not found in %s', wfFile);
at = idx(1) + numel(anchor);
if at <= numel(txt) && txt(at) == newline, at = at + 1; end
txt = [txt(1:at-1) newline L txt(at:end)];
fid = fopen(wfFile, 'w');
fwrite(fid, txt); fclose(fid);
fprintf('patch_hdlworkflow_taps: added AXI mappings 0x150 (rstcs_count) + 0x154 (cfc_est) to %s\n', wfFile);
end
