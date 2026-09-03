% payload_diff.m — diff decoded fail-capture payloads vs golden + cross-frame consistency
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
G=load('/mnt/onetb/scratch/qpsk_variants/k5_240/golden_k5.mat'); info120=double(G.msgBits(:)).';
codedGold=double(G.payload(:)).';   % interleaved coded golden payload bits
files={'soak/fail_10_035625_d2.iq','soak/fail_33_040727_d2.iq','soak/fail_90_043123_d2.iq'};
allinfo={}; allcoded={};
for fi=1:numel(files)
  [~,D]=soak_dumpbits_k5(files{fi},'label','dump');
  fprintf('%s: %d frames dumped\n',files{fi},numel(D.info));
  for k=1:numel(D.info)
    b=D.info{k}(1:120);
    e0=sum(b~=info120);
    besh=120; bs=0; for s=0:119, e=sum(circshift(b,[0 s])~=info120); if e<besh, besh=e; bs=s; end, end
    einv=sum((1-b)~=info120);
    fprintf('  f%d: err=%3d bestshift=%3d(@%d) inv=%3d bits(1:24)=%s\n',k,e0,besh,bs,einv,sprintf('%d',b(1:24)));
    allinfo{end+1}=b; %#ok<SAGROW>
    if numel(D.coded)>=k, allcoded{end+1}=D.coded{k}; end %#ok<SAGROW>
  end
end
n=numel(allinfo); fprintf('pairwise decoded-frame distances (of 120):\n');
for i=1:min(n,8), for j=i+1:min(n,8), fprintf(' d(%d,%d)=%d',i,j,sum(allinfo{i}~=allinfo{j})); end, end; fprintf('\n');
fprintf('golden  bits(1:24)=%s\n',sprintf('%d',info120(1:24)));
% coded-domain: raw demod coded bits vs golden coded (pre-Viterbi)
if ~isempty(allcoded)
  m=min(numel(allcoded{1}),numel(codedGold));
  for k=1:min(3,numel(allcoded))
    cerr=mean(allcoded{k}(1:m)~=codedGold(1:m));
    fprintf('coded-domain raw BER frame%d vs golden: %.3f (0.5=uncorrelated)\n',k,cerr);
  end
end
