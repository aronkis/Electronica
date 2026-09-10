classdef TestPerfToolSelftest < matlab.unittest.TestCase
    %TESTPERFTOOLSELFTEST  L1: qpsk_perf UDP instrument self-check.
    %   Builds qpsk_perf and runs its --selftest (fork server+client over
    %   127.0.0.1, 200 kbit/s, 88-byte payloads, 2 s, echo/RTT). Confirms the
    %   pacing, loss accounting, and RTT path work before the tool is trusted
    %   for the L3 RF-link characterization. No hardware.

    methods (Test, TestTags = {'L1'})
        function selftestPasses(tc)
            p = modem_paths();
            [rcb, ob] = run_shell('make -s qpsk_perf', 'Dir', p.host);
            tc.assumeEqual(rcb, 0, sprintf('could not build qpsk_perf:\n%s', ob));

            log = fullfile(p.results, 'qpsk_perf_selftest.log');
            [rc, out] = run_shell('./qpsk_perf --selftest', 'Dir', p.host, 'Log', log);
            tc.verifyEqual(rc, 0, sprintf('qpsk_perf selftest rc=%d:\n%s', rc, out));
            tc.verifySubstring(out, 'PERF_SELFTEST PASS', 'selftest did not pass');
            % pacing accuracy: offered == sent within 5% at localhost
            tok = regexp(out, 'offered_kbps=([\d.]+) sent_kbps=([\d.]+)', 'tokens', 'once');
            tc.assertNotEmpty(tok, 'no PERF_CLI_DONE line');
            offered = str2double(tok{1}); sent = str2double(tok{2});
            tc.verifyLessThan(abs(sent-offered)/offered, 0.05, 'pacing off > 5%');
            % zero echo loss over localhost
            lost = regexp(out, 'PERF_RTT_SUMMARY ok=\d+ lost=(\d+)', 'tokens', 'once');
            tc.verifyEqual(str2double(lost{1}), 0, 'localhost echo loss should be 0');
        end
    end
end
