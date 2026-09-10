classdef TestTunLoopbackHost < matlab.unittest.TestCase
    %TESTTUNLOOPBACKHOST  L1 (root-gated): the tun-fd data path in loopback.
    %   Wraps host/tests/test_loopback.sh -- the only test that drives a real
    %   /dev/net/tun fd: qpsk_tun -l in two netns with ping across. Needs root
    %   (the script exits 77 = SKIP otherwise), so without privilege the test
    %   assumes-out to Incomplete rather than failing. Run the suite under
    %   `sudo -E matlab -batch "runTests"` to exercise it.
    %
    %   This is the host complement to test_k5.c (which unit-tests tx_send /
    %   rx_pump_frame against a fake DMA): here the real tun plumbing + netns
    %   framing is on the line, still with no hardware.

    methods (Test, TestTags = {'L1'})
        function loopbackSmoke(tc)
            p = modem_paths();
            [rcb, ob] = run_shell('make -s qpsk_tun', 'Dir', p.host);
            tc.assumeEqual(rcb, 0, sprintf('could not build qpsk_tun:\n%s', ob));

            log = fullfile(p.results, 'tun_loopback.log');
            [rc, out] = run_shell('bash test_loopback.sh', 'Dir', fullfile(p.host, 'tests'), 'Log', log);
            tc.assumeNotEqual(rc, 77, 'test_loopback.sh needs root (run under sudo -E)');
            tc.verifyEqual(rc, 0, sprintf('tun loopback failed (rc=%d):\n%s', rc, out));
            tc.verifySubstring(out, 'LOOPBACK SMOKE PASS', 'no PASS token');
        end
    end
end
