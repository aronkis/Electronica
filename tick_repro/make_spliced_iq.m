function info = make_spliced_iq(rawPath, outPath, n0, nInsert, mode, sps, spf)
%MAKE_SPLICED_IQ  Inject the board-148 device tick into a clean IQ capture.
%   info = make_spliced_iq(rawPath, outPath, n0, nInsert, mode, sps, spf)
%
%   sps/spf are geometry-only (default 8 / 9064 = 240k) and affect ONLY the
%   symbol/frame diagnostics printed; the splice itself is rate-agnostic. For
%   R3/f1536 pass sps=4, spf=49332.
%
%   Inserts nInsert samples (default 256 = +32 symbols at sps=8) into an
%   int16-interleaved I/Q capture at sample offset n0, writing the spliced
%   capture to outPath. This is the *sample-stream* form of the tick: the live
%   ADRV9002 inserts exactly 256 samples into the consumed RX branch at each
%   BBDC-cal iteration; splicing them into a clean capture and decoding
%   reproduces the +32-symbol Peak-Search offset step and the ~2-frame loss
%   (content-independent -- see two_jup/ERROR_TAXONOMY.md and the netlist splice
%   battery k5_240/gen_hdlD2.py / rtl_sim/splice_score.m).
%
%   rawPath  : int16-interleaved I,Q capture (e.g. two_jup/evmcap/fwd1/raw.iq)
%   outPath  : spliced .iq to write (same format)
%   n0       : sample offset of the insertion (default 2000000, the sample the
%              netlist battery spliced at so results match the published table)
%   nInsert  : samples to insert (default 256)
%   mode     : content of the inserted run (default 'repeat'):
%              'repeat'  - repeat the nInsert samples ending at n0 (the tick is
%                          "statistically normal, not held" -> a repeat of local
%                          signal is the closest benign match)
%              'noise'   - complex Gaussian at the local RMS
%              'phase90' - the 'repeat' block rotated +90 deg
%              'zeros'   - a dropout-style zero run
%   All four reproduce the 2-frame loss (the failure is the displacement, not
%   the inserted content).

if nargin < 3 || isempty(n0),      n0 = 2000000; end
if nargin < 4 || isempty(nInsert), nInsert = 256; end
if nargin < 5 || isempty(mode),    mode = 'repeat'; end
if nargin < 6 || isempty(sps),     sps = 8; end
if nargin < 7 || isempty(spf),     spf = 9064; end

% ---- load int16-interleaved -> complex ----
fid = fopen(rawPath, 'r');
assert(fid > 0, 'make_spliced_iq:open', 'cannot open %s', rawPath);
raw = fread(fid, Inf, 'int16'); fclose(fid);
if mod(numel(raw), 2), raw = raw(1:end-1); end
I = raw(1:2:end); Q = raw(2:2:end);
x = double(I) + 1i*double(Q);
n = numel(x);
assert(n0 >= nInsert+1 && n0 <= n, 'make_spliced_iq:n0', ...
    'n0=%d out of range [%d, %d]', n0, nInsert+1, n);

% ---- build the inserted run ----
switch lower(mode)
    case 'repeat'
        ins = x(n0-nInsert+1:n0);
    case 'phase90'
        ins = x(n0-nInsert+1:n0) * exp(1i*pi/2);
    case 'noise'
        loc = x(max(1,n0-1000):n0);
        s = sqrt(mean(abs(loc).^2)/2);
        ins = s*(randn(nInsert,1) + 1i*randn(nInsert,1));
    case 'zeros'
        ins = zeros(nInsert,1);
    otherwise
        error('make_spliced_iq:mode', 'unknown mode "%s"', mode);
end

% ---- splice: x[1..n0] , insert , x[n0+1..end]  (stream grows by nInsert) ----
y = [x(1:n0); ins(:); x(n0+1:end)];

% ---- write int16-interleaved ----
yi = round(real(y)); yq = round(imag(y));
lim = double(intmax('int16'));
yi = max(min(yi, lim), -lim-1); yq = max(min(yq, lim), -lim-1);
out = zeros(2*numel(y), 1);
out(1:2:end) = yi; out(2:2:end) = yq;
fo = fopen(outPath, 'w');
assert(fo > 0, 'make_spliced_iq:out', 'cannot write %s', outPath);
fwrite(fo, int16(out), 'int16'); fclose(fo);

info = struct('in_samples', n, 'out_samples', numel(y), 'n0', n0, ...
    'nInsert', nInsert, 'mode', mode, 'sps', sps, 'spf', spf, ...
    'insert_symbol', n0/sps, 'insert_frame', n0/spf);
fprintf(['make_spliced_iq: %s -> %s\n  %d -> %d samples; +%d (%d sym @sps%d) ' ...
    'at n0=%d (sym %.0f, frame %.1f), mode=%s\n'], rawPath, outPath, n, ...
    numel(y), nInsert, nInsert/sps, sps, n0, n0/sps, n0/spf, mode);
end
