function p = modem_paths()
%MODEM_PATHS  Single source of truth for repo directory locations.
%   Returns a struct of absolute paths derived from this file's location, so
%   the test suite never hardcodes an absolute tree (the exact bug that left
%   test_byte_helpers_k5.m / selftest_decode_k5.m silently testing the retired
%   /mnt/onetb/scratch/qpsk_variants tree).
%
%   p.root      repo root (qpsk-jupiter-modem)
%   p.tests     tests/
%   p.helpers   tests/helpers/
%   p.results   tests/results/   (created if missing; gitignored)
%   p.kit       modem/
%   p.k5        contract/
%   p.host      host/
%   p.two_jup   ops/    (field name kept for history)
%   p.docs      docs/

here = fileparts(mfilename('fullpath'));      % .../tests/helpers
p.helpers = here;
p.tests   = fileparts(here);                  % .../tests
p.root    = fileparts(p.tests);               % repo root
p.results = fullfile(p.tests, 'results');
p.kit     = fullfile(p.root, 'modem');
p.k5      = fullfile(p.root, 'contract');
p.host    = fullfile(p.root, 'host');
p.two_jup = fullfile(p.root, 'ops');   % field name kept for history; points at ops/
p.docs    = fullfile(p.root, 'docs');

if ~isfolder(p.results)
    mkdir(p.results);
end
end
