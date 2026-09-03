% s1b_analyze_byte.m -- S1B NETLIST byte-gate analysis (jupiter_240k5_byte).
% Consumes the Verilator run artifacts produced by run_netlist_gates.sh:
%   rtl_sim/s1b_rot0_{sym.csv,rxw.txt,res.txt}   (word-aligned stream)
%   rtl_sim/s1b_rot17_{sym.csv,rxw.txt,res.txt}  (rotated word phase)
% and applies the S1B gate lines:
%   (a) AIR: modulator symbol stream -> frames; every frame from the first
%       golden frame on is BIT-EXACT to k5_240/rom_words_70_k5.txt
%   (b) BIST: cap_out == 0x04922282 and bit_errors STOPS increasing
%       (biterr@end == biterr@70%)
%   (c) BYTE-RX: steady-state 16-word packets == the golden info words
% Writes S1B_GATE.txt. Errors out on any gate failure.
KITDIR=fileparts(mfilename('fullpath'));
cd(KITDIR); addpath(KITDIR);
logf='s1b_analyze_byte.log'; if exist(logf,'file'), delete(logf); end
diary(logf);
fprintf('=== S1B analyze %s ===\n', char(datetime('now')));

CAPG = uint32(hex2dec('04922282'));
romLit = strtrim(fileread(fullfile(fileparts(KITDIR),'k5_240','rom_words_70_k5.txt')));
romW = eval(romLit); %#ok<EVLDIR>
rombits = zeros(2240,1);
for w2=0:69, for bb=0:31, rombits(w2*32+bb+1)=double(bitget(uint32(romW(w2+1)),32-bb)); end, end
rxGold = read_hexwords(fullfile('rtl_sim','rx_words_golden.hex')); assert(numel(rxGold)==16);

runs = {'s1b_rot0', 0, 3; 's1b_rot17', 17, 8};   % {prefix, rot, firstGold allowance}
allPass = true; lines = {};
for r = 1:size(runs,1)
    pfx = runs{r,1}; allow = runs{r,3};
    R = parse_res(fullfile('rtl_sim',[pfx '_res.txt']));
    S = readmatrix(fullfile('rtl_sim',[pfx '_sym.csv']),'FileType','text');
    sym = complex(S(:,1), S(:,2));
    [nF, firstG, nG, tailG, frErr] = air_frames_local(sym, rombits);
    gate_air = (nF>=15) && ~isnan(firstG) && (firstG<=allow) && tailG && (nG>=10);
    gate_bist = (R.capout==CAPG) && (R.biterr==R.errLate) && (R.packets>=R.pkLate+4);
    % byte-rx packets
    [W,L,U] = read_rxw(fullfile('rtl_sim',[pfx '_rxw.txt']));
    li = find(L); gate_rx=false; npk=0;
    if numel(li)>=3
        okp=true; npk=numel(li)-1;
        ncheck=min(4,npk);
        for k=npk-ncheck+1:npk
            seg = li(k)+1:li(k+1);
            okp = okp && numel(seg)==16 && isequal(W(seg),rxGold(:)) ...
                && U(seg(1)) && ~any(U(seg(2:end))) && L(seg(end)) && ~any(L(seg(1:end-1)));
        end
        gate_rx = okp && npk>=4;
    end
    ok = gate_air && gate_bist && gate_rx; allPass = allPass && ok;
    ln = sprintf(['%s: frames=%d firstGold=%d golden=%d tailGold=%d | cap=%08X ' ...
        'errs %u->%u pkts %u->%u | rx pkts=%d | %s'], pfx, nF, firstG, nG, tailG, ...
        R.capout, R.errLate, R.biterr, R.pkLate, R.packets, npk, ternary(ok,'PASS','FAIL'));
    fprintf('%s\n', ln); lines{end+1}=ln; %#ok<AGROW>
    fprintf('  perFrameErr(1:%d) = %s\n', min(nF,30), mat2str(frErr(1:min(nF,30))));
end

fid=fopen('S1B_GATE.txt','w');
fprintf(fid,'============ jupiter_240k5_byte S1B NETLIST BYTE GATE ============\n');
fprintf(fid,'date: %s\nresult: %s\n', char(datetime('now')), ternary(allPass,'PASS','FAIL'));
fprintf(fid,'DUT: makehdl TxRxComposite netlist (s1_rtl/hdlsrc, cadence_rtl_patch applied),\n');
fprintf(fid,'  Verilator wrap_byte.v + sim_byte.cpp: internal loopback, tx_data_source=1,\n');
fprintf(fid,'  1-in-2 adc_validIn, skip=0, AXIS byte source (registered handshake) driving\n');
fprintf(fid,'  the golden info frame (35 words: 1084 info bits + zero fill).\n');
fprintf(fid,'gates: air bits == K5 ROM words from first golden frame on; cap_out 0x04922282;\n');
fprintf(fid,'  bit_errors steady (end==70%%); byte-rx steady packets == 16 golden info words.\n');
for k=1:numel(lines), fprintf(fid,'%s\n', lines{k}); end
fprintf(fid,'==================================================================\n');
fclose(fid);
fprintf('WROTE S1B_GATE.txt (%s)\n', ternary(allPass,'PASS','FAIL'));
assert(allPass, 'S1B_GATE FAILED');
diary off;
fprintf('S1B_ANALYZE_DONE PASS\n');

% ---------------- local functions ----------------
function R = parse_res(f)
txt = fileread(f);
R.packets = grab(txt,'packets=(\d+)'); R.biterr = grab(txt,'biterr=(\d+)');
R.errLate = grab(txt,'errLate=(\d+)'); R.pkLate = grab(txt,'pkLate=(\d+)');
R.capout  = uint32(hex2dec(regexp(txt,'capout=([0-9a-fA-F]+)','tokens','once')));
end
function v = grab(txt,pat)
t = regexp(txt,pat,'tokens','once'); v = uint32(str2double(t{1}));
end
function [W,L,U] = read_rxw(f)
W=uint64([]); L=logical([]); U=logical([]);
fid=fopen(f,'r');
while true
    ln=fgetl(fid); if ~ischar(ln), break; end
    c=strsplit(ln,','); if numel(c)<3, continue; end
    W(end+1,1)=hex2u64(c{1});       %#ok<AGROW>
    L(end+1,1)=str2double(c{2})~=0; %#ok<AGROW>
    U(end+1,1)=str2double(c{3})~=0; %#ok<AGROW>
end
fclose(fid);
end
function w = read_hexwords(f)
txt = strtrim(fileread(f)); c = strsplit(txt); w = zeros(numel(c),1,'uint64');
for k=1:numel(c), w(k)=hex2u64(c{k}); end
end
function v = hex2u64(s)
% exact 64-bit hex parse (hex2dec goes through double -> lossy above 2^53)
s = char(strtrim(s));
if numel(s) < 16, s = [repmat('0',1,16-numel(s)) s]; end
v = bitor(bitshift(uint64(hex2dec(s(1:8))), 32), uint64(hex2dec(s(9:16))));
end
function [nFrames, firstGold, nGold, tailGold, frErr] = air_frames_local(sym, refbits)
sI = real(sym)>0; sQ = imag(sym)>0;
q  = double(sI)*2 + double(sQ);
bark = logical([1 1 1 1 1 0 0 1 1 0 1 0 1]);
preQ = zeros(1,13); preQ(~bark) = 3;
qr = q(:).'; n = numel(qr);
starts = [];
for i=1:n-12
    if isequal(qr(i:i+12), preQ), starts(end+1)=i; end %#ok<AGROW>
end
bitI = double(~sQ); bitQ = double(~sI);
nFrames=0; frErr=[];
for i=1:numel(starts)
    s0 = starts(i);
    if s0+13+1120-1 > n, break; end
    idx = s0+13 : s0+13+1120-1;
    bits = reshape([bitI(idx) bitQ(idx)].',[],1);
    frErr(end+1) = sum(bits(:) ~= refbits(:)); %#ok<AGROW>
    nFrames = nFrames+1;
end
gold = (frErr==0); firstGold=NaN; nGold=sum(gold); tailGold=false;
fi_ = find(gold,1);
if ~isempty(fi_), firstGold=fi_; tailGold=all(gold(fi_:end)); end
end
function s = ternary(c,a,b)
if c, s=a; else, s=b; end
end
