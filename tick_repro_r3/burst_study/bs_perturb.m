function y = bs_perturb(x, n0, N, kind)
%BS_PERTURB  Single mid-stream sample-domain disturbance (insert or delete).
%
%   y = bs_perturb(x, n0, N, kind)
%
%   x    : complex sample stream (column)
%   n0   : sample offset of the disturbance
%   N    : number of samples
%   kind : 'insert' -- insert a copy of the N samples ending at n0 (the
%                      'repeat' mode of tick_repro/make_spliced_iq.m: closest
%                      benign match to the proven forward-link device tick,
%                      "statistically normal, not held")
%          'delete' -- remove samples n0+1 .. n0+N (stream shrinks by N)
%
%   Same splice convention as make_spliced_iq.m (stream x(1..n0), then the
%   event, then the remainder) but operating on in-memory vectors so the study
%   loop does not round-trip through int16 files.

x = x(:);
switch lower(kind)
    case 'insert'
        assert(n0 >= N+1 && n0 <= numel(x), 'bs_perturb:n0', 'n0 out of range');
        ins = x(n0-N+1:n0);
        y = [x(1:n0); ins; x(n0+1:end)];
    case 'delete'
        assert(n0 >= 1 && n0+N <= numel(x), 'bs_perturb:n0', 'n0 out of range');
        y = [x(1:n0); x(n0+N+1:end)];
    otherwise
        error('bs_perturb:kind', 'kind must be ''insert'' or ''delete''');
end
end
