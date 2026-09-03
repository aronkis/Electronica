function run_all_ladders()
here = fileparts(mfilename('fullpath'));
caps = {'evm_swap_A','evm_swap_B','cp1_verdict2'};
offs = [0 80];
T = {};
for c = 1:numel(caps)
  for a = 1:numel(offs)
    tag = sprintf('t_%s_o%d', caps{c}, offs(a));
    iqf = fullfile(here, sprintf('win_%s_o%d.iq', caps{c}, offs(a)));
    fprintf('\n===== %s =====\n', tag);
    res = ladder_f1536(fullfile(here,tag), iqf, 0, 50);
    for k = 1:numel(res)
      T(end+1,:) = {caps{c}, offs(a), res(k).rung, res(k).nF, res(k).medEVM, res(k).meanEVM, res(k).p90}; %#ok<AGROW>
    end
  end
end
fid = fopen(fullfile(here,'ladder_all.csv'),'w');
fprintf(fid,'capture,off,rung,nF,medEVM,meanEVM,p90\n');
for i = 1:size(T,1)
  fprintf(fid,'%s,%d,%s,%d,%.4f,%.4f,%.4f\n',T{i,:});
end
fclose(fid);
fprintf('\nwrote ladder_all.csv (%d rows)\n', size(T,1));
end
