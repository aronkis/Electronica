function best = replay_verdict(outdir, reffile)
% replay_verdict  Score the 8-run rotation x vphase replay sweep and pick the
% hypothesis the HW resolver would have locked (max aligned frames, tie-break
% min BER). Consumes r{0,90,180,270}v{0,1}_rxw.txt written by replay_capture.sh
% / sim_byte_iq, scores each with score_rxw_ref vs the -B reference (or REFFILE,
% a hexwords path e.g. rx_words_golden.hex for ROM-on-air captures).
%
% Prints a compact sweep table + the winner's full score report; saves
% <outdir>/replay_verdict.mat (all runs + best) and <outdir>/verdict.txt.
if nargin < 2, reffile = ''; end
rots = [0 90 180 270]; vps = [0 1];
all = {}; best = []; bestTxt = '';
lines = {};
for r = rots
  for v = vps
    pfx = fullfile(outdir, sprintf('r%dv%d', r, v));
    if ~exist([pfx '_rxw.txt'], 'file'), continue; end
    if isempty(reffile)
      [txt, res] = evalc('score_rxw_ref(pfx)');
    else
      [txt, res] = evalc('score_rxw_ref(pfx, reffile)');
    end
    res.rot = r; res.vphase = v;
    if res.ber_measurable, bs = sprintf('%.3e', res.ber); else, bs = 'N/A'; end
    lines{end+1} = sprintf('rot=%-3d vph=%d  frames=%-4d aligned=%-4d CLEAN=%-4d NOISY=%-4d PHASE=%-4d ROT=%-3d MISS=%-4d BER=%s', ...
      r, v, res.frames, res.aligned, res.buckets(1), res.buckets(2), res.buckets(3), res.buckets(4), res.buckets(5), bs); %#ok<AGROW>
    all{end+1} = res; %#ok<AGROW>
    if isempty(best) || res.aligned > best.aligned || ...
       (res.aligned == best.aligned && res.ber_measurable && best.ber_measurable && res.ber < best.ber)
      best = res; bestTxt = txt;
    end
  end
end
assert(~isempty(all), 'replay_verdict: no r*v*_rxw.txt runs found in %s', outdir);

fid = fopen(fullfile(outdir, 'verdict.txt'), 'w');
out2(fid, '=== replay sweep: %s (ref=%s) ===', outdir, char(string(reffile)));
for i = 1:numel(lines), out2(fid, '%s', lines{i}); end
if best.aligned <= 0
  out2(fid, 'VERDICT: NO_LOCK -- no hypothesis produced aligned frames (all PHASE/MISS)');
else
  out2(fid, 'VERDICT: best rot=%d vphase=%d  aligned=%d/%d  BER=%.3e  bit_errors=%d', ...
      best.rot, best.vphase, best.aligned, best.frames, best.ber, best.bit_errors);
end
fclose(fid);
% winner's full report (incl. per-offset error map) -> stdout only
fprintf('%s', bestTxt);
runs = all; %#ok<NASGU>
save(fullfile(outdir, 'replay_verdict.mat'), 'runs', 'best');
end

function out2(fid, fmt, varargin)
fprintf(1, [fmt '\n'], varargin{:});
fprintf(fid, [fmt '\n'], varargin{:});
end
