classdef TestSshLink < HilBase
    %TESTSSHLINK  L3: SSH usability over the RF link.
    %   Drives `link_test.sh ssh` (ed25519 key install out-of-band, then SSH
    %   B->A over tun0) and asserts the RF-SSH-OK token -- the evidence
    %   STATUS.md has marked "pending" since 2026-07-10. Retries once (the
    %   script's own hint) before failing, since key exchange can time out on
    %   a lossy no-ARQ link.

    methods (Test, TestTags = {'L3'})
        function rfSshOk(tc)
            p = modem_paths();
            log = fullfile(p.results, 'hil_ssh.log');
            [~, out] = tc.linktest('ssh -w', log);
            if ~contains(out, 'RF-SSH-OK')
                fprintf('SSH attempt 1 no RF-SSH-OK; retrying once...\n');
                [~, out] = tc.linktest('ssh -w', log);
            end
            tc.verifySubstring(out, 'RF-SSH-OK', ...
                sprintf('SSH over tun0 did not complete; see %s', log));
        end
    end
end
