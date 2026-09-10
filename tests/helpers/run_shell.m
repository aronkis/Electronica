function [rc, out] = run_shell(cmd, varargin)
%RUN_SHELL  system() wrapper with clean toolchain PATH + optional logging.
%   [rc, out] = run_shell(cmd) runs cmd and returns exit code + combined
%   stdout/stderr.
%
%   Name/value options:
%     'Dir'   <path>   run inside this directory (cd ...; cmd)
%     'Log'   <file>   also tee the transcript to this file
%     'Env'   <cellstr> extra 'VAR=val' assignments prepended to the command
%
%   PATH is prefixed with /usr/bin:/bin so host builds find the real GNU
%   assembler rather than the ~/.local/bin/as shadow present on this dev box.

ip = inputParser;
ip.addParameter('Dir', '');
ip.addParameter('Log', '');
ip.addParameter('Env', {});
ip.parse(varargin{:});
o = ip.Results;

pre = 'export PATH=/usr/bin:/bin:$PATH; ';
for k = 1:numel(o.Env)
    pre = [pre 'export ' o.Env{k} '; ']; %#ok<AGROW>
end
if ~isempty(o.Dir)
    pre = [pre 'cd ' o.Dir '; '];
end

[rc, out] = system([pre cmd]);

if ~isempty(o.Log)
    fid = fopen(o.Log, 'a');
    if fid > 0
        fprintf(fid, '$ %s\n%s\n[rc=%d]\n', cmd, out, rc);
        fclose(fid);
    end
end
end
