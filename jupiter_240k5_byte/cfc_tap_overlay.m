function cfc_tap_overlay(sys, base)
% cfc_tap_overlay -- debug-mux mode 5 = Coarse Frequency Compensator output.
%
% Bisects the mode-1 (postSS) -> mode-2 (postCS) gap: in THIS design the FTS
% chain is SS -> CFC -> CS (netlist-verified), so a live CFC-out stream
% separates {CFC estimator + derotation} corruption from {carrier sync}
% corruption during Class-1 episodes. CFC dataOut is sfix16_En14 == the mux
% data type; the DTC-SI is an identity wire in the netlist and exists only to
% keep the tap type context-independent (byte_harness_k5 lesson).
%
% Sim twin: wrap_byte_taps ... u_Frequency_and_Time_Synchronizer.
% Coarse_Frequency_Compensator_dataOut_re/_im (public in the inject harness).
%
% Apply AFTER canary3_telemetry_overlay (mode numbering: 4=telemetry, 5=CFC).
% Idempotent. Read-only tap: datapath untouched, gates must stay bit-identical.

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end

rcv = [base '/Receiver'];
qrx = [rcv '/QPSK Rx'];
fts = [qrx '/Frequency and Time Synchronizer'];
cfc = [fts '/Coarse Frequency Compensator'];

if ~isempty(find_system(fts,'SearchDepth',1,'LookUnderMasks','all', ...
        'FollowLinks','on','BlockType','Outport','Name','cfc_out'))
    fprintf('cfc_tap_overlay: already present -- skipping\n');
    return;
end

% surface CFC dataOut as a new FTS outport -- wire by outport NAME (Simulink
% port order != HDL port order; CFC has 4 outputs incl. rstCS/validOut)
pn = str2double(get_param([cfc '/dataOut'],'Port'));
nFts = numel(find_system(fts,'SearchDepth',1,'LookUnderMasks','all','BlockType','Outport'));
add_block('built-in/Outport',[fts '/cfc_out'],'Port',num2str(nFts+1), ...
    'Position',[1300 1150 1330 1166]);
add_line(fts, sprintf('Coarse Frequency Compensator/%d', pn), 'cfc_out/1', ...
    'autorouting','on');

% qrx level: DTC-SI + widen the debug mux by one data input (mode 5)
mux = find_system(qrx,'SearchDepth',1,'LookUnderMasks','all','BlockType','MultiPortSwitch');
assert(numel(mux)==1, 'expected exactly one debug MultiPortSwitch in QPSK Rx, found %d', numel(mux));
mux = mux{1};
nIn = str2double(get_param(mux,'Inputs'));
set_param(mux,'Inputs',num2str(nIn+1));
add_block('simulink/Signal Attributes/Data Type Conversion',[qrx '/CfcDtc'], ...
    'OutDataTypeStr','fixdt(1,16,14)','ConvertRealWorld','Stored Integer (SI)', ...
    'Position',[1510 1620 1550 1650]);
add_line(qrx, sprintf('Frequency and Time Synchronizer/%d', nFts+1), ...
    'CfcDtc/1', 'autorouting','on');
add_line(qrx, 'CfcDtc/1', sprintf('%s/%d', get_param(mux,'Name'), nIn+2), ...
    'autorouting','on');

fprintf('cfc_tap_overlay: DONE (0x10C=5 -> CFC output; SS->CFC->CS bisect)\n');
end
