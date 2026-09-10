function pd_harness_k5(loopModel, matFile, outIq, stopSyms)
% pd_harness_k5 -- Simulink PD replay harness: run the EXACT consumed data
% (and implicitly state) from hardware telemetry through the assembled
% Preamble Detector subsystem, and emit the SAME serialized telemetry
% stream the hardware emits (PdTelemetry is inside the copied subsystem),
% so live-vs-sim comparison is npz-vs-npz through tel_pd_parse.py.
%
%   loopModel : assembled loopback model name (loaded) containing the P1D
%               overlay, e.g. 'commhdlQPSKTxRxLoopback'
%   matFile   : tel_export_mat.py output (drive_dI/dQ/drive_beats)
%   outIq     : output .iq path (int16 I,Q per beat = tap-file format)
%   stopSyms  : optional symbol cap (default: all records)
%
% Drive model: per record k, at its strobe beat dataIn takes the symbol
% value and validIn pulses 1; dataIn holds between strobes; inter-strobe
% spacing = drive_beats(k) (P1D beat field; 8 where absent). This is
% beat-exact reproduction of what the live PD consumed.

d = load(matFile);
nSym = numel(d.drive_dI);
if nargin >= 4 && ~isempty(stopSyms), nSym = min(nSym, stopSyms); end
beats = double(d.drive_beats(1:nSym));
strobe = cumsum(beats);                 % strobe beat index per symbol (1-based end)
nBeat = strobe(end) + 8;

loop = loopModel;
pdPath = [loop '/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector'];
assert(~isempty(find_system(pdPath,'SearchDepth',1,'LookUnderMasks','all', ...
    'FollowLinks','on','Name','PdTelemetry')), ...
    'pd_harness_k5: model has no PdTelemetry (assemble with the p1d overlay first)');

h = 'pd_harness';
if bdIsLoaded(h), close_system(h, 0); end
new_system(h);
% carry the loop model's config (internal-rule/hardware settings parity)
cs = getActiveConfigSet(loop);
csc = cs.copy; csc.Name = 'pdh_cfg';
attachConfigSet(h, csc, true);
setActiveConfigSet(h, 'pdh_cfg');
% mask parameters (Numerator/fifoSize/CountMax...) live in the loop model's
% workspace -- copy them into the harness model workspace
mwsS = get_param(loop, 'ModelWorkspace');
mwsD = get_param(h, 'ModelWorkspace');
for v = reshape(mwsS.whos, 1, [])
    mwsD.assignin(v.name, mwsS.getVariable(v.name));
end
fprintf('pd_harness: %d model-workspace vars copied\n', numel(mwsS.whos));
% blocks inside PD reference ANCESTOR MASK workspace variables (QPSK Rx /
% FTS masks) -- harvest the evaluated mask workspaces outer->inner so the
% extracted copy resolves them from the harness model workspace
anc = { [loop '/TxRxComposite'], [loop '/TxRxComposite/Receiver'], ...
        [loop '/TxRxComposite/Receiver/QPSK Rx'], ...
        [loop '/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer'], ...
        pdPath };
nmv = 0;
for a = anc
    try
        mv = get_param(a{1}, 'MaskWSVariables');
        for k = 1:numel(mv)
            mwsD.assignin(mv(k).Name, mv(k).Value);
            nmv = nmv + 1;
        end
    catch
    end
end
fprintf('pd_harness: %d ancestor mask vars harvested\n', nmv);
add_block(pdPath, [h '/PD'], 'Position', [400 80 700 520]);

% ---- introspect the PD copy's ports ----
ins  = find_system([h '/PD'],'SearchDepth',1,'BlockType','Inport');
outs = find_system([h '/PD'],'SearchDepth',1,'BlockType','Outport');
inNames = cellfun(@(b) get_param(b,'Name'), ins, 'UniformOutput', false);
outNames = cellfun(@(b) get_param(b,'Name'), outs, 'UniformOutput', false);
fprintf('pd_harness: PD inports = {%s}\n', strjoin(inNames, ', '));
fprintf('pd_harness: PD outports = {%s}\n', strjoin(outNames, ', '));
assert(numel(ins) == 2, 'pd_harness: expected 2 PD inports (dataIn, validIn), got %d', numel(ins));
% identify by type: the boolean one is validIn
dtIn = cellfun(@(b) get_param(b,'OutDataTypeStr'), ins, 'UniformOutput', false);
vIdx = find(contains(dtIn, 'boolean'), 1);
if isempty(vIdx)   % fall back to name match
    vIdx = find(contains(lower(inNames), 'valid'), 1);
end
assert(~isempty(vIdx), 'pd_harness: cannot identify validIn among {%s}', strjoin(inNames,','));
dIdx = 3 - vIdx;
telIi = find(strcmp(outNames, 'p1c_telI'), 1);
telQi = find(strcmp(outNames, 'p1c_telQ'), 1);
assert(~isempty(telIi) && ~isempty(telQi), 'pd_harness: p1c_tel ports not found on PD copy');
pIn  = cellfun(@(b) str2double(get_param(b,'Port')), ins);
pOut = cellfun(@(b) str2double(get_param(b,'Port')), outs);

% ---- build the beat-domain drive vectors ----
dataI = zeros(nBeat, 1); dataQ = zeros(nBeat, 1); valid = false(nBeat, 1);
prevI = 0; prevQ = 0; b0 = 1;
for k = 1:nSym
    sb = strobe(k);
    dataI(b0:sb-1) = prevI; dataQ(b0:sb-1) = prevQ;
    dataI(sb) = double(d.drive_dI(k)); dataQ(sb) = double(d.drive_dQ(k));
    valid(sb) = true;
    prevI = dataI(sb); prevQ = dataQ(sb); b0 = sb + 1;
end
dataI(b0:end) = prevI; dataQ(b0:end) = prevQ;
t = (0:nBeat-1)';
assignin('base', 'pdh_data', timeseries(complex(dataI, dataQ) * 2^-14, t));
assignin('base', 'pdh_valid', timeseries(valid, t));

% ---- wire: From Workspace -> DTC -> PD; tel outs -> To Workspace ----
add_block('simulink/Sources/From Workspace', [h '/SrcD'], 'VariableName','pdh_data', ...
    'SampleTime','1','Interpolate','off','ZeroCross','off','OutputAfterFinalValue','Holding final value', ...
    'Position',[80 100 180 130]);
add_block('simulink/Sources/From Workspace', [h '/SrcV'], 'VariableName','pdh_valid', ...
    'SampleTime','1','Interpolate','off','ZeroCross','off','OutputAfterFinalValue','Holding final value', ...
    'Position',[80 200 180 230]);
add_block('simulink/Signal Attributes/Data Type Conversion', [h '/DtcD'], ...
    'OutDataTypeStr','fixdt(1,16,14)','Position',[220 105 270 125]);
add_block('simulink/Signal Attributes/Data Type Conversion', [h '/DtcV'], ...
    'OutDataTypeStr','boolean','Position',[220 205 270 225]);
add_line(h, 'SrcD/1', 'DtcD/1'); add_line(h, ['DtcD/1'], sprintf('PD/%d', pIn(dIdx)));
add_line(h, 'SrcV/1', 'DtcV/1'); add_line(h, ['DtcV/1'], sprintf('PD/%d', pIn(vIdx)));
add_block('simulink/Sinks/To Workspace', [h '/TelI'], 'VariableName','pdh_telI', ...
    'SaveFormat','Array','SampleTime','1','Position',[820 100 900 130]);
add_block('simulink/Sinks/To Workspace', [h '/TelQ'], 'VariableName','pdh_telQ', ...
    'SaveFormat','Array','SampleTime','1','Position',[820 160 900 190]);
add_line(h, sprintf('PD/%d', pOut(telIi)), 'TelI/1');
add_line(h, sprintf('PD/%d', pOut(telQi)), 'TelQ/1');
for k = 1:numel(outs)
    if k == telIi || k == telQi, continue; end
    tn = sprintf('T%d', k);
    add_block('simulink/Sinks/Terminator', [h '/' tn], 'Position',[820 240+30*k 840 260+30*k]);
    add_line(h, sprintf('PD/%d', pOut(k)), [tn '/1']);
end

% ---- run ----
set_param(h, 'SolverType','Fixed-step', 'Solver','FixedStepDiscrete', ...
    'FixedStep','1', 'StopTime', num2str(nBeat - 1), ...
    'SaveOutput','off','SaveTime','off','SignalLogging','off');
fprintf('pd_harness: simulating %d symbols (%d beats)...\n', nSym, nBeat);
simOut = sim(h, 'ReturnWorkspaceOutputs', 'on');
telI = simOut.get('pdh_telI'); telQ = simOut.get('pdh_telQ');

% ---- write the tap-format stream ----
ti = int16(telI(:)); tq = int16(telQ(:));
iq = zeros(2*numel(ti), 1, 'int16'); iq(1:2:end) = ti; iq(2:2:end) = tq;
fid = fopen(outIq, 'w'); fwrite(fid, iq, 'int16'); fclose(fid);
fprintf('PD_HARNESS_DONE %s (%d beats)\n', outIq, numel(ti));
end
