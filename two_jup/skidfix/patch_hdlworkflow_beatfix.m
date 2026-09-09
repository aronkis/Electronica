function patch_hdlworkflow_beatfix(wfFile)
% patch_hdlworkflow_beatfix -- AXI mappings for the BEATFIX phase-contract fix
% (beatfix_overlay.m). Env-gated like the overlay: with QPSK_BEATFIX unset this
% is a NO-OP so the workflow file stays byte-identical (the ports don't exist).
%   fixctl              x"208"  uint32 WRITE (bit0 contract, bit1 ser-anchor,
%                               bit2 grid-pace; default 0 = legacy-identical)
%   beatfix_viol_count  x"20C"  uint32 READ  (always-on tag-continuity counter)
%   beatfix_viol_latch  x"210"  uint32 READ  ({delta[15:0], tag_prev[15:0]})
% 0x208-0x210 verified free (occupied map ends at loop_tune's 0x204).
% Pattern-clone of patch_hdlworkflow_forensic.m; idempotent.

if isempty(getenv('QPSK_BEATFIX'))
    fprintf('patch_hdlworkflow_beatfix: QPSK_BEATFIX unset -- no-op\n');
    return;
end
if nargin < 1, wfFile = 'hdlworkflow_loopback.m'; end
sys = 'commhdlQPSKTxRxLoopback';
txt = fileread(wfFile);
if contains(txt, 'beatfix mapping')
    fprintf('patch_hdlworkflow_beatfix: already patched -- skipping\n');
    return;
end
L = ['% --- beatfix mapping (phase contract: fixctl + violation counter/latch) ---' newline];
for p = {{'fixctl','208'}, {'beatfix_viol_count','20C'}, {'beatfix_viol_latch','210'}}
    L = [L 'hdlset_param(''' sys '/TxRxComposite/' p{1}{1} ''', ''IOInterface'', ''AXI4-Lite'');' newline]; %#ok<AGROW>
    L = [L 'hdlset_param(''' sys '/TxRxComposite/' p{1}{1} ''', ''IOInterfaceMapping'', ''x"' p{1}{2} '"'');' newline]; %#ok<AGROW>
end
L = [L '% --- end beatfix mapping ---' newline];
anchor = ['hdlset_param(''' sys '/TxRxComposite/cfc_est'', ''IOInterfaceMapping'', ''x"154"'');'];
idx = strfind(txt, anchor);
assert(~isempty(idx), 'patch_hdlworkflow_beatfix: cfc_est anchor not found in %s', wfFile);
at = idx(1) + numel(anchor);
if at <= numel(txt) && txt(at) == newline, at = at + 1; end
txt = [txt(1:at-1) newline L txt(at:end)];
fid = fopen(wfFile, 'w');
fwrite(fid, txt); fclose(fid);
fprintf('patch_hdlworkflow_beatfix: added AXI mappings 0x208/0x20C/0x210 to %s\n', wfFile);
end
