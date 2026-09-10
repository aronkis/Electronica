classdef TestLinkPreflight < HilBase
    %TESTLINKPREFLIGHT  L3-safe: read-only board readiness (no arm).
    %   Wraps `link_test.sh preflight` -- verifies both boards are reachable,
    %   the host tool is present/executable, the LVDS profile + watchdog
    %   exist, reg access works, and cap_out matches the BIST golden. It does
    %   NOT arm the radios, so it is safe to run any time the boards are up
    %   (still QPSK_HIL-gated via HilBase to avoid touching boards in a plain
    %   L1 run). This is the smoke test that the whole HIL harness -- the
    %   anyssh/link_test path from MATLAB -- works end to end.

    methods (Test, TestTags = {'L3', 'L3safe'})
        function preflightPasses(tc)
            p = modem_paths();
            log = fullfile(p.results, 'hil_preflight.log');
            [~, out] = tc.linktest('preflight', log);
            % judge by the token, not rc (remote pipelines mask ssh's own rc)
            tc.verifySubstring(out, 'PREFLIGHT: PASS', ...
                sprintf('preflight did not pass; see %s', log));
        end
    end
end
