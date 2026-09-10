classdef TestTapLoopbackHost < matlab.unittest.TestCase
    %TESTTAPLOOPBACKHOST  L1 (root-gated): the TAP (-t) L2 data path.
    %   Wraps host/tests/test_tap_loopback.sh: qpsk_tun -l -t in two netns
    %   with fixed MACs, ping across, and an explicit check that ARP resolved
    %   over the in-process L2 bridge. The daemon's -l -t composition was
    %   verified in source (tun_alloc honours the tap flag in loopback mode);
    %   this is the first automated coverage of the TAP path. Needs root
    %   (exit 77 = SKIP -> Incomplete).

    methods (Test, TestTags = {'L1'})
        function tapLoopbackSmoke(tc)
            p = modem_paths();
            [rcb, ob] = run_shell('make -s qpsk_tun', 'Dir', p.host);
            tc.assumeEqual(rcb, 0, sprintf('could not build qpsk_tun:\n%s', ob));

            log = fullfile(p.results, 'tap_loopback.log');
            [rc, out] = run_shell('bash test_tap_loopback.sh', 'Dir', fullfile(p.host, 'tests'), 'Log', log);
            tc.assumeNotEqual(rc, 77, 'test_tap_loopback.sh needs root (run under sudo -E)');
            tc.verifyEqual(rc, 0, sprintf('tap loopback failed (rc=%d):\n%s', rc, out));
            tc.verifySubstring(out, 'ARP resolved peer MAC', 'ARP did not resolve over TAP');
            tc.verifySubstring(out, 'TAP LOOPBACK SMOKE PASS', 'no PASS token');
        end
    end
end
