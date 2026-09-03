% inspect_phaseamb.m -- dump the Phase Ambiguity Estimation and Correction
% subsystem structure (blocks, the estimator's input ports + feeding lines)
% so the resolver-fix overlay can insert look-back Delay blocks correctly.
run('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/setup.m');
KIT='/mnt/onetb/scratch/qpsk_variants/jupiter_240k5_byte'; cd(KIT); addpath(KIT);
sys='commhdlQPSKTxRx';
load_system(sys);
pae = find_system(sys,'LookUnderMasks','all','FollowLinks','on', ...
    'BlockType','SubSystem','Name','Phase Ambiguity Estimation and Correction');
fprintf('=== Phase Ambiguity Est&Corr subsystems found: %d ===\n', numel(pae));
if isempty(pae),
  % try partial name
  pae = find_system(sys,'LookUnderMasks','all','FollowLinks','on','BlockType','SubSystem');
  for i=1:numel(pae), if contains(pae{i},'Phase Ambiguity'), fprintf('  candidate: %s\n', pae{i}); end; end
  return;
end
P = pae{1};
fprintf('PATH: %s\n', P);
fprintf('LinkStatus: %s\n', get_param(P,'LinkStatus'));
% list child blocks
ch = find_system(P,'SearchDepth',1,'LookUnderMasks','all','FollowLinks','on','Type','Block');
fprintf('\n=== child blocks (depth 1) ===\n');
for i=1:numel(ch)
  fprintf('  [%s] %s\n', get_param(ch{i},'BlockType'), strrep(ch{i},[P '/'],''));
end
% find the estimator subsystem
est = find_system(P,'SearchDepth',1,'LookUnderMasks','all','FollowLinks','on', ...
    'BlockType','SubSystem','Name','Phase Ambiguity Estimator');
if isempty(est)
  est = find_system(P,'SearchDepth',1,'LookUnderMasks','all','FollowLinks','on','BlockType','SubSystem');
  fprintf('\n(estimator by exact name not found; subsystems at depth1:)\n');
  for i=1:numel(est), fprintf('  %s\n', strrep(est{i},[P '/'],'')); end
end
if ~isempty(est)
  E=est{1};
  fprintf('\n=== ESTIMATOR block: %s ===\n', strrep(E,[P '/'],''));
  ph = get_param(E,'PortHandles');
  fprintf('num inports=%d\n', numel(ph.Inport));
  % port names (from the subsystem''s Inport blocks)
  inp = find_system(E,'SearchDepth',1,'BlockType','Inport');
  for i=1:numel(inp), fprintf('  inport %s = "%s"\n', get_param(inp{i},'Port'), get_param(inp{i},'Name')); end
  % what feeds each estimator inport
  fprintf('\n=== lines feeding estimator inports ===\n');
  for i=1:numel(ph.Inport)
    l = get_param(ph.Inport(i),'Line');
    if l==-1, fprintf('  inport %d: <unconnected>\n', i); continue; end
    src = get_param(l,'SrcBlockHandle');
    if src==-1, fprintf('  inport %d: line has no single src\n', i); continue; end
    sp = get_param(l,'SrcPortHandle');
    fprintf('  inport %d <- block "%s" (BlockType %s) port %d\n', i, ...
      strrep(getfullname(src),[P '/'],''), get_param(src,'BlockType'), get_param(sp,'PortNumber'));
  end
end
fprintf('\n=== Delay blocks in the subsystem (name : DelayLength) ===\n');
dl = find_system(P,'LookUnderMasks','all','FollowLinks','on','BlockType','Delay');
for i=1:numel(dl)
  try, len=get_param(dl{i},'DelayLength'); catch, len='?'; end
  fprintf('  %s : len=%s : sampletime=%s\n', strrep(dl{i},[P '/'],''), len, get_param(dl{i},'SampleTime'));
end
fprintf('INSPECT_DONE\n');
