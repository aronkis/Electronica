function T = evm_report(sessionDir, cfg, opts)
%EVM_REPORT  Batch EVM runner over a capture-session directory.
%
%   T = evm_report(sessionDir, cfg, opts)
%
%   sessionDir layout (per two_jup/capture_evm.sh and the existing
%   two_jup/tapsmoke/<ts>_<A|B>/ and two_jup/paired/<ts>_<dir>/ conventions):
%     tap_m<mode>.bin   -- rx2-lpc debug-tap capture for that mode (evm_from_tap
%                          for mode>=1; mode==0 is AGC-out, a continuous/
%                          unheld raw stream, so it is routed to evm_ideal_ref
%                          instead, same as in_m0.bin below)
%     in_m<mode>.bin    -- rx-lpc receiver-input capture, same mode window
%                          (datapath-stability reference; also run through
%                          evm_from_tap in 'symbols'-agnostic raw mode is NOT
%                          meaningful -- these are logged but not EVM-scored
%                          unless mode==0, in which case they ARE the AGC-out
%                          raw stream and are routed to evm_ideal_ref instead)
%     pair.iq           -- raw rx-lpc capture (evm_ideal_ref)
%     regs_m<mode>.txt / regs_*.txt -- register snapshots (logged, not scored)
%     meta.txt          -- session metadata (copied into notes)
%
%   For each usable capture file found, runs evm_from_tap (tap_m*.bin) or
%   evm_ideal_ref (pair.iq / any file that looks like a raw AGC/rx-lpc
%   capture) and appends one row to evm/evm_results.csv (created here if
%   absent) with header:
%     ts,dir,mode,image,rms_evm,peak_evm,phase_evm,mag_evm,evm_excised,notes
%   Figures are saved as PNG next to the source captures. A comparison table
%   is printed and returned as T (a MATLAB table).

if nargin < 2 || isempty(cfg), cfg = evm_config_240k(); end
if nargin < 3, opts = struct(); end
if ~isfield(opts,'plot'),    opts.plot = true; end
if ~isfield(opts,'csvPath')
    opts.csvPath = fullfile(fileparts(mfilename('fullpath')), 'evm_results.csv');
end

assert(isfolder(sessionDir), 'evm_report:noDir', 'session dir not found: %s', sessionDir);
d = dir(sessionDir);

metaNote = '';
metaFile = fullfile(sessionDir, 'meta.txt');
if isfile(metaFile)
    m = fileread(metaFile);
    metaNote = strtrim(regexprep(m, '\s+', ' '));
end

rows = struct('ts',{},'dir',{},'mode',{},'image',{},'rms_evm',{},'peak_evm',{}, ...
    'phase_evm',{},'mag_evm',{},'evm_excised',{},'notes',{});

nowTs = char(datetime('now','Format','yyyyMMdd''_''HHmmss'));

% ---- tap_m<mode>.bin -> evm_from_tap ----
% mode 0 (AGC-out) is excluded here: it is a continuous (unheld) raw stream,
% not a debugValid-gated tap, so it belongs on the evm_ideal_ref path below
% (same as in_m0.bin) rather than evm_from_tap's low-confidence naive-stride
% fallback, which is only appropriate for genuinely held/strobed taps.
tapFiles = d(~[d.isdir] & ~cellfun(@isempty, regexp({d.name}, '^tap_m\d+\.bin$', 'once')));
tapFiles = tapFiles(cellfun(@(n) str2double(regexp(n,'\d+','match','once')), {tapFiles.name}) ~= 0);
for k = 1:numel(tapFiles)
    fn = tapFiles(k).name;
    modeNum = str2double(regexp(fn, '\d+', 'match', 'once'));
    fpath = fullfile(sessionDir, fn);
    try
        r = evm_from_tap(fpath, cfg, modeNum, struct('plot',opts.plot,'label',fn));
        notes = sprintf('nFrames=%d rot=%ddeg decim=%s conf=%s%s', r.nFrames, r.globalRotDeg, ...
            r.decimation.method, r.decimation.confidence, ternary(isempty(metaNote),'',[' | ' metaNote]));
        rows(end+1) = struct('ts',nowTs,'dir',sessionDir,'mode',num2str(modeNum),'image',fn, ...
            'rms_evm',r.rms_evm,'peak_evm',r.peak_evm,'phase_evm',r.phase_evm,'mag_evm',r.mag_evm, ...
            'evm_excised',r.evm_excised,'notes',notes); %#ok<AGROW>
        if opts.plot && ~isempty(r.figs)
            save_figs(r.figs, sessionDir, sprintf('tap_m%d', modeNum));
        end
    catch ME
        fprintf('[evm_report] WARN: evm_from_tap failed on %s: %s\n', fpath, ME.message);
        rows(end+1) = struct('ts',nowTs,'dir',sessionDir,'mode',num2str(modeNum),'image',fn, ...
            'rms_evm',NaN,'peak_evm',NaN,'phase_evm',NaN,'mag_evm',NaN,'evm_excised',NaN, ...
            'notes',['ERROR: ' ME.message]); %#ok<AGROW>
    end
end

% ---- pair.iq / raw rx-lpc capture -> evm_ideal_ref ----
% pair.iq (capture_paired.sh), raw.iq (capture_evm.sh's own passthrough
% capture), in_m0.bin (tap_smoke.sh's mode-0 receiver-input capture), and
% tap_m0.bin (mode-0 debug-tap capture, which is AGC-out and therefore
% continuous/unheld just like in_m0.bin) are all raw rx-lpc-equivalent
% streams -- route any that are present through evm_ideal_ref.
rawCands = {fullfile(sessionDir,'pair.iq'), fullfile(sessionDir,'raw.iq')};
inMode0 = fullfile(sessionDir, 'in_m0.bin');
if isfile(inMode0), rawCands{end+1} = inMode0; end
tapMode0 = fullfile(sessionDir, 'tap_m0.bin');
if isfile(tapMode0), rawCands{end+1} = tapMode0; end
for k = 1:numel(rawCands)
    fpath = rawCands{k};
    if ~isfile(fpath), continue; end
    [~, bn, ext] = fileparts(fpath); fn = [bn ext];
    try
        r = evm_ideal_ref(fpath, cfg, struct('plot',opts.plot,'label',fn));
        notes = sprintf('nFrames=%d rot=%ddeg CFO=%.0fHz%s', r.nFrames, r.globalRotDeg, ...
            r.coarseCFO, ternary(isempty(metaNote),'',[' | ' metaNote]));
        rows(end+1) = struct('ts',nowTs,'dir',sessionDir,'mode','ideal_ref','image',fn, ...
            'rms_evm',r.rms_evm,'peak_evm',r.peak_evm,'phase_evm',r.phase_evm,'mag_evm',r.mag_evm, ...
            'evm_excised',r.evm_excised,'notes',notes); %#ok<AGROW>
        if opts.plot && ~isempty(r.figs)
            save_figs(r.figs, sessionDir, 'ideal_ref');
        end
    catch ME
        fprintf('[evm_report] WARN: evm_ideal_ref failed on %s: %s\n', fpath, ME.message);
        rows(end+1) = struct('ts',nowTs,'dir',sessionDir,'mode','ideal_ref','image',fn, ...
            'rms_evm',NaN,'peak_evm',NaN,'phase_evm',NaN,'mag_evm',NaN,'evm_excised',NaN, ...
            'notes',['ERROR: ' ME.message]); %#ok<AGROW>
    end
end

if isempty(rows)
    fprintf('[evm_report] no recognized capture files (tap_m*.bin / pair.iq / in_m0.bin) in %s\n', sessionDir);
    T = table();
    return;
end

T = struct2table(rows);

% ---- append to CSV ----
header = {'ts','dir','mode','image','rms_evm','peak_evm','phase_evm','mag_evm','evm_excised','notes'};
writeHeader = ~isfile(opts.csvPath);
fid = fopen(opts.csvPath, 'a');
assert(fid > 0, 'evm_report:csvOpenFailed', 'cannot open %s for append', opts.csvPath);
if writeHeader
    fprintf(fid, '%s\n', strjoin(header, ','));
end
for i = 1:height(T)
    fprintf(fid, '%s,"%s",%s,"%s",%.4f,%.4f,%.4f,%.4f,%.4f,"%s"\n', ...
        T.ts{i}, csv_escape(T.dir{i}), T.mode{i}, csv_escape(T.image{i}), ...
        T.rms_evm(i), T.peak_evm(i), T.phase_evm(i), T.mag_evm(i), T.evm_excised(i), ...
        csv_escape(T.notes{i}));
end
fclose(fid);
fprintf('[evm_report] appended %d row(s) to %s\n', height(T), opts.csvPath);

% ---- comparison table ----
fprintf('\n%-24s %-8s %10s %10s %10s %10s %10s\n', 'image','mode','rms_evm','peak_evm','phase_evm','mag_evm','excised');
for i = 1:height(T)
    fprintf('%-24s %-8s %10.2f %10.2f %10.2f %10.2f %10.2f\n', T.image{i}, T.mode{i}, ...
        T.rms_evm(i), T.peak_evm(i), T.phase_evm(i), T.mag_evm(i), T.evm_excised(i));
end

end

function save_figs(figs, sessionDir, prefix)
for i = 1:numel(figs)
    fn = fullfile(sessionDir, sprintf('%s_fig%d.png', prefix, i));
    try
        exportgraphics(figs(i), fn);
    catch
        saveas(figs(i), fn);
    end
    close(figs(i));
end
end

function s = csv_escape(s)
s = strrep(s, '"', '""');
end

function s = ternary(cond, a, b)
if cond, s = a; else, s = b; end
end
