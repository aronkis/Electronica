function rxfix_model_check()
% rxfix_model_check -- confirm the rxfix working model IS the deployed nodescr
% FEC Rx (deint->Viterbi->RxAlign->BIST, no descramble) and that the
% RxCaptureFromHW replay path exists. Structural, fast, no sim.
kit='/mnt/onetb/scratch/qpsk_variants/fec_jupiter_rxfix';
diary(fullfile(kit,'rxfix_model_check.log')); diary on;
c=onCleanup(@() diary('off')); %#ok<NASGU>
addpath(kit); % kit first so it shadows the repo copy
mdl='commhdlQPSKTxRx';
% ensure the kit's model is the one loaded (path-order)
w=which([mdl '.slx']); fprintf('which model: %s\n',w);
load_system(fullfile(kit,[mdl '.slx']));
allb=find_system(mdl,'LookUnderMasks','all','FollowLinks','on','Type','Block');
haveFEC = any(~cellfun('isempty',regexpi(allb,'Viterbi|FEC Decoder|Deinterleav','once')));
haveDescr = any(~cellfun('isempty',regexpi(allb,'Descrambler','once')));
haveCap  = any(~cellfun('isempty',regexpi(allb,'cap_out|cap_in|CAP_OUT','once')));
haveSkip = any(~cellfun('isempty',regexpi(allb,'skip','once')));
haveReplay = ~isempty(find_system(mdl,'SearchDepth',1,'BlockType','FromFile'));
fprintf('FEC(Viterbi/deint) present : %d\n', haveFEC);
fprintf('Descrambler present        : %d (expect 0 = nodescr)\n', haveDescr);
fprintf('cap regs present           : %d\n', haveCap);
fprintf('skip regs present          : %d\n', haveSkip);
fprintf('RxCaptureFromHW present    : %d\n', haveReplay);
% list any Viterbi / deint blocks
vb=allb(~cellfun('isempty',regexpi(allb,'Viterbi|Deinterleav|FEC Decoder|RxAlign|cap','once')));
fprintf('\n-- FEC / cap blocks --\n');
for i=1:numel(vb), fprintf('  %s\n', strrep(vb{i},[mdl '/'],'')); end
% FromFile filename + sampletime
ff=find_system(mdl,'SearchDepth',1,'BlockType','FromFile');
for i=1:numel(ff)
  fprintf('\nFromFile %s FileName=%s SampleTime=%s\n', get_param(ff{i},'Name'), get_param(ff{i},'FileName'), get_param(ff{i},'SampleTime'));
end
close_system(mdl,0);
fprintf('MODEL CHECK DONE\n');
end
