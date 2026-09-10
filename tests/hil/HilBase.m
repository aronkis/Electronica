classdef HilBase < matlab.unittest.TestCase
    %HILBASE  Base for hardware-in-loop (L3) tests.
    %   Provides the QPSK_HIL env guard (default off -> Incomplete, so an L3
    %   file never touches the boards by accident), board reachability
    %   assumes, a link_test.sh mutex check, a hunt/<ts>_hiltest artifact
    %   bundle, and shell helpers that go through the proven anyssh.sh /
    %   link_test.sh wrappers. MATLAB NEVER writes a modem register -- every
    %   hardware action is a proven script.

    properties (Constant)
        TUN_A = '10.66.0.2';   % role-fixed point-to-point (independent of mgmt IP)
        TUN_B = '10.66.0.1';
    end

    properties
        % Board management IPs. Default to boards A/B; override via env (A_IP /
        % B_IP) so the L3 suite can target a DIFFERENT pair -- same convention as
        % link_test.sh (see docs/bringup.rst). Resolved in TestClassSetup below.
        A_IP = '10.0.0.148';
        B_IP = '10.0.0.146';
        bundle = '';   % created lazily by tests that save artifacts
    end

    methods (TestClassSetup)
        function guardAndReach(tc)
            tc.assumeTrue(strcmp(getenv('QPSK_HIL'), '1'), ...
                'L3 hardware test: set QPSK_HIL=1 with both boards up');
            % board IPs: env override (A_IP/B_IP) -> default pair A/B
            a = getenv('A_IP'); if ~isempty(a), tc.A_IP = a; end
            b = getenv('B_IP'); if ~isempty(b), tc.B_IP = b; end
            % mutex: refuse to run alongside a live operator link_test session
            [~, pg] = run_shell('pgrep -f "[l]ink_test.sh" | wc -l');
            tc.assumeLessThan(str2double(strtrim(pg)), 1.5, ...
                'another link_test.sh is running -- serialize board access');
            for ip = {tc.A_IP, tc.B_IP}
                [rc, ~] = tc.anyssh(ip{1}, 'echo up');
                tc.assumeEqual(rc, 0, sprintf('board %s unreachable', ip{1}));
            end
        end
    end

    methods
        function b = ensureBundle(tc)
            if isempty(tc.bundle)
                p = modem_paths();
                ts = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
                tc.bundle = fullfile(p.two_jup, 'hunt', ['hiltest_' ts]);
                if ~isfolder(tc.bundle), mkdir(tc.bundle); end
            end
            b = tc.bundle;
        end

        function [rc, out] = anyssh(tc, ip, cmd)
            p = modem_paths();
            q = strrep(cmd, '''', '''\''''');   % single-quote-safe
            [rc, out] = run_shell(sprintf('%s %s ''%s''', ...
                fullfile(p.two_jup, 'anyssh.sh'), ip, q));
        end

        function [rc, out] = linktest(tc, args, varargin)
            p = modem_paths();
            log = '';
            if ~isempty(varargin), log = varargin{1}; end
            [rc, out] = run_shell(sprintf('bash link_test.sh %s', args), ...
                'Dir', p.two_jup, 'Log', log);
        end
    end
end
