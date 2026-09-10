classdef TestGates < matlab.unittest.TestCase
    %TESTGATES  L2: HDL gate-suite verdicts, one MATLAB test per gate stage.
    %   Each of the four gate stamps is a separate parameterized test, so a
    %   stale/failed stage localizes instead of one opaque loop. Default
    %   (stamp mode) reads the existing stamps in seconds; RUN_GATES=1 runs
    %   the full 6-stage run_full_gates_t8.sh (~30 min) first, then re-checks.
    %   The env guard keeps a stray invocation cheap.

    properties (TestParameter)
        gate = struct( ...
            simByte  = struct('file','SIM_BYTE_GATE_K5.txt',    'token','result: PASS'), ...
            checkhdl = struct('file','CHECKHDL_240K5_BYTE.txt', 'token','errors=0'),     ...
            s1       = struct('file','S1_GATE.txt',             'token','result: PASS'), ...
            s1b      = struct('file','S1B_GATE.txt',            'token','result: PASS'));
    end

    methods (Test, TestTags = {'L2'})

        function gateSuiteExecutes(tc)
            % Only when explicitly asked (RUN_GATES=1); otherwise skip cheaply.
            tc.assumeTrue(strcmp(getenv('RUN_GATES'), '1'), ...
                'set RUN_GATES=1 to execute the ~30 min gate suite');
            p = modem_paths();
            log = fullfile(p.results, 'run_full_gates_t8.log');
            [rc, out] = run_shell('bash run_full_gates_t8.sh', 'Dir', p.kit, 'Log', log);
            tc.verifyEqual(rc, 0, sprintf('gate suite rc=%d (see %s)', rc, log));
            tc.verifySubstring(out, 'FULL_GATES_T8_DONE', 'gate suite did not complete');
        end

        function stampPasses(tc, gate)
            p = modem_paths();
            f = fullfile(p.kit, gate.file);
            tc.assertTrue(isfile(f), sprintf('missing gate stamp %s', gate.file));
            txt = fileread(f);
            tc.verifySubstring(txt, gate.token, ...
                sprintf('%s missing PASS token "%s"', gate.file, gate.token));
            % staleness signal (warning, not failure)
            newestM = TestGates.newestKitMtime(p.kit);
            d = dir(f);
            if ~isempty(newestM) && d.datenum < newestM
                warning('TestGates:stale', ...
                    '%s predates the newest kit .m -- rerun gates (RUN_GATES=1)', gate.file);
            end
        end

    end

    methods (Static, Access = private)
        function m = newestKitMtime(kit)
            d = dir(fullfile(kit, '*.m'));
            if isempty(d), m = []; else, m = max([d.datenum]); end
        end
    end
end
