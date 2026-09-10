function s = parse_iperf_json(txt)
%PARSE_IPERF_JSON  Parse `iperf3 -J` output into a compact struct.
%   Returns s with fields (empty if absent):
%     s.sent_kbps, s.recv_kbps   end-of-test throughput
%     s.retransmits              TCP retransmit count (NaN for UDP)
%     s.lost_percent, s.jitter_ms  (UDP)
%     s.raw                      the decoded jsondecode struct
%   Accepts either a JSON string or a transcript containing one JSON object.

if isstring(txt), txt = char(txt); end
s = struct('sent_kbps', NaN, 'recv_kbps', NaN, 'retransmits', NaN, ...
    'lost_percent', NaN, 'jitter_ms', NaN, 'raw', []);

% isolate the JSON object (iperf3 -J emits a single top-level object)
a = strfind(txt, '{'); b = strfind(txt, '}');
if isempty(a) || isempty(b), return; end
j = txt(a(1):b(end));
try
    d = jsondecode(j);
catch
    return;
end
s.raw = d;
if isfield(d, 'end')
    e = d.end;
    if isfield(e, 'sum_sent')
        if isfield(e.sum_sent, 'bits_per_second'), s.sent_kbps = e.sum_sent.bits_per_second/1e3; end
        if isfield(e.sum_sent, 'retransmits'),     s.retransmits = e.sum_sent.retransmits; end
    end
    if isfield(e, 'sum_received') && isfield(e.sum_received, 'bits_per_second')
        s.recv_kbps = e.sum_received.bits_per_second/1e3;
    end
    if isfield(e, 'sum')   % UDP summary
        if isfield(e.sum, 'lost_percent'), s.lost_percent = e.sum.lost_percent; end
        if isfield(e.sum, 'jitter_ms'),    s.jitter_ms = e.sum.jitter_ms; end
        if isnan(s.sent_kbps) && isfield(e.sum, 'bits_per_second')
            s.sent_kbps = e.sum.bits_per_second/1e3;
        end
    end
end
end
