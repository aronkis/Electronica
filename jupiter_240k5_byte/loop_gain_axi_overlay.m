function loop_gain_axi_overlay(sys, base)
% loop_gain_axi_overlay -- make 6 receiver loop constants RUNTIME-writable via
% AXI4-Lite registers (0x170-0x184) so on-air EVM/BER tuning sweeps + per-rung
% loop retuning need no bitstream rebuild. Task C3.
%
% ZERO-DEFAULT = COMPILED CONSTANT, BIT-IDENTICAL (hard gate). For every site
% the ORIGINAL block (Gain / Compare-To-Constant) is LEFT UNTOUCHED on the
% mux's default (register==0) path, so with the registers at reset the netlist
% is provably bit-for-bit the shipped 240k behavior -- the added datapath is
% dead (its Switch selects the original) and only wakes on a nonzero write.
%
% Semantics per register: value 0 => compiled default; nonzero => the low W bits
% of the 32-bit word are reinterpreted (stored-integer passthrough) as the
% SAME fi type as the compiled constant, and drive the loop. Host writes the
% stored integer of the desired fixed-point value in the register's fi type.
%
% The 6 registers reuse the 0x170-0x184 offsets that the (debug-only) canary
% telemetry OUTPUT registers occupy in NON-LEAN builds. The JUPITER regmap is a
% UNIFIED read/write space (no offset is shared across directions), so this
% overlay is LEAN-ONLY: production/tuning images are LEAN (QPSK_LEAN=1) and the
% canaries are stripped there, freeing 0x170-0x184. Applying it to a non-LEAN
% build is a hard error (address collision). See README_BYTE.md.
%
% Apply LATE in assemble (after the byte plumbing) so the composite port set is
% stable; the hdlworkflow_loopback.m IOInterfaceMapping is patched separately by
% patch_hdlworkflow_loopgain(). Idempotent.
%
% Sites (traced 2026-07-21, probe_sites.m):
%   cs_prop_gain  0x170  Carrier Synchronizer/Loop Filter/Gain1  ufix16_En16 SI 98
%   cs_integ_gain 0x174  Carrier Synchronizer/Loop Filter/Gain   ufix16_En16 SI 1
%   ss_prop_gain  0x178  Symbol Synchronizer/Loop Filter/K1      sfix24_En24 SI -163506
%   ss_integ_gain 0x17C  Symbol Synchronizer/Loop Filter/K2      sfix24_En24 SI -2180
%   agc_loop_gain 0x180  Automatic Gain Control/Loop Filter/Gain1 (param LFG is
%                        a DOUBLE 2e-3 -> no native fi; runtime type CHOSEN
%                        ufix32_En31, zero-default keeps the exact double via
%                        the untouched Gain on the mux default path)
%   cfo_threshold 0x184  Coarse Frequency Compensator/CFO step change detector
%                        (Compare To Constant +/-thr) sfix22_En21 SI +/-26214

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end
loop = base;

% ---- guard: LEAN only (0x170-0x184 free), else address collision with canaries
if isempty(getenv('QPSK_LEAN'))
    error(['loop_gain_axi_overlay: NON-LEAN build -- 0x170-0x184 are occupied by ' ...
           'the canary telemetry registers. This overlay is LEAN-only. Assemble ' ...
           'with QPSK_LEAN=1 (production/tuning image).']);
end
assert(isempty(find_system(loop,'SearchDepth',1,'BlockType','Outport','Name','shdw_pdiv_cnt')), ...
    'loop_gain_axi_overlay: canary outport shdw_pdiv_cnt present -> 0x170 collision (non-LEAN)');

% ---- idempotency
if ~isempty(find_system(loop,'SearchDepth',1,'BlockType','Inport','Name','cs_prop_gain'))
    fprintf('loop_gain_axi_overlay: cs_prop_gain already present -- skipping\n');
    return;
end

rcv = [loop '/Receiver'];
qrx = [rcv '/QPSK Rx'];
fts = [qrx '/Frequency and Time Synchronizer'];
cs  = [fts '/Carrier Synchronizer'];
ss  = [fts '/Symbol Synchronizer'];
agc = [qrx '/Automatic Gain Control'];
cfc = [fts '/Coarse Frequency Compensator'];
cfod= [cfc '/CFO step change detector'];

% rate carriers (mirror debugMuxCtrl / skip_count): bus == rail == 15.36e6 (T8)
dm = [qrx '/debugMuxCtrl'];
assert(~isempty(find_system(qrx,'SearchDepth',1,'LookUnderMasks','all', ...
    'BlockType','Inport','Name','debugMuxCtrl')), 'debugMuxCtrl not found (rate ref)');
dmDT = get_param(dm,'OutDataTypeStr');   % uint32
dmST = get_param(dm,'SampleTime');       % 1/(Rsym*SamplesPerSymbol)
busST = '1/15.36e6';

% register table: name, addr(doc only), block, kind, [S W F]
R = { ...
 'cs_prop_gain',  '170', [cs  '/Loop Filter/Gain1'], 'gain', [0 16 16]; ...
 'cs_integ_gain', '174', [cs  '/Loop Filter/Gain'],  'gain', [0 16 16]; ...
 'ss_prop_gain',  '178', [ss  '/Loop Filter/K1'],    'gain', [1 24 24]; ...
 'ss_integ_gain', '17C', [ss  '/Loop Filter/K2'],    'gain', [1 24 24]; ...
 'agc_loop_gain', '180', [agc '/Loop Filter/Gain1'], 'gain', [0 32 31]; ...
 'cfo_threshold', '184', cfod,                       'cfo',  [1 22 21]; ...
};

udRef = struct();   % stash per-reg {si,s,w,f} for the poke test / host

for i = 1:size(R,1)
    name = R{i,1}; blk = R{i,3}; kind = R{i,4}; T = R{i,5};
    S=T(1); W=T(2); F=T(3);
    switch kind
        case 'gain'
            container = fileparts(blk);   % the Loop Filter subsystem
        case 'cfo'
            container = blk;              % the detector subsystem itself
    end
    % 1. thread a uint32 AXI inport from composite down to 'container'
    coeffSrc = thread_axi_down(loop, rcv, qrx, name, container, dmDT, dmST, busST);
    % 2. insert the zero-default-safe mux at the site
    switch kind
        case 'gain'
            insert_gain_mux(container, blk, name, coeffSrc, S, W, F);
        case 'cfo'
            insert_cfo_mux(container, name, coeffSrc, S, W, F);
    end
    % 3. record the compiled stored-integer reference for the poke/host
    udRef.(name) = ref_storedint(blk, kind, S, W, F);
    fprintf('loop_gain_axi_overlay: %-14s 0x%s  fi[s=%d w=%d f=%d]  wired\n', name, R{i,2}, S,W,F);
end

% stash refs on the TxRxComposite block's UserData (the model ROOT has no
% UserData param; a subsystem block does). Poke reads get_param(loop,'UserData').
ud = get_param(loop,'UserData');
if ~isstruct(ud), ud = struct(); end
ud.loopGainAxi = udRef;
set_param(loop,'UserData',ud,'UserDataPersistent','on');
fprintf('loop_gain_axi_overlay: DONE -- 6 loop-gain AXI regs 0x170-0x184 (LEAN)\n');
end

% ===================================================================
% thread a uint32 AXI inport: composite -> Receiver(rate xing) -> QPSK Rx ->
% ... -> target container. Returns the line-source spec ('<name>/1') INSIDE the
% target container that carries the routed uint32 value.
function coeffSrc = thread_axi_down(loop, rcv, qrx, name, container, dmDT, dmST, busST)
% build the container chain from Receiver down to 'container'
chain = {};                 % full paths, outermost (rcv) .. target
p = container;
while ~strcmp(p, loop)
    chain{end+1} = p; %#ok<AGROW>
    if strcmp(p, rcv), break; end
    p = fileparts(p);
end
chain = fliplr(chain);      % rcv, qrx, ..., container

% composite inport
nTop = numel(find_system(loop,'SearchDepth',1,'BlockType','Inport'));
add_block('built-in/Inport',[loop '/' name],'Port',num2str(nTop+1), ...
    'Position',[40 40+22*(nTop+1) 70 56+22*(nTop+1)]);
set_param([loop '/' name],'OutDataTypeStr',dmDT,'SampleTime',busST);

prevSrc = [name '/1'];      % line source available in the current parent
parent = loop;
for k = 1:numel(chain)
    c = chain{k};
    childName = get_param(c,'Name');
    nIn = numel(find_system(c,'SearchDepth',1,'LookUnderMasks','all','BlockType','Inport'));
    port = nIn+1;
    add_block('built-in/Inport',[c '/' name],'Port',num2str(port), ...
        'Position',[25 25+22*port 55 41*1+22*port]);
    if k==1
        set_param([c '/' name],'OutDataTypeStr',dmDT,'SampleTime',busST);
    else
        set_param([c '/' name],'OutDataTypeStr',dmDT,'SampleTime',dmST);
    end
    add_line(parent, prevSrc, sprintf('%s/%d', childName, port), 'autorouting','on');
    if k==1
        % Receiver: bus(15.36e6) -> rail(15.36e6) held-value crossing (skip_count
        % pattern: unit Delay + Downsample N=1 passthrough). Static config value.
        add_block('built-in/Delay',[c '/RegHold_' name],'DelayLength','1', ...
            'Position',[120 25+22*port 150 41+22*port]);
        add_block('dspsigops/Downsample',[c '/RegDS_' name],'N','1', ...
            'InputProcessing','Elements as channels (sample based)', ...
            'RateOptions','Allow multirate processing', ...
            'Position',[170 25+22*port 200 41+22*port]);
        add_line(c, [name '/1'], ['RegHold_' name '/1'], 'autorouting','on');
        add_line(c, ['RegHold_' name '/1'], ['RegDS_' name '/1'], 'autorouting','on');
        prevSrc = ['RegDS_' name '/1'];
    else
        prevSrc = [name '/1'];
    end
    parent = c;
end
coeffSrc = [name '/1'];      % inport line source inside the target container
end

% ===================================================================
% GAIN site: keep original Gain on the default path; parallel Product on the
% runtime path; Switch(nz) selects. Zero-default => original Gain bits.
function insert_gain_mux(container, gainBlk, name, coeffSrc, S, W, F)
gname = get_param(gainBlk,'Name');
% original Gain input source (branch it into the Product) + output dest (rewire)
gph = get_param(gainBlk,'PortHandles');
inLine = get_param(gph.Inport(1),'Line');
assert(inLine~=-1, 'gain %s input unconnected', gainBlk);
srcPH = get_param(inLine,'SrcPortHandle');
srcBlk = get_param(get_param(inLine,'SrcBlockHandle'),'Name');
srcPort = get_param(srcPH,'PortNumber');
outLine = get_param(gph.Outport(1),'Line');
assert(outLine~=-1, 'gain %s output unconnected', gainBlk);
dstBlk = get_param(get_param(outLine,'DstBlockHandle'),'Name');
dstPort = get_param(get_param(outLine,'DstPortHandle'),'PortNumber');
assert(isscalar(dstBlk) || ischar(dstBlk), 'gain %s fans out (%d) -- handle', gainBlk, numel(dstBlk));

% reinterpret MLFB: [coeff, nz] = f(axi)
mlfb = [container '/LGMux_' name];
add_block('simulink/User-Defined Functions/MATLAB Function', mlfb, ...
    'Position',[260 620 360 690]);
set_fcn_script(mlfb, reinterp_src(name, S, W, F));
add_line(container, coeffSrc, ['LGMux_' name '/1'], 'autorouting','on');

% Product: coeff .* tapped signal ; match the Gain's fixed-point output exactly
prod = [container '/LGProd_' name];
add_block('built-in/Product', prod, 'Inputs','2', 'Multiplication','Element-wise(.*)', ...
    'OutDataTypeStr', get_param(gainBlk,'OutDataTypeStr'), ...
    'RndMeth', get_param(gainBlk,'RndMeth'), ...
    'SaturateOnIntegerOverflow', get_param(gainBlk,'SaturateOnIntegerOverflow'), ...
    'Position',[420 600 460 660]);
add_line(container, sprintf('%s/%d', srcBlk, srcPort), ['LGProd_' name '/1'], 'autorouting','on');
add_line(container, ['LGMux_' name '/1'], ['LGProd_' name '/2'], 'autorouting','on');

% Switch: u2~=0 ? u1(Product) : u3(original Gain)
sw = [container '/LGSw_' name];
add_block('built-in/Switch', sw, 'Criteria','u2 ~= 0', ...
    'OutDataTypeStr', get_param(gainBlk,'OutDataTypeStr'), ...
    'Position',[520 600 560 700]);
delete_line(outLine);
add_line(container, ['LGProd_' name '/1'], ['LGSw_' name '/1'], 'autorouting','on');
add_line(container, ['LGMux_' name '/2'], ['LGSw_' name '/2'], 'autorouting','on');
add_line(container, sprintf('%s/1', gname), ['LGSw_' name '/3'], 'autorouting','on');
add_line(container, ['LGSw_' name '/1'], sprintf('%s/%d', dstBlk, dstPort), 'autorouting','on');
end

% ===================================================================
% CFO site: two Compare-To-Constant (x > +thr ; x < -thr). Keep both originals
% on the default path; add runtime compares (x vs +/- reinterpreted thr) and
% Switch each boolean on nz. Zero-default => original compare bits.
function insert_cfo_mux(container, name, coeffSrc, S, W, F)
cmpNames = {'Compare To Constant','Compare To Constant1'};   % +thr(>) , -thr(<)
ops = {'>','<'};   % must match the originals (probe: op '>' and '<')
% detector input x (source feeding the compares); REQUIRE both share a source
srcs = cell(1,2);
for j=1:2
    b=[container '/' cmpNames{j}];
    ph=get_param(b,'PortHandles'); li=get_param(ph.Inport(1),'Line');
    assert(li~=-1, 'CFO %s input unconnected', cmpNames{j});
    sName=get_param(get_param(li,'SrcBlockHandle'),'Name');
    sPort=get_param(get_param(li,'SrcPortHandle'),'PortNumber');
    srcs{j}=sprintf('%s/%d', sName, sPort);
end
assert(strcmp(srcs{1},srcs{2}), ...
    'insert_cfo_mux: the two CFO compares take DIFFERENT inputs (%s vs %s) -- fireNeg would compare the wrong signal', srcs{1}, srcs{2});
xsrc = srcs{1};
% MLFB: [firePos, fireNeg, nz] = f(axi, x)
mlfb=[container '/LGMux_' name];
add_block('simulink/User-Defined Functions/MATLAB Function', mlfb, 'Position',[260 620 380 720]);
set_fcn_script(mlfb, cfo_src(name, S, W, F, ops));
add_line(container, coeffSrc, ['LGMux_' name '/1'], 'autorouting','on');
add_line(container, xsrc,     ['LGMux_' name '/2'], 'autorouting','on');
% Switch each original compare output on nz
for j=1:2
    b=[container '/' cmpNames{j}];
    ph=get_param(b,'PortHandles'); lo=get_param(ph.Outport(1),'Line');
    assert(lo~=-1,'CFO %s output unconnected', cmpNames{j});
    dbh=get_param(lo,'DstBlockHandle');
    assert(numel(dbh)==1, 'insert_cfo_mux: %s output fans out (%d) -- unhandled', cmpNames{j}, numel(dbh));
    dName=get_param(dbh,'Name');
    dPort=get_param(get_param(lo,'DstPortHandle'),'PortNumber');
    sw=[container sprintf('/LGSw_%s_%d', name, j)];
    add_block('built-in/Switch', sw, 'Criteria','u2 ~= 0', 'Position',[520 600+120*(j-1) 560 700+120*(j-1)]);
    delete_line(lo);
    add_line(container, sprintf('LGMux_%s/%d', name, j), sprintf('LGSw_%s_%d/1', name, j), 'autorouting','on');
    add_line(container, sprintf('LGMux_%s/3', name),      sprintf('LGSw_%s_%d/2', name, j), 'autorouting','on');
    add_line(container, sprintf('%s/1', cmpNames{j}),     sprintf('LGSw_%s_%d/3', name, j), 'autorouting','on');
    add_line(container, sprintf('LGSw_%s_%d/1', name, j), sprintf('%s/%d', dName, dPort), 'autorouting','on');
end
end

% ===================================================================
function s = reinterp_src(name, S, W, F)
% [coeff, nz] = f(axi): low W bits reinterpreted as numerictype(S,W,F).
s = sprintf([ ...
'function [coeff, nz] = %s_mux(axi)\n' ...
'%%#codegen\n' ...
'nz = axi ~= uint32(0);\n' ...
'si = bitsliceget(axi, %d, 1);\n' ...
'coeff = reinterpretcast(si, numerictype(%d, %d, %d));\n' ...
'end\n'], name, W, S, W, F);
end

function s = cfo_src(name, S, W, F, ops)
% [firePos, fireNeg, nz] = f(axi, x): reinterpret thr, compare x vs +/-thr.
s = sprintf([ ...
'function [firePos, fireNeg, nz] = %s_mux(axi, x)\n' ...
'%%#codegen\n' ...
'nz = axi ~= uint32(0);\n' ...
'si = bitsliceget(axi, %d, 1);\n' ...
'thr = reinterpretcast(si, numerictype(%d, %d, %d));\n' ...
'firePos = x %s thr;\n' ...
'fireNeg = x %s (-thr);\n' ...
'end\n'], name, W, S, W, F, ops{1}, ops{2});
end

function set_fcn_script(blk, src)
rt = sfroot;
chart = rt.find('-isa','Stateflow.EMChart','Path',blk);
chart.Script = src;
end

% compiled stored-integer of the site's constant, in fi[S W F], for host/poke
function r = ref_storedint(blk, kind, S, W, F)
r = struct('s',S,'w',W,'f',F);
switch kind
    case 'gain'
        try
            g = slResolve(get_param(blk,'Gain'), blk);
            if isa(g,'embedded.fi')
                gd = double(g);
            else
                gd = double(g);
            end
        catch
            gd = NaN;
        end
        r.si = round(gd * 2^F);
    case 'cfo'
        try
            c = slResolve(get_param([blk '/Compare To Constant'],'const'), blk);
            r.si = round(double(c) * 2^F);
        catch
            r.si = NaN;
        end
end
end
