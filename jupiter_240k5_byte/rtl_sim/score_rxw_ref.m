function res = score_rxw_ref(prefix, ref)
% score_rxw_ref  Offline reference scorer for the RTL-replay decoded byte output.
%
%   res = score_rxw_ref(PREFIX)         score <PREFIX>_rxw.txt vs the -B ref
%   res = score_rxw_ref(PREFIX, REF)    score vs a custom 16-word reference
%   score_rxw_ref('selftest')           run the built-in classifier self-test
%
% Reads the <PREFIX>_rxw.txt file written by sim_byte_iq / Vwrap_byte
% (one line per accepted decoded beat: "hex,last,user"; last==1 marks the end
% of a 16-word = 128-byte frame), groups 16-word frames by the `last` flag
% exactly as s1b_analyze_byte.m/read_rxw does, and classifies each frame against
% a 16-word reference using a WORD-ROTATION Hamming search + a PHASE bucket.
% This is a direct MATLAB port of host_app_k5/qpsk_ber.c (qpsk_ber_score_frame):
%
%   ham0  = Hamming(rx, ref)                     (aligned, k=0)
%   bestk = argmin_k Hamming(rx, rot(ref,k))     (k=0..15 words; strict-< so k=0
%                                                  wins ties -> ROTATED needs a
%                                                  strictly better non-zero rot)
%   f0 = ham0/1024 ,  fb = bestham/1024
%     ham0==0                  -> CLEAN
%     f0  < 0.10               -> NOISY    (counts toward BER)
%     fb  < 0.10 && bestk~=0   -> ROTATED  (a word slip aligns it)
%     f0 >= 0.35               -> PHASE    (aligned but scrambled -> quadrant/slip)
%     else                     -> MISS
% Bits/frame = 16 words * 64 = 1024.  BER is computed over CLEAN+NOISY frames
% only, plus a per-128-byte-offset (LSB-byte-first) error map over those frames.
%
% NOTE: no 90/180/270 QPSK quadrant de-rotation is attempted -- a quadrant
% rotation scrambles the coded stream non-linearly and is NOT recoverable at the
% byte level; such frames land (correctly) in the PHASE bucket.
%
% REF may be: omitted/[]  -> the built-in -B reference (QK header seq=0x1a5);
%             uint64(16)  -> used directly;
%             char/string -> path to a hexwords file (read like rx_words_golden.hex).

    CLEAN=1; NOISY=2; PHASE=3; ROTATED=4; MISS=5;
    names = {'CLEAN','NOISY','PHASE','ROTATED','MISS'};
    PC = uint16(sum(dec2bin(0:255)-'0', 2));   % 8-bit popcount table, PC(b+1)=popc(b)

    if nargin>=1 && (ischar(prefix)||isstring(prefix)) && strcmpi(prefix,'selftest')
        selftest(PC); return;
    end

    if nargin < 2 || isempty(ref)
        ref = default_ref_B();
    elseif ischar(ref) || isstring(ref)
        ref = read_hexwords(char(ref));
    end
    ref = uint64(ref(:));
    assert(numel(ref)==16, 'reference must be 16 uint64 words');

    rxwf = [char(prefix) '_rxw.txt'];
    [W,L,U] = read_rxw(rxwf); %#ok<ASGLU>

    li  = find(L);
    nfr = max(0, numel(li)-1);           % drop the leading all-zeros prime frame
    buckets = zeros(1,5);
    total_bits = 0; total_errs = 0;
    peroff = zeros(1,128);
    nbad = 0;

    for kf = 1:nfr
        seg = li(kf)+1 : li(kf+1);
        if numel(seg) ~= 16, nbad = nbad+1; continue; end
        rxw = W(seg);
        [b, ham0] = classify_frame(rxw, ref, PC);
        buckets(b) = buckets(b) + 1;
        if b==CLEAN || b==NOISY
            total_bits = total_bits + 1024;
            total_errs = total_errs + ham0;
            for w = 1:16                 % per-offset error map (aligned, LSB-first)
                for j = 0:7
                    rb = bitand(bitshift(rxw(w), -8*j), uint64(255));
                    fb = bitand(bitshift(ref(w), -8*j), uint64(255));
                    off = 8*(w-1) + j;
                    peroff(off+1) = peroff(off+1) + ...
                        double(PC(double(bitxor(rb,fb)) + 1));
                end
            end
        end
    end

    aligned = buckets(CLEAN) + buckets(NOISY);
    ber = 0; havBER = total_bits > 0;
    if havBER, ber = total_errs / total_bits; end

    res = struct('prefix',char(prefix), 'file',rxwf, 'frames',nfr, ...
        'buckets',buckets, 'names',{names}, 'aligned',aligned, ...
        'total_bits',total_bits, 'bit_errors',total_errs, ...
        'ber',ber, 'ber_measurable',havBER, 'per_offset',peroff, 'malformed',nbad);

    % ---- report ----
    fprintf('=== score_rxw_ref: %s ===\n', rxwf);
    fprintf('frames=%d  aligned(clean+noisy)=%d  total_bits=%d  bit_errors=%d\n', ...
            nfr, aligned, total_bits, total_errs);
    if havBER
        fprintf('BER = %.3e   (over %d CLEAN+NOISY frames)\n', ber, aligned);
    else
        fprintf('BER = N/A (0 aligned frames -- BER NOT MEASURABLE; not "clean")\n');
    end
    fprintf('buckets:');
    for i = 1:5
        pct = 0; if nfr>0, pct = 100*buckets(i)/nfr; end
        fprintf(' %s=%d(%.1f%%)', names{i}, buckets(i), pct);
    end
    fprintf('\n');
    if nbad>0, fprintf('malformed(non-16-word) frames skipped: %d\n', nbad); end
    if any(peroff)
        fprintf('per-offset bit errors (byte 0..127):\n');
        for i = 0:127
            if mod(i,16)==0, fprintf('  [%3d]', i); end
            fprintf(' %6d', peroff(i+1));
            if mod(i,16)==15, fprintf('\n'); end
        end
    else
        fprintf('per-offset map empty (no CLEAN/NOISY frames to accumulate)\n');
    end
end

% ---------------- core classifier (shared by loop + self-test) ----------------
function [b, ham0, bestk] = classify_frame(rxw, ref, PC)
    CLEAN=1; NOISY=2; PHASE=3; ROTATED=4; MISS=5;
    ham = zeros(1,16);
    for k = 0:15
        rr = ref(mod((0:15)+k, 16) + 1);     % rotate ref by k words (= 8k bytes)
        h = 0;
        for w = 1:16
            h = h + popc64(bitxor(rxw(w), rr(w)), PC);
        end
        ham(k+1) = h;
    end
    ham0 = ham(1);
    bestham = ham0; bestk = 0;               % strict-< : k=0 wins ties
    for k = 1:15
        if ham(k+1) < bestham, bestham = ham(k+1); bestk = k; end
    end
    f0 = ham0/1024; fb = bestham/1024;
    if     ham0==0,               b = CLEAN;
    elseif f0 < 0.10,             b = NOISY;
    elseif fb < 0.10 && bestk~=0, b = ROTATED;
    elseif f0 >= 0.35,            b = PHASE;
    else                          b = MISS;
    end
end

function p = popc64(x, PC)
    p = 0;
    for j = 0:7
        b = bitand(bitshift(x, -8*j), uint64(255));
        p = p + double(PC(double(b) + 1));
    end
end

% ---------------- reference builders (LSB-64-bit exact) ----------------
function w = default_ref_B()
% The -B reference frame = 128 bytes = 16 uint64 words (LSB-byte-first).
% word0 = 0x000001a500004b51 : 'Q'0x51 'K'0x4B, len=0, seq=0x1a5.
    hx = {'000001a500004b51','cb3a16fd6db8acfb','ea6bc16e6bd07d3c', ...
          'd793ce81bbbc52a0','0fefd06c2f9c2151','1eed942073f13df8', ...
          '444c5c6d1ca9d87c','c84d6f58e5841102','3335f92dc97e5aa1', ...
          '96752cfa4ba38c01','d5d782ddd6a0fb78','ae279d037779a540', ...
          '1fdea1d95e3843a2','3cda2941e6e27bf0','8898b8da3852b1f9', ...
          '919bdeb0ca092304'};
    w = zeros(16,1,'uint64');
    for k = 1:16, w(k) = hex2u64(hx{k}); end
end

function w = read_hexwords(f)
    txt = strtrim(fileread(f)); c = strsplit(txt);
    c = c(~cellfun(@isempty,c));
    w = zeros(numel(c),1,'uint64');
    for k = 1:numel(c), w(k) = hex2u64(c{k}); end
end

function v = hex2u64(s)
% exact 64-bit hex parse (hex2dec goes through double -> lossy above 2^53)
    s = char(strtrim(s));
    if numel(s) < 16, s = [repmat('0',1,16-numel(s)) s]; end
    v = bitor(bitshift(uint64(hex2dec(s(1:8))), 32), uint64(hex2dec(s(9:16))));
end

% ---------------- rxw reader (ported from s1b_analyze_byte.m) ----------------
function [W,L,U] = read_rxw(f)
    W = uint64([]); L = logical([]); U = logical([]);
    fid = fopen(f,'r');
    if fid<0, error('cannot open %s', f); end
    while true
        ln = fgetl(fid); if ~ischar(ln), break; end
        c = strsplit(ln, ','); if numel(c) < 3, continue; end
        W(end+1,1) = hex2u64(c{1});        %#ok<AGROW>
        L(end+1,1) = str2double(c{2}) ~= 0; %#ok<AGROW>
        U(end+1,1) = str2double(c{3}) ~= 0; %#ok<AGROW>
    end
    fclose(fid);
end

% ---------------- built-in self-test (validates classifier logic) ----------------
function selftest(PC)
    CLEAN=1; NOISY=2; PHASE=3; ROTATED=4; MISS=5;
    ref = default_ref_B();
    % 1. CLEAN: exact reference
    b = classify_frame(ref, ref, PC);                 assert(b==CLEAN,  'selftest CLEAN');
    % 2. NOISY: single-bit flip (1/1024 < 0.10)
    t = ref; t(5) = bitxor(t(5), uint64(1));
    b = classify_frame(t, ref, PC);                   assert(b==NOISY,  'selftest NOISY');
    % 3. ROTATED: reference rotated by 3 words
    t = ref(mod((0:15)+3,16)+1);
    [b,~,bk] = classify_frame(t, ref, PC);            assert(b==ROTATED && bk~=0, 'selftest ROTATED');
    % 4. PHASE: full complement (f0 = 1.0)
    t = bitcmp(ref);
    b = classify_frame(t, ref, PC);                   assert(b==PHASE,  'selftest PHASE');
    % 5. MISS: 3 words complemented (~18.75%): >0.10, <0.35, no rotation aligns
    t = ref; t(1:3) = bitcmp(ref(1:3));
    b = classify_frame(t, ref, PC);                   assert(b==MISS,   'selftest MISS');
    fprintf('score_rxw_ref selftest OK (CLEAN/NOISY/ROTATED/PHASE/MISS)\n');
end
