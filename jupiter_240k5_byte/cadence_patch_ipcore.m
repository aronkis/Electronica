function cadence_patch_ipcore(projFolder, mode)
% cadence_patch_ipcore -- apply the cadence RTL patch (RXROOT E11) to EVERYTHING
% the Vivado build consumes, between the 'Generate RTL Code and IP Core' task
% and project creation:
%   1. <proj>/hdlsrc/commhdlQPSKTxRxLoopback           (generated sources)
%   2. <proj>/ipcore/TxRxCompo_ip_v1_0/ (expanded)     (packaged IP, if present)
%   3. <proj>/ipcore/TxRxCompo_ip_v1_0.zip             (THE artifact
%      vivado_insert_ip.tcl feeds to update_ip_catalog -- authoritative)
% FAILS LOUDLY (error) unless the patched markers are verifiably present in the
% hdlsrc files AND inside the re-packed zip. Idempotent.

MARKERS = {'CADENCE FIX v6', 'enb_1_4_0_smp'};

% ---- 1. hdlsrc ----
hs = fullfile(projFolder, 'hdlsrc', 'commhdlQPSKTxRxLoopback');
assert(isfolder(hs), 'cadence_patch_ipcore: %s missing', hs);
cadence_rtl_patch(hs, mode);
verify_dir(hs, MARKERS);

% ---- 2./3. packaged ipcore ----
ipdir = fullfile(projFolder, 'ipcore');
zips = dir(fullfile(ipdir, '**', '*.zip'));   % packaged zip sits inside the component dir
assert(~isempty(zips), 'cadence_patch_ipcore: no ipcore zip under %s', ipdir);
for k = 1:numel(zips)
    zf = fullfile(zips(k).folder, zips(k).name);
    tmp = fullfile(tempname);
    unzip(zf, tmp);
    vdirs = find_hdl_dirs(tmp);
    assert(~isempty(vdirs), 'cadence_patch_ipcore: no composite RTL inside %s', zf);
    for v = 1:numel(vdirs)
        cadence_rtl_patch(vdirs{v}, mode);
        verify_dir(vdirs{v}, MARKERS);
    end
    % re-pack preserving the internal layout
    zip(zf, {'*'}, tmp);
    % verify the re-packed zip really carries the markers
    tmp2 = fullfile(tempname);
    unzip(zf, tmp2);
    vdirs2 = find_hdl_dirs(tmp2);
    assert(~isempty(vdirs2), 'cadence_patch_ipcore: re-packed zip lost the RTL?!');
    for v = 1:numel(vdirs2), verify_dir(vdirs2{v}, MARKERS); end
    rmdir(tmp, 's'); rmdir(tmp2, 's');
    fprintf('cadence_patch_ipcore: PATCH VERIFIED inside %s\n', zf);
    % the split workflow's CreateProject rediscovers the packaged IP by scanning
    % <proj>/ipcore/*.zip at the TOP level; stage 1 leaves the zip one level down
    % (ipcore/<comp>/<comp>.zip). Mirror the PATCHED zip to the top level so the
    % generated vivado_insert_ip.tcl points at a real file.
    ipinfo = dir(ipdir); absIp = ipinfo(1).folder;   % absolute path of ipdir
    topzip = fullfile(absIp, zips(k).name);
    if ~strcmp(zips(k).folder, absIp)                % skip if already at top level
        copyfile(zf, topzip);
        fprintf('cadence_patch_ipcore: mirrored patched zip -> %s\n', topzip);
    end
    % NOTE (build-6 lesson): do NOT pre-extract the component anywhere --
    % 'update_ip_catalog -add_ip <zip>' unzips it itself, and a pre-extracted
    % copy creates a DUPLICATE catalog entry, which makes get_ipdefs return two
    % defs and silently kills the create_bd_cell of the modem. The insert tcl's
    % degraded '-add_ip {./ipcore}' path is repaired at build time by the
    % sidecar (sidecar_fix.sh) which rewrites it to point at this patched zip.
end
% expanded component dir (some flows read it directly; keep consistent)
xdirs = find_hdl_dirs(ipdir);
for v = 1:numel(xdirs)
    cadence_rtl_patch(xdirs{v}, mode);
    verify_dir(xdirs{v}, MARKERS);
end
fprintf('cadence_patch_ipcore: DONE for %s\n', projFolder);
end

% ---------------------------------------------------------------------------
function dirs = find_hdl_dirs(root)
% directories containing the composite RTL (either naming convention)
dirs = {};
for nm = {'TxRxCompo_ip_src_TxRxComposite.v', 'TxRxComposite.v'}
    d = dir(fullfile(root, '**', nm{1}));
    for k = 1:numel(d)
        if ~any(strcmp(dirs, d(k).folder)), dirs{end+1} = d(k).folder; end %#ok<AGROW>
    end
end
end

% ---------------------------------------------------------------------------
function verify_dir(hdlDir, MARKERS)
d = [dir(fullfile(hdlDir, '*TxRxComposite.v')); dir(fullfile(hdlDir, '*Receiver.v'))];
% keep only the exact composite/receiver files
txt = '';
for k = 1:numel(d)
    if contains(d(k).name, 'Composite') || endsWith(d(k).name, 'Receiver.v')
        txt = [txt fileread(fullfile(d(k).folder, d(k).name))]; %#ok<AGROW>
    end
end
for m = 1:numel(MARKERS)
    assert(contains(txt, MARKERS{m}), ...
        'cadence_patch_ipcore: HARD VERIFY FAILED -- marker "%s" missing in %s (REFUSING to continue; do not build unpatched RTL)', ...
        MARKERS{m}, hdlDir);
end
fprintf('cadence_patch_ipcore: markers verified in %s\n', hdlDir);
end
