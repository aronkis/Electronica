function cadence_rtl_patch(hdlDir, mode, applySticky)
% cadence_rtl_patch v6b -- per-board Rx sample cadence (KEPT) + sticky hardware
% reset (v6b: DISABLED by default), applied to the GENERATED Verilog
% (RXROOT E13/E14). Post-codegen transform.
%
% v6b CHANGE (regression fix): the STICKY RESET added in v6 REGRESSED silicon
% (zed Tx fragmented to 0.1ms-on/50ms-off bursts, zed Rx starved to ~30 pkts vs
% v5's full-rate golden, jupiter Rx 48%). Root cause: the first-release latch
% blocks the adc_1_rst datapath resyncs the modem NEEDS to reach and hold lock
% -> permanent mis-sync. The cadence strobe (v5-proven, zed on-chip golden
% 0.025%) is the essential fix and is KEPT verbatim. Sticky is now gated by the
% optional applySticky arg (DEFAULT false); pass true only to restore v6.
%
% mode 'zed' (IPCORE_CLK = 30.72 MHz deployed):
%   v5 logic unchanged (silicon-proven GOLDEN: BIST CAP_OUT 0x04922282,
%   BER 0.025%): free-running mod-4 counter on the enb_1_4_0 rail
%   (7.68 MHz / 1.92 Msps = 4 beats/sample), loopback bypass via
%   rx_input_select==0.
%
% mode 'jupiter' (IPCORE_CLK = adc_1_clk = 3.84 MHz deployed -- clock monitor
%   CLK_FREQ 0x9D4 = 2516/65536 x 100 MHz AXI ref; CLK_RATIO 0x4 -> dclk
%   15.36 MHz LVDS):
%   The deployed clock is DESIGN-CORRECT for Tx: REP_TxI/Q are x2 polyphase
%   interpolators on enb_1_2_0, so Tx output = clk/2 = 1.92 Msps (matches the
%   measured 240-ksym air). The Rx ingress however DECIMATES: Downsample2/3
%   (enb_1_4_1 passthrough) keep only every other TRUE sample when the /2 rail
%   equals the stream rate -> the QPSK Rx saw 4 sps of an 8 sps design ->
%   ~46% BER (defect 2). FIX: retime the Rx ingress + core to the /2 rail:
%   Downsample2/3 passthrough on enb_1_2_1 (no decimation), Delay3/Delay on
%   enb_1_2_0, and QPSK_Rx + Capture_Data_Bits enabled by enb_1_2_0 (1 beat
%   per sample, N=1 -- also correct for loopback BIST, whose internal Tx
%   produces one sample per /2 beat). No composite edits, no counters.
%
% STICKY RESET (RXROOT E14, v6 only -- DISABLED in v6b): would gate reset_cm in
% the packaged IP top (TxRxCompo_ip.v) with a first-release latch so only the
% power-on assertion resets the modem, ignoring later adc_1_rst pulses. On
% silicon this BLOCKED the datapath resyncs the modem needs -> regression.
% v6b leaves reset_cm = ~IPCORE_RESETN (stock v5 behavior). The patch_top_sticky
% transform is retained but only runs when applySticky==true.
%
% Idempotent. Markers: 'CADENCE FIX v6', 'enb_1_4_0_smp' (cadence, KEPT).
% 'STICKY RESET (RXROOT E14)' marker is ABSENT in v6b (applySticky==false).

if nargin < 3, applySticky = false; end   % v6b: sticky reset OFF by default
assert(any(strcmp(mode, {'zed','jupiter'})), ...
    'cadence_rtl_patch: mode must be ''zed'' or ''jupiter''');
d = dir(fullfile(hdlDir, '*.v'));
names = {d.name};
recv = pick(names, {'Receiver.v','TxRxCompo_ip_src_Receiver.v'});
if strcmp(mode, 'zed')
    comp = pick(names, {'TxRxComposite.v','TxRxCompo_ip_src_TxRxComposite.v'});
    patch_composite_zed(fullfile(hdlDir, comp));
    patch_receiver_zed(fullfile(hdlDir, recv));
else
    comp = pick(names, {'TxRxComposite.v','TxRxCompo_ip_src_TxRxComposite.v'});
    patch_composite_zed(fullfile(hdlDir, comp));      % cadBypass + dataInT port
    patch_composite_jupiter(fullfile(hdlDir, comp));  % enb_1_2_1 threading
    patch_receiver_jupiter(fullfile(hdlDir, recv));
end
topName = 'TxRxCompo_ip.v';
if applySticky && any(strcmp(names, topName))
    patch_top_sticky(fullfile(hdlDir, topName));   % v6b: gated OFF by default
elseif any(strcmp(names, topName))
    fprintf('cadence_rtl_patch v6b: sticky reset DISABLED (applySticky=false) -- %s left stock\n', topName);
end
fprintf('cadence_rtl_patch v6b (%s): patched %s in %s\n', mode, recv, hdlDir);
end

% ---------------------------------------------------------------------------
function nm = pick(names, cands)
nm = '';
for k = 1:numel(cands)
    if any(strcmp(names, cands{k})), nm = cands{k}; return; end
end
error('cadence_rtl_patch: none of %s found', strjoin(cands, ', '));
end

% ============================ zed (v5 verbatim) ============================
function patch_composite_zed(f)
s = fileread(f);
if contains(s, 'cadBypass')
    fprintf('cadence_rtl_patch: %s already patched -- skip\n', f); return;
end
anchor = sprintf('  assign MUX_RxI_out1 = (rx_input_select');
i = strfind(s, anchor); assert(~isempty(i), 'MUX_RxI_out1 not found');
i = i(1);
inj = [ ...
'  // ===== CADENCE FIX v6 (zed = v5 logic, RXROOT E13) ==================', newline, ...
'  wire cadBypass = (rx_input_select == 1''b0);', newline, ...
'  // ====================================================================', newline];
s = [s(1:i-1), inj, s(i:end)];
s = inject_port(s, 'Receiver', 'u_Receiver', '.dataInT(cadBypass),');
writefile(f, s);
end

function patch_receiver_zed(f)
s = fileread(f);
if contains(s, 'enb_1_4_0_smp')
    fprintf('cadence_rtl_patch: %s already patched -- skip\n', f); return;
end
s = regexprep(s, '(\n\s*)validIn,(\s*\n\s*dataInI,)', '$1dataInT,$1validIn,$2', 'once');
s = regexprep(s, '(\n\s*input\s+)validIn;(\s*\n\s*input\s+signed \[15:0\] dataInI;)', ...
    '$1dataInT;  // cadence strobe bypass (loopback)$1validIn;$2', 'once');
istart = strfind(s, 'QPSK_Rx u_QPSK_Rx ('); assert(~isempty(istart), 'u_QPSK_Rx inst not found');
istart = istart(1);
ls = find(s(1:istart)==newline, 1, 'last') + 1;
inj = [ ...
'  // ===== CADENCE FIX v6 (zed, RXROOT E13): mod-4 rail sample strobe ===', newline, ...
'  reg [1:0] cadCnt;', newline, ...
'  always @(posedge clk or posedge reset) begin', newline, ...
'    if (reset) cadCnt <= 2''d0;', newline, ...
'    else if (enb_1_4_0) cadCnt <= (cadCnt == 2''d3) ? 2''d0 : cadCnt + 2''d1;', newline, ...
'  end', newline, ...
'  wire newSample     = dataInT | (cadCnt == 2''d0);', newline, ...
'  wire enb_1_4_0_smp = enb_1_4_0 & newSample;', newline, ...
'  // ====================================================================', newline];
s = [s(1:ls-1), inj, s(ls:end)];
s = gate_enable(s, 'u_QPSK_Rx', 'enb_1_4_0_smp');
s = gate_enable(s, 'u_Capture_Data_Bits', 'enb_1_4_0_smp');
writefile(f, s);
end

% ============================ jupiter (div2 retime) ========================
function patch_receiver_jupiter(f)
s = fileread(f);
if contains(s, 'enb_1_4_0_smp')
    fprintf('cadence_rtl_patch: %s already patched -- skip\n', f); return;
end
% add the enb_1_2_1 input (threaded from the composite tc) and retime the
% Downsample2/3 passthrough to it: faithful half-beat staging of the
% original /4 pipeline (passthrough on /2 phase-1, Delay3 capture on phase-0)
s = regexprep(s, '(\n\s*)enb_1_2_0,', '$1enb_1_2_0,$1enb_1_2_1,', 'once');
s = regexprep(s, '(\n\s*input\s+)enb_1_2_0;', '$1enb_1_2_0;$1enb_1_2_1;  // v6 jupiter retime phase', 'once');
% dataInT = cadBypass from the composite (loopback mode indicator)
s = regexprep(s, '(\n\s*)validIn,(\s*\n\s*dataInI,)', '$1dataInT,$1validIn,$2', 'once');
s = regexprep(s, '(\n\s*input\s+)validIn;(\s*\n\s*input\s+signed \[15:0\] dataInI;)', ...
    '$1dataInT;  // loopback mode (cadBypass)$1validIn;$2', 'once');
n0 = count_occ(s, 'enb_1_4_1');
s = strrep(s, '(enb_1_4_1 == 1''b1 ?', '(enb_1_2_1 == 1''b1 ?');
s = regexprep(s, 'if \(enb_1_4_1\) begin(\s*\n\s*Downsample)', 'if (enb_1_2_1) begin$1');
assert(count_occ(s, 'enb_1_4_1') < n0, 'Downsample2/3 retime failed');
s = regexprep(s, 'if \(enb_1_4_0\) begin(\s*\n\s*Delay3_out1_re)', 'if (enb_1_2_0) begin$1');
s = regexprep(s, 'if \(enb_1_4_0\) begin(\s*\n\s*Delay_out1_re)',  'if (enb_1_2_0) begin$1');
istart = strfind(s, 'QPSK_Rx u_QPSK_Rx ('); assert(~isempty(istart), 'u_QPSK_Rx inst not found');
istart = istart(1);
ls = find(s(1:istart)==newline, 1, 'last') + 1;
inj = [ ...
'  // ===== CADENCE FIX v6 (jupiter, RXROOT E14): RX_DIV2_RETIME =========', newline, ...
'  // ADC mode: deployed IPCORE_CLK = adc_1_clk = 3.84 MHz; /2 rail = 1.92', newline, ...
'  // MHz = the SSI sample rate exactly -> one Rx beat per true sample and', newline, ...
'  // the ingress no longer decimates (Downsample2/3 retimed to /2).', newline, ...
'  // LOOPBACK: the internal source is the x2-interpolated REP stream (one', newline, ...
'  // sample per /2 beat at DOUBLE density); consuming it at /4 reproduces', newline, ...
'  // the original Downsample-by-2 loopback behavior (zed-silicon-proven).', newline, ...
'  wire enb_1_4_0_smp = dataInT ? enb_1_4_0 : enb_1_2_0;', newline, ...
'  // ====================================================================', newline];
s = [s(1:ls-1), inj, s(ls:end)];
s = gate_enable(s, 'u_QPSK_Rx', 'enb_1_4_0_smp');
s = gate_enable(s, 'u_Capture_Data_Bits', 'enb_1_4_0_smp');
writefile(f, s);
end

% ---- jupiter composite: thread enb_1_2_1 into the Receiver instance ----
function patch_composite_jupiter(f)
s = fileread(f);
% idempotency must be checked WITHIN the u_Receiver instance: the REP
% instances naturally contain '.enb_1_2_1(enb_1_2_1),' elsewhere in the file
i = strfind(s, 'Receiver u_Receiver (');
assert(~isempty(i), 'u_Receiver instance not found in %s', f);
seg = s(i(1):min(end, i(1)+2500));
if contains(seg, '.enb_1_2_1(')
    fprintf('cadence_rtl_patch: %s already threaded -- skip\n', f); return;
end
s = inject_port(s, 'Receiver', 'u_Receiver', '.enb_1_2_1(enb_1_2_1),');
writefile(f, s);
end

% ============================ sticky reset (both) ==========================
function patch_top_sticky(f)
s = fileread(f);
if contains(s, 'STICKY RESET')
    fprintf('cadence_rtl_patch: %s sticky already applied -- skip\n', f); return;
end
old = 'assign reset_cm =  ~ IPCORE_RESETN;';
i = strfind(s, old); assert(~isempty(i), 'reset_cm assign not found in %s', f);
new = [ ...
'// ===== STICKY RESET (RXROOT E14) ======================================', newline, ...
'// IPCORE_RESETN = NOT(axi_adrv9001/adc_1_rst) pulses on SSI resync events', newline, ...
'// (ADRV9001 tracking cals, ~1/min) and was zeroing the modem/BIST state.', newline, ...
'// Only the FIRST release arms the modem; later pulses are ignored. The AXI', newline, ...
'// soft reset (reset_internal) still resets the modem deliberately.', newline, ...
'  reg rstDone = 1''b0;', newline, ...
'  always @(posedge IPCORE_CLK) begin', newline, ...
'    if (IPCORE_RESETN == 1''b1) rstDone <= 1''b1;', newline, ...
'  end', newline, ...
'  assign reset_cm = ( ~ IPCORE_RESETN) & ( ~ rstDone);', newline, ...
'// ======================================================================'];
s = [s(1:i(1)-1), new, s(i(1)+numel(old):end)];
writefile(f, s);
fprintf('cadence_rtl_patch: sticky reset applied to %s\n', f);
end

% ---------------------------------------------------------------------------
function s = gate_enable(s, inst, sig)
i = strfind(s, inst); assert(~isempty(i), '%s not found', inst); i = i(1);
seg = s(i:min(end, i+4000));
seg2 = regexprep(seg, '\.enb_1_4_0\(enb_1_4_0\)', ['.enb_1_4_0(' sig ')'], 'once');
assert(~strcmp(seg, seg2), 'enable not gated for %s', inst);
s = [s(1:i-1), seg2, s(i+numel(seg):end)];
end

function s = inject_port(s, modName, instName, portLine)
i = strfind(s, [modName ' ' instName ' (']);
if isempty(i), i = strfind(s, [instName ' (']); end
assert(~isempty(i), '%s instance not found', instName); i = i(1);
j = strfind(s(i:end), '.clk(clk),'); assert(~isempty(j), 'clk port not found');
j = i + j(1) + numel('.clk(clk),') - 1;
k = find(s(j:end)==newline, 1, 'first') + j - 1;
pad = '                       ';
s = [s(1:k), pad, portLine, s(k:end)];
end

function n = count_occ(s, pat)
n = numel(strfind(s, pat));
end

function writefile(f, s)
fid = fopen(f, 'w'); fwrite(fid, s); fclose(fid);
end
