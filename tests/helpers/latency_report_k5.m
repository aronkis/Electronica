function rep = latency_report_k5(cells, outFile)
%LATENCY_REPORT_K5  Percentiles + link latency category from RTT samples.
%   cells: struct array, one per measurement cell, each with
%       .name    (char)   e.g. 'idle -s32 fwd'
%       .rtt_ms  (vector) per-sample RTT
%       .sent    (scalar) datagrams/pings offered (for loss)
%   Computes p5/p50/p90/p99/max + loss per cell and assigns an overall
%   category from the idle -s32 cell (or the first cell if none matches).
%
%   The one-way component model sets the physical floor: t_ow >= one frame
%   serialization (1133/240e3 = 4.72 ms) + host overheads, so RTT floor is
%   ~10-15 ms -- the historical "~5 ms" assumption is impossible and this
%   report retires it with data.
%
%   Categories (idle, -s 32, p90 RTT):
%     A interactive  < 40 ms      SSH typing feels live
%     B usable       40-100 ms    fine, noticeable
%     C sluggish     100-250 ms   transfers only
%     D batch        > 250 ms or loss > 10%   scripted use only
%
%   Returns rep struct (rep.table, rep.category, rep.frameMs) and, if outFile
%   given, writes a Markdown report.

FRAME_MS = 1133/240e3*1e3;   % 4.7208 ms
pct = @(v,q) (isempty(v))*NaN + (~isempty(v))*prctileLocal(v,q);

n = numel(cells);
name = strings(n,1); p5=zeros(n,1); p50=zeros(n,1); p90=zeros(n,1);
p99=zeros(n,1); mx=zeros(n,1); lossPct=zeros(n,1); nsamp=zeros(n,1);
for i = 1:n
    v = cells(i).rtt_ms(:); v = v(isfinite(v));
    name(i) = string(cells(i).name);
    nsamp(i) = numel(v);
    p5(i)=pct(v,5); p50(i)=pct(v,50); p90(i)=pct(v,90); p99(i)=pct(v,99);
    mx(i) = isempty(v)*NaN + (~isempty(v))*max([v;-Inf]);
    sent = 0; if isfield(cells(i),'sent') && ~isempty(cells(i).sent), sent = cells(i).sent; end
    lossPct(i) = (sent>0) * 100*max(0,(sent-numel(v)))/max(1,sent);
end
rep.table = table(name, nsamp, p5, p50, p90, p99, mx, lossPct, ...
    'VariableNames', {'cell','n','p5_ms','p50_ms','p90_ms','p99_ms','max_ms','loss_pct'});
rep.frameMs = FRAME_MS;

% pick the categorizing cell: prefer an idle -s32 forward cell
idx = find(contains(lower(name), 'idle') & contains(name, '32'), 1);
if isempty(idx), idx = 1; end
rep.categoryCell = name(idx);
cp90 = p90(idx); closs = lossPct(idx);
if closs > 10 || cp90 > 250
    rep.category = 'D batch';
elseif cp90 > 100
    rep.category = 'C sluggish';
elseif cp90 > 40
    rep.category = 'B usable';
else
    rep.category = 'A interactive';
end

if nargin >= 2 && ~isempty(outFile)
    fid = fopen(outFile, 'w');
    fprintf(fid, '# RF link latency report\n\n');
    fprintf(fid, 'Frame serialization time: %.3f ms (RTT floor ~= %.0f ms 2-way + host overhead).\n\n', ...
        FRAME_MS, 2*FRAME_MS);
    fprintf(fid, '**Category: %s** (from cell `%s`, p90=%.1f ms, loss=%.1f%%)\n\n', ...
        rep.category, rep.categoryCell, cp90, closs);
    fprintf(fid, '| cell | n | p5 | p50 | p90 | p99 | max | loss%% |\n|---|--|--|--|--|--|--|--|\n');
    for i = 1:n
        fprintf(fid, '| %s | %d | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f |\n', ...
            name(i), nsamp(i), p5(i), p50(i), p90(i), p99(i), mx(i), lossPct(i));
    end
    fclose(fid);
    rep.file = outFile;
end
end

function q = prctileLocal(v, p)
%PRCTILELOCAL  Percentile without the Statistics Toolbox (linear interp).
v = sort(v(:));
if isscalar(v), q = v; return; end
r = (p/100) * (numel(v)-1) + 1;
lo = floor(r); hi = ceil(r); f = r - lo;
q = v(lo)*(1-f) + v(hi)*f;
end
