function res = score_rxw_seq(prefix)
% score_rxw_seq  -S-aware scorer for the RTL-replay decoded byte output: the
% qpsk_seq analog of score_rxw_ref. Reads <PREFIX>_rxw.txt (hex,last,user per
% accepted byte_rx beat; last==1 ends a 16-word = 128-byte frame), converts
% each frame to bytes (LSB-byte-first per word, the byte-DMA convention) and
% scores it with the loss-proof seq logic: CRC-pass = OK (exact seq); CRC-fail
% = raw-seq recovery (window 64) or next-expect fallback -> BITERR (bit count
% vs the regenerated seq_frame_bytes_k5 reference); JUNK else; seq jumps
% counted LOST. Returns per-frame table incl. seq -- join against the live
% events log to compare fixed-replay vs live for the SAME seq.
    K5 = fullfile(fileparts(fileparts(fileparts(mfilename('fullpath')))), 'contract');
    addpath(K5);
    PKT = 128; NREF = PKT*8;

    rxwf = [char(prefix) '_rxw.txt'];
    [W, L] = read_rxw(rxwf);
    li = find(L);
    nfr = max(0, numel(li) - 1);   % drop the leading all-zeros prime frame

    perFrame = struct('seq',{},'errs',{},'crcok',{},'class',{});
    ok=0; biterr=0; junk=0; dup=0; lost=0; lostev=0;
    totBits=0; totErr=0; per_byte=zeros(PKT,1);
    nextExpect=[]; firstSeq=[];
    for kf = 1:nfr
        seg = li(kf)+1 : li(kf+1);
        if numel(seg) ~= 16, continue; end
        by = words2bytes(W(seg));
        cls='JUNK'; errs=NaN; seq=NaN; cok=false;
        if crc_ok(by)
            cok=true; errs=0;
            seq=double(by(5))+256*double(by(6))+65536*double(by(7))+16777216*double(by(8));
        else
            seqr=double(by(5))+256*double(by(6))+65536*double(by(7))+16777216*double(by(8));
            cand=[];
            if ~isempty(nextExpect)
                d=seqr-nextExpect;
                if d>=0 && d<64, cand=seqr; end
                if isempty(cand), cand=nextExpect; end
            end
            if ~isempty(cand)
                e=bitdiff(by, seq_frame_bytes_k5(cand,PKT));
                if e < 0.35*NREF, seq=cand; errs=e; end
            end
        end
        if ~isnan(seq)
            if isempty(nextExpect), firstSeq=seq; nextExpect=seq; end
            if seq<nextExpect
                dup=dup+1; cls='DUP';
            else
                if seq>nextExpect, lost=lost+seq-nextExpect; lostev=lostev+1; end
                totBits=totBits+NREF; totErr=totErr+errs;
                if errs>0
                    biterr=biterr+1; cls='BITERR';
                    eb=bitxor(by, seq_frame_bytes_k5(seq,PKT));
                    for i=1:PKT, per_byte(i)=per_byte(i)+sum(dec2bin(eb(i),8)=='1'); end
                else
                    ok=ok+1; cls='OK';
                end
                nextExpect=seq+1;
            end
        else
            junk=junk+1;
        end
        perFrame(end+1)=struct('seq',seq,'errs',errs,'crcok',cok,'class',cls); %#ok<AGROW>
    end
    BER = totErr/max(totBits,1);
    res = struct('prefix',char(prefix),'frames',nfr,'ok',ok,'biterr',biterr,...
        'lost',lost,'lost_events',lostev,'dup',dup,'junk',junk,...
        'total_bits',totBits,'bit_errors',totErr,'ber',BER,...
        'ber_measurable',totBits>0,'aligned',ok+biterr,...
        'per_byte',per_byte,'perFrame',perFrame,...
        'firstSeq',firstSeq,'nextExpect',nextExpect);
    fprintf('=== score_rxw_seq: %s ===\n', rxwf);
    fprintf('frames=%d OK=%d BITERR=%d LOST=%d(%d gaps) DUP=%d JUNK=%d  bits=%d errs=%d BER=%.3e\n',...
        nfr,ok,biterr,lost,lostev,dup,junk,totBits,totErr,BER);
    be=[perFrame(strcmp({perFrame.class},'BITERR')).seq];
    if ~isempty(be), fprintf('BITERR seqs: %s\n',num2str(be(1:min(20,end)))); end
end

function by = words2bytes(w)
by = zeros(128,1);
for k = 1:16
    v = w(k);
    for j = 0:7
        by((k-1)*8+j+1) = double(bitand(bitshift(v,-8*j), uint64(255)));
    end
end
end
function tf = crc_ok(by)
c = seq_crc32_k5(by(1:76),[9 10 11 12]);
rx = double(by(9))+256*double(by(10))+65536*double(by(11))+16777216*double(by(12));
tf = (c==rx) && by(1)==hex2dec('51') && by(2)==hex2dec('4B');
end
function e = bitdiff(a,b)
e = 0;
for i = 1:numel(a), e = e + sum(dec2bin(bitxor(a(i),b(i)),8)=='1'); end
end
function [W,L] = read_rxw(f)
W = uint64([]); L = logical([]);
fid = fopen(f,'r');
if fid<0, error('cannot open %s', f); end
while true
    ln = fgetl(fid); if ~ischar(ln), break; end
    c = strsplit(ln, ','); if numel(c) < 3, continue; end
    s = char(strtrim(c{1}));
    if numel(s) < 16, s = [repmat('0',1,16-numel(s)) s]; end %#ok<AGROW>
    W(end+1,1) = bitor(bitshift(uint64(hex2dec(s(1:8))),32), uint64(hex2dec(s(9:16)))); %#ok<AGROW>
    L(end+1,1) = str2double(c{2}) ~= 0; %#ok<AGROW>
end
fclose(fid);
end
