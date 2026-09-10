classdef TestHostAppC < matlab.unittest.TestCase
    %TESTHOSTAPPC  L1: the host/ C unit tests, one MATLAB test per binary.
    %   Each host-pure C test (test_frame, test_k5, test_ber, test_whiten,
    %   test_seq) is a separate parameterized MATLAB unittest: a failure in
    %   one localizes to that binary instead of a single opaque `make test`.
    %   The binaries are built once in TestClassSetup, then each runs and its
    %   pass token is verified. No hardware. test_k5 exercises the daemon's
    %   tx_send/rx_pump_frame against a fake in-memory DMA regfile.
    %
    %   run_shell corrects PATH so the build finds the real GNU assembler
    %   (this dev box shadows `as` in ~/.local/bin).

    properties (TestParameter)
        % struct fields become the parameter names shown in the test name.
        ctest = struct( ...
            frame  = struct('bin','test_frame',  'token','frame tests:', 'ok','0 failed'), ...
            k5     = struct('bin','test_k5',      'token','k5 tests:',    'ok','0 failed'), ...
            ber    = struct('bin','test_ber',     'token','qpsk_ber_selftest OK', 'ok','qpsk_ber_selftest OK'), ...
            whiten = struct('bin','test_whiten',  'token','whiten tests:', 'ok','whiten tests: OK'), ...
            seq    = struct('bin','test_seq',     'token','qpsk_seq_selftest OK', 'ok','qpsk_seq_selftest OK'));
    end

    methods (TestClassSetup)
        function buildBinaries(tc)
            p = modem_paths();
            log = fullfile(p.results, 'hostapp_build.log');
            [rc, out] = run_shell(...
                'make -s clean >/dev/null 2>&1; make -s test_frame test_k5 test_ber test_whiten test_seq', ...
                'Dir', p.host, 'Log', log);
            tc.assertEqual(rc, 0, sprintf('host C test build failed:\n%s', out));
        end
    end

    methods (Test, TestTags = {'L1'})
        function cTestPasses(tc, ctest)
            p = modem_paths();
            log = fullfile(p.results, ['hostapp_' ctest.bin '.log']);
            [rc, out] = run_shell(['./' ctest.bin], 'Dir', p.host, 'Log', log);
            tc.verifyEqual(rc, 0, ...
                sprintf('%s exited %d (assert failure):\n%s', ctest.bin, rc, out));
            tc.verifySubstring(out, ctest.token, ...
                sprintf('%s did not run (no "%s")', ctest.bin, ctest.token));
            tc.verifySubstring(out, ctest.ok, ...
                sprintf('%s did not report success ("%s")', ctest.bin, ctest.ok));
            tc.verifyEmpty(regexp(out, '\<FAIL\>', 'once'), ...
                sprintf('%s printed a FAIL line', ctest.bin));
        end
    end
end
