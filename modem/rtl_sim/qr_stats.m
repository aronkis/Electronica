% qr_stats.m -- characterize how far the floor_148 quadrant-sweep frames are
% from the -B reference: aligned (k=0) Hamming fraction and best-rotation
% fraction per frame, to distinguish "wrong quadrant / no-lock (~50%)" from a
% "decode-path NOISY floor (~0.2%)".
ref = default_ref_local();
PC = uint16(sum(dec2bin(0:255)-'0',2));
cfgs = {'qr_r0_s0','qr_r0_s1'};
for c = 1:numel(cfgs)
    [W,L] = read_rxw_local([cfgs{c} '_rxw.txt']);
    li = find(L); nfr = numel(li)-1; f0=[]; fb=[];
    for kf = 1:nfr
        seg = li(kf)+1:li(kf+1); if numel(seg)~=16, continue; end
        rxw = W(seg); ham = zeros(1,16);
        for k=0:15
            rr = ref(mod((0:15)+k,16)+1); h=0;
            for w=1:16, h=h+popc64_local(bitxor(rxw(w),rr(w)),PC); end
            ham(k+1)=h;
        end
        f0(end+1)=ham(1)/1024; fb(end+1)=min(ham)/1024; %#ok<AGROW>
    end
    fprintf('%-9s : aligned f0/frame  min=%.3f med=%.3f max=%.3f | best-rot fb min=%.3f med=%.3f\n',...
        cfgs{c}, min(f0), median(f0), max(f0), min(fb), median(fb));
end

function w = default_ref_local()
    hx = {'000001a500004b51','cb3a16fd6db8acfb','ea6bc16e6bd07d3c','d793ce81bbbc52a0',...
          '0fefd06c2f9c2151','1eed942073f13df8','444c5c6d1ca9d87c','c84d6f58e5841102',...
          '3335f92dc97e5aa1','96752cfa4ba38c01','d5d782ddd6a0fb78','ae279d037779a540',...
          '1fdea1d95e3843a2','3cda2941e6e27bf0','8898b8da3852b1f9','919bdeb0ca092304'};
    w = zeros(16,1,'uint64'); for k=1:16, w(k)=h2u(hx{k}); end
end
function v = h2u(s)
    s=char(s); if numel(s)<16, s=[repmat('0',1,16-numel(s)) s]; end
    v = bitor(bitshift(uint64(hex2dec(s(1:8))),32), uint64(hex2dec(s(9:16))));
end
function [W,L] = read_rxw_local(f)
    W=uint64([]); L=logical([]); fid=fopen(f,'r');
    while true
        ln=fgetl(fid); if ~ischar(ln), break; end
        c=strsplit(ln,','); if numel(c)<3, continue; end
        W(end+1,1)=h2u(c{1}); L(end+1,1)=str2double(c{2})~=0; %#ok<AGROW>
    end
    fclose(fid);
end
function p = popc64_local(x,PC)
    p=0; for j=0:7, b=bitand(bitshift(x,-8*j),uint64(255)); p=p+double(PC(double(b)+1)); end
end
