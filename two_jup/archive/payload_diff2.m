addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
G=load('/mnt/onetb/scratch/qpsk_variants/k5_240/golden_k5.mat'); info120=double(G.msgBits(:)).'; TB=G.TB;
fprintf('TB=%d\n',TB);
files={'soak/fail_10_035625_d2.iq','soak/fail_90_043123_d2.iq'};
allb={};
for fi=1:numel(files)
  [~,D]=soak_dumpbits_k5(files{fi},'label','d');
  for k=1:numel(D.info)
    dec=D.info{k}; b=dec(TB+1:TB+120);
    e0=sum(b~=info120); z=sum(b==0);
    besh=120; bs=0; for s=0:119, e=sum(circshift(b,[0 s])~=info120); if e<besh, besh=e; bs=s; end, end
    fprintf('%s f%d: err=%3d zeros=%3d bestshift=%3d(@%d) bits(1:32)=%s\n',files{fi}(6:12),k,e0,z,besh,bs,sprintf('%d',b(1:32)));
    allb{end+1}=b; %#ok<SAGROW>
  end
end
fprintf('golden        bits(1:32)=%s (weight=%d)\n',sprintf('%d',info120(1:32)),sum(info120));
n=numel(allb); fprintf('pairwise distances: ');
for i=1:min(n,6), for j=i+1:min(n,6), fprintf('d(%d,%d)=%d ',i,j,sum(allb{i}~=allb{j})); end, end; fprintf('\n');
