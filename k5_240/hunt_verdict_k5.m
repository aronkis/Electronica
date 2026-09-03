function T = hunt_verdict_k5(huntdir)
% hunt_verdict_k5  Per-event three-way verdict for an error_hunt session dir.
% For each ev<N>_seq<S>.iq (receiver-input window, rx-lpc) and its matching
% ev<N>_seq<S>_tap.iq (constellation window, rx2-lpc, mux mode 3):
%   AIR  = decode_seq_k5 on the input window   (what the air carried)
%   LIVE = decode_con_k5 on the tap window     (what the live loops delivered)
% and classifies the trigger seq (and any errored seqs in the windows):
%   AIR-DIRTY            errored in the input decode -> sample-carried (RF/channel)
%   LIVE-DIRTY           air-clean but errored in the constellation -> loop-state
%                        divergence between receiver input and FTS output
%   POST-CONSTELLATION   clean in BOTH decodes yet errored live -> demod/FEC/
%                        byte-DMA/host plane
%   NOT-COVERED          trigger seq absent from a window (ring timing miss)
% Prints one row per event; returns/saves a struct array (hunt_verdicts.mat).
%
% Usage: T = hunt_verdict_k5('/path/to/two_jup/hunt/20260712_..._fwd');

d=dir(fullfile(huntdir,'ev*_seq*.iq'));
names={d.name};
inputs=names(~contains(names,'_tap'));
assert(~isempty(inputs),'no ev*.iq input windows in %s',huntdir);
T=struct('ev',{},'seq',{},'air',{},'live',{},'verdict',{},'airres',{},'liveres',{});
for i=1:numel(inputs)
  nm=inputs{i};
  tok=regexp(nm,'ev(\d+)_seq(\d+)\.iq','tokens','once');
  if isempty(tok), continue; end
  evn=str2double(tok{1}); trig=str2double(tok{2});
  tapnm=strrep(nm,'.iq','_tap.iq');
  fprintf('=== ev%d trigger seq=%d ===\n',evn,trig);
  ra=[]; rl=[];
  try, ra=decode_seq_k5(fullfile(huntdir,nm),'label',sprintf('ev%d_air',evn));
  catch e, fprintf('  AIR decode failed: %s\n',e.message); end
  if exist(fullfile(huntdir,tapnm),'file')
    try, rl=decode_con_k5(fullfile(huntdir,tapnm),'label',sprintf('ev%d_live',evn));
    catch e, fprintf('  LIVE decode failed: %s\n',e.message); end
  else
    fprintf('  (no tap window)\n');
  end
  air=classify(ra,trig); live=classify(rl,trig);
  if strcmp(air,'ERR'), v='AIR-DIRTY';
  elseif strcmp(live,'ERR'), v='LIVE-DIRTY';
  elseif strcmp(air,'OK') && strcmp(live,'OK'), v='POST-CONSTELLATION';
  else, v='NOT-COVERED';
  end
  fprintf('  ev%d seq=%d: air=%s live=%s -> %s\n',evn,trig,air,live,v);
  T(end+1)=struct('ev',evn,'seq',trig,'air',air,'live',live,'verdict',v,...
                  'airres',ra,'liveres',rl); %#ok<AGROW>
end
fprintf('--- %s: %d events ---\n',huntdir,numel(T));
for v={'AIR-DIRTY','LIVE-DIRTY','POST-CONSTELLATION','NOT-COVERED'}
  fprintf('  %-18s %d\n',v{1},sum(strcmp({T.verdict},v{1})));
end
save(fullfile(huntdir,'hunt_verdicts.mat'),'T','-v7.3');
end

function s=classify(r,trig)
% OK / ERR / ABSENT for the trigger seq in a decode result
s='ABSENT';
if isempty(r) || ~isstruct(r) || ~isfield(r,'perFrame'), return; end
pf=r.perFrame; seqs=[pf.seq];
k=find(seqs==trig,1);
if isempty(k)
  % LOST inside the window still counts as an error against the trigger
  if any(strcmp({pf.class},'BITERR')) || (r.lost>0 && trig>=min(seqs) && trig<=max(seqs))
    if trig>=min(seqs) && trig<=max(seqs), s='ERR'; end
  end
  return;
end
if pf(k).errs>0 || strcmp(pf(k).class,'BITERR'), s='ERR'; else, s='OK'; end
end
