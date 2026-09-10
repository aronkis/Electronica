function t = parse_ping(txt)
%PARSE_PING  Parse a `ping` transcript into a table of per-reply samples.
%   Returns a table with columns: seq (double), ttl (double), rtt_ms (double).
%   Handles standard iputils/BusyBox ping output ("icmp_seq=N ttl=M
%   time=X ms"). Lost replies do not appear as rows; recover the loss rate
%   from the summary or by comparing max(seq)+1 to height(t).

if isstring(txt), txt = char(txt); end
tok = regexp(txt, 'icmp_seq=(\d+)\s+ttl=(\d+)\s+time=([\d.]+)\s*ms', 'tokens');
if isempty(tok)
    % BusyBox variant may omit ttl
    tok2 = regexp(txt, 'seq=(\d+)\s+ttl=(\d+)\s+time=([\d.]+)', 'tokens');
    tok = tok2;
end
if isempty(tok)
    t = table('Size', [0 3], 'VariableTypes', {'double','double','double'}, ...
        'VariableNames', {'seq','ttl','rtt_ms'});
    return;
end
m = cell2mat(cellfun(@(x) str2double(x), tok, 'UniformOutput', false).');
t = array2table(m, 'VariableNames', {'seq','ttl','rtt_ms'});
end
