function results = runTests(level)
%RUNTESTS  Primary MATLAB test runner for the qpsk-jupiter-modem repo.
%
%   runTests            % L1 (default): fast host-pure suite, target < 3 min
%   runTests('L1')      % host-pure: C tests, frame contract, byte/decode
%   runTests('L2')      % HDL gate wrappers (stamp mode; RUN_GATES=1 executes)
%   runTests('L3')      % hardware-in-loop (requires QPSK_HIL=1 + boards)
%   runTests('all')     % everything the environment permits
%
%   Layer is selected by the 'L1'/'L2'/'L3' TestTags on each class. The env
%   guards make accidental invocation harmless: an L3 file run without
%   QPSK_HIL=1 assumes-out to Incomplete (never touches the boards); an L2
%   file without RUN_GATES=1 only checks the existing gate stamps.
%
%   Results: JUnit XML + TAP written to tests/results/. Under `matlab -batch`
%   the process exits nonzero if any test fails (CI contract).

import matlab.unittest.TestRunner
import matlab.unittest.TestSuite
import matlab.unittest.plugins.XMLPlugin
import matlab.unittest.plugins.TAPPlugin
import matlab.unittest.plugins.ToFile
import matlab.unittest.selectors.HasTag

if nargin < 1 || isempty(level), level = 'L1'; end
level = upper(level);

% Bootstrap: helpers/ holds modem_paths itself, so add it via this file's
% own location before the first helper call.
thisDir = fileparts(mfilename('fullpath'));
addpath(fullfile(thisDir, 'helpers'));

p = modem_paths();
addpath(p.helpers, p.tests, fullfile(p.tests,'hil'), p.k5);

batchMode = ~usejava('desktop');   % true under `matlab -batch`

suite = testsuite(p.tests, 'IncludeSubfolders', true);
if ~strcmp(level, 'ALL')
    suite = suite.selectIf(HasTag(level));
end
if isempty(suite)
    warning('runTests:empty', 'No tests matched level %s', level);
    results = matlab.unittest.TestResult.empty;
    return;
end

runner = TestRunner.withTextOutput('OutputDetail', 3);

ts = char(datetime('now','Format','yyyyMMdd_HHmmss'));
xmlFile = fullfile(p.results, sprintf('junit_%s_%s.xml', level, ts));
tapFile = fullfile(p.results, sprintf('tap_%s_%s.tap',  level, ts));
runner.addPlugin(XMLPlugin.producingJUnitFormat(xmlFile));
runner.addPlugin(TAPPlugin.producingVersion13(ToFile(tapFile)));

results = runner.run(suite);

disp(repmat('=', 1, 72));
disp(table(results));
nFail = nnz([results.Failed]);
nInc  = nnz([results.Incomplete]);
fprintf('runTests(%s): %d passed, %d failed, %d incomplete  (junit: %s)\n', ...
    level, nnz([results.Passed]), nFail, nInc, xmlFile);

if batchMode
    exit(double(nFail > 0));
end
end
