function splice_score(tag)
% splice_score  Score the ACQUISITION-RUNWAY SPLICE test.
%   <tag>_rxw.txt is the decoded byte_rx stream from a concatenation of a CLEAN
%   BIST prefix (the RTL locks on it -> BIST 'ADI Hello World' words) followed by
%   the full floor_148 (-B QK payload). We locate the prefix->floor boundary by
%   BIST content (last BIST-clean frame), then score ONLY the floor portion vs
%   the -B reference -- i.e. how floor_148's frames decode under a WARM, already-
%   locked loop, the way live HW ran.
    refB    = ref_B();
    refBIST = read_hex('rx_words_golden.hex');
    PC = uint16(sum(dec2bin(0:255)-'0',2));
    [W,L] = rrxw([tag '_rxw.txt']);
    li = find(L); nfr = numel(li)-1;
    gbist = nan(nfr,1); f0 = nan(nfr,1); fbest = nan(nfr,1); buck = zeros(nfr,1);
    for kf = 1:nfr
        seg = li(kf)+1:li(kf+1);
        if numel(seg) ~= 16, buck(kf) = -1; continue; end
        rxw = W(seg);
        gbist(kf) = minrot(rxw, refBIST, PC) / 1024;         % vs BIST prefix ref
        [b, h0, hb] = classifyB(rxw, refB, PC);              % vs -B floor ref
        f0(kf) = h0/1024; fbest(kf) = hb/1024; buck(kf) = b;
    end
    bistclean = gbist < 0.10;
    lastpref  = find(bistclean, 1, 'last');
    if isempty(lastpref), lastpref = 0; end
    npref = sum(bistclean);
    fidx = (lastpref+1):nfr;                                 % floor portion

    names = {'CLEAN','NOISY','PHASE','ROTATED','MISS'};
    fprintf('\n==== SPLICE test %s ====\n', tag);
    fprintf('total frames=%d | BIST-clean prefix frames=%d | last prefix idx=%d | FLOOR frames=%d\n',...
            nfr, npref, lastpref, numel(fidx));
    % show the transition: last 2 prefix + first 6 floor frames
    fprintf('--- boundary detail (idx: bucket  f0(-B)  fbest(-B)  gbist) ---\n');
    lo = max(1,lastpref-1); hi = min(nfr,lastpref+6);
    for i = lo:hi
        tagb = '?'; if buck(i)>=1, tagb = names{buck(i)}; end
        mk = ''; if i==lastpref, mk=' <-prefix end'; elseif i==lastpref+1, mk=' <-first floor'; end
        fprintf('  %3d: %-7s f0=%.3f fbest=%.3f gbist=%.3f%s\n', i, tagb, f0(i), fbest(i), gbist(i), mk);
    end
    % aggregate over floor portion
    bc = zeros(1,5); tb=0; te=0;
    for i = fidx
        if buck(i)<1, continue; end
        bc(buck(i)) = bc(buck(i))+1;
        if buck(i)==1 || buck(i)==2, tb=tb+1024; te=te+round(f0(i)*1024); end
    end
    fprintf('--- FLOOR-portion buckets (vs -B) ---\n ');
    for i=1:5, fprintf(' %s=%d', names{i}, bc(i)); end
    if tb>0, fprintf(' | BER=%.3e (over %d aligned)\n', te/tb, (bc(1)+bc(2)));
    else,    fprintf(' | BER=N/A (0 aligned)\n'); end
    fprintf('floor f0(-B) stats: min=%.3f med=%.3f max=%.3f\n', ...
            min(f0(fidx)), median(f0(fidx)), max(f0(fidx)));
end

% ---- helpers ----
function h = minrot(rxw, ref, PC)
    best = inf;
    for k=0:15
        rr = ref(mod((0:15)+k,16)+1); s=0;
        for w=1:16, s=s+pc64(bitxor(rxw(w),rr(w)),PC); end
        if s<best, best=s; end
    end
    h = best;
end
function [b,ham0,hb] = classifyB(rxw, ref, PC)
    ham=zeros(1,16);
    for k=0:15
        rr=ref(mod((0:15)+k,16)+1); s=0;
        for w=1:16, s=s+pc64(bitxor(rxw(w),rr(w)),PC); end
        ham(k+1)=s;
    end
    ham0=ham(1); hb=ham0; bk=0;
    for k=1:15, if ham(k+1)<hb, hb=ham(k+1); bk=k; end, end
    f0=ham0/1024; fbf=hb/1024;
    if ham0==0, b=1; elseif f0<0.10, b=2; elseif fbf<0.10 && bk~=0, b=4; elseif f0>=0.35, b=3; else, b=5; end
end
function p = pc64(x,PC)
    p=0; for j=0:7, bb=bitand(bitshift(x,-8*j),uint64(255)); p=p+double(PC(double(bb)+1)); end
end
function w = ref_B()
    hx={'000001a500004b51','cb3a16fd6db8acfb','ea6bc16e6bd07d3c','d793ce81bbbc52a0',...
        '0fefd06c2f9c2151','1eed942073f13df8','444c5c6d1ca9d87c','c84d6f58e5841102',...
        '3335f92dc97e5aa1','96752cfa4ba38c01','d5d782ddd6a0fb78','ae279d037779a540',...
        '1fdea1d95e3843a2','3cda2941e6e27bf0','8898b8da3852b1f9','919bdeb0ca092304'};
    w=zeros(16,1,'uint64'); for k=1:16, w(k)=h2u(hx{k}); end
end
function w = read_hex(f)
    t=strtrim(fileread(f)); c=strsplit(t); c=c(~cellfun(@isempty,c));
    w=zeros(numel(c),1,'uint64'); for k=1:numel(c), w(k)=h2u(c{k}); end
end
function v = h2u(s)
    s=char(s); if numel(s)<16, s=[repmat('0',1,16-numel(s)) s]; end
    v=bitor(bitshift(uint64(hex2dec(s(1:8))),32),uint64(hex2dec(s(9:16))));
end
function [W,L] = rrxw(f)
    W=uint64([]); L=logical([]); fid=fopen(f,'r');
    while true
        ln=fgetl(fid); if ~ischar(ln), break; end
        c=strsplit(ln,','); if numel(c)<3, continue; end
        W(end+1,1)=h2u(c{1}); L(end+1,1)=str2double(c{2})~=0; %#ok<AGROW>
    end
    fclose(fid);
end
