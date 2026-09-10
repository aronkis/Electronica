function s = parse_qpsk_perf(txt)
%PARSE_QPSK_PERF  Parse qpsk_perf stdout/log into a struct.
%   txt is the transcript (char). Returns:
%     s.cli   struct: tx_pkts, tx_bytes, offered_kbps, sent_kbps, dur
%     s.srv   struct: rx_pkts, rx_bytes, lost, dup, reorder
%     s.rtt   struct: ok, lost, min_us, mean_us, max_us
%     s.rtts  Nx1 per-packet RTT (us) from PERF_RTT lines
%     s.bins  table of per-second server bins (t, rx_pkts, rx_kbps, lost)
%   Missing sections come back empty.

if isstring(txt), txt = char(txt); end
s = struct('cli', [], 'srv', [], 'rtt', [], 'rtts', [], 'bins', []);

c = regexp(txt, ['PERF_CLI_DONE tx_pkts=(\d+) tx_bytes=(\d+) ' ...
    'offered_kbps=([\d.]+) sent_kbps=([\d.]+) dur=([\d.]+)'], 'tokens', 'once');
if ~isempty(c)
    s.cli = struct('tx_pkts', str2double(c{1}), 'tx_bytes', str2double(c{2}), ...
        'offered_kbps', str2double(c{3}), 'sent_kbps', str2double(c{4}), 'dur', str2double(c{5}));
end

v = regexp(txt, ['PERF_SRV_DONE rx_pkts=(\d+) rx_bytes=(\d+) lost=(\d+) ' ...
    'dup=(\d+) reorder=(\d+)'], 'tokens', 'once');
if ~isempty(v)
    s.srv = struct('rx_pkts', str2double(v{1}), 'rx_bytes', str2double(v{2}), ...
        'lost', str2double(v{3}), 'dup', str2double(v{4}), 'reorder', str2double(v{5}));
end

r = regexp(txt, ['PERF_RTT_SUMMARY ok=(\d+) lost=(\d+) rtt_min_us=([\d.]+) ' ...
    'rtt_mean_us=([\d.]+) rtt_max_us=([\d.]+)'], 'tokens', 'once');
if ~isempty(r)
    s.rtt = struct('ok', str2double(r{1}), 'lost', str2double(r{2}), ...
        'min_us', str2double(r{3}), 'mean_us', str2double(r{4}), 'max_us', str2double(r{5}));
end

rr = regexp(txt, 'PERF_RTT seq=\d+ rtt_us=([\d.]+)', 'tokens');
if ~isempty(rr), s.rtts = cellfun(@(x) str2double(x{1}), rr).'; end

b = regexp(txt, ['PERF_SRV t=([\d.]+) rx_pkts=(\d+) rx_kbps=([\d.]+) ' ...
    'cum_pkts=\d+ lost=(\d+)'], 'tokens');
if ~isempty(b)
    m = cell2mat(cellfun(@(x) str2double(x), b, 'UniformOutput', false).');
    s.bins = array2table(m, 'VariableNames', {'t', 'rx_pkts', 'rx_kbps', 'lost'});
end
end
