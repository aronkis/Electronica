function patch_hdlworkflow_forensic(wfFile)
% patch_hdlworkflow_forensic -- add the T8.3 ADC-forensic AXI mapping
% (adc_forensic x"15C") to hdlworkflow_loopback.m.
% Pattern-clone of patch_hdlworkflow_taps.m. Idempotent. Inserts right after
% the cfc_est x"154" mapping so the read map stays contiguous.
% Register-map preservation: 0x100..0x154 untouched; ONLY 0x15C added
% (0x158 left reserved).

if nargin < 1, wfFile = 'hdlworkflow_loopback.m'; end
sys = 'commhdlQPSKTxRxLoopback';
txt = fileread(wfFile);
if contains(txt, 'adc_forensic mapping')
    fprintf('patch_hdlworkflow_forensic: already patched -- skipping\n');
    return;
end
L = ['% --- adc_forensic mapping (T8.3 valid-cadence + rail-level forensic) ---' newline];
L = [L 'hdlset_param(''' sys '/TxRxComposite/adc_forensic'', ''IOInterface'', ''AXI4-Lite'');' newline];
L = [L 'hdlset_param(''' sys '/TxRxComposite/adc_forensic'', ''IOInterfaceMapping'', ''x"15C"'');' newline];
L = [L '% --- end adc_forensic mapping ---' newline];
anchor = ['hdlset_param(''' sys '/TxRxComposite/cfc_est'', ''IOInterfaceMapping'', ''x"154"'');'];
idx = strfind(txt, anchor);
assert(~isempty(idx), 'patch_hdlworkflow_forensic: cfc_est anchor not found in %s', wfFile);
at = idx(1) + numel(anchor);
if at <= numel(txt) && txt(at) == newline, at = at + 1; end
txt = [txt(1:at-1) newline L txt(at:end)];
fid = fopen(wfFile, 'w');
fwrite(fid, txt); fclose(fid);
fprintf('patch_hdlworkflow_forensic: added AXI mapping 0x15C (adc_forensic) to %s\n', wfFile);
end
